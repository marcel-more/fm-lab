const { DuckDBInstance } = require('@duckdb/node-api');
const fs = require('fs');
const path = require('path');
const environment = require('./environment');
const solutions = require('./solutions');

/**
 * Ausbaustufe M: LRU-Connection-Pool statt Singleton.
 *
 * Eine READ_ONLY-DuckDB-Instanz je Lösung, Schlüssel `ctx.solution`
 * (Deckel FMLAB_DB_POOL_MAX, Default 3; LRU-Eviction schließt Instanz +
 * Sidecar sauber). Die ctx-ersten Signaturen aus dem Phase-1.5-Sweep bleiben
 * unverändert — nur das Innere dieses Moduls routet jetzt wirklich pro Lösung.
 *
 * RAM ist die harte Grenze: max_memory gilt PRO Instanz → poolMax × maxMemory
 * (+ RW-Sidecars) muss in den Host-RAM passen.
 *
 * Pool-Slot: { solutionId, promise, entry, pending, lastUsed }.
 * `promise` dedupliziert parallele Erst-Zugriffe (in-flight-Factory);
 * `pending` schützt Slots mit laufenden Queries vor der Eviction.
 */
const pool = new Map(); // solutionId → slot
let reloading = false;
// Die Referenz-DB ist lösungsUNabhängig (ein Attach-Ergebnis für alle Slots):
// entweder die Datei existiert oder nicht. Der letzte Attach-Versuch zählt.
let referenceAttached = false;
// fm_spec >= 1.13.0 ships the OS-affinity tables (step_os_affinity /
// function_os_affinity / runtime_os_matrix); older reference DBs stay valid —
// OS members degrade to 'skipped' instead of erroring (checked at attach time).
let referenceHasOsAffinity = false;
let pluginSpecAttached = false;

/**
 * Aktivieren einer Lösung ohne konvertierte DB: leere Platzhalter-DB anlegen,
 * damit der READ_ONLY-Open nicht scheitert — der bestehende Empty-State-
 * Mechanismus (ensureCoreStubs → db_empty=true) übernimmt danach.
 */
async function ensurePlaceholderDb(dbPath) {
  if (fs.existsSync(dbPath)) return;
  console.log(`Database not found — creating empty placeholder at: ${dbPath}`);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const tmp = await DuckDBInstance.create(dbPath);
  tmp.closeSync();
}

/** Pool-Factory: eine READ_ONLY-Instanz für genau eine Lösung aufbauen. */
async function createEntry(solutionId) {
  const dbPath = solutions.resolveDbPath(solutionId);
  await ensurePlaceholderDb(dbPath);
  console.log(`Connecting to DuckDB at: ${dbPath} (solution: ${solutionId})`);

  const instance = await DuckDBInstance.create(dbPath, {
    access_mode: 'READ_ONLY',
    max_memory: environment.duckdb.maxMemory,
    threads: String(environment.duckdb.threads),
  });
  const connection = await instance.connect();

  // Scan-heavy analytische Queries (z.B. /api/graph/subgraph: Recursive CTE über
  // ~800k ObjectLinks) sprengen sonst unter dem konservativen max_memory die
  // Buffer-Manager-Pins ("failed to pin block"). Insertion-Order-Erhaltung baut
  // große Zwischenpuffer auf, die wir nicht brauchen — alle Templates ordnen
  // explizit via ORDER BY. Abschalten senkt den Speicher-Peak deutlich (genau die
  // vom DuckDB-OOM-Hinweis empfohlene Maßnahme). Gilt für die ganze Verbindung.
  try {
    await (await connection.prepare('SET preserve_insertion_order = false')).run();
    console.log('  - preserve_insertion_order: false (memory tuning)');
  } catch (err) {
    console.warn(`  - preserve_insertion_order tuning skipped: ${err.message}`);
  }

  // DuckDB-Spill auf das DEDIZIERTE Volume lenken statt neben die DB. DuckDB
  // liest DUCKDB_TEMP_DIR NICHT nativ → ohne dieses SET landet großer Spill in
  // rest-api/db/…tmp, also auf dem macOS-Bind-Mount: das flutet die
  // File-Sharing-Schicht (Docker-„injecting event blocked"-Crash-Risiko) und
  // umgeht das eigens angelegte /duckdb_spill-Volume. Guarded: nur wenn die Env
  // gesetzt UND das Verzeichnis vorhanden ist (Nicht-Container → DuckDB-Default).
  const tempDir = process.env.DUCKDB_TEMP_DIR;
  if (tempDir && fs.existsSync(tempDir)) {
    try {
      const esc = (s) => s.replace(/'/g, "''");
      await (await connection.prepare(`SET temp_directory = '${esc(tempDir)}'`)).run();
      console.log(`  - temp_directory: ${tempDir} (spill off the bind mount)`);
      if (process.env.DUCKDB_MAX_TEMP) {
        await (await connection.prepare(`SET max_temp_directory_size = '${esc(process.env.DUCKDB_MAX_TEMP)}'`)).run();
        console.log(`  - max_temp_directory_size: ${process.env.DUCKDB_MAX_TEMP}`);
      }
    } catch (err) {
      console.warn(`  - temp_directory tuning skipped: ${err.message}`);
    }
  }

  console.log(`DuckDB connection established (READ_ONLY, solution: ${solutionId})`);

  const entry = { solutionId, dbPath, instance, connection };
  await ensureCoreStubs(entry);
  await attachReferenceDb(entry);
  await attachPluginSpecDb(entry);
  return entry;
}

/**
 * Slot beschaffen (lazy, in-flight-dedupliziert) und auf Bereitschaft warten.
 * Nach dem Anlegen eines NEUEN Slots wird der LRU-Überhang evictet.
 */
async function acquireSlot(solutionId) {
  let slot = pool.get(solutionId);
  if (!slot) {
    slot = { solutionId, promise: null, entry: null, pending: 0, lastUsed: Date.now() };
    slot.promise = createEntry(solutionId)
      .then((entry) => {
        slot.entry = entry;
        return entry;
      })
      .catch((err) => {
        // Fehlgeschlagene Factory nicht im Pool lassen — nächster Zugriff
        // versucht es frisch (z.B. nachdem die Kopie synchronisiert wurde).
        if (pool.get(solutionId) === slot) pool.delete(solutionId);
        throw err;
      });
    pool.set(solutionId, slot);
    evictOverflow(solutionId);
  }
  slot.lastUsed = Date.now();
  await slot.promise;
  return slot;
}

/** Slot-Ressourcen schließen (best-effort; wartet eine laufende Factory ab). */
async function closeSlot(slot) {
  let entry = null;
  try {
    entry = await slot.promise;
  } catch { /* Factory war schon gescheitert — nichts zu schließen */ }
  if (!entry) return;
  try { entry.connection.disconnectSync(); } catch { /* schon zu */ }
  try { entry.instance.closeSync(); } catch { /* schon zu */ }
  console.log(`Database connection closed (solution: ${slot.solutionId})`);
}

/**
 * LRU-Eviction über den Deckel hinaus. Slots mit laufenden Queries
 * (pending > 0) und der gerade angeforderte Slot sind tabu; sind alle tabu,
 * bleibt der Pool vorübergehend über dem Deckel (nächster acquire räumt auf).
 * Der Annotations-Sidecar der Lösung wird mitgeschlossen (gleiche Lebensdauer).
 */
function evictOverflow(keepId) {
  while (pool.size > environment.duckdb.poolMax) {
    let victimId = null;
    let victim = null;
    for (const [id, slot] of pool) {
      if (id === keepId) continue;
      if (slot.pending > 0) continue;
      if (!victim || slot.lastUsed < victim.lastUsed) { victimId = id; victim = slot; }
    }
    if (!victim) {
      console.warn(`[db] pool over capacity (${pool.size} > ${environment.duckdb.poolMax}) but all entries busy — eviction deferred`);
      return;
    }
    pool.delete(victimId);
    console.log(`[db] pool evict (LRU): ${victimId}`);
    closeSlot(victim); // async, nicht awaited — Queries laufen dort keine mehr
    require('./annotations-db').closeSolution(victimId);
  }
}

/** Boot-Pfad: Server-Default-Lösung öffnen (wie bisher initialize()). */
async function initialize() {
  const slot = await acquireSlot(solutions.getActiveSolutionId());
  return slot.entry.connection;
}

/**
 * Core-Tabellen-Stubs (TEMP, leer) anlegen, wenn die DB sie (noch) nicht hat.
 * Zwei Fälle, ein Mechanismus:
 *
 * 1. **Cluster-Layer** (`ObjectClusters`/`CommunityNames`): Die Graph-Atlas-Templates
 *    (graph_overview_aggregate/leaf/topology) referenzieren sie per `LEFT JOIN` — auch
 *    für group_dim=file/type. Fehlen sie (DB ohne fm-graph-cluster oder per force-rebuild
 *    gewischt), schlägt schon das BINDEN fehl (Catalog Error) und der GESAMTE Atlas bricht
 *    ab. Mit leerem Stub degradiert er sauber zu „keine Communities" (Frontend schaltet
 *    auf Datei+Komposition um und dimmt Community/Topologie).
 *
 * 2. **Universal-Kataloge** (`FilesCatalog`/`ObjectCatalog`/`ObjectLinks`): Auf einer
 *    frischen, NICHT konvertierten DB (z. B. die leere Platzhalter-DB des Docker-Erst-
 *    starts) existieren sie nicht. Das Home-Dashboard (`project_summary`/`object_counts`/
 *    `files_overview`) liefe sonst in „Table … does not exist" statt in den dafür
 *    vorgesehenen Leerzustand. Mit leeren Stubs laufen die Aggregate durch →
 *    `project_summary` meldet `db_empty=true` → das Frontend zeigt die „erst XML
 *    konvertieren"-Karte statt roter Fehler; Listen/Suche liefern leer statt Fehler.
 *
 * DuckDB erlaubt im READ_ONLY-Modus TEMP-Tabellen (rein In-Memory, kein Schreiben in die
 * Datei). Eine TEMP-Tabelle gleichen Namens wird von unqualifizierten Referenzen aufgelöst.
 * Die Stub-Spalten spiegeln das echte Schema, damit Queries, die einzelne Spalten
 * selektieren, nicht an einer fehlenden Spalte scheitern. Idempotent + reload-fest: läuft
 * in der Pool-Factory auf jeder frischen Verbindung; sobald die echte (konvertierte/
 * geclusterte) Tabelle existiert, entfällt der Stub.
 */
const CORE_STUB_DDL = {
  // Cluster-Layer — Atlas degradiert zu „keine Communities".
  ObjectClusters: `CREATE TEMP TABLE ObjectClusters (
     Object_UUID VARCHAR, File_Name VARCHAR, Community INTEGER, Engine VARCHAR
   )`,
  CommunityNames: `CREATE TEMP TABLE CommunityNames (
     Community INTEGER, Engine VARCHAR, Member_Count BIGINT,
     Dominant_Type VARCHAR, Dominant_File VARCHAR,
     Top_Member_UUID VARCHAR, Top_Member_Label VARCHAR, Sample_Labels VARCHAR[],
     Heuristic_Name VARCHAR, Semantic_Name VARCHAR, Semantic_Description VARCHAR
   )`,
  // Universal-Kataloge — frische/leere DB zeigt den designierten Empty-State statt Crash.
  FilesCatalog: `CREATE TEMP TABLE FilesCatalog (
     File_Name VARCHAR, File_FullName VARCHAR, File_UUID VARCHAR,
     FileMaker_Version VARCHAR, Has_DDR_INFO BOOLEAN,
     Import_Timestamp TIMESTAMP, XML_Path VARCHAR
   )`,
  ObjectCatalog: `CREATE TEMP TABLE ObjectCatalog (
     Object_UUID VARCHAR, Object_Type VARCHAR, Object_Name VARCHAR,
     File_Name VARCHAR, Source_Table VARCHAR, Object_ID BIGINT
   )`,
  ObjectLinks: `CREATE TEMP TABLE ObjectLinks (
     Source_UUID VARCHAR, Source_Type VARCHAR, Target_UUID VARCHAR, Target_Type VARCHAR,
     Link_Type VARCHAR, Link_Role VARCHAR, Link_Subrole VARCHAR,
     Source_File VARCHAR, Target_File VARCHAR, Is_Cross_File BOOLEAN
   )`,
  // Calculation-Objekttyp (Schema 1.22.0) — Detail-/Token-Templates und die
  // get-calc-Instanzliste laufen auf Alt-/Leer-DBs sonst in „Table … does not exist".
  CalculationsCatalog: `CREATE TEMP TABLE CalculationsCatalog (
     Calculation_UUID VARCHAR, Owner_UUID VARCHAR, Owner_Type VARCHAR, Owner_Name VARCHAR,
     Calc_Role VARCHAR, Calc_Kind_Raw VARCHAR, Calc_Index INTEGER, Edge_Subrole VARCHAR,
     Formula_Text VARCHAR, Formula_Hash VARCHAR, DDR_Calc_UUID VARCHAR,
     Context_TO_UUID VARCHAR, Context_TO_Name VARCHAR,
     Is_Static BOOLEAN, Chunk_Count BIGINT, Ref_Count BIGINT,
     Display_Text VARCHAR, Source_Path VARCHAR, File_Name VARCHAR
   )`,
  // v_calculation_links ist in konvertierten DBs eine View; der leere TEMP-Stub
  // deckt Alt-DBs (Schema < 1.22.0), in denen die View nie angelegt wurde.
  v_calculation_links: `CREATE TEMP TABLE v_calculation_links (
     Calculation_UUID VARCHAR, Link_Role VARCHAR, Target_UUID VARCHAR,
     Target_Type VARCHAR, Target_File VARCHAR, Is_Cross_File BOOLEAN
   )`,
};

// Läuft INNERHALB der Pool-Factory → direkt auf der Entry-Verbindung
// (kein executeQuery: das würde acquireSlot re-entrant aufrufen).
async function ensureCoreStubs(entry) {
  try {
    const names = Object.keys(CORE_STUB_DDL);
    const inList = names.map((n) => `'${n}'`).join(', ');
    const stmt = await entry.connection.prepare(
      `SELECT table_name FROM information_schema.tables
        WHERE table_name IN (${inList})`
    );
    const result = await stmt.run();
    const rows = await result.getRowObjectsJS();
    try { stmt.destroySync(); } catch { /* freigegeben */ }
    const present = new Set(rows.map((r) => r.table_name));
    for (const [name, ddl] of Object.entries(CORE_STUB_DDL)) {
      if (present.has(name)) continue;
      await (await entry.connection.prepare(ddl)).run();
      console.log(`  - core stub created (TEMP, empty): ${name} — not present yet`);
    }
  } catch (err) {
    // Nie fatal: ohne Stub crasht nur die betroffene Ansicht (wie bisher), der Rest läuft.
    console.warn(`  - core stub setup skipped: ${err.message}`);
  }
}

async function attachReferenceDb(entry) {
  const refPath = path.resolve(__dirname, '../../', environment.reference.duckdbPath);
  if (!fs.existsSync(refPath)) {
    referenceAttached = false;
    console.warn(`Reference-DB not found at ${refPath} — /api/reference endpoints will return 503.`);
    return false;
  }
  // ATTACH erlaubt READ_ONLY-Modus selbst auf einer READ_ONLY-Hauptverbindung
  // (getestet mit DuckDB 1.5.x).
  const escaped = refPath.replace(/'/g, "''");
  const stmt = await entry.connection.prepare(`ATTACH '${escaped}' AS ref (READ_ONLY)`);
  await stmt.run();
  referenceAttached = true;
  console.log(`Reference-DB attached as 'ref' from: ${refPath}`);
  try {
    const probe = await entry.connection.prepare(
      `SELECT COUNT(*) AS n FROM information_schema.tables
        WHERE table_catalog = 'ref'
          AND table_name IN ('step_os_affinity', 'function_os_affinity', 'runtime_os_matrix')`
    );
    const res = await probe.run();
    const rows = await res.getRowObjectsJS();
    try { probe.destroySync(); } catch { /* freigegeben */ }
    referenceHasOsAffinity = Number(rows[0]?.n || 0) === 3;
    if (!referenceHasOsAffinity) {
      console.warn('Reference-DB predates schema 1.13.0 — OS-affinity members will be skipped (re-run pull-reference.sh).');
    }
  } catch {
    referenceHasOsAffinity = false;
  }
  return true;
}

function isReferenceAttached() {
  return referenceAttached;
}

function hasOsAffinityTables() {
  return referenceAttached && referenceHasOsAffinity;
}

async function attachPluginSpecDb(entry) {
  const specPath = path.resolve(__dirname, '../../', environment.pluginSpec.duckdbPath);
  if (!fs.existsSync(specPath)) {
    pluginSpecAttached = false;
    console.warn(`Plugin-Spec-DB not found at ${specPath} — plugin platform members will be skipped (the file ships with every fm-lab release; restore it from the release checkout).`);
    return false;
  }
  const escaped = specPath.replace(/'/g, "''");
  const stmt = await entry.connection.prepare(`ATTACH '${escaped}' AS plugref (READ_ONLY)`);
  await stmt.run();
  pluginSpecAttached = true;
  console.log(`Plugin-Spec-DB attached as 'plugref' from: ${specPath}`);
  return true;
}

function isPluginSpecAttached() {
  return pluginSpecAttached;
}

/**
 * Fehlende Plugin-Spec-DB zu einem sprechenden Fehler veredeln: Queries, die
 * `plugref.*` referenzieren (SCA-Dashboards), scheitern ohne ATTACH mit einem
 * rohen Catalog-Error („… does not exist"). Der stabile englische
 * `PLUGSPEC_MISSING:`-Präfix (analog SCHEMA_DRIFT) lässt das Frontend eine
 * ruhige, handlungsfähige Notiz rendern. MUSS vor der Schema-Drift-
 * Klassifikation laufen — deren MISSING_TABLE-Muster matcht sonst zuerst und
 * empfähle fälschlich einen Re-Import.
 */
function classifyPluginSpecMissing(err) {
  if (pluginSpecAttached) return null;
  const message = (err && err.message) || '';
  if (!/\bplugref\b/.test(message) || !/does not exist/i.test(message)) return null;
  const e = new Error(
    'PLUGSPEC_MISSING: the plugin reference database (reference/plugin_spec.duckdb) is not installed — ' +
    'plugin platform and deprecation data is unavailable. It ships with every fm-lab release; ' +
    'restore the file from the release checkout.'
  );
  e.code = 'PLUGSPEC_NOT_ATTACHED';
  return e;
}

/** Pool-Eintrag einer Lösung schließen und entfernen (No-op, wenn keiner existiert). */
async function evictSolution(solutionId) {
  const slot = pool.get(solutionId);
  if (!slot) return false;
  pool.delete(solutionId);
  await closeSlot(slot);
  return true;
}

/**
 * Gezielter Reload: den Pool-Eintrag GENAU EINER Lösung invalidieren (Default:
 * Server-Default) — andere Lösungen/User arbeiten ungestört weiter. Der
 * Annotations-Sidecar der Lösung wird mitgeschlossen. Frisch geöffnet wird nur,
 * wenn vorher ein Eintrag existierte oder es der Server-Default ist — für eine
 * nie angefragte Lösung genügt die Invalidierung (Kopie liegt frisch bereit).
 */
async function reload(solutionId) {
  if (reloading) {
    throw new Error('Reload already in progress');
  }
  reloading = true;
  try {
    const id = solutionId || solutions.getActiveSolutionId();
    const hadEntry = pool.has(id);
    await evictSolution(id);
    await require('./annotations-db').closeSolution(id);

    if (!hadEntry && id !== solutions.getActiveSolutionId()) {
      return { status: 'invalidated', solution: id, tables: null, path: solutions.resolveDbPath(id) };
    }

    const slot = await acquireSlot(id);
    const result = await executeQuery({ solution: id, requested: null }, 'SELECT COUNT(*) AS c FROM duckdb_tables()');
    const tableCount = result.rows[0]?.c;
    return {
      status: 'reloaded',
      solution: id,
      tables: typeof tableCount === 'bigint' ? Number(tableCount) : tableCount,
      path: slot.entry.dbPath,
    };
  } finally {
    reloading = false;
  }
}

// ── Request-Kontext-Kontrakt ────────────────────────────────────────────────
// Ausbaustufe M: ctx.solution IST der Pool-Schlüssel. Die Legacy-Form
// (sql-first / argloses getConnection) läuft mit Server-Default weiter,
// warnt aber einmalig je Aufrufstelle.
const warnedLegacySites = new Set();

function callerSite() {
  const stack = String(new Error().stack || '').split('\n');
  const line = stack.find((l) => l.includes('/src/') && !l.includes('config/database.js'));
  return line ? line.trim() : 'unknown';
}

function warnLegacyOnce(fn) {
  const site = callerSite();
  if (warnedLegacySites.has(site)) return;
  warnedLegacySites.add(site);
  console.warn(`[db] DEPRECATED contextless ${fn}() call — pass the request context (req.solutionContext / solutions.serverDefaultContext()). At: ${site}`);
}

function normalizeContext(ctx, fn) {
  if (!ctx || typeof ctx.solution !== 'string') {
    warnLegacyOnce(fn);
    return solutions.serverDefaultContext();
  }
  return ctx;
}

/**
 * Synchroner Verbindungszugriff (Kompatibilität) — liefert die Verbindung der
 * Kontext-Lösung, sofern ihr Pool-Eintrag bereit ist. Neuer Code nutzt
 * executeQuery(); dieser Getter kann keinen Eintrag lazy öffnen.
 */
function getConnection(ctx) {
  const { solution } = normalizeContext(ctx, 'getConnection');
  const slot = pool.get(solution);
  if (!slot || !slot.entry) {
    throw new Error(`Database not initialized for solution '${solution}'. Call initialize() first.`);
  }
  slot.lastUsed = Date.now();
  return slot.entry.connection;
}

async function executeQuery(ctx, sql, params = []) {
  // Legacy-Form executeQuery(sql, params) tolerieren (Deprecation-WARN).
  if (typeof ctx === 'string') {
    params = Array.isArray(sql) ? sql : [];
    sql = ctx;
    ctx = null;
  }
  const { solution } = normalizeContext(ctx, 'executeQuery');
  const slot = await acquireSlot(solution);

  const startTime = Date.now();
  slot.pending += 1;

  let stmt = null;
  try {
    stmt = await slot.entry.connection.prepare(sql);
    if (params.length > 0) {
      stmt.bind(params);
    }
    const result = await stmt.run();
    const rows = await result.getRowObjectsJS();

    return {
      rows,
      meta: {
        execution_time_ms: Date.now() - startTime,
        result_count: rows.length,
      },
    };
  } catch (err) {
    console.error('Query execution failed:', err.message);
    console.error('SQL:', sql);
    console.error('Params:', params);
    // Fehlende Plugin-Spec-DB VOR der Drift-Prüfung erkennen — der plugref-
    // Catalog-Error matcht sonst das Drift-Muster und riete zum Re-Import.
    const plugMissing = classifyPluginSpecMissing(err);
    if (plugMissing) throw plugMissing;
    // Schema-Drift (Lösung mit älterem Katalog-Schema importiert als die App
    // erwartet) zu einem sprechenden SCHEMA_DRIFT-Fehler veredeln — zentral hier,
    // damit JEDES Template/Dashboard/Report profitiert. Nur bei nachgewiesenem
    // Drift; echte Template-Bugs bleiben unverändert (siehe utils/schema-drift).
    const drift = require('../utils/schema-drift').classifySchemaDrift({ solution }, err);
    throw drift || err;
  } finally {
    slot.pending -= 1;
    slot.lastUsed = Date.now();
    // Prepared Statement explizit freigeben. @duckdb/node-api hält die native
    // DuckDB-Ressource sonst bis zum GC — unter dem konservativen max_memory
    // akkumulieren scan-schwere Queries (z.B. /api/graph/subgraph) sonst bis
    // "failed to pin block". Die Engine selbst gibt pro Statement frei (im
    // CLI kein Leak); nur die ungeschlossenen Node-Handles stauen sich.
    if (stmt) {
      try { stmt.destroySync(); } catch { /* schon freigegeben / Reload */ }
    }
  }
}

/** Shutdown: alle Pool-Einträge schließen. */
async function close() {
  const slots = [...pool.values()];
  pool.clear();
  for (const slot of slots) {
    await closeSlot(slot);
  }
  referenceAttached = false;
  referenceHasOsAffinity = false;
  pluginSpecAttached = false;
}

async function getDatabaseStats(ctx) {
  const stats = {};
  const { solution } = normalizeContext(ctx || solutions.serverDefaultContext(), 'getDatabaseStats');

  try {
    const dbPath = solutions.resolveDbPath(solution);

    if (fs.existsSync(dbPath)) {
      const fileStats = fs.statSync(dbPath);
      stats.size_mb = Math.round((fileStats.size / 1024 / 1024) * 100) / 100;
    } else {
      stats.size_mb = 0;
    }

    const tableResult = await executeQuery({ solution, requested: null }, `
      SELECT COUNT(*) as table_count
      FROM duckdb_tables()
    `);
    const tableCount = tableResult.rows[0]?.table_count || 0;
    stats.table_count = typeof tableCount === 'bigint' ? Number(tableCount) : tableCount;

    stats.solution = solution;
    stats.database_path = dbPath;
    stats.connected = !!(pool.get(solution) && pool.get(solution).entry);
    stats.max_memory = environment.duckdb.maxMemory;
    stats.threads = environment.duckdb.threads;
  } catch (error) {
    console.error('Error getting database stats:', error);
  }

  return stats;
}

/**
 * Leichtgewichtige DuckDB-Memory-Probe für das Debug-Session-Log.
 * Summiert duckdb_memory().memory_usage_bytes (Buffer-Manager-Belegung über alle
 * Tags) + meldet die größten Einzel-Tags. Niemals werfen: bei (z.B. OOM-naher)
 * Fehlabfrage liefern wir { error } statt den Aufrufer zu kippen.
 *
 * Achtung: das ist eine ECHTE Extra-Query auf derselben Verbindung — sparsam
 * einsetzen (nur vor/nach einer instrumentierten Query, nicht pro Zeile).
 */
async function probeMemory(ctx) {
  const { solution } = normalizeContext(ctx || solutions.serverDefaultContext(), 'probeMemory');
  const slot = pool.get(solution);
  if (!slot || !slot.entry) return { error: 'no-connection' };
  try {
    const { rows } = await executeQuery(
      { solution, requested: null },
      `SELECT tag, memory_usage_bytes AS bytes
         FROM duckdb_memory()
        WHERE memory_usage_bytes > 0
        ORDER BY memory_usage_bytes DESC`
    );
    const toNum = (v) => (typeof v === 'bigint' ? Number(v) : Number(v) || 0);
    const total = rows.reduce((s, r) => s + toNum(r.bytes), 0);
    const top = rows.slice(0, 5).map((r) => ({ tag: r.tag, mb: +(toNum(r.bytes) / 1e6).toFixed(1) }));
    return { total_mb: +(total / 1e6).toFixed(1), top };
  } catch (err) {
    return { error: err.message };
  }
}

/** Diagnose (M5): aktuelle Pool-Belegung — für /api/admin/pool und Logs. */
function poolStatus() {
  return {
    max: environment.duckdb.poolMax,
    size: pool.size,
    entries: [...pool.values()].map((s) => ({
      solution: s.solutionId,
      ready: !!s.entry,
      pending: s.pending,
      last_used: new Date(s.lastUsed).toISOString(),
      path: s.entry ? s.entry.dbPath : null,
    })),
  };
}

module.exports = {
  initialize,
  getConnection,
  executeQuery,
  probeMemory,
  close,
  reload,
  evictSolution,
  poolStatus,
  getDatabaseStats,
  isReferenceAttached,
  hasOsAffinityTables,
  isPluginSpecAttached,
  classifyPluginSpecMissing, // exportiert für Unit-Tests
};
