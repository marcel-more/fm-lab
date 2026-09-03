const fs = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const templateService = require('./template.service');
const db = require('../config/database');
const annotations = require('./annotations.service');
const debugSession = require('./debug-session.service');
const environment = require('../config/environment');
const settingsStore = require('../plugins/settings-store');

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
 * SQL-Kern: templates/sql/graph_subgraph.sql (Recursive CTE, mode=logical via
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

  const payload = {
    focus: p.focus,
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
    .filter((k) => !['format', 'meta', 'debug'].includes(k))
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
    node_limit: p.node_limit,
    hub_degree: p.hub_degree,
    exclude: p.exclude ?? null,
  };
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
 * Trace-Berechnung. `startType` kommt vom Controller (bereits für die
 * v1-Typ-Weiche aufgelöst) und bestimmt das effektive Einstiegs-Preset —
 * deckungsgleich mit der entry_sel-Logik im Template.
 * @returns {Promise<{payload: Object, sql: string}>}
 */
async function getTrace(ctx, p, startType) {
  const cacheKey = traceCacheKey(ctx, p);
  const cached = traceCache.get(cacheKey);
  if (cached) {
    return { payload: cached.payload, sql: cached.sql, cached: true };
  }

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
      edges.push({
        id: r.id,
        source: r.source,
        target: r.target,
        role: r.role,
        subrole: r.subrole,
        linkType: r.link_type,
        crossFile: r.cross_file === true,
        traceKind: r.trace_kind,
      });
    } else if (r.row_kind === 'seed') {
      seeds.push({ uuid: r.uuid, label: r.label, type: r.type, file: r.file });
    }
  }

  // P5-Naht: Community-Daten nachreichen (no-op ohne Cluster-Tabellen).
  await enrichCommunities(ctx, nodes);

  // Ausschlussliste katalog-aufgelöst (auch nicht mehr erreichte Einträge).
  const excluded = await resolveExcluded(ctx, p.exclude);

  const entry = startType === 'Script' ? 'script' : (p.entry ?? 'layout_runtime');
  const payload = {
    start: p.start,
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
      nodeLimit: p.node_limit,
      hubDegree: p.hub_degree,
      exclude: p.exclude ?? null,
    },
    trace: {
      start: { uuid: p.start, file: p.start_file ?? null, type: startType ?? null },
      entry,
      seeds,
      excluded,
      // Score-absteigend — die Reihenfolge ist die Anzeige-Reihenfolge der Chips.
      suggestions: suggestions.sort((a, b) => b.score - a.score),
      stats: { dynamicCalls },
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
  const result = await templateService.executeTemplate(
    ctx,
    'graph_search',
    { q: p.q, type: p.type ?? null, file: p.file ?? null, limit: p.limit },
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
  if (p.view === 'topology') {
    return {
      template: 'graph_overview_topology',
      params: {
        weight: p.weight,
        segment_by: p.segment_by,
        include_builtins: p.include_builtins,
        exclude_types,
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
    params: { weight: p.weight, group_dim, parent_community, parent_file, parent_type, include_builtins: p.include_builtins, exclude_types },
  };
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
  const tiles = rows.map((r) => ({
    key: r.key,
    uuid: r.uuid,
    file: r.file,
    label: r.label,
    type: r.type,
    community: r.community === null || r.community === undefined ? null : Number(r.community),
    weight: numOf(r.weight),
    kind: 'leaf',
  }));
  const remaining = total - tiles.length;
  const rest = remaining > 0
    ? { key: '__rest__', label: `+ ${remaining} weitere`, kind: 'rest', node_count: remaining, weight: null }
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
 * Liest die persistierte Cluster-Run-Summary (`.fmlab/cluster_run.json`, von
 * cluster.sh je Lauf geschrieben) plus den „letzter Run"-
 * Zeitstempel. Fehlt die Datei (noch nie geclustert / alter Stand) → `run:null`.
 * `last_run` bevorzugt `cluster_run.json.finished_at`, fällt sonst auf
 * `cluster.json.updated_at` (Config-für-Reuse) zurück. Best-effort, wirft nie.
 */
function fmlabFilePath(name) {
  // Per-Solution-State (solutions/<id>/state/); Fallback auf das alte flache
  // .fmlab/ für unmigrierte Workspaces.
  const solutions = require('../config/solutions');
  const p = path.join(solutions.resolveStateDir(), name);
  if (fs.existsSync(p)) return p;
  return path.join(settingsStore.resolveRepoRoot(), '.fmlab', name);
}

function numOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function readClusterRunSummary() {
  let run = null;
  let lastRun = null;
  try {
    const raw = JSON.parse(fs.readFileSync(fmlabFilePath('cluster_run.json'), 'utf-8'));
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
      const cfg = JSON.parse(fs.readFileSync(fmlabFilePath('cluster.json'), 'utf-8'));
      if (cfg.updated_at) lastRun = String(cfg.updated_at);
    } catch { /* fehlend → null */ }
  }
  return { run, lastRun };
}

async function getCommunityStats(ctx) {
  const engine = await activeEngine(ctx);
  const { run, lastRun } = readClusterRunSummary();
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
}

module.exports = {
  objectExists,
  objectFocusStatus,
  objectTypeOf,
  getSubgraph,
  getNeighbors,
  getTrace,
  getTraceEntries,
  getOverview,
  getDepthProfile,
  getCommunityStats,
  getCommunities,
  search,
  clearCache,
};
