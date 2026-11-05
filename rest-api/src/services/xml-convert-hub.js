const xmlConvert = require('./xml-convert');
const solutions = require('../config/solutions');
const environment = require('../config/environment');
const { performReload } = require('./system-reload');

/**
 * XML-Convert Broadcast-Hub.
 *
 * Entkoppelt den Konvertierungs-Lauf von der startenden HTTP-Anfrage: `POST
 * /api/xml/convert` startet den Job (202) und kehrt SOFORT zurück; der Lauf lebt
 * im Hub weiter, auch wenn der Client wegnavigiert (kein SIGTERM mehr durch
 * `res.on('close')`). Mehrere Clients abonnieren denselben Lauf über `GET
 * /api/xml/convert/stream` (Ring-Replay → Live-Tail), sodass ein Wiedereintritt
 * sofort den aktuellen Stand sieht statt des Default-States. Abbrechen geht nur
 * noch explizit über `cancel()` (POST /api/xml/convert/cancel).
 *
 * Run-Registry: der Hub führt eine `Map<solution_id, run>` —
 * parallele Importe VERSCHIEDENER Lösungen sind erlaubt (per-Solution-Lock),
 * Ring/Replay und Subscriber sind solution-scoped, damit User A nicht den
 * Fortschritt von User B eingespielt bekommt. Dieselbe Lösung doppelt → 409.
 * Globaler Concurrency-Deckel: `limits.maxConverts` (Default 1, Quelle
 * FMLAB_MAX_CONVERTS bzw. instance.json.limits) — Überschreitung → 429; er
 * zählt auch fremde (CLI-)Läufe über den per-Solution-Lock-Scan.
 *
 * Der Hub besitzt den vollen Lebenszyklus: Lauf → (exit 0) Reload NUR wenn die
 * Lauf-Lösung die aktive ist (No-op-Regel wie am Reload-Endpoint) → finales
 * `done`. Das Terminal-`done` sendet AUSSCHLIESSLICH der Hub (angereichert mit
 * exit_code); das eigene `done` des Konverters (emit_done, ohne exit_code) wird
 * beim Broadcast absorbiert — sonst sähen Subscriber das Paar "exit ?" + echter
 * Code als doppelte Endzeile. Persistenz bleibt in runConverter (transiente
 * import_progress-/chunk_*-Events landen im Live-`ring`, werden aber NICHT in
 * last_xml_run.json persistiert).
 */

const RING_CAP = 2000;

const activeRuns = new Map();     // solution_id → { run_id, solution, started_at, ring, subscribers, controller, … }
const lastSnapshots = new Map();  // solution_id → letzte Terminal-Events (für Subscriber ohne aktiven Lauf)

function isActive(solutionId) {
  if (solutionId) return activeRuns.has(solutionId);
  return activeRuns.size > 0;
}

/** Flaches { run_id, solution, started_at, phase, pct, processed, total } für getStatus(). */
function runMeta(run) {
  const p = run.lastProgress || {};
  return {
    run_id: run.run_id,
    solution: run.solution,
    started_at: run.started_at,
    phase: typeof p.phase === 'string' ? p.phase : null,
    pct: typeof p.pct === 'number' ? p.pct : null,
    processed: run.processed,
    total: run.total,
  };
}

function getActiveRunMeta(solutionId) {
  const id = solutionId || solutions.getActiveSolutionId();
  const run = activeRuns.get(id);
  return run ? runMeta(run) : null;
}

/**
 * Alle laufenden Importe (GET /api/xml/runs): Hub-Registry ∪
 * Lock-Scan (CLI-Läufe ohne Hub). Hub-Läufe tragen Phase/Progress, reine
 * Lock-Läufe nur PID/Quelle.
 */
function listRuns() {
  const runs = new Map();
  for (const run of activeRuns.values()) {
    runs.set(run.solution, { ...runMeta(run), source: 'api' });
  }
  try {
    for (const lock of xmlConvert.scanRunningLocks()) {
      if (runs.has(lock.solution)) continue;
      runs.set(lock.solution, {
        run_id: null,
        solution: lock.solution,
        started_at: lock.started_at,
        phase: null,
        pct: null,
        processed: null,
        total: null,
        source: lock.source || 'cli',
        pid: lock.pid,
      });
    }
  } catch (err) {
    console.warn(`[xml-convert-hub] lock scan skipped: ${err.message}`);
  }
  return Array.from(runs.values()).sort((a, b) => String(a.solution).localeCompare(String(b.solution)));
}

function safeWrite(res, evt) {
  try { res.write(`data: ${JSON.stringify(evt)}\n\n`); } catch { /* dead socket */ }
}

function broadcast(run, evt) {
  // (i) Ring (inkl. transienter Events — für feinen Catch-up), gekappt.
  run.ring.push(evt);
  if (run.ring.length > RING_CAP) {
    run.ring.splice(0, run.ring.length - RING_CAP);
  }
  // Flaches phase/pct + Zähler aus den bekannten Events ableiten (active_run).
  if (evt.event === 'progress') run.lastProgress = evt;
  if ((evt.event === 'batch_start' || evt.event === 'file_start') && typeof evt.total === 'number') {
    run.total = evt.total;
  }
  if (evt.event === 'file') {
    if (typeof evt.total === 'number') run.total = evt.total;
    if (typeof evt.index === 'number' && evt.ok !== false) {
      run.processed = Math.max(run.processed, evt.index);
    }
  }
  if (evt.event === 'import_progress') {
    if (typeof evt.processed === 'number') run.processed = evt.processed;
    if (typeof evt.total === 'number') run.total = evt.total;
  }
  // (ii) Fan-out an alle Subscriber dieses Laufs.
  for (const res of run.subscribers) safeWrite(res, evt);
}

function finishRun(run) {
  // Snapshot der letzten Events für Subscriber, die NACH dem Lauf eintreffen.
  lastSnapshots.set(run.solution, run.ring.slice(-80));
  // Live-Subscriber sauber schließen (das `done` haben sie bereits erhalten).
  for (const res of run.subscribers) {
    try { res.end(); } catch { /* already closed */ }
  }
  activeRuns.delete(run.solution);
}

/**
 * Startet einen Lauf für die Kontext-Lösung, entkoppelt von der Anfrage.
 * Wirft `ALREADY_RUNNING` (409), wenn für DIESE Lösung bereits ein Lauf (Hub
 * oder externes Lock) aktiv ist, und `MAX_CONVERTS` (429), wenn der globale
 * Deckel erreicht ist. Gibt `{ run_id }` zurück.
 */
function startRun({ changedOnly = true, solution } = {}) {
  const targetSolution = solution || solutions.getActiveSolutionId();
  if (activeRuns.has(targetSolution) || xmlConvert.isRunning(targetSolution)) {
    const err = new Error(`A conversion for solution '${targetSolution}' is already running.`);
    err.code = 'ALREADY_RUNNING';
    throw err;
  }
  // Globaler Deckel: Hub-Läufe + fremde lebendige Locks (CLI) zählen.
  const maxConverts = environment.limits.maxConverts;
  let liveCount = activeRuns.size;
  try {
    for (const lock of xmlConvert.scanRunningLocks()) {
      if (!activeRuns.has(lock.solution)) liveCount += 1;
    }
  } catch { /* Lock-Scan best-effort */ }
  if (liveCount >= maxConverts) {
    const err = new Error(`Concurrent-import limit reached (${liveCount}/${maxConverts}) — wait for a running import to finish.`);
    err.code = 'MAX_CONVERTS';
    err.running = listRuns();
    throw err;
  }

  const controller = new AbortController();
  const started_at = new Date().toISOString();
  const run = {
    run_id: started_at,
    solution: targetSolution,
    started_at,
    changed_only: changedOnly,
    ring: [],
    subscribers: new Set(),
    controller,
    lastProgress: null,
    processed: 0,
    total: 0,
  };
  activeRuns.set(targetSolution, run);

  // Lebenszyklus im Hub — NICHT an die startende Anfrage gebunden.
  (async () => {
    try {
      broadcast(run, { event: 'start', ts: started_at, changedOnly, solution: targetSolution });
      const { exit_code } = await xmlConvert.runConverter({
        // Kind-`done` absorbieren — das eine Terminal-`done` sendet der Hub unten.
        onEvent: (evt) => { if (evt?.event !== 'done') broadcast(run, evt); },
        signal: controller.signal,
        changedOnly,
        solution: targetSolution,
      });

      if (controller.signal.aborted) {
        // reason disambiguates a USER cancel from the converter's own memory/incomplete
        // self-abort (which also uses the `aborted` event, but with reason
        // oom/incomplete/no_importable_files).
        broadcast(run, { event: 'aborted', reason: 'cancelled' });
      } else if (exit_code === 0) {
        // Im --quiet-Modus triggert das Skript den Reload NICHT selbst (überlässt
        // ihn dem API-Caller). Stage M: gezielter Reload GENAU der Lauf-Lösung —
        // invalidiert nur deren Pool-Eintrag; eine nie angefragte Lösung wird
        // bloß invalidiert (status 'invalidated'), nicht geöffnet. Andere
        // Lösungen/User bleiben ungestört.
        try {
          const result = await performReload(targetSolution);
          broadcast(run, {
            event: 'reload',
            ok: true,
            tables: result.tables,
            ...(result.status === 'invalidated' ? { skipped: true, reason: 'pool entry invalidated' } : {}),
          });
        } catch (err) {
          broadcast(run, { event: 'reload', ok: false, error: err.message });
        }
        broadcast(run, { event: 'done', ok: true, exit_code: 0 });
      } else {
        // Exit 8 = insufficient memory (clean self-abort). Tag the terminal event so a
        // late subscriber that only sees the `done` still gets the memory reason.
        const doneEvt = { event: 'done', ok: false, exit_code };
        if (exit_code === 8) doneEvt.reason = 'oom';
        broadcast(run, doneEvt);
      }
    } catch (err) {
      broadcast(run, { event: 'error', message: err.message });
      broadcast(run, { event: 'done', ok: false, exit_code: -1 });
    } finally {
      finishRun(run);
    }
  })();

  return { run_id: started_at };
}

/**
 * Subscribe eines SSE-Response auf den Lauf EINER Lösung. Aktiver Lauf → Ring
 * replayen (Catch-up auf den aktuellen Stand) + zum Live-Tail registrieren
 * (true). Kein aktiver Lauf → letztes Terminal-Snapshot dieser Lösung bzw.
 * `idle` senden (false → Controller schließt).
 */
function subscribe(res, solutionId) {
  const id = solutionId || solutions.getActiveSolutionId();
  const run = activeRuns.get(id);
  if (!run) {
    const snapshot = lastSnapshots.get(id);
    if (snapshot && snapshot.length > 0) {
      for (const evt of snapshot) safeWrite(res, evt);
    } else {
      safeWrite(res, { event: 'idle' });
    }
    return false;
  }
  for (const evt of run.ring) safeWrite(res, evt);
  run.subscribers.add(res);
  return true;
}

function unsubscribe(res, solutionId) {
  if (solutionId) {
    const run = activeRuns.get(solutionId);
    if (run) run.subscribers.delete(res);
    return;
  }
  for (const run of activeRuns.values()) run.subscribers.delete(res);
}

/** Expliziter Abbruch (der EINZIGE Pfad zu child.kill). True, wenn ein Lauf lief. */
function cancel(solutionId) {
  const id = solutionId || solutions.getActiveSolutionId();
  const run = activeRuns.get(id);
  if (!run) return false;
  run.controller.abort();
  return true;
}

module.exports = {
  isActive,
  getActiveRunMeta,
  listRuns,
  startRun,
  subscribe,
  unsubscribe,
  cancel,
};
