import { useEffect, useState } from 'react';
import type cytoscape from 'cytoscape';
import { API_BASE } from '../config/apiBase';
import { getTypeColor, getCommunityColor } from '../lib/graphColors';
import { recencyPaint, resolveCssColor } from '../lib/activityColors';
import { formatObjectDisplayName } from '../lib/objectName';
import type { CallSite } from './useTrace';

/**
 * Loads a focus-centered subgraph from `GET /api/graph/subgraph` and exposes
 * the typed response plus a helper that maps nodes/edges to Cytoscape elements.
 */

export type SubgraphDirection = 'out' | 'in' | 'both';
export type SubgraphMode = 'logical' | 'raw';

export type GraphNode = {
  /**
   * Composite graph key `uuid::file` (synthetische NULL-File-Objekte: `uuid`). In
   * geklonten Lösungen ist die nackte UUID nicht eindeutig → der Cytoscape-Element-
   * Key + Edge-Endpunkte nutzen die composite `id`. Für Navigation/Focus/Expand
   * IMMER `uuid`+`file` verwenden, NICHT `id`.
   */
  id: string;
  /** Rohe Object_UUID (für Navigation, Re-Focus, Lazy-Expand, fmIDE). */
  uuid: string;
  label: string;
  type: string;
  file: string | null;
  depth: number;
  degree: number;
  isHub: boolean;
  isFocus: boolean;
  /** P5 — Louvain/Leiden community id (color-lens key); null = unclustered. */
  community: number | null;
  /** P5 — display name COALESCE(User_Name, Semantic_Name, Heuristic_Name); null = unclustered. */
  communityName: string | null;
  /** User-Annotation — true = vom Nutzer ausgeblendet (Noise-Filter). */
  hidden?: boolean;
  /** Änderungs-Aktivität (Farbmodus „Aktivität"); null ohne Stempel-Katalog. */
  activity?: NodeActivity | null;
  /** Trace-Modus (GET /api/graph/trace): Rolle des Knotens im Ablauf — Styling-Achse. */
  traceRole?: string;
  /** Trace-Modus: vorzeichenbehaftete Ablauf-Tiefe (aufwärts negativ). */
  traceDepth?: number;
  /** Trace-Modus (W7/D10): Boundary-Knoten — sichtbar, aber nicht expandiert. */
  isExcluded?: boolean;
  /** Datenfluss-Trace (mode=data): Rolle im Wertfluss — start · field · step · variable · param · result · calc · entry · control · sink · blind. */
  flowRole?: string;
  /** Datenfluss-Trace: Feld- bzw. Variablenebene des Knotens. */
  fieldLevel?: number | null;
  varLevel?: number | null;
  /** Datenfluss-Trace: Blatt (Steuerung, Senke, Grenzebene) — nicht weiter verfolgt. */
  isLeaf?: boolean;
  /** Datenfluss-Trace: Pseudoknoten (Parameter, Ergebnis, Auto-Eingabe …) mit Eigentümer. */
  isPseudo?: boolean;
  ownerUuid?: string | null;
  ownerType?: string | null;
  /** Datenfluss-Trace: Schritt-Anker (Script-Ansicht `?step=`). */
  stepIndex?: number | null;
  stepId?: number | null;
  scriptUuid?: string | null;
  /** Datenfluss-Trace: Haltepunkt des Lösungsprofils (Regelart) — sichtbar, nicht expandiert. */
  profileStop?: string | null;
  /** Datenfluss-Trace: Sprungziel beim Klick (vom Server aufgelöst, siehe buildOpenTargetPath). */
  open?: OpenTarget;
  /** Ablauf-Trace: Wirkung je Script — Zahl verschiedener Ziele je Touch-Rolle. */
  effects?: Record<string, number>;
};

/**
 * Sprungziel eines Knotens: Objekt der Detailansicht (`type`/`uuid`/`file`),
 * hervorzuhebender Unterknoten (`ref`), Schritt-Anker (`step`) bzw.
 * Variablen-Auswahl (`var`, `<scope>:<name>`); `type: 'File'` = Dateiansicht.
 */
export type OpenTarget = {
  type: string;
  uuid: string;
  file: string | null;
  ref?: string;
  step?: string;
  var?: string;
};

export type GraphEdge = {
  id: string;
  source: string;
  target: string;
  role: string;
  subrole: string | null;
  linkType: 'operational' | 'structural';
  crossFile: boolean;
  /** Trace-Modus: Kanten-Klasse im Ablauf (chain/trigger/touch/induced) — Styling-Achse. */
  traceKind?: string;
  /** Datenfluss-Trace: Kantenart (`step_writes_field`, `local_def_use`, …). */
  flowKind?: string;
  /** Datenfluss-Trace: Kantenklasse data · control · entry · sink — Styling-Achse. */
  flowClass?: string;
  /** Datenfluss-Trace: exact · approx. Ablauf-Trace: exact · approx (ohne Schritt-Anker) · dynamic. */
  precision?: string;
  /** Ablauf-Trace: Aufrufstellen einer calls_script-/navigates_to_layout-Kante, nach Schritt sortiert. */
  callSites?: CallSite[];
};

export type SubgraphStats = {
  nodeCount: number;
  edgeCount: number;
  totalReachable: number;
  maxDepthReached: number;
};

export type SubgraphResponse = {
  focus: string;
  params: {
    depth: number;
    direction: string;
    mode: string;
    types: string[] | null;
    roles: string[] | null;
    includeBuiltins: boolean;
    nodeLimit: number;
    hubDegree: number;
  };
  /** true ⇔ totalReachable > nodeLimit — UI must surface a "truncated" banner. */
  truncated: boolean;
  stats: SubgraphStats;
  /** Change activity: stamps present + data state (colour lens "activity"). */
  activity?: GraphActivityHead;
  nodes: GraphNode[];
  edges: GraphEdge[];
};

export type SubgraphParams = {
  focus: string | null;
  /**
   * Klon-Disambiguierung: File_Name des Fokus-Knotens. Geteilte Klon-UUIDs sind
   * sonst mehrdeutig (Backend: 409 AMBIGUOUS_UUID auf den Fokus). Optional →
   * Graceful Downgrade.
   */
  focusFile?: string | null;
  depth: number;
  direction: SubgraphDirection;
  mode: SubgraphMode;
  types?: string[] | null;
  includeBuiltins?: boolean;
  nodeLimit?: number;
};

type ApiEnvelope<T> = {
  success: boolean;
  data: T;
  error?: { message: string };
};

const baseUrl = `${API_BASE}/api`;

/** Build the subgraph query string from the typed params. */
function buildQuery(p: SubgraphParams): string {
  const q = new URLSearchParams();
  q.set('focus', p.focus ?? '');
  if (p.focusFile) q.set('focus_file', p.focusFile);
  q.set('depth', String(p.depth));
  q.set('direction', p.direction);
  q.set('mode', p.mode);
  if (p.types && p.types.length > 0) q.set('types', p.types.join(','));
  if (p.includeBuiltins) q.set('include_builtins', 'true');
  if (p.nodeLimit) q.set('node_limit', String(p.nodeLimit));
  return q.toString();
}

/**
 * Display label for one rendered (grouped) edge. Receives the role, the sorted
 * distinct subroles collected by the id-dedup, and the source node's object
 * type (placement labelling). Returning the role verbatim is the neutral
 * default.
 */
export type EdgeLabeler = (role: string, subroles: string[], sourceType: string | null) => string;

/**
 * Change activity of a node: class 1 ≤ 30 days · 2 ≤ 90 days · 3 ≤ 1 year ·
 * 4 ≤ 2 years · 5 > 2 years · 6 unknown (only a young mass stamp) · 7 no own stamp
 * (layout objects and menu items carry their container's stamp). Ages count back
 * from the data state — the same classes as in the Graph Atlas.
 */
export type NodeActivity = {
  class: number;
  newestChange: string | null;
  newestAgeDays: number | null;
  saves: number | null;
  undated: boolean;
};

/** Activity head of a subgraph/trace response. */
export type GraphActivityHead = { available: boolean; dataState: string | null };

/** Cytoscape data fields of the recency colour lens (see ExplorerGraph `.color-recency`). */
export function recencyData(a: NodeActivity | null | undefined) {
  const cls = a ? a.class : 7;
  const paint = recencyPaint(cls);
  return {
    recencyClass: a ? a.class : null,
    recencyVar: paint.fillVar,
    recencyColor: resolveCssColor(paint.fillVar),
    recencyUnknown: cls === 6,
    newestChange: a?.newestChange ?? null,
    newestAgeDays: a?.newestAgeDays ?? null,
  };
}

/**
 * Map subgraph nodes/edges to Cytoscape element definitions. Carries the raw
 * fields in `data` so the stylesheet can branch on type/isFocus/isHub/crossFile
 * and tap handlers can read the UUID and metadata.
 *
 * Two edge reductions happen here:
 *  1. **Dedup by id** (`source|role|target`) — the backend id ignores `subrole`,
 *     so the same field read via `Tooltip` *and* `Condition_1` collides; we keep
 *     one Cytoscape edge and collect the distinct subroles in `subroles`.
 *     (Cytoscape throws "second element with ID …" on duplicates → render crash.)
 *     For trigger mirrors this grouping is the deliberate display aggregation:
 *     parallel event edges become ONE edge whose label lists the events (via
 *     `edgeLabel`).
 *  2. **Reciprocal collapse** — when A→B *and* B→A both exist, render a single
 *     arrow in the "uses" direction. Canonical direction points away from the
 *     focus (lower source depth → outward); ties broken deterministically by id.
 */
export function subgraphToElements(nodes: GraphNode[], edges: GraphEdge[], edgeLabel?: EdgeLabeler): cytoscape.ElementDefinition[] {
  const nodeIds = new Set(nodes.map((n) => n.id));
  const depthOf = new Map(nodes.map((n) => [n.id, n.depth]));
  const elements: cytoscape.ElementDefinition[] = nodes.map((n) => ({
    data: {
      id: n.id,        // composite (uuid::file) — eindeutiger Cytoscape-Key bei Klonen
      uuid: n.uuid,    // rohe UUID für Tap-Handler (Navigation/Focus/Expand)
      label: formatObjectDisplayName(n.type, n.label) || '(ohne Namen)',
      type: n.type,
      file: n.file,
      depth: n.depth,
      degree: n.degree,
      isFocus: n.isFocus,
      isHub: n.isHub,
      community: n.community,
      communityName: n.communityName,
      // User-Annotation (Noise-Filter): in den Soft-Filter eingespeist → folgt dem
      // dim/hide-Modus des Explorers (rücknehmbar im Atlas-Hidden-Manager).
      userHidden: n.hidden === true,
      // Trace-Modus: Rolle/Tiefe als Datenattribute — das Stylesheet selektiert
      // per `node[traceRole = "…"]`; im Subgraph-Modus schlicht undefined.
      traceRole: n.traceRole,
      traceDepth: n.traceDepth,
      // Trace-Modus (W7): Boundary-Markierung — Stylesheet `node[?traceExcluded]`.
      traceExcluded: n.isExcluded === true,
      // Datenfluss-Trace: Rolle + Profil-Haltepunkt (`node[flowRole = "…"]`, `node[?profileStop]`).
      flowRole: n.flowRole,
      profileStop: n.profileStop ? n.profileStop : undefined,
      flowLeaf: n.isLeaf === true || undefined,
      // Both colors travel in data; the stylesheet picks one via the
      // `.color-community` class toggled by the standalone färb-lens.
      color: getTypeColor(n.type),
      communityColor: getCommunityColor(n.community),
      // Farbmodus „Aktivität": Token-Name (Theme-Wechsel löst neu auf) + aufgelöste
      // Farbe; „unbekannt" bekommt im Stylesheet einen gestrichelten Ring.
      ...recencyData(n.activity),
    },
  }));

  // (1) Dedup by id, merging subroles. Guard against dangling edges (a capped
  // subgraph may reference a node that fell outside the node_limit).
  const byId = new Map<string, { edge: GraphEdge; subroles: Set<string> }>();
  for (const e of edges) {
    if (!nodeIds.has(e.source) || !nodeIds.has(e.target)) continue;
    const existing = byId.get(e.id);
    if (existing) {
      if (e.subrole) existing.subroles.add(e.subrole);
      continue;
    }
    const subroles = new Set<string>();
    if (e.subrole) subroles.add(e.subrole);
    byId.set(e.id, { edge: e, subroles });
  }

  // (2) Reciprocal collapse. Build the set of present directed node-pairs, then
  // drop every edge whose direction is the non-canonical side of a reciprocal pair.
  const directedPairs = new Set<string>();
  for (const { edge } of byId.values()) directedPairs.add(`${edge.source} ${edge.target}`);

  const dropped = new Set<string>();
  for (const { edge } of byId.values()) {
    if (edge.source === edge.target) continue; // never drop self-loops
    const reverse = `${edge.target} ${edge.source}`;
    if (!directedPairs.has(reverse)) continue; // not reciprocal — keep
    const ds = depthOf.get(edge.source) ?? 0;
    const dt = depthOf.get(edge.target) ?? 0;
    // Keep the direction that points away from the focus (lower source depth).
    const keepThisDirection = ds !== dt ? ds < dt : edge.source < edge.target;
    if (!keepThisDirection) dropped.add(edge.id);
  }

  const typeOf = new Map(nodes.map((n) => [n.id, n.type]));
  for (const { edge: e, subroles } of byId.values()) {
    if (dropped.has(e.id)) continue;
    const sorted = [...subroles].sort();
    elements.push({
      data: {
        id: e.id,
        source: e.source,
        target: e.target,
        label: edgeLabel ? edgeLabel(e.role, sorted, typeOf.get(e.source) ?? null) : e.role,
        role: e.role,
        subrole: e.subrole,
        subroles: sorted.length > 0 ? sorted : null,
        // Quell-Objekttyp mitführen: Label-Neuberechnung (Locale-Nachladen) und
        // Edge-Tooltip brauchen ihn ohne Knoten-Lookup.
        sourceType: typeOf.get(e.source) ?? null,
        linkType: e.linkType,
        isCrossFile: e.crossFile,
        // Trace-Modus: Ablauf-Klasse der Kante (Styling via `edge[traceKind = "…"]`).
        traceKind: e.traceKind,
        // Datenfluss-Trace: Kantenklasse + Präzision (`edge[flowClass = "…"]`, `edge[precision = "approx"]`).
        flowClass: e.flowClass,
        precision: e.precision,
        // Ablauf-Trace: Aufrufstellen (Tooltip) und „alle bedingt" (`edge[?traceConditional]`
        // gestrichelt). Fehlendes ifDepth = 0 (der Server lässt leere Felder weg).
        callSites: e.callSites && e.callSites.length > 0 ? e.callSites : undefined,
        traceConditional: e.callSites && e.callSites.length > 0
          && e.callSites.every((c) => (c.ifDepth ?? 0) > 0) ? true : undefined,
      },
    });
  }

  return elements;
}

/**
 * One-shot fetch of a node's direct neighbors (`GET /api/graph/neighbors`,
 * depth=1) for the inspect-panel "expand 1 hop" action. Returns the raw
 * nodes/edges so the caller can merge them into the live Cytoscape graph.
 */
export async function fetchNeighbors(
  focus: string,
  opts: { direction: SubgraphDirection; mode: SubgraphMode; types?: string[] | null; includeBuiltins?: boolean; focusFile?: string | null },
): Promise<{ nodes: GraphNode[]; edges: GraphEdge[] }> {
  const q = new URLSearchParams();
  q.set('focus', focus);
  if (opts.focusFile) q.set('focus_file', opts.focusFile);
  q.set('direction', opts.direction);
  q.set('mode', opts.mode);
  if (opts.types && opts.types.length > 0) q.set('types', opts.types.join(','));
  if (opts.includeBuiltins) q.set('include_builtins', 'true');

  const r = await fetch(`${baseUrl}/graph/neighbors?${q.toString()}`);
  const json: ApiEnvelope<SubgraphResponse> = await r.json();
  if (!r.ok || !json.success) {
    throw new Error(json.error?.message || `HTTP ${r.status}`);
  }
  return { nodes: json.data.nodes, edges: json.data.edges };
}

export function useSubgraph(params: SubgraphParams) {
  const [data, setData] = useState<SubgraphResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Serialize the params so the effect only re-fires on a real change.
  const key = params.focus
    ? buildQuery(params)
    : null;

  useEffect(() => {
    if (!params.focus || !key) {
      setData(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);

    fetch(`${baseUrl}/graph/subgraph?${key}`)
      .then(async (r) => {
        const json: ApiEnvelope<SubgraphResponse> = await r.json();
        if (!r.ok || !json.success) {
          throw new Error(json.error?.message || `HTTP ${r.status}`);
        }
        return json.data;
      })
      .then((d) => {
        if (!cancelled) setData(d);
      })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
    // `key` already encodes every param that affects the request.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return { data, loading, error };
}
