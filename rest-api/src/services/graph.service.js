const fs = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const templateService = require('./template.service');
const db = require('../config/database');
const annotations = require('./annotations.service');
const debugSession = require('./debug-session.service');
const { buildFlowWays } = require('./graph-trace-flow-ways');
const ddrCoverage = require('./ddr-coverage');
const environment = require('../config/environment');
const settingsStore = require('../plugins/settings-store');
const { classifyIdTerm } = require('./object.service');
const { createError } = require('../middleware/error-handler');

/**
 * LRU-Cache für Subgraph-Antworten („LRU-Cache cacht (focus, depth,
 * direction, mode)"). Schlüssel = vollständige Parametermenge. Der Explorer
 * fragt denselben Fokus beim Filter-Togglen oft erneut ab — Cache spart die
 * Recursive-CTE. Invalidierung über TTL; nach einem convert-xml-Reload sind die
 * Daten neu, aber die kurze TTL fängt das praktisch ab (Worst Case: 5 min stale).
 */
const subgraphCache = new LRUCache({
  max: 200,
  ttl: 1000 * 60 * 5, // 5 min
});

function subgraphCacheKey(ctx, p) {
  return [
    ctx?.solution ?? '',
    p.focus, p.focus_file ?? '', p.depth, p.direction, p.mode,
    p.types ?? '', p.roles ?? '',
    p.include_builtins, p.node_limit, p.hub_degree,
  ].join('|');
}

/**
 * LRU-Cache für den Graph-Atlas (/api/graph/overview). Eigener Cache, gleiche
 * Mechanik/TTL wie subgraphCache. Atlas-Antworten sind read-heavy (jeder Ebenen-
 * Wechsel/Toggle fragt erneut) und rein aus stabilen Aggregaten gebaut → gut cachebar.
 */
const overviewCache = new LRUCache({
  max: 200,
  ttl: 1000 * 60 * 5, // 5 min
});

function overviewCacheKey(ctx, p) {
  return [
    ctx?.solution ?? '',
    p.view, p.level, p.segment_by,
    p.parent_community ?? '', p.parent_file ?? '', p.parent_type ?? '',
    p.weight, p.include_builtins, p.exclude_types ?? '', p.fold, p.limit,
    p.activity ? 1 : 0, p.activity_bulk ?? 'hide',
  ].join('|');
}

/**
 * Serialisierungs-Mutex für Overview-SQL-Ausführungen.
 *
 * Der Atlas feuert pro Ebene MEHRERE Full-Graph-Queries quasi gleichzeitig
 * (Haupt-Query + Typ-Universum der Filterleiste). Diese materialisieren je die
 * teure ClusterEdges/LogicalLinks-View — laufen sie auf der einen READ_ONLY-
 * Verbindung NEBENLÄUFIG, pinnen beide gleichzeitig Buffer-Blöcke und der Peak
 * sprengt das 2GB-Limit ("could not allocate block … 1.8 GiB/1.8 GiB used").
 * Serialisiert: nur EINE Overview-Query rechnet zur Zeit → Peak = Einzel-Query
 * (passt). Cache-Treffer umgehen den Lock (sofortige Antwort). Subgraph/Search
 * (fokus-skopiert, leicht) bleiben unberührt.
 */
let _overviewChain = Promise.resolve();
// Wie viele Overview-Jobs warten/laufen gerade im Lock? Wichtigstes Nebenläufigkeits-
// Signal für die OOM-Diagnose: feuert der Atlas Haupt- + Typ-Universum-Query
// gleichzeitig, steht hier 2 — und die Memory-Probe zeigt, ob die serialisierte
// Ausführung den Buffer trotzdem nicht zwischen den Jobs freigibt.
let _overviewInflight = 0;
function runExclusiveOverview(fn) {
  const result = _overviewChain.then(fn, fn);
  // Kette weiterführen, ohne Fehler zu verschlucken (nächster Job startet trotzdem).
  _overviewChain = result.then(() => undefined, () => undefined);
  return result;
}

/**
 * Graph Service (Subgraph-Backend)
 *
 * Liefert fokus-zentrierte k-Hop-Subgraphen aus ObjectCatalog/ObjectLinks.
 * SQL-Kern: templates/queries/system/graph/graph_subgraph.sql (Recursive CTE, mode=logical via
 * graph_logical_links.sql-Logik, Deckel + ehrliche Truncation).
 *
 * Dieser Service ist Core.
 */

function escapeLiteral(value) {
  return String(value).replace(/'/g, "''");
}

/**
 * P5-Naht — Community-Anreicherung, abgesichert gegen fehlende Tabellen.
 *
 * Bewusst NICHT als LEFT JOIN in graph_subgraph.sql: der Subgraph läuft READ_ONLY
 * gegen die rest-api-Kopie und muss funktionieren, BEVOR P5-Clustering jemals lief
 * (ein harter Join auf eine nicht existierende ObjectClusters-Tabelle würde den
 * GESAMTEN Explorer brechen). Stattdessen reichert der Service nach: existieren
 * ObjectClusters + CommunityNames, wird eine schlanke IN-(≤node_limit)-Abfrage
 * nachgeschoben; sonst bleiben community/communityName null (= Verhalten vor P5).
 * Hält den Subgraph cluster-unabhängig (kein convert-xml-Wiring).
 *
 * Memoisiert (einmal pro Prozess); clearCache() setzt zurück, damit ein Reload
 * (frisch geclusterte DB) die Tabellen neu erkennt.
 */
const _communityTablesPresent = new Map();

/**
 * Aktive Cluster-Engine (single active engine — fm-graph-cluster ersetzt die
 * Partition komplett). Wird als Live-Overlay-Key (`<engine>|<community>`) für
 * User-Community-Annotationen gebraucht und dem Frontend mitgegeben (Write-Key).
 * Memoisiert (pro Solution); clearCache() setzt zurück (nach Reload neu erkennen).
 */
const _activeEngine = new Map();

async function activeEngine(ctx) {
  const key = ctx?.solution ?? '';
  if (_activeEngine.has(key)) return _activeEngine.get(key);
  if (!(await communityTablesPresent(ctx))) { _activeEngine.set(key, ''); return ''; }
  let engine = '';
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT Engine FROM ObjectClusters WHERE Engine IS NOT NULL
        GROUP BY Engine ORDER BY COUNT(*) DESC LIMIT 1`
    );
    engine = r.rows[0]?.Engine ?? '';
  } catch {
    engine = '';
  }
  _activeEngine.set(key, engine);
  return engine;
}

async function communityTablesPresent(ctx) {
  const key = ctx?.solution ?? '';
  if (_communityTablesPresent.has(key)) return _communityTablesPresent.get(key);
  const result = await db.executeQuery(
    ctx,
    `SELECT COUNT(*) AS cnt FROM information_schema.tables
      WHERE table_name IN ('ObjectClusters', 'CommunityNames')`
  );
  const row = result.rows[0];
  const cnt = typeof row.cnt === 'bigint' ? Number(row.cnt) : row.cnt;
  const present = cnt === 2;
  _communityTablesPresent.set(key, present);
  return present;
}

/**
 * Setzt community (INT-Key, für die Farb-Bucketing-Palette) + communityName
 * (COALESCE(User_Name, Semantic_Name, Heuristic_Name), für Anzeige/Legende) und
 * den User-Sichtbarkeits-Flag `hidden` auf den Knoten. Mutiert `nodes` in place.
 *
 * Zwei unabhängige Nähte:
 *  - Community-Anreicherung: no-op ohne Cluster-Tabellen (Verhalten vor P5).
 *  - Node-Sichtbarkeit (User-Annotation): unabhängig vom Clustering, läuft auch
 *    ohne Cluster-Tabellen (no-op nur ohne Annotations-Sidecar).
 */
async function enrichCommunities(ctx, nodes) {
  if (nodes.length === 0) return;

  const keyOf = (uuid, file) => `${uuid}::${file ?? ''}`;

  // ── Node-Sichtbarkeit (immer, cluster-unabhängig) ──
  const hiddenSet = await annotations.getHiddenKeySet(ctx);
  for (const n of nodes) n.hidden = hiddenSet.has(keyOf(n.uuid, n.file));

  if (!(await communityTablesPresent(ctx))) {
    for (const n of nodes) { n.community = null; n.communityName = null; }
    return;
  }

  // Klon-Robustheit: ObjectClusters ist auf (Object_UUID, File_Name) gekeyt (Cluster-
  // Node-Key) → Community-Match DATEI-GENAU,
  // damit zwei Klone derselben UUID NICHT die Community teilen. Wir laden über die rohe
  // n.uuid (IN-Liste ≤ node_limit) und matchen client-seitig über den composite Key
  // `uuid::file` — exakt das Node-id-Format aus graph_subgraph.sql (NULL-File ⇒ bare uuid).
  const uuids = [...new Set(nodes.map((n) => n.uuid).filter(Boolean))];
  if (uuids.length === 0) return;
  const inList = uuids.map((u) => `'${escapeLiteral(u)}'`).join(',');
  const result = await db.executeQuery(
    ctx,
    `SELECT c.Object_UUID AS uuid,
            c.File_Name    AS file,
            c.Community    AS community,
            cn.Semantic_Name  AS semantic_name,
            cn.Heuristic_Name AS heuristic_name
       FROM ObjectClusters c
       LEFT JOIN CommunityNames cn
         ON cn.Community = c.Community AND cn.Engine = c.Engine
      WHERE c.Object_UUID IN (${inList})`
  );
  const byKey = new Map(result.rows.map((r) => [keyOf(r.uuid, r.file), r]));

  // Namens-Priorität 4-stufig: User_Name (Sidecar) > Semantic_Name (Copy,
  // live) > SemanticNameRestore (Sidecar — greift nach Force-Rebuild) >
  // Heuristic_Name (Copy). User-Namen überschreiben alles in der Legende.
  const commMap = await annotations.getCommunityAnnotationMap(ctx);
  const restoreMap = await annotations.getSemanticRestoreMap(ctx);
  const engine = await activeEngine(ctx);
  for (const n of nodes) {
    const hit = byKey.get(keyOf(n.uuid, n.file)) ?? null;
    n.community = hit ? Number(hit.community) : null;
    const ckey = n.community != null ? `${engine}|${n.community}` : null;
    const ann = ckey ? commMap.get(ckey) : null;
    const restore = ckey ? restoreMap.get(ckey) : null;
    n.communityName = ann?.userName
      ?? (hit ? hit.semantic_name : null)
      ?? restore?.semanticName
      ?? (hit ? hit.heuristic_name : null)
      ?? null;
  }
}

/**
 * Änderungs-Aktivität je Explorer-Knoten (Farbmodus „Aktivität" in Subgraph und
 * Trace) — dieselbe Klassenlogik wie Atlas und Dashboard (graph_node_activity.sql
 * mit dem shared activity block), über dieselbe UUID-IN-Liste wie die Community-
 * Anreicherung. Setzt je Knoten `activity` = { class, newestChange, newestAgeDays,
 * saves, undated } (null ohne Stempel-Katalog) und liefert den Kopf
 * `{ available, dataState }` für die Payload. Kostet ~10–15 ms (Datenstand +
 * Rang über alle Stempel) — bei Subgraphen von einigen 100 ms vernachlässigbar,
 * daher ohne Gate. Nie fatal: ein Fehler lässt die Knoten ohne Aktivität.
 */
async function enrichActivity(ctx, nodes) {
  const head = { available: await changeMetaPresent(ctx), dataState: null };
  for (const n of nodes) n.activity = null;
  if (!head.available || nodes.length === 0) return head;
  const uuids = [...new Set(nodes.map((n) => n.uuid).filter(Boolean))];
  if (uuids.length === 0) return head;
  try {
    const result = await templateService.executeTemplate(
      ctx,
      'graph_node_activity',
      { uuids: uuids.join(','), activity: true, activity_bulk: 'hide' },
      'report'
    );
    const byKey = new Map(result.data.map((r) => [r.node_key, r]));
    for (const n of nodes) {
      const r = byKey.get(`${n.uuid}::${n.file ?? ''}`);
      if (!r) continue;
      n.activity = {
        class: numOf(r.activity_class),
        newestChange: r.newest_change ?? null,
        newestAgeDays: r.newest_age_days === null || r.newest_age_days === undefined ? null : numOf(r.newest_age_days),
        saves: r.saves === null || r.saves === undefined ? null : numOf(r.saves),
        undated: r.undated === true,
      };
      if (!head.dataState && r.data_state) head.dataState = r.data_state;
    }
  } catch { /* älterer Katalog / Stub — Knoten bleiben ohne Aktivität */ }
  return head;
}

/**
 * Fokus-Auflösung im ObjectCatalog (clone-aware). Liefert den Existenz-/
 * Eindeutigkeits-Status, damit der Controller drei Fälle unterscheiden kann:
 *   - { exists:false }                    → Fokus unbekannt (404)
 *   - { exists:true, ambiguous:true }     → UUID in mehreren Dateien, ohne focus_file (409)
 *   - { exists:true, ambiguous:false }    → eindeutig (bzw. via focus_file eingegrenzt) → 200
 * Geteilte UUIDs entstehen bei geklonten/modularen Dateien.
 * @param {Object} ctx - Request-Kontext
 * @param {string} uuid
 * @param {string} [file] - optionaler File_Name (focus_file)
 */
async function objectFocusStatus(ctx, uuid, file) {
  const where = file
    ? `Object_UUID = '${escapeLiteral(uuid)}' AND File_Name = '${escapeLiteral(file)}'`
    : `Object_UUID = '${escapeLiteral(uuid)}'`;
  const result = await db.executeQuery(
    ctx,
    `SELECT File_Name FROM ObjectCatalog WHERE ${where}`
  );
  const files = [...new Set(result.rows.map((r) => r.File_Name))].sort();
  return { exists: result.rows.length > 0, ambiguous: !file && files.length > 1, files };
}

/**
 * Rückwärtskompatibler Existenz-Check (bare UUID, ignoriert Mehrdeutigkeit).
 */
async function objectExists(ctx, uuid, file) {
  const { exists } = await objectFocusStatus(ctx, uuid, file);
  return exists;
}

/** Validierte Query-Params → graph_subgraph.sql-Parameter (NULL für optionale CSV). */
function toSubgraphParams(p) {
  return {
    focus: p.focus,
    // Klon-Robustheit: focus_file an das Template durchreichen — der Walk seedet auf
    // (focus, focus_file) und folgt der Kante datei-genau (sonst merged eine geklonte
    // Fokus-UUID die Nachbarschaften aller Dateien). NULL → Katalog-Auflösung (Nicht-Klon).
    focus_file: p.focus_file ?? null,
    depth: p.depth,
    direction: p.direction,
    mode: p.mode,
    types: p.types ?? null,
    roles: p.roles ?? null,
    include_builtins: p.include_builtins,
    node_limit: p.node_limit,
    hub_degree: p.hub_degree,
  };
}

/**
 * Fokus-zentrierter Subgraph.
 * @param {Object} p - Joi-validierte Query-Params (Defaults bereits angewandt)
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getSubgraph(ctx, p) {
  const cacheKey = subgraphCacheKey(ctx, p);
  const cached = subgraphCache.get(cacheKey);
  if (cached) {
    return { payload: cached.payload, sql: cached.sql, cached: true };
  }

  const result = await templateService.executeTemplate(
    ctx,
    'graph_subgraph',
    toSubgraphParams(p),
    'report'
  );

  const nodes = [];
  const edges = [];
  let totalReachable = 0;
  let maxDepthReached = 0;

  // Getaggte Union partitionieren (row_kind = 'node' | 'edge').
  for (const r of result.data) {
    if (r.row_kind === 'node') {
      totalReachable = Number(r.total_reachable ?? 0); // auf jeder Knoten-Zeile identisch
      const depth = Number(r.depth ?? 0);
      if (depth > maxDepthReached) maxDepthReached = depth;
      nodes.push({
        id: r.id,            // composite (uuid::file) — eindeutiger Graph-Key bei Klonen
        uuid: r.uuid,        // rohe UUID für Navigation / Lazy-Expand / fmIDE
        label: r.label,
        type: r.type,
        file: r.file,
        depth,
        degree: Number(r.degree ?? 0),
        isHub: r.is_hub === true,
        isFocus: r.is_focus === true,
        community: null,      // P5-Naht — via enrichCommunities() gesetzt
        communityName: null,
      });
    } else if (r.row_kind === 'edge') {
      edges.push({
        id: r.id,
        source: r.source,
        target: r.target,
        role: r.role,
        subrole: r.subrole,
        linkType: r.link_type,
        crossFile: r.cross_file === true,
      });
    }
  }

  // P5-Naht: Community-Daten nachreichen (no-op ohne Cluster-Tabellen).
  await enrichCommunities(ctx, nodes);
  const activity = await enrichActivity(ctx, nodes);

  const payload = {
    focus: p.focus,
    activity,
    params: {
      depth: p.depth,
      direction: p.direction,
      mode: p.mode,
      types: p.types ?? null,
      roles: p.roles ?? null,
      includeBuiltins: p.include_builtins,
      nodeLimit: p.node_limit,
      hubDegree: p.hub_degree,
    },
    truncated: totalReachable > p.node_limit, // "no silent caps"
    stats: {
      nodeCount: nodes.length,
      edgeCount: edges.length,
      totalReachable,
      maxDepthReached,
    },
    nodes,
    edges,
  };

  subgraphCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/**
 * 1-Hop-Expansion eines Knotens (Lazy-Expand im Explorer).
 * = Subgraph mit depth=1 — kein eigenes Template nötig.
 */
async function getNeighbors(ctx, p) {
  return getSubgraph(ctx, { ...p, depth: 1 });
}

/**
 * Trace (selektiver Ablauf-Graph) — /api/graph/trace + /trace/entries.
 *
 * Gleiche Antwort-Grundform wie der Subgraph (nodes/edges/stats/truncated),
 * zusätzlich traceRole/traceDepth pro Knoten, traceKind pro Kante und der
 * data.trace-Block (Start, Einstiegspfad, Seeds, dynamicCalls-Blind-Spot).
 *
 * Cache-Key wird AUS DEM VALIDATOR-SCHEMA generiert (nicht von Hand gepflegt):
 * jeder fachliche Parameter des graphTrace-Schemas wandert automatisch in den
 * Key — ein beim Schema ergänzter Parameter kann nie mehr im Key fehlen.
 */
const traceCache = new LRUCache({ max: 200, ttl: 1000 * 60 * 5 });
const traceEntriesCache = new LRUCache({ max: 200, ttl: 1000 * 60 * 5 });

const TRACE_KEY_FIELDS = (() => {
  const { schemas } = require('../middleware/validator');
  return Object.keys(schemas.graphTrace.describe().keys)
    .filter((k) => !['format', 'meta', 'debug', 'way', 'way_dir'].includes(k))
    .sort();
})();

function traceCacheKey(ctx, p) {
  return [ctx?.solution ?? '', ...TRACE_KEY_FIELDS.map((k) => String(p[k] ?? ''))].join('|');
}

/** Object_Type des Startobjekts (v1-Typ-Weiche im Controller: Script/Layout). */
async function objectTypeOf(ctx, uuid, file) {
  const where = file
    ? `Object_UUID = '${escapeLiteral(uuid)}' AND File_Name = '${escapeLiteral(file)}'`
    : `Object_UUID = '${escapeLiteral(uuid)}'`;
  const result = await db.executeQuery(
    ctx,
    `SELECT Object_Type FROM ObjectCatalog WHERE ${where} LIMIT 1`
  );
  return result.rows[0]?.Object_Type ?? null;
}

/** Validierte Query-Params → graph_trace.sql-Parameter. */
function toTraceParams(p) {
  return {
    start: p.start,
    start_file: p.start_file ?? null,
    entry: p.entry ?? null,
    up_depth: p.up_depth,
    down_depth: p.down_depth,
    trigger_depth: p.trigger_depth,
    expand_up: p.expand_up,
    include_local_vars: p.include_local_vars,
    include_buttons: p.include_buttons,
    include_builtins: p.include_builtins,
    include_interaction_triggers: p.include_interaction_triggers,
    include_disabled: p.include_disabled === true,
    node_limit: p.node_limit,
    hub_degree: p.hub_degree,
    exclude: p.exclude ?? null,
    // „Quelle verfolgen“ aufwärts: Weg-IDs, deren Einstieg eine Ebene weiter geht
    expand_way: p.expand_way ?? null,
  };
}

/** JSON-Spalte des Templates (DuckDB liefert VARCHAR) → Objekt; leer → null. */
function parseTracePayload(v) {
  if (v === null || v === undefined || v === '') return null;
  return typeof v === 'string' ? JSON.parse(v) : v;
}

/**
 * Aufrufstelle ohne leere Felder (Nutzlast): null, false, 0 und [] entfallen;
 * `enabled` steht nur bei deaktivierten Schritten (false), fehlt = aktiv.
 * Der Anker (stepUuid, stepIndex, stepId) bleibt immer.
 */
function compactCallSite(site) {
  const out = {};
  for (const [k, v] of Object.entries(site)) {
    if (k === 'stepUuid' || k === 'stepIndex' || k === 'stepId') out[k] = v;
    else if (k === 'enabled') { if (v === false) out.enabled = false; }
    else if (k === 'guard' && v) {
      const g = {};
      for (const [gk, gv] of Object.entries(v)) if (gv !== null && gv !== undefined) g[gk] = gv;
      out.guard = g;
    } else if (v !== null && v !== undefined && v !== false && v !== 0
               && !(Array.isArray(v) && v.length === 0)) out[k] = v;
  }
  return out;
}

/** Wirkung je Script: [{ role, n }] (Template, nach Rolle sortiert) → { role: n }. */
function effectsObject(list) {
  const out = {};
  for (const e of list || []) out[e.role] = Number(e.n);
  return out;
}

/** Exclude-Items ('uuid' oder 'uuid::file') parsen — Reihenfolge-erhaltend. */
function parseExcludeItems(exclude) {
  if (!exclude) return [];
  return exclude
    .split(',')
    .filter((s) => s.trim() !== '')
    .map((item) => {
      const sep = item.indexOf('::');
      return sep === -1
        ? { id: item, uuid: item, file: null }
        : { id: item, uuid: item.slice(0, sep), file: item.slice(sep + 2) };
    });
}

/**
 * data.trace.excluded[] — katalog-aufgelöste Ausschlussliste. Bewusst
 * unabhängig vom Knoten-Set aufgelöst: ein Ausschluss, den der gedämpfte Trace
 * gar nicht mehr erreicht, muss als Chip sichtbar (und entfernbar) bleiben.
 * Unbekannte UUIDs bleiben mit label/type = null in der Liste (wirkungslos, kein Fehler).
 */
async function resolveExcluded(ctx, exclude) {
  const items = parseExcludeItems(exclude);
  if (items.length === 0) return [];
  const uuidList = [...new Set(items.map((i) => i.uuid))]
    .map((u) => `'${escapeLiteral(u)}'`)
    .join(', ');
  const result = await db.executeQuery(
    ctx,
    `SELECT Object_UUID, Object_Name, Object_Type, File_Name
     FROM ObjectCatalog WHERE Object_UUID IN (${uuidList})`
  );
  return items.map((i) => {
    const row = result.rows.find(
      (r) => r.Object_UUID === i.uuid
        && (i.file === null || (r.File_Name ?? '') === i.file)
    );
    return {
      id: i.id,
      uuid: i.uuid,
      file: i.file ?? row?.File_Name ?? null,
      label: row?.Object_Name ?? null,
      type: row?.Object_Type ?? null,
    };
  });
}

/**
 * Beschriftung von Graph-IDs (`uuid::file`) aus dem Katalog — für Knoten, die
 * eine Antwort nennt, ohne sie zu liefern. Unbekannte IDs fallen weg.
 * @returns {Promise<Array<{id: string, label: ?string, type: ?string, file: ?string}>>}
 */
async function resolveCatalogIds(ctx, ids) {
  if (!ids || ids.length === 0) return [];
  const items = ids.map((id) => {
    const sep = id.indexOf('::');
    return { id, uuid: sep === -1 ? id : id.slice(0, sep), file: sep === -1 ? null : id.slice(sep + 2) };
  });
  const uuidList = [...new Set(items.map((i) => i.uuid))].map((u) => `'${escapeLiteral(u)}'`).join(', ');
  const result = await db.executeQuery(
    ctx,
    `SELECT Object_UUID, Object_Name, Object_Type, File_Name
     FROM ObjectCatalog WHERE Object_UUID IN (${uuidList})`
  );
  const out = [];
  for (const i of items) {
    const row = result.rows.find((r) => r.Object_UUID === i.uuid && (r.File_Name ?? null) === i.file);
    if (row) out.push({ id: i.id, label: row.Object_Name ?? null, type: row.Object_Type ?? null, file: row.File_Name ?? null });
  }
  return out;
}

/**
 * Trace-Berechnung. `startType` kommt vom Controller (bereits für die
 * v1-Typ-Weiche aufgelöst) und bestimmt das effektive Einstiegs-Preset —
 * deckungsgleich mit der entry_sel-Logik im Template.
 *
 * Template 2.x ist schrittgenau (v_script_step_links, v_step_guards,
 * v_dataflow_edges) und verlangt Schema 1.43.0: ältere Kataloge antworten mit
 * SCHEMA_DRIFT, eine gescheiterte Datenfluss-Phase mit DATAFLOW_NOT_BUILT.
 * Die Wege beider Richtungen (trace.ways, overview, refs) baut
 * graph-trace-flow-ways.js aus den Vorgänger-, Einstiegs- und Aufwärts-Zeilen.
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getTrace(ctx, p, startType) {
  const cacheKey = traceCacheKey(ctx, p);
  const cached = traceCache.get(cacheKey);
  if (cached) {
    return { payload: cached.payload, sql: cached.sql, cached: true };
  }

  await assertDataflowAvailable(ctx);

  const result = await templateService.executeTemplate(
    ctx,
    'graph_trace',
    toTraceParams(p),
    'report'
  );

  const nodes = [];
  const edges = [];
  const seeds = [];
  const suggestions = []; // Hub-Score-Kandidaten (Node-Zeilen mit sugg_reason)
  const preds = [];       // Vorgänger je Knoten (Grundlage der Wege, nicht in der Antwort)
  const entries = [];     // Einstiegsgruppen je Script des Aufwärts-Walks
  const upinfo = [];      // Aufwärts-Knoten mit Aufrufer-Zahl (root / budget)
  const xpreds = [];      // „Quelle verfolgen“: Vorgänger je aufgeklapptem Weg
  const xupinfo = [];     // „Quelle verfolgen“: neue Knoten je aufgeklapptem Weg
  const dynamicCallSites = []; // Aufrufschritte ohne statisches Ziel
  let stepStats = {};
  let totalReachable = 0;
  let maxDepthReached = 0;
  let dynamicCalls = 0;

  // Getaggte Union partitionieren (row_kind = 'node' | 'edge' | 'seed').
  for (const r of result.data) {
    if (r.row_kind === 'node') {
      totalReachable = Number(r.total_reachable ?? 0); // auf jeder Knoten-Zeile identisch
      dynamicCalls = Number(r.dynamic_calls ?? 0);     // dito (Blind-Spot-Ausweis)
      const traceDepth = Number(r.trace_depth ?? 0);
      if (Math.abs(traceDepth) > maxDepthReached) maxDepthReached = Math.abs(traceDepth);
      nodes.push({
        id: r.id,
        uuid: r.uuid,
        label: r.label,
        type: r.type,
        file: r.file,
        depth: Number(r.depth ?? 0), // |traceDepth| — Subgraph-kompatibel
        degree: Number(r.degree ?? 0),
        isHub: r.is_hub === true,
        isFocus: r.is_focus === true,
        community: null,      // P5-Naht — via enrichCommunities() gesetzt
        communityName: null,
        traceRole: r.trace_role,
        traceDepth,
        isExcluded: r.is_excluded === true, // Boundary-Knoten
      });
      // Wirkung je Script: Zahl verschiedener Ziele je Touch-Rolle
      const nodePayload = parseTracePayload(r.payload);
      if (nodePayload?.effects) nodes[nodes.length - 1].effects = effectsObject(nodePayload.effects);
      if (r.sugg_reason) {
        suggestions.push({
          id: r.id,
          uuid: r.uuid,
          file: r.file,
          label: r.label,
          type: r.type,
          trigIn: Number(r.sugg_trig_in ?? 0),
          fanIn: Number(r.sugg_fan_in ?? 0),
          touchOut: Number(r.sugg_touch_out ?? 0),
          score: Number(r.sugg_score ?? 0),
          reason: r.sugg_reason,
        });
      }
    } else if (r.row_kind === 'edge') {
      const edge = {
        id: r.id,
        source: r.source,
        target: r.target,
        role: r.role,
        subrole: r.subrole,
        linkType: r.link_type,
        crossFile: r.cross_file === true,
        traceKind: r.trace_kind,
      };
      // Aufruf- und Navigationskanten: Aufrufstellen (Schritt, Bedingung,
      // Schleife, Parameter, Ergebnis-Leser) und Präzision (approx = ohne
      // Schritt-Anker, heute nur MBS FM.RunScript)
      const edgePayload = parseTracePayload(r.payload);
      if (edgePayload) {
        edge.precision = edgePayload.precision;
        edge.callSites = (edgePayload.callSites ?? []).map(compactCallSite);
      }
      edges.push(edge);
    } else if (r.row_kind === 'seed') {
      seeds.push({ uuid: r.uuid, label: r.label, type: r.type, file: r.file });
    } else if (r.row_kind === 'pred') {
      const pr = parseTracePayload(r.payload);
      preds.push({ id: r.id, label: r.label, type: r.type, file: r.file, ...pr });
    } else if (r.row_kind === 'blind') {
      const b = parseTracePayload(r.payload);
      dynamicCallSites.push({ id: r.id, script: r.source, file: r.file, ...b });
    } else if (r.row_kind === 'stats') {
      stepStats = parseTracePayload(r.payload) || {};
    } else if (r.row_kind === 'entry') {
      entries.push({ script: r.source, ...parseTracePayload(r.payload) });
    } else if (r.row_kind === 'upinfo') {
      upinfo.push({ id: r.id, label: r.label, type: r.type, file: r.file, ...parseTracePayload(r.payload) });
    } else if (r.row_kind === 'xpred') {
      xpreds.push({ id: r.id, label: r.label, type: r.type, file: r.file, ...parseTracePayload(r.payload) });
    } else if (r.row_kind === 'xupinfo') {
      xupinfo.push({ id: r.id, label: r.label, type: r.type, file: r.file, ...parseTracePayload(r.payload) });
    }
  }

  // Bedingte Aufrufe: Aufrufstellen an Script-Aufrufkanten innerhalb eines If
  const conditionalCalls = edges
    .filter((e) => e.role === 'calls_script' && e.callSites)
    .reduce((n, e) => n + e.callSites.filter((s) => (s.ifDepth ?? 0) > 0).length, 0);

  // P5-Naht: Community-Daten nachreichen (no-op ohne Cluster-Tabellen).
  await enrichCommunities(ctx, nodes);
  const activity = await enrichActivity(ctx, nodes);

  // Ausschlussliste katalog-aufgelöst (auch nicht mehr erreichte Einträge).
  const excluded = await resolveExcluded(ctx, p.exclude);

  // Wege beidseitig aus den Vorgängern, Einstiegsgruppen und blinden
  // Stellen; die Vorgänger selbst bleiben Arbeitsmaterial (Nutzlast).
  const focus = nodes.find((n) => n.isFocus);
  const startId = focus ? focus.id : `${p.start}${p.start_file ? `::${p.start_file}` : ''}`;
  const labels = new Map(nodes.map((n) => [n.id, { label: n.label, type: n.type, file: n.file }]));
  const waysLimit = p.ways_limit ?? 300;
  const built = buildFlowWays({
    startId, preds, blind: dynamicCallSites, entries, upinfo, labels,
    upDepth: p.up_depth, waysLimit, xpreds, xupinfo,
  });
  // Referenzen nur für Knoten außerhalb des Canvas (Schritte, gedeckelte Knoten,
  // Einstiegsobjekte); Sprungziele für Referenzen und abweichende Knoten.
  const refs = {};
  for (const [id, r] of Object.entries(built.refs)) {
    if (!labels.has(id)) refs[id] = r;
  }
  // Ereignis-Owner der Trigger-Wege eines Layout-Starts (Layout-Objekt, Feld
  // nach Feld-Anker, das Layout selbst) stehen weder im Canvas noch in den
  // Pfaden — Beschriftung aus dem Katalog
  const ownerIds = [...new Set(built.ways.map((w) => w.eventOwner).filter(
    (id) => id && !labels.has(id) && !refs[id]
  ))];
  for (const o of await resolveCatalogIds(ctx, ownerIds)) {
    refs[o.id] = { label: o.label, type: o.type, file: o.file, flowRole: 'entry' };
  }
  // Schritt und DynamicCall: nur die UUID des Scripts (`script`) statt eines
  // open-Ziels — Schritt-UUID und Datei stecken im Schlüssel der Referenz
  // (`<Step_UUID>::<Datei>` bzw. `<Step_UUID>#dyncall::<Datei>`), das Script
  // liegt in derselben Datei. Der Client öffnet das Script am Schritt (Nutzlast).
  const isStepRef = (r) => r.type === 'ScriptStep' || r.type === 'DynamicCall';
  for (const r of Object.values(refs)) {
    if (isStepRef(r) && r.scriptId) {
      const sep = r.scriptId.indexOf('::');
      r.script = sep === -1 ? r.scriptId : r.scriptId.slice(0, sep);
      delete r.scriptId;
      delete r.stepUuid;
    }
  }
  const refItems = Object.entries(refs)
    .filter(([, r]) => !isStepRef(r))
    .map(([id, r]) => {
      const sep = id.indexOf('::');
      return { id, uuid: sep === -1 ? id : id.slice(0, sep), type: r.type, file: r.file, ref: r };
    });
  await enrichTraceOpen(ctx, [...nodes, ...refItems], { omitSelf: true });
  for (const it of refItems) if (it.open) it.ref.open = it.open;

  const waysTruncated = built.stats.downTotal > built.stats.down || built.stats.upTotal > built.stats.up;
  const truncatedBy = [];
  if (totalReachable > p.node_limit) truncatedBy.push('node_limit');
  if (waysTruncated) truncatedBy.push('ways_limit');

  // Wirkung über den Trace: verschiedene Ziele je Touch-Rolle im Canvas
  const effectsTotal = {};
  {
    const seen = new Map();
    for (const e of edges) {
      if (e.traceKind !== 'touch') continue;
      if (!seen.has(e.role)) seen.set(e.role, new Set());
      seen.get(e.role).add(e.target);
    }
    for (const role of [...seen.keys()].sort()) effectsTotal[role] = seen.get(role).size;
  }

  const entry = startType === 'Script' ? 'script' : (p.entry ?? 'layout_runtime');
  const payload = {
    start: p.start,
    activity,
    params: {
      entry,
      upDepth: p.up_depth,
      downDepth: p.down_depth,
      triggerDepth: p.trigger_depth,
      expandUp: p.expand_up,
      includeLocalVars: p.include_local_vars,
      includeButtons: p.include_buttons,
      includeBuiltins: p.include_builtins,
      includeInteractionTriggers: p.include_interaction_triggers,
      includeDisabled: p.include_disabled === true,
      nodeLimit: p.node_limit,
      hubDegree: p.hub_degree,
      exclude: p.exclude ?? null,
      expandWay: p.expand_way ? String(p.expand_way).split(',') : [],
      waysLimit,
    },
    trace: {
      mode: 'flow',
      start: { uuid: p.start, file: p.start_file ?? null, type: startType ?? null },
      entry,
      seeds,
      excluded,
      // Score-absteigend — die Reihenfolge ist die Anzeige-Reihenfolge der Chips.
      suggestions: suggestions.sort((a, b) => b.score - a.score),
      // Wege beider Richtungen (dir down = „Ruft auf“, up = „Erreicht über“),
      // Nummern je Richtung; Weg 0 je Richtung als Übersicht; Beschriftung und
      // Schritt-Kontext der Knoten außerhalb des Canvas unter refs.
      ways: built.ways,
      overview: built.overview,
      refs,
      effectsTotal,
      // Blinde Stellen wie im Datenfluss-Modus als Zähler; die Aufrufschritte
      // selbst (by_name / unresolved, mit Anker am Script) unter sites.
      blindSpots: {
        dynamicCalls,
        unresolvedCalls: Number(stepStats.unresolvedCalls ?? 0),
        sites: dynamicCallSites,
        // Files without DDR info the trace touches: formula references (fields
        // read, parameters, results) are missing there, effects undercount.
        noDdr: ddrCoverage.noDdrBlindSpot(
          (await ddrCoverage.loadDdrCoverage(ctx)).noDdr,
          [p.start_file, ...nodes.map((n) => n.file), ...Object.values(refs).map((r) => r.file)]
        ),
      },
      stats: {
        dynamicCalls,
        unresolvedCalls: Number(stepStats.unresolvedCalls ?? 0),
        disabledSteps: Number(stepStats.disabledSteps ?? 0),
        conditionalCalls,
        ways: { down: built.stats.down, up: built.stats.up },
        waysTotal: { down: built.stats.downTotal, up: built.stats.upTotal },
        truncatedBy,
      },
    },
    truncated: totalReachable > p.node_limit, // "no silent caps"
    stats: {
      nodeCount: nodes.length,
      edgeCount: edges.length,
      totalReachable,
      maxDepthReached,
      dynamicCalls,
    },
    nodes,
    edges,
  };

  // Mermaid je Weg und je Übersicht beider Richtungen (ways_mermaid)
  if (p.ways_mermaid === true) {
    const { buildFlowWayMermaid } = require('./graph-trace-mermaid');
    const idMap = (built) => Object.fromEntries([...built.ids].map(([key, nid]) => [nid, key]));
    for (const w of payload.trace.ways) {
      const built = buildFlowWayMermaid(payload, w.wayNo, { dir: w.dir });
      w.mermaid = built.text;
      w.mermaidIds = idMap(built);
    }
    payload.trace.overviewMermaid = {};
    payload.trace.overviewMermaidIds = {};
    for (const dir of ['down', 'up']) {
      const built = buildFlowWayMermaid(payload, 0, { dir });
      payload.trace.overviewMermaid[dir] = built.text;
      payload.trace.overviewMermaidIds[dir] = idMap(built);
    }
  }

  traceCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/**
 * Datenfluss-Tabellen vorhanden? Fehlen sie, entscheidet die Schema-Version der
 * Lösung: älteres Schema → SCHEMA_DRIFT (neu konvertieren), aktuelles Schema →
 * DATAFLOW_NOT_BUILT (die nicht abschaltbare Phase ist beim Import gescheitert;
 * convert_fm_xml.sh entfernt dann die halb gebauten Tabellen). Bewusst
 * ohne REST-Stub — ein leerer Stub würde den Zustand verdecken.
 */
async function assertDataflowAvailable(ctx) {
  const result = await db.executeQuery(
    ctx,
    `SELECT COUNT(*) AS cnt FROM information_schema.tables WHERE table_name = 'v_dataflow_edges'`
  );
  if (numOf(result.rows[0]?.cnt) > 0) return;
  const { classifySchemaDrift } = require('../utils/schema-drift');
  const drift = classifySchemaDrift(
    ctx, new Error('Table with name v_dataflow_edges does not exist!')
  );
  if (drift) throw drift;
  throw createError(
    'DATAFLOW_NOT_BUILT',
    'The dataflow tables are missing in this catalog — the dataflow phase failed during'
      + ' the import (see the import log); re-import the solution',
    { solution: ctx?.solution ?? null, table: 'v_dataflow_edges' }
  );
}

/** Validierte Query-Params → graph_trace_data.sql-Parameter. */
function toDataTraceParams(p, labelsAll, prof, anchor = null) {
  return {
    start: p.start,
    start_file: p.start_file ?? null,
    dir: p.dir,
    field_levels: p.field_levels,
    var_levels: p.var_levels,
    step_limit: p.step_limit,
    call_context: p.call_context,
    include_control: p.include_control,
    include_sinks: p.include_sinks,
    node_limit: p.node_limit,
    exclude: p.exclude ?? null,
    expand_way: p.expand_way ?? null,
    include_reset: p.include_reset === true,
    ways_limit: p.ways_limit ?? 300,
    labels_all: labelsAll === true,
    // Lösungsprofil: aufgelöste Knotenlisten der bestätigten Regeln (leer = aus)
    prof_layouts: prof && prof.layouts.length ? prof.layouts.join(',') : null,
    prof_scripts: prof && prof.scripts.length ? prof.scripts.join(',') : null,
    prof_ui_vars: prof && prof.uiVars.length ? prof.uiVars.join(',') : null,
    prof_hub_vars: prof && prof.hubVars.length ? prof.hubVars.join(',') : null,
    // Schritt-Anker: nur für lokale Startvariablen, Rolle aufgelöst
    start_step: anchor ? anchor.uuid : null,
    start_role: anchor ? anchor.role : null,
  };
}

/**
 * Schritt-Anker einer Variablen-Startes: prüft, dass die Variable
 * lokal ist und der Schritt sie in der verlangten Rolle liest bzw. setzt.
 * Rolle ohne Angabe: Herkunft (up) → `read`, wenn der Schritt liest, sonst
 * `set`; Verwendung (down) → `set`. Globale Variablen: Anker ohne Wirkung
 * (`null` — Setzer und Leser liegen in beliebigen Scripts).
 * @returns {Promise<null|{uuid, file, role, roles, stepIndex, stepName, scriptUuid, scriptName}>}
 */
async function resolveStartStep(ctx, p, startType) {
  if (!p.start_step) return null;
  if (startType !== 'Variable') {
    throw createError('VALIDATION_ERROR', `start_step is only valid for a Variable start (start is a ${startType})`,
      { start: p.start, start_step: p.start_step });
  }
  const lit = (v) => `'${escapeLiteral(String(v))}'`;
  const fileCond = p.start_file ? `AND v.File_Name = ${lit(p.start_file)}` : '';
  const scope = (await db.executeQuery(ctx,
    `SELECT any_value(v.Variable_Scope) AS scope, any_value(v.File_Name) AS file
       FROM VariablesCatalog v
      WHERE md5(v.Variable_Scope || '::' || v.Scope_Anchor || '::' || v.Variable_Name) = ${lit(p.start)} ${fileCond}`
  )).rows[0];
  if (!scope || scope.scope !== 'local') return null;
  const file = p.start_file || scope.file;
  const rows = (await db.executeQuery(ctx,
    `SELECT l.Link_Role AS role, l.Step_Index AS step_index, l.Step_Name AS step_name,
            l.Script_UUID AS script_uuid, sc.Script_Name AS script_name
       FROM v_script_step_links l
       LEFT JOIN ScriptCatalog sc ON sc.Script_UUID = l.Script_UUID AND sc.File_Name = l.File_Name
      WHERE l.Step_UUID = ${lit(p.start_step)} AND l.File_Name = ${lit(file)}
        AND l.Target_UUID = ${lit(p.start)} AND l.Link_Role IN ('sets_variable', 'reads_variable')`
  )).rows;
  const roles = [...new Set(rows.map((r) => (r.role === 'sets_variable' ? 'set' : 'read')))].sort();
  const role = p.start_role || (p.dir === 'up' ? (roles.includes('read') ? 'read' : 'set') : 'set');
  if (!roles.includes(role)) {
    throw createError('TRACE_STEP_ROLE',
      roles.length === 0
        ? `Step '${p.start_step}' neither reads nor sets this variable`
        : p.dir === 'down' && role === 'set'
          ? 'Usage needs a step that sets the variable; this step only reads it'
          : `Step '${p.start_step}' does not ${role === 'set' ? 'set' : 'read'} this variable`,
      { start: p.start, start_step: p.start_step, roles, role, dir: p.dir });
  }
  if (p.dir === 'down' && role === 'read') {
    throw createError('TRACE_STEP_ROLE', 'Usage needs a step that sets the variable (start_role=set)',
      { start: p.start, start_step: p.start_step, roles, role, dir: p.dir });
  }
  const r = rows[0];
  return {
    uuid: p.start_step,
    file,
    role,
    roles,
    stepIndex: r.step_index === null || r.step_index === undefined ? null : Number(r.step_index),
    stepName: r.step_name ?? null,
    scriptUuid: r.script_uuid ?? null,
    scriptName: r.script_name ?? null,
  };
}

/**
 * Offene Profil-Kandidaten, die dieser Trace berührt: Layouts der Einstiegs-
 * gruppen (H1, Name), Scripts/Parameter/Ergebnisse (H2) und Variablen (H3/H4)
 * unter den Knoten.
 */
function candidatesOnTrace(candidates, nodes, ways) {
  const ids = new Set(nodes.map((n) => n.id));
  for (const w of ways) for (const id of w.pathNodes || []) ids.add(id);
  const layoutNames = new Set();
  for (const w of ways) for (const g of w.entryGroups || []) for (const l of g.layouts || []) layoutNames.add(l.name);
  const hit = (c) => {
    if (c.kind === 'technical_layout') return layoutNames.has(c.pattern);
    if (c.kind === 'boundary_script') {
      return ids.has(`${c.uuid}::${c.file}`) || ids.has(`${c.uuid}#param::${c.file}`)
        || ids.has(`${c.uuid}#result::${c.file}`);
    }
    return ids.has(`${c.uuid}::${c.file}`);
  };
  return candidates
    .filter((c) => c.status === 'open' && hit(c))
    // Regel-Schlüssel (pattern bzw. uuid + file) mitliefern: das Panel bestätigt
    // bzw. verwirft den Kandidaten damit direkt per PUT /trace/profile.
    .map((c) => ({
      key: c.key,
      heuristic: c.heuristic,
      kind: c.kind,
      name: c.name,
      uncertain: c.uncertain,
      ...(c.pattern !== undefined && c.pattern !== null ? { pattern: c.pattern } : { uuid: c.uuid, file: c.file }),
    }));
}

const intOrNull = (v) => (v === null || v === undefined ? null : Number(v));

/** Template-Knotenzeile → Knoten der Antwort. */
function dataTraceNode(r) {
  return {
    id: r.id,
    uuid: r.uuid,
    label: r.label,
    type: r.type,
    file: r.file,
    depth: intOrNull(r.depth),
    degree: 0,
    isHub: false,
    isFocus: r.is_focus === true,
    community: null,
    communityName: null,
    flowRole: r.flow_role,
    fieldLevel: intOrNull(r.field_level),
    varLevel: intOrNull(r.var_level),
    isLeaf: r.is_leaf === true,
    isExcluded: r.is_excluded === true,
    // Pseudoknoten (Parameter, Ergebnis, Auto-Eingabe, …): Klick führt zum Eigentümer
    isPseudo: r.owner_uuid !== null && r.owner_uuid !== undefined,
    ownerUuid: r.owner_uuid ?? null,
    ownerType: r.owner_type ?? null,
    stepIndex: intOrNull(r.step_index),
    stepId: intOrNull(r.step_id),
    scriptUuid: r.script_uuid ?? null,
    // Haltepunkt des Lösungsprofils (Regelart) — sichtbar, aber nicht expandiert
    profileStop: r.profile_stop ?? null,
  };
}

/**
 * Sprungziel eines Trace-Knotens (Klick in Wege-Liste und Mermaid-Weg; Datenfluss-
 * und Ablauf-Modus):
 * `open = { type, uuid, file, ref?, step?, var? }` — das Objekt, das die
 * Detailansicht öffnet, dazu der hervorzuhebende Unterknoten (`ref`), der
 * Schritt-Anker (`step`) bzw. die Variablen-Auswahl (`var`, `<scope>:<name>`).
 *
 * - Schritt → Script am Schritt; Layout-Objekt → Layout mit Objekt; Menübefehl →
 *   Menü mit Befehl; Datei → Dateiansicht (`type: 'File'`).
 * - Berechnung und Pseudoknoten (Parameter, Ergebnis, Auto-Eingabe, Import-Quelle,
 *   dynamisches Ziel …) springen zu ihrem Eigentümer — und von dort nach den
 *   Regeln oben (eine Berechnung im Schritt öffnet das Script am Schritt).
 * - Lokale Variable → ihr Script mit Variablen-Auswahl; globale → Variable selbst.
 * - Sonst das Objekt selbst.
 * @param {Object} ctx
 * @param {Array<{id:string, uuid:string, type:string, file:?string, ownerUuid:?string, ownerType:?string}>} items
 * @param {Object} [opts]
 * @param {boolean} [opts.omitSelf] - kein `open`, wenn es nur auf den Knoten selbst zeigt
 *   (Ablauf-Modus: hält die Nutzlast klein; der Client fällt auf den Knoten zurück)
 */
async function enrichTraceOpen(ctx, items, opts = {}) {
  if (items.length === 0) return;
  const lit = (v) => `'${escapeLiteral(String(v))}'`;
  const pairs = (list) => [...new Map(list.map((x) => [`${x.uuid}::${x.file ?? ''}`, x])).values()]
    .map((x) => `(${lit(x.uuid)}, ${lit(x.file ?? '')})`).join(',');
  const query = async (sql) => (await db.executeQuery(ctx, sql)).rows;

  // Stufe 1: Subjekt = Eigentümer (Pseudoknoten, Berechnung) bzw. der Knoten selbst
  const subject = new Map();
  const calcs = items.filter((n) => n.type === 'Calculation' && !n.ownerUuid);
  const calcOwner = new Map();
  if (calcs.length > 0) {
    const rows = await query(
      `SELECT Calculation_UUID AS uuid, File_Name AS file, Owner_UUID AS owner, Owner_Type AS owner_type
         FROM CalculationsCatalog
        WHERE (Calculation_UUID, File_Name) IN (${pairs(calcs)})`
    );
    for (const r of rows) calcOwner.set(`${r.uuid}::${r.file ?? ''}`, r);
  }
  for (const n of items) {
    const key = `${n.uuid}::${n.file ?? ''}`;
    if (n.ownerUuid) subject.set(n.id, { uuid: n.ownerUuid, type: n.ownerType, file: n.file });
    else if (calcOwner.has(key)) {
      const o = calcOwner.get(key);
      subject.set(n.id, { uuid: o.owner, type: o.owner_type, file: n.file });
    } else subject.set(n.id, { uuid: n.uuid, type: n.type, file: n.file });
  }

  // Stufe 2: Container der Subjekte (Schritt → Script, Layout-Objekt → Layout,
  // Menübefehl → Menü, Variable → Bereich + Anker)
  const subs = [...subject.values()].filter((x) => x.uuid);
  const ofType = (t) => subs.filter((x) => x.type === t);
  const stepScript = new Map();
  const loLayout = new Map();
  const itemMenu = new Map();
  const varInfo = new Map();
  if (ofType('ScriptStep').length > 0) {
    for (const r of await query(
      `SELECT Step_UUID AS uuid, File_Name AS file, Script_UUID AS script
         FROM StepsForScripts WHERE (Step_UUID, File_Name) IN (${pairs(ofType('ScriptStep'))})`
    )) stepScript.set(`${r.uuid}::${r.file ?? ''}`, r.script);
  }
  if (ofType('LayoutObject').length > 0) {
    for (const r of await query(
      `SELECT lo.Object_UUID AS uuid, lo.File_Name AS file, any_value(l.L_UUID) AS layout
         FROM LayoutObjects lo JOIN Layouts l ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
        WHERE (lo.Object_UUID, lo.File_Name) IN (${pairs(ofType('LayoutObject'))})
        GROUP BY ALL`
    )) loLayout.set(`${r.uuid}::${r.file ?? ''}`, r.layout);
  }
  if (ofType('CustomMenuItem').length > 0) {
    for (const r of await query(
      `SELECT Source_UUID AS uuid, Source_File AS file, any_value(Target_UUID) AS menu
         FROM ObjectLinks
        WHERE Link_Role = 'parent_menu' AND (Source_UUID, Source_File) IN (${pairs(ofType('CustomMenuItem'))})
        GROUP BY ALL`
    )) itemMenu.set(`${r.uuid}::${r.file ?? ''}`, r.menu);
  }
  if (ofType('Variable').length > 0) {
    for (const r of await query(
      `SELECT md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) AS uuid,
              File_Name AS file, Variable_Scope AS scope, Scope_Anchor AS anchor, Variable_Name AS name
         FROM VariablesCatalog
        WHERE (md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name), File_Name)
              IN (${pairs(ofType('Variable'))})`
    )) varInfo.set(`${r.uuid}::${r.file ?? ''}`, r);
  }

  for (const n of items) {
    const sub = subject.get(n.id);
    const key = `${sub.uuid}::${sub.file ?? ''}`;
    let open = { type: sub.type, uuid: sub.uuid, file: sub.file ?? null };
    if (sub.type === 'ScriptStep' && stepScript.has(key)) {
      open = { type: 'Script', uuid: stepScript.get(key), file: sub.file ?? null, step: sub.uuid };
    } else if (sub.type === 'LayoutObject' && loLayout.has(key)) {
      open = { type: 'Layout', uuid: loLayout.get(key), file: sub.file ?? null, ref: sub.uuid };
    } else if (sub.type === 'CustomMenuItem' && itemMenu.has(key)) {
      open = { type: 'CustomMenu', uuid: itemMenu.get(key), file: sub.file ?? null, ref: sub.uuid };
    } else if (sub.type === 'Variable' && varInfo.has(key)) {
      const v = varInfo.get(key);
      if (v.scope === 'local' && v.anchor) {
        open = { type: 'Script', uuid: v.anchor, file: sub.file ?? null, var: `local:${v.name}` };
      }
    }
    // omitSelf (Ablauf-Modus): kein open, wenn es nur auf den Knoten selbst zeigt
    // — der Client öffnet dann { type, uuid, file } des Knotens.
    if (opts.omitSelf && open.type === n.type && open.uuid === n.uuid
        && (open.file ?? null) === (n.file ?? null) && !open.step && !open.ref && !open.var) continue;
    n.open = open;
  }
}

/** Feld eines Wegs: Verwendung ordnet es der Wirkungsgruppe writes/calc zu. */
function wayField(f, dir) {
  if (dir !== 'down') return { id: f.id, via: f.via };
  const kind = f.via === 'step_writes_field' || f.via === 'step_writes_dynamic' ? 'writes' : 'calc';
  return { id: f.id, via: f.via, kind };
}

/**
 * Datenfluss-Trace (mode=data) ab einem Feld oder einer Variable — Herkunft (dir=up) bzw.
 * Verwendung (dir=down) über v_dataflow_edges (Template graph_trace_data.sql).
 * Antwort wie der Ablauf-Trace (nodes/edges/stats/truncated), Knoten mit
 * flowRole/fieldLevel/varLevel, Kanten mit flowKind/flowClass/precision, dazu
 * data.trace.stats (Kürzungen, deaktivierte Schritte, offener Aufrufkontext),
 * data.trace.blindSpots und die Wege: data.trace.ways, resetGroup (up),
 * usageGroups (down), overview (Weg 0) und refs (Beschriftung der Knoten, die
 * Wege und Gruppen nennen, außerhalb von node_limit).
 * @param {Object} [opts]
 * @param {boolean} [opts.labelsAll] - alle Pfadknoten beschriften (Mermaid je Weg)
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getDataTrace(ctx, p, opts = {}) {
  const labelsAll = opts.labelsAll === true || p.ways_mermaid === true;
  await assertDataflowAvailable(ctx);

  // Lösungsprofil: nur bestätigte Regeln; der Hash gehört in den Cache-Key
  const profileSvc = require('./dataflow-profile.service');
  const profile = profileSvc.loadProfile(ctx);
  const profileOn = p.profile !== 'off';
  const hash = profileSvc.profileHash(profile);
  const cacheKey = `${traceCacheKey(ctx, p)}|labels:${labelsAll}|profile:${profileOn ? hash : 'off'}`;
  const cached = traceCache.get(cacheKey);
  if (cached) return { payload: cached.payload, sql: cached.sql, cached: true };

  const resolved = await profileSvc.resolveRules(ctx, profile);
  const anchor = await resolveStartStep(ctx, p, opts.startType || 'Field');
  const result = await templateService.executeTemplate(
    ctx, 'graph_trace_data', toDataTraceParams(p, labelsAll, profileOn ? resolved : null, anchor), 'report'
  );

  const nodes = [];
  const edges = [];
  const refs = {};
  const ways = [];
  const usageGroups = [];
  let resetGroup = null;
  let overview = { fields: [], links: [] };
  let s = {};
  const json = (v) => (typeof v === 'string' ? JSON.parse(v) : v);
  for (const r of result.data) {
    switch (r.row_kind) {
      case 'node':
        nodes.push(dataTraceNode(r));
        break;
      case 'ref': {
        const n = dataTraceNode(r);
        refs[n.id] = {
          label: n.label, type: n.type, file: n.file, flowRole: n.flowRole, depth: n.depth,
          ownerUuid: n.ownerUuid, ownerType: n.ownerType,
          stepIndex: n.stepIndex, stepId: n.stepId, scriptUuid: n.scriptUuid,
        };
        break;
      }
      case 'edge':
        edges.push({
          id: r.id,
          source: r.source,
          target: r.target,
          role: r.flow_kind,
          subrole: r.subrole,
          crossFile: r.cross_file === true,
          flowKind: r.flow_kind,
          flowClass: r.flow_class,
          precision: r.precision,
        });
        break;
      case 'way': {
        const w = json(r.payload);
        w.fields = (w.fields || []).map((f) => wayField(f, p.dir));
        ways.push(w);
        break;
      }
      case 'usage':
        usageGroups.push(json(r.payload));
        break;
      case 'reset':
        resetGroup = json(r.payload);
        break;
      case 'overview': {
        const o = json(r.payload);
        overview = { fields: o.fields || [], links: o.links || [] };
        break;
      }
      case 'stats':
        s = json(r.payload) || {};
        break;
      default:
        break;
    }
  }
  ways.sort((a, b) => a.wayNo - b.wayNo);
  usageGroups.sort((a, b) => b.n - a.n || String(a.kind).localeCompare(String(b.kind)));

  await enrichCommunities(ctx, nodes.filter((n) => !n.isPseudo));
  // Sprungziele für Knoten und Refs (Klick in Wege-Liste und Mermaid-Weg)
  const refItems = Object.entries(refs).map(([id, r]) => {
    const sep = id.indexOf('::');
    const raw = sep === -1 ? id : id.slice(0, sep);
    return Object.assign(r, { id, uuid: raw.split('#')[0], type: r.type, file: r.file });
  });
  await enrichTraceOpen(ctx, [...nodes, ...refItems]);
  for (const r of refItems) { delete r.id; delete r.uuid; }
  const excluded = await resolveExcluded(ctx, p.exclude);

  // Files without DDR info: formula references are missing there, so a way
  // through such a file can end early (way.noDdr) — see ddr-coverage.js.
  const ddrNoDdr = (await ddrCoverage.loadDdrCoverage(ctx)).noDdr;
  const ddrSet = new Set(ddrNoDdr);
  const wayFiles = (w) => [w.writer, ...(w.pathNodes || [])].map(ddrCoverage.fileOfId);
  if (ddrSet.size > 0) {
    for (const w of ways) if (wayFiles(w).some((f) => ddrSet.has(f))) w.noDdr = true;
  }
  const noDdrBlind = ddrCoverage.noDdrBlindSpot(ddrNoDdr, [
    p.start_file,
    ...nodes.map((n) => n.file),
    ...Object.values(refs).map((r) => r.file),
    ...ways.flatMap(wayFiles),
  ]);

  const totalReachable = numOf(s.total_reachable);
  const waysTotal = numOf(s.ways_total);
  const truncatedBy = [];
  if (numOf(s.cut_field_levels) > 0) truncatedBy.push('field_levels');
  if (numOf(s.cut_var_levels) > 0) truncatedBy.push('var_levels');
  if (numOf(s.cut_step_limit) > 0) truncatedBy.push('step_limit');
  if (s.cut_state_limit === true) truncatedBy.push('state_limit');
  if (totalReachable > p.node_limit) truncatedBy.push('node_limit');
  if (waysTotal > ways.length) truncatedBy.push('ways_limit');

  const payload = {
    start: p.start,
    params: {
      mode: 'data',
      dir: p.dir,
      fieldLevels: p.field_levels,
      varLevels: p.var_levels,
      stepLimit: p.step_limit,
      callContext: p.call_context,
      includeControl: p.include_control,
      includeSinks: p.include_sinks,
      nodeLimit: p.node_limit,
      exclude: p.exclude ?? null,
      expandWay: p.expand_way ? String(p.expand_way).split(',') : [],
      includeReset: p.include_reset === true,
      waysLimit: p.ways_limit ?? 300,
    },
    trace: {
      mode: 'data',
      dir: p.dir,
      start: { uuid: p.start, file: p.start_file ?? null, type: opts.startType || 'Field', step: anchor },
      excluded,
      stats: {
        states: numOf(s.states),
        truncatedBy,
        cutFieldLevels: numOf(s.cut_field_levels),
        cutVarLevels: numOf(s.cut_var_levels),
        cutStepLimit: numOf(s.cut_step_limit),
        disabledSteps: numOf(s.disabled_steps),
        contextOpen: numOf(s.context_open),
        maxFieldLevel: s.max_field_level === null || s.max_field_level === undefined ? 0 : Number(s.max_field_level),
        maxVarLevel: s.max_var_level === null || s.max_var_level === undefined ? 0 : Number(s.max_var_level),
        ways: ways.length,
        waysTotal,
        resetWays: numOf(s.reset_ways),
        entries: numOf(s.entries),
        reachedFields: numOf(s.reached_fields),
      },
      blindSpots: {
        uninitialized: numOf(s.blind_uninitialized),
        dynamicWrites: numOf(s.blind_dynamic_writes),
        dynamicCalls: numOf(s.blind_dynamic_calls),
        dynamicSql: numOf(s.blind_dynamic_sql),
        approxEdges: numOf(s.approx_edges),
        noDdr: noDdrBlind,
      },
      ways,
      resetGroup: p.dir === 'up' ? (resetGroup || { n: 0, ways: [] }) : null,
      usageGroups: p.dir === 'down' ? usageGroups : null,
      overview,
      refs,
      profile: {
        enabled: profileOn,
        hash,
        confirmed: profile.rules.filter((r) => r.status === 'confirmed').length,
        orphaned: resolved.orphaned.length,
        applied: {
          technicalLayout: numOf(s.profile_applied?.technical_layout),
          boundaryScript: numOf(s.profile_applied?.boundary_script),
          uiStateVariable: numOf(s.profile_applied?.ui_state_variable),
          hubVariable: numOf(s.profile_applied?.hub_variable),
          hubReaders: numOf(s.profile_applied?.hub_readers),
        },
        candidates: [],
      },
    },
    truncated: truncatedBy.length > 0,
    stats: {
      nodeCount: nodes.length,
      edgeCount: edges.length,
      totalReachable,
      maxDepthReached: s.max_depth === null || s.max_depth === undefined ? 0 : Number(s.max_depth),
    },
    nodes,
    edges,
  };

  // Kandidaten auf dem Weg (Hinweis-Chips) — Fehler hier lassen den Trace stehen
  try {
    const candidates = await profileSvc.getCandidates(ctx, profile);
    payload.trace.profile.candidates = candidatesOnTrace(candidates, nodes, ways);
  } catch (err) {
    payload.trace.profile.candidatesError = err.message;
  }

  if (p.ways_mermaid === true) {
    const { buildWayMermaid } = require('./graph-trace-mermaid');
    // Mermaid-Knoten-ID → Graph-ID (Klick im Diagramm wählt den Knoten im Canvas)
    const idMap = (built) => Object.fromEntries([...built.ids].map(([key, nid]) => [nid, key]));
    for (const w of ways) {
      const built = buildWayMermaid(payload, w.wayNo);
      w.mermaid = built.text;
      w.mermaidIds = idMap(built);
    }
    const overview = buildWayMermaid(payload, 0);
    payload.trace.overviewMermaid = overview.text;
    payload.trace.overviewMermaidIds = idMap(overview);
  }

  traceCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/** Anzeige-Labels der Einstiegspfad-Presets (Frontend lokalisiert über den Key). */
const TRACE_ENTRY_LABELS = {
  script: 'Script start',
  layout_runtime: 'Runtime (layout/object triggers + buttons)',
  layout_inbound: 'Inbound (scripts navigating here)',
  layout_full: 'Runtime + inbound',
};

/**
 * Einstiegspfad-Vorschau — eine Zeile je verfügbarem Preset mit Seed-Zähler und
 * Namens-Stichprobe. Leere Liste = Startobjekt-Typ ohne v1-Trace (Controller → 422).
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getTraceEntries(ctx, p) {
  const cacheKey = [ctx?.solution ?? '', p.start, p.start_file ?? ''].join('|');
  const cached = traceEntriesCache.get(cacheKey);
  if (cached) return { payload: cached.payload, sql: cached.sql, cached: true };

  const result = await templateService.executeTemplate(
    ctx,
    'graph_trace_entries',
    { start: p.start, start_file: p.start_file ?? null },
    'report'
  );

  const entries = result.data.map((r) => {
    let sample = [];
    try {
      sample = JSON.parse(r.seeds_sample ?? '[]');
    } catch { /* defensiv — leere Stichprobe */ }
    return {
      entry: r.entry,
      label: TRACE_ENTRY_LABELS[r.entry] ?? r.entry,
      isDefault: r.is_default === true,
      seedCount: numOf(r.seed_count),
      seedsSample: sample,
    };
  });

  const payload = { start: p.start, entries };
  traceEntriesCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/**
 * LRU-Cache für Tiefen-Profile (/api/graph/depth-profile). Klein + read-heavy
 * (Slider-Anzeige fragt pro Fokus/Richtung); gleiche Mechanik/TTL wie subgraphCache.
 */
const depthProfileCache = new LRUCache({ max: 200, ttl: 1000 * 60 * 5 });

function depthProfileCacheKey(ctx, p) {
  return [ctx?.solution ?? '', p.focus, p.focus_file ?? '', p.direction, p.mode, p.include_builtins, p.types ?? ''].join('|');
}

/**
 * Tiefen-Profil ab dem Fokus: max. erreichbare Tiefe (Exzentrizität) +
 * Knotenzahl je Tiefe (kumulativ = Last eines Subgraphen dieser Tiefe).
 * Richtungsabhängig; Walk ist bei graphMaxDepth gedeckelt (Runaway-Schutz) →
 * hitCap signalisiert eine evtl. größere echte Exzentrizität.
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getDepthProfile(ctx, p) {
  const cacheKey = depthProfileCacheKey(ctx, p);
  const cached = depthProfileCache.get(cacheKey);
  if (cached) return { payload: cached.payload, sql: cached.sql, cached: true };

  const hardCap = environment.duckdb.graphMaxDepth;
  const result = await templateService.executeTemplate(
    ctx,
    'graph_depth_profile',
    {
      focus: p.focus,
      focus_file: p.focus_file ?? null,
      direction: p.direction,
      mode: p.mode,
      include_builtins: p.include_builtins,
      roles: null,
      types: p.types ?? null,
      hard_cap: hardCap,
    },
    'report'
  );

  // Rohzeilen {depth, nodes} → kumulative Last + maxDepth. depth 0 = Fokus selbst.
  const rows = result.data
    .map((r) => ({ depth: numOf(r.depth), nodes: numOf(r.nodes) }))
    .sort((a, b) => a.depth - b.depth);
  let cumulative = 0;
  const perDepth = [];
  let maxDepth = 0;
  for (const r of rows) {
    cumulative += r.nodes;
    if (r.depth >= 1) {
      perDepth.push({ depth: r.depth, nodes: r.nodes, cumulative });
      maxDepth = r.depth;
    }
  }

  const payload = {
    focus: p.focus,
    direction: p.direction,
    mode: p.mode,
    maxDepth,
    hitCap: maxDepth >= hardCap, // echte Exzentrizität evtl. > Cap
    hardCap,
    perDepth,
  };
  depthProfileCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/**
 * Fokus-Autocomplete über ObjectCatalog (Sucheingabe).
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function search(ctx, p) {
  // Volle UUID bzw. Import-Schlüssel im Fokusfeld → direkter Treffer (nur als
  // ganzer Begriff, s. classifyIdTerm). `id:<n>` bleibt der Objektsuche
  // vorbehalten — eine Datei-lokale ID ist kein Fokus-Kandidat.
  const id = classifyIdTerm(p.q);
  const idTerm = id && id.kind !== 'object_id' ? id.value : null;
  const result = await templateService.executeTemplate(
    ctx,
    'graph_search',
    { q: p.q, id_term: idTerm, type: p.type ?? null, file: p.file ?? null, limit: p.limit },
    'report'
  );
  const results = result.data.map(r => ({
    id: r.id,
    label: r.label,
    type: r.type,
    file: r.file,
  }));
  return {
    payload: { query: p.q, count: results.length, results },
    sql: result.sql,
  };
}

/**
 * Graph-Atlas (Top-Down-Einstieg) — /api/graph/overview.
 *
 * Zwei orthogonale Achsen: Segmentierung (segment_by) × Darstellung (view).
 * Composition (Treemap) hat den 3-Ebenen-Trichter root→segment→leaf; Topology
 * (Meta-Graph) ist einstufig. Drei SQL-Templates (aggregate/leaf/topology) decken
 * die Fälle ab; die Top-K/„Rest"-Faltung und die ehrliche Blatt-Trunkierung liegen
 * hier im Service (testbar, schema-unabhängig).
 */

/** DuckDB liefert BigInt für int64/int128 → robuste Number-Konvertierung. */
function numOf(v) {
  if (v === null || v === undefined) return 0;
  return typeof v === 'bigint' ? Number(v) : Number(v);
}

/**
 * Top-K-Schwellen nach Kalibrierung. Über K Segmente werden in eine
 * graue „Rest"-Sammelkachel/-Super-Node gefaltet — sonst wäre die Treemap/der
 * Meta-Graph bei 371 Communities flach unbrauchbar. Typ (≤27) wird nie gefaltet.
 */
const ATLAS_FOLD_K = { community: 30, file: 40, type: Infinity };

/** Wählt Template + interpolierte Parameter aus den (Joi-validierten) Query-Params. */
function overviewTemplateAndParams(p) {
  const exclude_types = p.exclude_types ?? null;
  const activity = p.activity === true;
  const activity_bulk = p.activity_bulk ?? 'hide';
  if (p.view === 'topology') {
    return {
      template: 'graph_overview_topology',
      params: {
        weight: p.weight,
        segment_by: p.segment_by,
        include_builtins: p.include_builtins,
        exclude_types,
        activity,
        activity_bulk,
      },
    };
  }
  // composition
  if (p.segment_by === 'hubs' || p.level === 'leaf') {
    // Blattebene bzw. globale Direkt-Hubs (segment_by=hubs ⇒ keine parent-Filter).
    const hubs = p.segment_by === 'hubs';
    return {
      template: 'graph_overview_leaf',
      params: {
        weight: p.weight,
        parent_community: hubs ? null : (p.parent_community ?? null),
        parent_file: hubs ? null : (p.parent_file ?? null),
        parent_type: hubs ? null : (p.parent_type ?? null),
        include_builtins: p.include_builtins,
        exclude_types,
        limit: p.limit,
        activity,
        activity_bulk,
      },
    };
  }
  // Aggregat-Ebene (root oder segment): group_dim + ggf. ein parent-Filter.
  let group_dim;
  let parent_community = null;
  let parent_file = null;
  let parent_type = null;
  if (p.level === 'root') {
    group_dim = p.segment_by; // community | file | type
  } else {
    // segment: komplementärer Subtree (Datei→Typ, Community→Typ, Typ→Datei)
    if (p.segment_by === 'community') { group_dim = 'type'; parent_community = p.parent_community ?? null; }
    else if (p.segment_by === 'file') { group_dim = 'type'; parent_file = p.parent_file ?? null; }
    else { group_dim = 'file'; parent_type = p.parent_type ?? null; } // type → file
  }
  return {
    template: 'graph_overview_aggregate',
    params: {
      weight: p.weight, group_dim, parent_community, parent_file, parent_type,
      include_builtins: p.include_builtins, exclude_types, activity, activity_bulk,
    },
  };
}

/**
 * Änderungs-Aktivität einer Overview-Zeile (Spalten des shared activity block der
 * Overview-Templates) → `activity`-Objekt der Kachel bzw. des Super-Nodes.
 *   class          1–5 Altersstufe der jüngsten Mitglieds-Änderung (≤ 30 Tage · ≤ 90 Tage
 *                  · ≤ 1 Jahr · ≤ 2 Jahre · > 2 Jahre), 6 = nur unbekannt (junger
 *                  Massenstempel), 7 = kein Mitglied mit Stempel
 *   class_counts   Mitglieder je Klasse 1…7 (Summe = Knoten der Kachel)
 *   saves_level    1–5 aus dem mittleren Rang des Speicher-Zählers (Modus „Speicherungen“)
 * null, wenn die Zeile keine Aktivitätsspalten trägt.
 */
function activityOf(r) {
  if (r.activity_class === null || r.activity_class === undefined || r.data_state === null) return null;
  const opt = (v) => (v === null || v === undefined ? null : numOf(v));
  return {
    class: numOf(r.activity_class),
    class_counts: Array.from(r.class_counts ?? [], numOf),
    newest_change: r.newest_change ?? null,
    newest_age_days: opt(r.newest_age_days),
    active_90: numOf(r.active_90),
    median_age_days: opt(r.median_age_days),
    median_saves: opt(r.median_saves),
    stamped: numOf(r.stamped),
    undated: numOf(r.undated),
    saves_level: opt(r.saves_level),
    saves_sum: r.saves_sum === null || r.saves_sum === undefined ? 0 : Number(r.saves_sum),
    saves_n: numOf(r.saves_n),
  };
}

/** Stufen-Grenzen des Modus „Speicherungen“ — dieselben wie im shared activity block. */
const SAVES_LEVEL_LIMITS = [0.3, 0.4, 0.5, 0.6];

/**
 * Aktivität einer Sammelkachel aus den gefalteten Kacheln: Zähler addieren, die
 * jüngste Klasse gewinnt (min über die Kachel-Klassen = min über alle Mitglieder),
 * die Speicher-Stufe aus Rang-Summe/-Anzahl. Mediane lassen sich nicht
 * zusammenführen → null.
 */
function mergeActivity(items) {
  const acts = items.map((t) => t.activity).filter(Boolean);
  if (acts.length === 0) return null;
  const sum = (f) => acts.reduce((a, x) => a + x[f], 0);
  const class_counts = Array.from({ length: 7 }, (_, i) =>
    acts.reduce((a, x) => a + (x.class_counts[i] ?? 0), 0));
  const newest = acts.map((x) => x.newest_change).filter(Boolean).sort();
  const ages = acts.map((x) => x.newest_age_days).filter((v) => v !== null);
  const saves_sum = sum('saves_sum');
  const saves_n = sum('saves_n');
  const mean = saves_n > 0 ? saves_sum / saves_n : null;
  return {
    class: Math.min(...acts.map((x) => x.class)),
    class_counts,
    newest_change: newest.length ? newest[newest.length - 1] : null,
    newest_age_days: ages.length ? Math.min(...ages) : null,
    active_90: sum('active_90'),
    median_age_days: null,
    median_saves: null,
    stamped: sum('stamped'),
    undated: sum('undated'),
    saves_level: mean === null ? null : 1 + SAVES_LEVEL_LIMITS.filter((l) => mean > l).length,
    saves_sum,
    saves_n,
  };
}

/**
 * Payload-Kopf der Aktivität:
 *   requested  die Aktivität wurde mitgerechnet (activity=true; nur die Farbmodi
 *              „Aktivität“/„Speicherungen“ brauchen sie — sie kostet ~10–15 ms)
 *   available  der Katalog trägt Änderungsstempel (sonst bleibt der Modus aus)
 *   data_state Datenstand, auf den sich die Altersstufen beziehen (nur mit requested)
 */
async function activityHead(ctx, p, rows) {
  const row = p.activity ? rows.find((r) => r.data_state !== undefined && r.data_state !== null) : null;
  return {
    requested: p.activity === true,
    available: await changeMetaPresent(ctx),
    data_state: row ? row.data_state : null,
    bulk: p.activity_bulk ?? 'hide',
  };
}

/** Trägt der Katalog Änderungsstempel? Memoisiert je Lösung (clearCache setzt zurück). */
const _changeMetaPresent = new Map();
async function changeMetaPresent(ctx) {
  const key = ctx?.solution ?? '';
  if (_changeMetaPresent.has(key)) return _changeMetaPresent.get(key);
  let present = false;
  try {
    const r = await db.executeQuery(
      ctx, 'SELECT EXISTS (SELECT 1 FROM ObjectChangeMeta WHERE Modified_At IS NOT NULL) AS present'
    );
    present = r.rows[0]?.present === true;
  } catch { /* älterer Katalog ohne Tabelle (Stub fehlt) → Modus aus */ }
  _changeMetaPresent.set(key, present);
  return present;
}

/**
 * Faltet eine nach Gewicht absteigend sortierte Tile-Liste auf Top-K + eine
 * „Rest"-Sammelkachel (kind='rest'), die node_count/weight des Schwanzes summiert.
 * Gibt { tiles, rest } zurück; rest=null wenn nichts gefaltet wurde.
 */
function foldTopK(tiles, k) {
  if (!Number.isFinite(k) || tiles.length <= k) return { tiles, rest: null };
  const head = tiles.slice(0, k);
  const tail = tiles.slice(k);
  const rest = {
    key: '__rest__',
    label: `+ ${tail.length} weitere`,
    kind: 'rest',
    node_count: tail.reduce((s, t) => s + t.node_count, 0),
    weight: tail.reduce((s, t) => s + t.weight, 0),
    color_type: null,
    segment_count: tail.length,
    activity: mergeActivity(tail),
  };
  return { tiles: head, rest };
}

/** Composition-Aggregat: rohe Zeilen → Tiles, dann Top-K/Rest-Faltung (außer fold=false). */
function buildAggregatePayload(p, rows, groupDim) {
  const tiles = rows.map((r) => ({
    key: r.key,
    label: r.label,
    kind: 'aggregate',
    node_count: numOf(r.node_count),
    weight: numOf(r.weight),
    color_type: r.color_type ?? null,
    activity: activityOf(r),
  }));
  // fold=false faltet die „Rest"-Kachel wieder auf (zeigt alle Segmente).
  if (p.fold === false) {
    return { tiles, truncated: false };
  }
  // Cutoff = interaktiver Top-N (limit, vom Schieberegler) — sonst Kalibrierungs-Default.
  const k = Number.isFinite(p.limit) && p.limit > 0 ? p.limit : (ATLAS_FOLD_K[groupDim] ?? Infinity);
  const { tiles: head, rest } = foldTopK(tiles, k);
  return {
    tiles: rest ? [...head, rest] : head,
    truncated: false, // Aggregate werden gefaltet (Rest-Kachel), nicht still gekappt
  };
}

/** Composition-Blatt: rohe Zeilen → Leaf-Tiles + ehrliche „+N weitere"-Sammelkachel. */
function buildLeafPayload(p, rows) {
  const total = rows.length > 0 ? numOf(rows[0].total_count) : 0;
  // Die Knoten jenseits des Top-N-Deckels kommen als eine Zeile kind='rest' mit ihrem
  // Aktivitäts-Aggregat (graph_overview_leaf.sql).
  const restRow = rows.find((r) => r.kind === 'rest');
  const tiles = rows.filter((r) => r.kind !== 'rest').map((r) => ({
    key: r.key,
    uuid: r.uuid,
    file: r.file,
    label: r.label,
    type: r.type,
    community: r.community === null || r.community === undefined ? null : Number(r.community),
    weight: numOf(r.weight),
    kind: 'leaf',
    activity: activityOf(r),
  }));
  const remaining = total - tiles.length;
  const rest = remaining > 0
    ? {
      key: '__rest__', label: `+ ${remaining} weitere`, kind: 'rest', node_count: remaining, weight: null,
      activity: restRow ? activityOf(restRow) : null,
    }
    : null;
  return {
    tiles: rest ? [...tiles, rest] : tiles,
    truncated: remaining > 0,
  };
}

/**
 * Topology-Meta-Graph: Super-Nodes Top-K falten, Kanten auf die gefalteten
 * Endpunkte umleiten (zur „Rest"-Super-Node), Rest↔Rest-Self-Loops verwerfen und
 * parallele Kanten neu aggregieren. So bleibt der Meta-Graph lesbar (K≈30).
 */
function buildTopologyPayload(p, rows) {
  const rawNodes = [];
  const rawEdges = [];
  for (const r of rows) {
    if (r.row_kind === 'node') {
      rawNodes.push({
        key: String(r.key),
        label: r.label,
        member_count: numOf(r.member_count),
        weight: numOf(r.weight),
        color_type: r.color_type ?? null,
        top_member_uuid: r.top_member_uuid ?? null,
        top_member_file: r.top_member_file ?? null,
        activity: activityOf(r),
      });
    } else if (r.row_kind === 'edge') {
      rawEdges.push({ source: String(r.source), target: String(r.target), weight: numOf(r.weight) });
    }
  }
  // Super-Nodes sind bereits gewichts-absteigend sortiert (SQL ORDER BY).
  // Cutoff = interaktiver Top-N (limit) — sonst Kalibrierungs-Default je Segment.
  const k = Number.isFinite(p.limit) && p.limit > 0 ? p.limit : (ATLAS_FOLD_K[p.segment_by] ?? Infinity);
  let nodes = rawNodes;
  let restNode = null;
  if (Number.isFinite(k) && rawNodes.length > k) {
    const tail = rawNodes.slice(k);
    nodes = rawNodes.slice(0, k);
    restNode = {
      key: '__rest__',
      label: `+ ${tail.length} weitere`,
      kind: 'rest',
      member_count: tail.reduce((s, n) => s + n.member_count, 0),
      weight: tail.reduce((s, n) => s + n.weight, 0),
      color_type: null,
      segment_count: tail.length,
      activity: mergeActivity(tail),
    };
  }

  // Kanten auf sichtbare Knoten projizieren (gefaltete Endpunkte → __rest__).
  const kept = new Set(nodes.map((n) => n.key));
  const map = (key) => (kept.has(key) ? key : '__rest__');
  const edgeAgg = new Map();
  for (const e of rawEdges) {
    let s = map(e.source);
    let t = map(e.target);
    if (s === t) continue; // Rest↔Rest (oder kept-Self nach Mapping) verwerfen
    if (s > t) [s, t] = [t, s]; // ungerichtet normalisieren
    const id = `${s}|${t}`;
    edgeAgg.set(id, (edgeAgg.get(id) ?? 0) + e.weight);
  }
  const edges = [...edgeAgg.entries()].map(([id, weight]) => {
    const [source, target] = id.split('|');
    return { source, target, weight };
  }).sort((a, b) => b.weight - a.weight);

  return {
    nodes: restNode ? [...nodes, restNode] : nodes,
    edges,
  };
}

/**
 * User-Annotationen über die fertige Atlas-Payload legen (weiche Naht, no-op ohne
 * Sidecar). Zwei Overlays:
 *  - Community-Kacheln/Super-Nodes (segment_by=community): User_Name überschreibt
 *    das Label, user_name/user_notes/engine wandern mit (Frontend-Panel + Write-Key).
 *  - Blatt-Kacheln: `hidden`-Flag aus der Node-Sichtbarkeit (Frontend dimmt/blendet).
 * Läuft VOR dem Caching → der gecachte Payload ist annotationskonsistent; jeder
 * Annotations-Write leert den overviewCache (clearCache) → nie stale.
 */
async function overlayAnnotations(ctx, p, payload) {
  const isCommunityAgg =
    payload.view === 'composition' && payload.segment_by === 'community' && payload.level === 'root';
  const isCommunityTopo = payload.view === 'topology' && payload.segment_by === 'community';
  const hasLeaves = payload.view === 'composition' && payload.tiles.some((t) => t.kind === 'leaf');
  if (!isCommunityAgg && !isCommunityTopo && !hasLeaves) return;

  const [commMap, hiddenSet, engine] = await Promise.all([
    isCommunityAgg || isCommunityTopo ? annotations.getCommunityAnnotationMap(ctx) : Promise.resolve(new Map()),
    hasLeaves ? annotations.getHiddenKeySet(ctx) : Promise.resolve(new Set()),
    isCommunityAgg || isCommunityTopo ? activeEngine(ctx) : Promise.resolve(''),
  ]);

  const applyCommunity = (obj) => {
    obj.engine = engine;
    const ann = commMap.get(`${engine}|${Number(obj.key)}`);
    obj.user_name = ann?.userName ?? null;
    obj.user_notes = ann?.userNotes ?? null;
    if (ann?.userName) obj.label = ann.userName;
  };

  if (isCommunityTopo) {
    // Topology-Super-Nodes tragen top_member_uuid bereits aus dem SQL.
    for (const n of payload.nodes) if (n.kind !== 'rest') applyCommunity(n);
    return;
  }

  // Community-Aggregat-Kacheln tragen keinen Member → den schwersten Member aus
  // CommunityNames nachreichen, damit das Panel „Im Graph Explorer öffnen" anbieten kann.
  let topMembers = new Map();
  if (isCommunityAgg) {
    const ids = payload.tiles.filter((t) => t.kind === 'aggregate').map((t) => Number(t.key));
    if (ids.length > 0) {
      try {
        const r = await db.executeQuery(
          ctx,
          `SELECT Community, Top_Member_UUID FROM CommunityNames
            WHERE Engine = '${escapeLiteral(engine)}' AND Community IN (${ids.join(',')})`
        );
        topMembers = new Map(r.rows.map((x) => [Number(x.Community), x.Top_Member_UUID ?? null]));
      } catch { /* keine CommunityNames → kein Explorer-Sprung aus dem Panel */ }
    }
  }

  for (const t of payload.tiles) {
    if (t.kind === 'leaf') t.hidden = hiddenSet.has(`${t.uuid}::${t.file ?? ''}`);
    else if (t.kind === 'aggregate' && isCommunityAgg) {
      applyCommunity(t);
      t.top_member_uuid = topMembers.get(Number(t.key)) ?? null;
    }
  }
}

/**
 * Graph-Atlas-Übersicht (Top-Down-Einstieg).
 * @param {Object} p - Joi-validierte Query-Params (Defaults bereits angewandt)
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getOverview(ctx, p, dbg) {
  const cacheKey = overviewCacheKey(ctx, p);
  const cached = overviewCache.get(cacheKey);
  if (cached) {
    dbgOverview(dbg, { kind: 'overview', phase: 'cache_hit', cacheKey });
    return { payload: cached.payload, sql: cached.sql, cached: true };
  }

  // Serialisiert: verhindert, dass parallele Atlas-Queries (Haupt + Typ-Universum)
  // gleichzeitig die teure View materialisieren und den 2GB-Buffer sprengen.
  // Queue-Tiefe loggen: zeigt, ob trotz Serialisierung mehrere Jobs anstehen.
  _overviewInflight += 1;
  const enqueuedMs = debugSession.nowMs();
  dbgOverview(dbg, { kind: 'overview', phase: 'enqueue', cacheKey, inflight: _overviewInflight });
  return runExclusiveOverview(() => executeOverview(ctx, p, cacheKey, dbg, enqueuedMs))
    .finally(() => { _overviewInflight -= 1; });
}

/** Debug-Log-Helfer für den Overview-Pfad — no-op ohne aktive Session. */
function dbgOverview(dbg, event) {
  if (!dbg || !dbg.active) return;
  debugSession.write({ sessionId: dbg.sessionId, reqId: dbg.reqId, ...event });
}

/** Memory-Probe ins Log (vor/nach der Query) — nur wenn aktiviert. */
async function dbgMem(dbg, when, extra = {}) {
  if (!dbg || !dbg.active || !environment.debugSession.probeMemory) return;
  const mem = await db.probeMemory();
  debugSession.write({ sessionId: dbg.sessionId, reqId: dbg.reqId, kind: 'mem', when, ...mem, ...extra });
}

/**
 * Prozess-RSS-Sampler WÄHREND der Query.
 *
 * `db.probeMemory()` (duckdb_memory()) sampelt nur an den Query-Grenzen — der
 * In-Query-Peak, der tatsächlich OOMt, fällt durch. Der RSS des Node-Prozesses
 * enthält die nativen DuckDB-Buffer-Allokationen und lässt sich UNABHÄNGIG von
 * der (während der Query blockierten) DuckDB-Verbindung pollen → echte Kurve bis
 * zum Peak. Absolutwert enthält V8-Heap (~zig MB Sockel); das Δ über die Query
 * spiegelt das Buffer-Wachstum. Sampelt alle 100 ms, no-op ohne aktive Session.
 * Gibt eine Stop-Funktion zurück (idempotent).
 */
function startRssSampler(dbg, template) {
  if (!dbg || !dbg.active || !environment.debugSession.probeMemory) return () => {};
  const emit = (mark) => {
    const rssMb = +(process.memoryUsage().rss / 1e6).toFixed(1);
    debugSession.write({
      sessionId: dbg.sessionId, reqId: dbg.reqId, kind: 'rss', template, rss_mb: rssMb, mark,
    });
  };
  emit('start');
  const timer = setInterval(() => emit('tick'), 100);
  if (timer.unref) timer.unref(); // Sampler darf den Prozess nicht am Leben halten
  let stopped = false;
  return () => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
    emit('stop');
  };
}

async function executeOverview(ctx, p, cacheKey, dbg, enqueuedMs) {
  // Re-Check: ein vorheriger, identischer Job im Lock könnte den Cache gefüllt haben.
  const cached = overviewCache.get(cacheKey);
  if (cached) {
    dbgOverview(dbg, { kind: 'overview', phase: 'cache_hit_locked', cacheKey });
    return { payload: cached.payload, sql: cached.sql, cached: true };
  }

  const { template, params } = overviewTemplateAndParams(p);
  // Wartezeit im Lock = Serialisierungs-Stau (enqueue → tatsächlicher Start).
  const waitMs = enqueuedMs != null ? debugSession.nowMs() - enqueuedMs : null;
  dbgOverview(dbg, { kind: 'overview', phase: 'run', template, params, wait_ms: waitMs, inflight: _overviewInflight });
  await dbgMem(dbg, 'before', { template });

  // Thread-Deckel: der Peak der Overview-Query (materialisiert die teure ClusterEdges-
  // View) skaliert mit der Thread-Zahl — bei threads=8 ~1.8 GB, bei 4 ~0.8 GB (gemessen).
  // Auf den (serialisierten) Overview-Queries threads runtersetzen, danach wieder hoch,
  // damit Subgraph/Search ihre volle Parallelität behalten. SET threads gilt für die
  // ganze (eine) Verbindung; weil Overview via Mutex serialisiert ist, kollidieren die
  // SET/Restore nicht miteinander. Restore in JEDEM Pfad (auch Fehler).
  const fullThreads = environment.duckdb.threads;
  const capThreads = environment.duckdb.overviewThreads > 0
    && environment.duckdb.overviewThreads < fullThreads;
  const restoreThreads = async () => {
    if (capThreads) {
      try { await db.executeQuery(ctx, `SET threads=${fullThreads}`); } catch { /* Reload o.ä. */ }
    }
  };
  if (capThreads) {
    try { await db.executeQuery(ctx, `SET threads=${environment.duckdb.overviewThreads}`); }
    catch { /* SET nicht möglich → mit voller Thread-Zahl weiter */ }
  }

  const startMs = debugSession.nowMs();
  const stopRss = startRssSampler(dbg, template); // In-Query-Peak einfangen
  let result;
  try {
    result = await templateService.executeTemplate(ctx, template, params, 'report');
  } catch (err) {
    stopRss();
    await restoreThreads();
    await dbgMem(dbg, 'on_error', { template });
    dbgOverview(dbg, {
      kind: 'overview', phase: 'error', template,
      dur_ms: debugSession.nowMs() - startMs, error: err.message,
    });
    throw err;
  }
  stopRss();
  await restoreThreads();
  await dbgMem(dbg, 'after', { template, rows: result.data.length });
  dbgOverview(dbg, {
    kind: 'overview', phase: 'done', template,
    dur_ms: debugSession.nowMs() - startMs, rows: result.data.length,
  });

  let payload;
  if (p.view === 'topology') {
    const { nodes, edges } = buildTopologyPayload(p, result.data);
    payload = {
      view: 'topology',
      segment_by: p.segment_by,
      weight: p.weight,
      activity: await activityHead(ctx, p, result.data),
      nodes,
      edges,
    };
  } else if (template === 'graph_overview_leaf') {
    const { tiles, truncated } = buildLeafPayload(p, result.data);
    payload = {
      view: 'composition',
      level: p.segment_by === 'hubs' ? 'root' : 'leaf',
      segment_by: p.segment_by,
      parent: { community: params.parent_community, file: params.parent_file, type: params.parent_type },
      weight: p.weight,
      activity: await activityHead(ctx, p, result.data),
      truncated,
      tiles,
    };
  } else {
    const { tiles, truncated } = buildAggregatePayload(p, result.data, params.group_dim);
    payload = {
      view: 'composition',
      level: p.level,
      segment_by: p.segment_by,
      parent: { community: params.parent_community, file: params.parent_file, type: params.parent_type },
      weight: p.weight,
      activity: await activityHead(ctx, p, result.data),
      truncated,
      tiles,
    };
  }

  // User-Annotationen über die Payload legen (weiche Naht, no-op ohne Sidecar).
  await overlayAnnotations(ctx, p, payload);

  overviewCache.set(cacheKey, { payload, sql: result.sql });
  return { payload, sql: result.sql, cached: false };
}

/**
 * Community-Namen-Status für die Atlas-Statusleiste + Cluster-Verfügbarkeit
 * (Failover). Mitglieder-gewichtete Abdeckung der semantischen Namen plus
 * Zähler (semantisch / benutzer-definiert). Liest CommunityNames (aktive
 * Partition) + CommunityAnnotation (Sidecar).
 *
 * Robuste Degradation: ohne Clustering (frische DB / Cluster-Layer gewischt →
 * leerer TEMP-Stub) liefert activeEngine() '' → `clusters_available:false`,
 * coverage_pct:null, alle Zähler 0. Das Frontend nutzt das Flag, um auf
 * Datei+Komposition umzuschalten und Community/Topologie zu dimmen.
 *
 * `clusters_available` hängt an der AKTIVEN ENGINE (= ObjectClusters hat Daten),
 * nicht an CommunityNames: eine geclusterte, aber noch unbenannte Partition ist
 * verfügbar (Community-Kacheln „Community N") — nur die Namens-Abdeckung ist dann
 * `--`.
 */
/**
 * Liest die persistierte Cluster-Run-Summary (`solutions/<id>/state/cluster_run.json`,
 * von cluster.sh je Lauf geschrieben) der LÖSUNG DES REQUESTS plus den „letzter Run"-
 * Zeitstempel. Fehlt die Datei (noch nie geclustert / alter Stand) → `run:null`.
 * `last_run` bevorzugt `cluster_run.json.finished_at`, fällt sonst auf
 * `cluster.json.updated_at` (Config-für-Reuse) zurück. Best-effort, wirft nie.
 */
function fmlabFilePath(name, solutionId) {
  // Per-Solution-State (solutions/<id>/state/) der Request-Lösung (X-Solution /
  // ?solution=), sonst der aktiven; Fallback auf das alte flache .fmlab/ nur für
  // die aktive Lösung eines unmigrierten Workspaces.
  const solutions = require('../config/solutions');
  const active = solutions.getActiveSolutionId();
  const id = solutionId || active;
  const p = path.join(solutions.stateDir(id), name);
  if (fs.existsSync(p) || id !== active) return p;
  return path.join(settingsStore.resolveRepoRoot(), '.fmlab', name);
}

function numOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function readClusterRunSummary(solutionId) {
  let run = null;
  let lastRun = null;
  try {
    const raw = JSON.parse(fs.readFileSync(fmlabFilePath('cluster_run.json', solutionId), 'utf-8'));
    run = {
      n_nodes: numOrNull(raw.n_nodes),
      n_edges: numOrNull(raw.n_edges),
      n_communities: numOrNull(raw.n_communities),
      modularity_q: numOrNull(raw.modularity_q),
      resolution: numOrNull(raw.resolution),
      seed: numOrNull(raw.seed),
      n_named: numOrNull(raw.n_named),
    };
    if (raw.finished_at) lastRun = String(raw.finished_at);
  } catch { /* fehlend/ungültig → run bleibt null */ }
  if (!lastRun) {
    try {
      const cfg = JSON.parse(fs.readFileSync(fmlabFilePath('cluster.json', solutionId), 'utf-8'));
      if (cfg.updated_at) lastRun = String(cfg.updated_at);
    } catch { /* fehlend → null */ }
  }
  return { run, lastRun };
}

async function getCommunityStats(ctx) {
  const engine = await activeEngine(ctx);
  const { run, lastRun } = readClusterRunSummary(ctx && ctx.solution);
  if (!engine) {
    return {
      engine: '',
      clusters_available: false,
      total_communities: 0,
      named_communities: 0,
      semantic_count: 0,
      user_defined_count: 0,
      coverage_pct: null,
      // Additiv: ohne Partition keine Run-Metriken, aber der
      // letzte bekannte Lauf bleibt anzeigbar (rein informativ).
      run,
      last_run: lastRun,
    };
  }

  // Aggregat über CommunityNames (aktive Engine): Zahl + mitglieder-gewichtete
  // Abdeckung. Fehlt/leer die Tabelle (unbenannt) → bleibt bei 0 / coverage null.
  let total = 0;
  let semantic = 0;
  let memberAll = 0;
  let memberNamed = 0;
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT
         COUNT(*)                                                                  AS total,
         COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL)                         AS semantic,
         COALESCE(SUM(Member_Count), 0)                                            AS member_all,
         COALESCE(SUM(Member_Count) FILTER (WHERE Semantic_Name IS NOT NULL), 0)   AS member_named
       FROM CommunityNames
       WHERE Engine = '${escapeLiteral(engine)}'`
    );
    const row = r.rows[0] ?? {};
    total = numOf(row.total);
    semantic = numOf(row.semantic);
    memberAll = numOf(row.member_all);
    memberNamed = numOf(row.member_named);
  } catch {
    /* CommunityNames fehlt → unbenannte Partition; Zähler bleiben 0. */
  }

  // Benutzer-definierte Namen der aktiven Engine (Sidecar-Overlay).
  let userDefined = 0;
  const commMap = await annotations.getCommunityAnnotationMap(ctx);
  const prefix = `${engine}|`;
  for (const [key, ann] of commMap) {
    if (key.startsWith(prefix) && ann.userName && ann.userName.trim()) userDefined += 1;
  }

  return {
    engine,
    clusters_available: true,
    total_communities: total,
    named_communities: semantic,
    semantic_count: semantic,
    user_defined_count: userDefined,
    // Mitglieder-gewichtet; null, wenn (noch) keine semantischen Namen.
    coverage_pct: semantic > 0 && memberAll > 0 ? memberNamed / memberAll : null,
    // ── Additiv: persistierte Run-Metriken + letzter Run ──
    // modularity/edges/seed/resolution kommen aus cluster_run.json (live nicht
    // billig nachrechenbar). nodes/communities haben dort einen Snapshot; die
    // Live-Zahl (total) bleibt die Wahrheit für „benannte N von M". Rückwärts-
    // kompatibel — die Atlas-Statusleiste ignoriert diese Felder.
    run,
    last_run: lastRun,
  };
}

/**
 * Vollständige Community-Liste der aktiven Engine — node-
 * gewichtet sortiert (Member_Count DESC). Merge aus Copy (CommunityNames, READ_
 * ONLY) + Sidecar-Overlays (User-Annotation, Namens-Restore), Muster wie
 * `enrichCommunities`/`overlayAnnotations`.
 *
 * Namens-/Beschreibungs-Priorität (4-stufig):
 *   display_name = User_Name > Semantic_Name (Copy) > SemanticNameRestore > Heuristic_Name
 *   description  = User_Notes > Semantic_Description (Copy) > SemanticNameRestore
 *
 * `top_member_file` wird über ObjectClusters nachgeschlagen (CommunityNames hat
 * keine File-Spalte) — datei-genau via (Engine, Community, Top_Member_UUID), damit
 * der Explorer-Sprung Klon-disambiguiert seedet. Guard: keine Partition →
 * `{ engine:'', communities: [] }` (Frontend zeigt Empty-State).
 */
async function getCommunities(ctx) {
  const engine = await activeEngine(ctx);
  if (!engine || !(await communityTablesPresent(ctx))) {
    return { engine: '', communities: [] };
  }

  let rows = [];
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT
         cn.Community            AS community,
         cn.Member_Count         AS member_count,
         cn.Dominant_Type        AS dominant_type,
         cn.Dominant_File        AS dominant_file,
         cn.Top_Member_UUID      AS top_member_uuid,
         cn.Top_Member_Label     AS top_member_label,
         cn.Heuristic_Name       AS heuristic_name,
         cn.Semantic_Name        AS semantic_name,
         cn.Semantic_Description AS semantic_description,
         (SELECT oc.File_Name FROM ObjectClusters oc
           WHERE oc.Engine = cn.Engine AND oc.Community = cn.Community
             AND oc.Object_UUID = cn.Top_Member_UUID
           LIMIT 1)             AS top_member_file
       FROM CommunityNames cn
       WHERE cn.Engine = '${escapeLiteral(engine)}'
       ORDER BY cn.Member_Count DESC`
    );
    rows = r.rows;
  } catch {
    /* CommunityNames fehlt/leer → leere Liste (Frontend Empty-State). */
    return { engine, communities: [] };
  }

  const commMap = await annotations.getCommunityAnnotationMap(ctx);
  const restoreMap = await annotations.getSemanticRestoreMap(ctx);

  const communities = rows.map((r) => {
    const community = Number(r.community);
    const ckey = `${engine}|${community}`;
    const ann = commMap.get(ckey) ?? null;
    const restore = restoreMap.get(ckey) ?? null;
    const userName = ann?.userName ?? null;
    const userNotes = ann?.userNotes ?? null;
    const semanticName = r.semantic_name ?? restore?.semanticName ?? null;
    const semanticDescription = r.semantic_description ?? restore?.semanticDescription ?? null;
    const heuristicName = r.heuristic_name ?? null;
    return {
      community,
      display_name: userName ?? semanticName ?? heuristicName ?? `Community ${community}`,
      description: userNotes ?? semanticDescription ?? null,
      user_name: userName,
      user_notes: userNotes,
      semantic_name: semanticName,
      heuristic_name: heuristicName,
      semantic_description: semanticDescription,
      member_count: numOf(r.member_count),
      dominant_type: r.dominant_type ?? null,
      dominant_file: r.dominant_file ?? null,
      top_member_uuid: r.top_member_uuid ?? null,
      top_member_label: r.top_member_label ?? null,
      top_member_file: r.top_member_file ?? null,
    };
  });

  return { engine, communities };
}

/**
 * Drop all cached subgraph responses. Called from performReload() so a DB swap
 * (XML re-import) or template change can never serve stale results within the
 * 5-min TTL window.
 */
function clearCache() {
  subgraphCache.clear();
  overviewCache.clear();
  depthProfileCache.clear();
  traceCache.clear();
  traceEntriesCache.clear();
  _communityTablesPresent.clear(); // nach Reload neu erkennen (P5-Tabellen könnten neu sein)
  _activeEngine.clear();           // aktive Engine nach Reload neu bestimmen
  _changeMetaPresent.clear();      // Änderungsstempel nach Reload/Re-Import neu erkennen
}

module.exports = {
  assertDataflowAvailable,
  objectExists,
  objectFocusStatus,
  objectTypeOf,
  getSubgraph,
  getNeighbors,
  getTrace,
  getDataTrace,
  getTraceEntries,
  getOverview,
  getDepthProfile,
  getCommunityStats,
  getCommunities,
  search,
  clearCache,
};
