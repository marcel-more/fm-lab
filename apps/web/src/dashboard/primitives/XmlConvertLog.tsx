import { API_BASE } from '../../config/apiBase';
import { useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import type { XmlConvertEventDetail, XmlConvertStatusDetail } from './XmlConvertControl';

/**
 * XmlConvertLog — Statuszeile + persistenter Log-Block für das Sub-Dashboard
 * "xml_convert". Lädt initial den letzten Run-Record via GET /api/xml/last-run/log
 * und hängt während einer laufenden Konvertierung neue Events live an, die per
 * `fmlab:xml-convert-event`-Window-Event vom XmlConvertControl gesendet werden.
 */

const PROGRESS_EVENT = 'fmlab:xml-convert-event';
const STATUS_EVENT = 'fmlab:xml-convert-status';

interface LastRun {
  run_id: string | null;
  started_at: string | null;
  finished_at: string | null;
  duration_ms: number | null;
  ok: boolean | null;
  processed: number;
  total: number;
  error_count: number;
  // Root-check skips (run record schema 2); null on older records.
  skipped_count?: number | null;
  events: Record<string, unknown>[];
}

function formatDuration(ms: number | null | undefined): string | null {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return null;
  const totalSec = Math.round(ms / 1000);
  const min = Math.floor(totalSec / 60);
  const sec = totalSec % 60;
  return `${min}:${String(sec).padStart(2, '0')} min`;
}

interface LogLine {
  ts?: string;
  text: string;
  level?: 'info' | 'warn' | 'error';
}

// Übersetzer-Signatur lokal, damit eventToLine ohne i18next-Typimport auskommt.
type Translate = (key: string, opts?: Record<string, unknown>) => string;

// Rendert ein Roh-Event in eine Log-Zeile. Wird bei JEDEM Render mit dem
// aktuellen `t` aufgerufen (die Komponente hält Roh-Events im State, keine
// fertigen Strings) — nur so übersetzt ein Sprachwechsel auch bereits
// angezeigte Zeilen um.
function eventToLine(evt: Record<string, unknown>, t: Translate): LogLine | null {
  switch (evt.event) {
    case 'start':
      return { text: t('xmlConvert.logStart', { defaultValue: '── Start ──' }), level: 'info' };
    case 'progress': {
      const phase = String(evt.phase ?? '');
      const pct = typeof evt.pct === 'number' ? evt.pct : Number(evt.pct ?? 0);
      const msg = evt.msg ? `: ${String(evt.msg)}` : '';
      return { text: `[${phase} ${pct}%]${msg}`, level: 'info' };
    }
    case 'file': {
      // Opt 2 (Log-Entrümpelung): Unveränderte Dateien erzeugen keine Log-Zeile —
      // die ⏭️-Status-Tabelle (file_skip) deckt sie ab. Die Live-Zähler
      // (processed/total) laufen unabhängig in der pushEvent-Logik weiter.
      // Root-Check-Skips (nicht unterstütztes Format) bekommen eine Zeile mit Grund.
      const status = String(evt.status ?? '');
      if (status === 'unchanged') return null;
      const filename = String(evt.filename ?? '');
      if (status === 'skipped') {
        const legacy = evt.reason === 'legacy_format';
        return {
          text: legacy
            ? t('xmlConvert.logSkippedFile', {
                defaultValue: '⊘ {{filename}} — FileMaker {{version}} export, not supported (re-export with FileMaker 19+)',
                filename,
                version: String(evt.source_version ?? '18'),
              })
            : t('xmlConvert.logSkippedFileUnknown', {
                defaultValue: '⊘ {{filename}} — no FileMaker XML export recognized, skipped',
                filename,
              }),
          level: 'warn',
        };
      }
      const idx = typeof evt.index === 'number' ? evt.index : Number(evt.index ?? 0);
      const total = typeof evt.total === 'number' ? evt.total : Number(evt.total ?? 0);
      const ok = evt.ok !== false;
      const marker = ok ? '✓' : '✗';
      return {
        text: `[${idx}/${total}] ${marker} ${filename}`,
        level: ok ? 'info' : 'error',
      };
    }
    case 'phase': {
      // Per-Phasen-Marker der 6-Phasen-Pipeline (P1–P6). `begin` als Divider
      // (wie Start/Beendet), `done` mit Dauer + produziertem Ergebnis.
      const id = String(evt.id ?? '');
      const name = String(evt.name ?? '');
      const head = [id, name].filter(Boolean).join(' · ');
      if (evt.state === 'done') {
        const dur = evt.duration ? ` · ${String(evt.duration)}` : '';
        const prod = evt.produced ? ` · ${String(evt.produced)}` : '';
        return { text: `✔ ${head}${dur}${prod}`, level: 'info' };
      }
      return { text: `── ${head} ──`, level: 'info' };
    }
    case 'log': {
      const level = (evt.level === 'warn' || evt.level === 'error') ? evt.level : 'info';
      return { text: String(evt.msg ?? ''), level };
    }
    case 'error':
      return { text: String(evt.message ?? evt.msg ?? 'Error'), level: 'error' };
    case 'reload':
      return {
        text: evt.ok === false
          ? t('xmlConvert.logReloadError', { defaultValue: 'Reload failed: {{error}}', error: String(evt.error ?? '') })
          : t('xmlConvert.logReloadOk', { defaultValue: 'Reload successful.' }),
        level: evt.ok === false ? 'error' : 'info',
      };
    case 'aborted': {
      const reason = String(evt.reason ?? '');
      if (reason === 'oom') {
        return {
          text: t('xmlConvert.logAbortedOom', {
            defaultValue: '⚠ Aborted — not enough memory (solution too large for this environment).',
          }),
          level: 'error',
        };
      }
      if (reason === 'no_importable_files') {
        return {
          text: t('xmlConvert.logAbortedNoInput', {
            defaultValue: '⚠ Aborted — no importable file ({{skipped}} skipped, {{failed}} failed of {{total}}).',
            total: Number(evt.total ?? 0),
            skipped: Number(evt.skipped ?? 0),
            failed: Number(evt.failed ?? 0),
          }),
          level: 'error',
        };
      }
      if (reason === 'incomplete') {
        return {
          text: t('xmlConvert.logAbortedIncomplete', {
            defaultValue: '⚠ Aborted — build incomplete (reference resolution failed).',
          }),
          level: 'error',
        };
      }
      return { text: t('xmlConvert.logAborted', { defaultValue: '── Aborted ──' }), level: 'warn' };
    }
    case 'done':
      return {
        text: evt.ok === false
          ? t('xmlConvert.logDoneError', { defaultValue: '── Finished with error (exit {{code}}) ──', code: evt.exit_code ?? '?' })
          : t('xmlConvert.logDone', { defaultValue: '── Finished ──' }),
        level: evt.ok === false ? 'error' : 'info',
      };
    default:
      return null;
  }
}

export function XmlConvertLog({}: PrimitiveProps) {
  const { t, i18n } = useTranslation('dashboard');
  const lang = i18n.language;
  const [run, setRun] = useState<LastRun | null>(null);
  // Roh-Events statt fertiger Zeilen: die Übersetzung passiert erst beim
  // Rendern (useMemo unten), damit ein Sprachwechsel das ganze Log umzieht.
  const [events, setEvents] = useState<Record<string, unknown>[]>([]);
  const [status, setStatus] = useState<'idle' | 'running' | 'done' | 'error'>('idle');
  const [liveCounts, setLiveCounts] = useState<{ processed: number; total: number; errorCount: number }>({
    processed: 0,
    total: 0,
    errorCount: 0,
  });
  const logRef = useRef<HTMLDivElement | null>(null);
  // Block 2 als Disclosure: erzwungen offen während eines Laufs, sonst
  // nach User-Toggle. Nach Lauf-Ende/Wiedereintritt default zugeklappt.
  const [userToggled, setUserToggled] = useState(false);
  // Kontext-Lösung der Import-Seite (?solution_id): das Protokoll gehört zur
  // Kontext-Lösung, nicht zwingend zur aktiven.
  const [searchParams] = useSearchParams();
  const contextSolution = searchParams.get('solution_id');
  const solutionQuery = contextSolution ? `?solution=${encodeURIComponent(contextSolution)}` : '';

  // Initial-Load: persistierter Run-Record.
  useEffect(() => {
    let cancelled = false;
    const apiBase = (API_BASE).replace(/\/+$/, '');
    (async () => {
      try {
        const res = await fetch(`${apiBase}/api/xml/last-run/log${solutionQuery}`);
        if (!res.ok) return;
        const json = await res.json();
        if (cancelled) return;
        const data = json?.data as LastRun | undefined;
        if (!data || !data.run_id) return;
        setRun(data);
        setEvents(data.events || []);
        setLiveCounts({
          processed: data.processed || 0,
          total: data.total || 0,
          errorCount: data.error_count || 0,
        });
      } catch {
        /* keine Daten verfügbar */
      }
    })();
    return () => { cancelled = true; };
  }, [solutionQuery]);

  // Live-Append: lauscht auf fmlab:xml-convert-event vom Control.
  useEffect(() => {
    const onEvt = (e: Event) => {
      const detail = (e as CustomEvent<XmlConvertEventDetail>).detail;
      if (!detail || !detail.evt) return;
      const evt = detail.evt;
      setEvents(prev => [...prev, evt]);

      if (evt.event === 'batch_start' || evt.event === 'file_start') {
        // Gesamtzahl steht damit schon vor dem ersten abgeschlossenen File —
        // batch_start kommt direkt nach der Dateisuche, file_start pro Datei;
        // sonst zeigt die Statuszeile bis dahin "0 von ?".
        const total = typeof evt.total === 'number' ? evt.total : Number(evt.total ?? 0);
        if (total) setLiveCounts(prev => ({ ...prev, total }));
      }
      if (evt.event === 'file') {
        const idx = typeof evt.index === 'number' ? evt.index : Number(evt.index ?? 0);
        const total = typeof evt.total === 'number' ? evt.total : Number(evt.total ?? 0);
        const okFile = evt.ok !== false;
        // Root-check skips are no errors (counted as skipped in the run record).
        const isError = !okFile && evt.status !== 'skipped';
        setLiveCounts(prev => ({
          processed: okFile ? Math.max(prev.processed, idx) : prev.processed,
          total: total || prev.total,
          errorCount: isError ? prev.errorCount + 1 : prev.errorCount,
        }));
      }
      if (evt.event === 'start') {
        // Bei Neustart Log und Counter resetten — der persistierte Record
        // wird beim done.ok=true gleich überschrieben.
        setEvents([{ event: 'start' }]);
        setLiveCounts({ processed: 0, total: 0, errorCount: 0 });
      }
    };
    window.addEventListener(PROGRESS_EVENT, onEvt);
    return () => window.removeEventListener(PROGRESS_EVENT, onEvt);
  }, []);

  // Status-Bus: Control teilt running/done/error mit.
  useEffect(() => {
    const onStatus = (e: Event) => {
      const detail = (e as CustomEvent<XmlConvertStatusDetail>).detail;
      if (!detail) return;
      setStatus(detail.status);
      if (detail.status === 'done' || detail.status === 'error') {
        setRun(prev => ({
          run_id: prev?.run_id || new Date().toISOString(),
          started_at: detail.startedAt || prev?.started_at || null,
          finished_at: detail.finishedAt || new Date().toISOString(),
          duration_ms: detail.durationMs ?? prev?.duration_ms ?? null,
          ok: detail.ok ?? (detail.status === 'done'),
          processed: liveCounts.processed,
          total: liveCounts.total,
          error_count: detail.errorCount ?? liveCounts.errorCount,
          events: [],
        }));
      }
    };
    window.addEventListener(STATUS_EVENT, onStatus);
    return () => window.removeEventListener(STATUS_EVENT, onStatus);
  }, [liveCounts]);

  // Abgeleitete Log-Zeilen — sprachabhängig, daher `lang` in den Deps.
  const lines = useMemo(() => {
    const out: LogLine[] = [];
    for (const evt of events) {
      const line = eventToLine(evt, t as Translate);
      if (line) out.push(line);
    }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [events, lang]);

  // Auto-Scroll auf neuestes Log-Ende.
  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight;
    }
  }, [lines]);

  // Statuszeile: drei Varianten — laufend, erfolgreich, fehlerhaft.
  // Bei abgeschlossenem Run zeigen wir zusätzlich die Dauer ("0:57 min")
  // an, sofern Backend bzw. Frontend `duration_ms` gesetzt haben.
  let statusText = '';
  let statusClass = 'xml-convert-status';
  if (status === 'running') {
    statusText = t('xmlConvert.statusRunning', {
      defaultValue: 'XML-Konvertierung läuft: {{processed}} von {{total}} Dateien verarbeitet',
      processed: liveCounts.processed,
      total: liveCounts.total || '?',
    }) as string;
    statusClass += ' xml-convert-status--running';
  } else if (run && run.finished_at) {
    const dt = new Date(run.finished_at);
    const tsLabel = Number.isNaN(dt.getTime()) ? run.finished_at : dt.toLocaleString(lang);
    const durLabel = formatDuration(run.duration_ms);
    if (run.ok && (run.error_count || 0) === 0) {
      statusText = durLabel
        ? (t('xmlConvert.statusOkWithDuration', {
            defaultValue: 'Datum: {{ts}}, Dauer: {{dur}}, erfolgreich ✅',
            ts: tsLabel,
            dur: durLabel,
          }) as string)
        : (t('xmlConvert.statusOk', {
            defaultValue: 'Datum: {{ts}}, erfolgreich ✅',
            ts: tsLabel,
          }) as string);
      statusClass += ' xml-convert-status--ok';
    } else if (run.ok === false && (run.error_count || 0) === 0) {
      // Failed without a counted file error — a clean self-abort (no importable
      // file, out of memory, incomplete build); the banner names the reason.
      statusText = durLabel
        ? (t('xmlConvert.statusAbortedWithDuration', {
            defaultValue: 'Datum: {{ts}}, Dauer: {{dur}}, abgebrochen 🚫',
            ts: tsLabel,
            dur: durLabel,
          }) as string)
        : (t('xmlConvert.statusAborted', {
            defaultValue: 'Datum: {{ts}}, abgebrochen 🚫',
            ts: tsLabel,
          }) as string);
      statusClass += ' xml-convert-status--error';
    } else {
      statusText = durLabel
        ? (t('xmlConvert.statusErrorWithDuration', {
            defaultValue: 'Datum: {{ts}}, Dauer: {{dur}}, {{count}} Fehler 🚫',
            ts: tsLabel,
            dur: durLabel,
            count: run.error_count || (run.ok === false ? 1 : 0),
          }) as string)
        : (t('xmlConvert.statusError', {
            defaultValue: 'Datum: {{ts}}, {{count}} Fehler 🚫',
            ts: tsLabel,
            count: run.error_count || (run.ok === false ? 1 : 0),
          }) as string);
      statusClass += ' xml-convert-status--error';
    }
  } else {
    statusText = t('xmlConvert.statusIdle', {
      defaultValue: 'Noch keine Konvertierung in dieser Sitzung gelaufen.',
    }) as string;
    statusClass += ' xml-convert-status--idle';
  }

  // open = running (erzwungen) || userToggled. Die Summary-Statuszeile bleibt
  // IMMER sichtbar; nur der Log-Body klappt auf/zu.
  const open = status === 'running' || userToggled;

  return (
    <details
      className="xml-convert-log-wrap"
      open={open}
      onToggle={(e) => setUserToggled((e.currentTarget as HTMLDetailsElement).open)}
    >
      <summary className={`${statusClass} xml-convert-log-summary disclosure-summary`}>{statusText}</summary>
      <div ref={logRef} className="xml-convert-log" role="log" aria-live="polite">
        {lines.length === 0 ? (
          <div className="xml-convert-log__empty">
            {t('xmlConvert.logEmpty', {
              defaultValue: 'Noch kein Log vorhanden.',
            })}
          </div>
        ) : (
          lines.map((l, i) => (
            <div key={i} className={`xml-convert-log__line xml-convert-log__line--${l.level || 'info'}`}>
              {l.text}
            </div>
          ))
        )}
      </div>
    </details>
  );
}
