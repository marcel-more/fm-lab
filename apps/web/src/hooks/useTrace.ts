import { useEffect, useState } from 'react';
import { API_BASE } from '../config/apiBase';
import type { GraphNode, GraphEdge, SubgraphStats, GraphActivityHead, OpenTarget } from './useSubgraph';
import type { WayMermaid } from '../lib/traceWays';
import type { NoDdrBlindSpot } from './useDataTrace';

/**
 * Trace mode data layer — sister of {@link useSubgraph}.
 *
 * Loads the selective flow walk from `GET /api/graph/trace` (same nodes/edges
 * shape as the subgraph plus `traceRole`/`traceDepth` per node and `traceKind`
 * per edge) and the entry-preset preview from `GET /api/graph/trace/entries`.
 * The extra trace fields ride on the shared GraphNode/GraphEdge types as
 * optional members, so the whole Explorer rendering pipeline
 * (subgraphToElements, lenses, panels) works unchanged.
 */

export type TraceRole =
  | 'start'
  | 'chain_down'
  | 'chain_up'
  | 'triggered'
  | 'touched'
  | 'trigger_touched'
  | 'trigger_owner';

export type TraceKind = 'chain' | 'trigger' | 'touch' | 'induced';

export type TraceEntryKey = 'script' | 'layout_runtime' | 'layout_inbound' | 'layout_full';

export type TraceSeed = {
  uuid: string;
  label: string;
  type: string;
  file: string | null;
};

/**
 * Katalog-aufgelöster Eintrag der Exclude-Liste — Basis der Chips.
 * `label`/`type` sind null, wenn die UUID nicht (mehr) im Katalog steht;
 * der Chip bleibt trotzdem entfernbar (URL ist die Quelle der Wahrheit).
 */
export type TraceExcludedItem = {
  id: string;
  uuid: string;
  file: string | null;
  label: string | null;
  type: string | null;
};

/**
 * Hub-Score-Vorschlag — Server-berechneter Exclude-Kandidat unter den
 * getraceten Scripts. Score-absteigend geliefert; wird NIE automatisch
 * angewandt — erst der Klick auf den Chip macht daraus einen Exclude.
 */
export type TraceSuggestion = {
  id: string;
  uuid: string;
  file: string | null;
  label: string;
  type: string;
  trigIn: number;
  fanIn: number;
  touchOut: number;
  score: number;
  reason: 'trigger_hub' | 'call_hub' | 'touch_hub';
};

export type TraceStats = SubgraphStats & {
  /** Call-Steps der Chain-Scripts ohne statisches Ziel („by name") — Blind-Spot. */
  dynamicCalls: number;
};

/** Innermost If / Else If / Else of a call site (`v_step_guards`). */
export type CallSiteGuard = {
  kind: 'if' | 'elseif' | 'else' | string;
  level?: number;
  stepIndex?: number;
  calcUuid?: string;
  /** One line, cut to 80 characters; `textFull` only when cut. */
  text?: string;
  textFull?: string;
};

/**
 * Call site of a Script → Script (calls_script) or Script → Layout
 * (navigates_to_layout) edge — one per step, sorted by step. Missing keys mean
 * 0 / false / empty (the server drops empty fields).
 */
export type CallSite = {
  stepUuid: string;
  /** 0-based; the user-facing step number is stepIndex + 1. */
  stepIndex: number;
  stepId: number;
  /** Only present (false) for a disabled step (include_disabled). */
  enabled?: boolean;
  guard?: CallSiteGuard;
  conditions?: number;
  ifDepth?: number;
  inLoop?: boolean;
  passesParam?: string;
  resultReadAt?: number[];
  unreachable?: boolean;
};

/** Context of the representative call site of a path edge (step refs). */
export type FlowSite = {
  guard?: CallSiteGuard;
  conditions?: number;
  inLoop?: boolean;
  passesParam?: string;
  unreachable?: boolean;
  sites?: number;
  allConditional?: boolean;
  anyLoop?: boolean;
  anyServer?: boolean;
  anyParam?: boolean;
  allUnreachable?: boolean;
};

/** Flags of a way over its full path; boolean flags only appear when true. */
export type FlowWayFlags = {
  /** Edges whose call sites are all conditional (0 = always runs). */
  conditions: number;
  loop?: boolean;
  server?: boolean;
  crossFile?: boolean;
  param?: boolean;
  unreachable?: boolean;
  cascade?: boolean;
};

export type FlowEntryGroup = {
  /** button · trigger · menu · file · root · budget · excluded */
  kind: string;
  event: string | null;
  n: number;
  nLayouts: number;
  layouts: { uuid: string; name: string; file: string | null }[];
  sample: string[];
};

export type FlowWay = {
  /** Numbered per direction. */
  wayNo: number;
  wayId: string;
  dir: 'up' | 'down';
  /** down: call · cascade · trigger · dynamic — up: entry. */
  kind: string;
  level: number;
  /** down: reached script (or DynamicCall key) — up: entry script. */
  target: string;
  parentWayId: string | null;
  /** Ways in the subtree below (down). */
  nDesc: number;
  precision: 'exact' | 'approx' | 'dynamic' | string;
  flags: FlowWayFlags;
  event?: string | null;
  eventOwner?: string | null;
  nEntries?: number;
  entryGroups?: FlowEntryGroup[];
  /** Way id whose full path precedes `pathNodes` (absent = full path). */
  pathPrefix?: string | null;
  /** "Follow source" (up): way id whose full path follows `pathNodes`. */
  pathSuffix?: string | null;
  pathNodes: string[];
};

/** Label info of path nodes outside the canvas (steps, DynamicCalls, capped nodes, entries). */
export type FlowRef = {
  label: string | null;
  type: string | null;
  file?: string | null;
  flowRole?: string | null;
  stepIndex?: number;
  stepId?: number;
  site?: FlowSite;
  /** Steps and DynamicCalls: UUID of their script (same file as the step). */
  script?: string;
  blindKind?: 'by_name' | 'unresolved' | string;
  name?: string | null;
  /** Jump target where it differs from the node (layout object → its layout, menu item → menu). */
  open?: OpenTarget;
};

export type FlowBlindSite = {
  id: string;
  /** Graph id of the calling script. */
  script: string;
  file: string | null;
  kind: 'by_name' | 'unresolved' | string;
  stepUuid: string;
  stepIndex: number;
  stepId: number;
  stepName?: string | null;
  name: string | null;
  nameFull?: string | null;
  guard?: CallSiteGuard | null;
  conditions?: number;
  ifDepth?: number;
  inLoop?: boolean;
  passesParam?: string | null;
  unreachable?: boolean;
};

export type FlowTraceStats = {
  dynamicCalls: number;
  unresolvedCalls: number;
  disabledSteps: number;
  conditionalCalls: number;
  ways: { down: number; up: number };
  waysTotal: { down: number; up: number };
  truncatedBy: string[];
};

export type TraceResponse = {
  start: string;
  params: {
    entry: TraceEntryKey;
    upDepth: number;
    downDepth: number;
    triggerDepth: number;
    expandUp: boolean;
    includeLocalVars: boolean;
    includeButtons: boolean;
    includeBuiltins: boolean;
    includeInteractionTriggers: boolean;
    nodeLimit: number;
    hubDegree: number;
    exclude: string | null;
  };
  trace: {
    start: { uuid: string; file: string | null; type: string | null };
    entry: TraceEntryKey;
    seeds: TraceSeed[];
    excluded: TraceExcludedItem[];
    suggestions: TraceSuggestion[];
    /** Absent only on a server before Script Trace v2. */
    ways?: FlowWay[];
    overview?: {
      down: { start: string; byLevel: Record<string, number>; byKind: Record<string, number> };
      up: { start: string; byLevel: Record<string, number>; byEntry: Record<string, number> };
    };
    refs?: Record<string, FlowRef>;
    effectsTotal?: Record<string, number>;
    blindSpots?: { dynamicCalls: number; unresolvedCalls: number; sites: FlowBlindSite[]; noDdr?: NoDdrBlindSpot };
    stats: FlowTraceStats;
  };
  truncated: boolean;
  stats: TraceStats;
  /** Change activity: stamps present + data state (colour lens "activity"). */
  activity?: GraphActivityHead;
  nodes: GraphNode[];
  edges: GraphEdge[];
};

export type TraceEntry = {
  entry: TraceEntryKey;
  label: string;
  isDefault: boolean;
  seedCount: number;
  seedsSample: string[];
};

/**
 * Frontend-Deep-Link-Familie (`?trace=…&up=…&down=…&tdepth=…`) ↔ API-Params
 * (`start`, `up_depth`, `down_depth`, `trigger_depth`) — die Übersetzung lebt
 * ausschließlich hier (Frontend-Param ≠ API-Param, wie `dir` ↔ `direction`).
 */
export type TraceParams = {
  start: string;
  startFile?: string | null;
  entry?: TraceEntryKey | null;
  upDepth: number;
  downDepth: number;
  triggerDepth: number;
  expandUp: boolean;
  includeLocalVars: boolean;
  includeButtons: boolean;
  /** Interaktions-Events (Keystroke & Co.) in die Kaskade aufnehmen. */
  includeInteractionTriggers: boolean;
  /** Composite-Node-IDs der Boundary-Ausschlüsse (leer = keine). */
  exclude?: string[];
  /** Deaktivierte Schritte mitverfolgen (`include_disabled`, SD6). */
  includeDisabled?: boolean;
  /** „Quelle verfolgen" aufwärts: Weg-IDs, deren Einstieg eine Ebene weiter geht. */
  expandWay?: string[];
};

/**
 * Exclude-fähige Typen (geteilt von InspectPanel + Typ-Objektliste) —
 * getrennt vom v1-Trace-Start-Gate (Script/Layout): Felder sind keine
 * Startobjekte, schalten aber über fields0/1/2 die selektiven Objekt-Trigger
 * der Stufe 3 scharf und sind deshalb ausschließbar.
 */
/** „Quelle verfolgen": höchstens 20 Weg-IDs (Validator graphTrace.expand_way). */
export const TRACE_EXPAND_MAX = 20;

export const EXCLUDABLE_TYPES = new Set(['Script', 'Layout', 'Field']);

export const TRACE_DEFAULTS = {
  upDepth: 3,
  downDepth: 6,
  triggerDepth: 1,
  expandUp: false,
  includeLocalVars: false,
  includeButtons: false,
  includeInteractionTriggers: false,
  includeDisabled: false,
} as const;

type ApiEnvelope<T> = {
  success: boolean;
  data: T;
  error?: { code?: string; message: string; details?: { entries?: TraceEntry[] } };
};

const baseUrl = `${API_BASE}/api`;

export function buildTraceQuery(p: TraceParams, extra?: Record<string, string>): string {
  const q = new URLSearchParams();
  q.set('start', p.start);
  if (p.startFile) q.set('start_file', p.startFile);
  if (p.entry) q.set('entry', p.entry);
  q.set('up_depth', String(p.upDepth));
  q.set('down_depth', String(p.downDepth));
  q.set('trigger_depth', String(p.triggerDepth));
  if (p.expandUp) q.set('expand_up', 'true');
  if (p.includeLocalVars) q.set('include_local_vars', 'true');
  if (p.includeButtons) q.set('include_buttons', 'true');
  if (p.includeInteractionTriggers) q.set('include_interaction_triggers', 'true');
  if (p.exclude && p.exclude.length > 0) q.set('exclude', p.exclude.join(','));
  if (p.includeDisabled) q.set('include_disabled', 'true');
  if (p.expandWay && p.expandWay.length > 0) q.set('expand_way', p.expandWay.join(','));
  for (const [k, v] of Object.entries(extra ?? {})) q.set(k, v);
  return q.toString();
}

/**
 * Fetches the trace. `params = null` disables the hook (subgraph mode).
 * A 422 TRACE_EMPTY_ENTRY is not a hard error — the chosen preset has no
 * seeds; the server sends the available presets, exposed as `emptyEntries`
 * so the host can render the entry chooser instead of an error wall.
 */
export function useTrace(params: TraceParams | null) {
  const [data, setData] = useState<TraceResponse | null>(null);
  const [emptyEntries, setEmptyEntries] = useState<TraceEntry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // SCHEMA_DRIFT / DATAFLOW_NOT_BUILT (SD16) — the host shows a hint instead of the raw error.
  const [errorCode, setErrorCode] = useState<string | null>(null);

  const key = params ? buildTraceQuery(params) : null;

  useEffect(() => {
    if (!key) {
      setData(null);
      setEmptyEntries(null);
      setError(null);
      setErrorCode(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setErrorCode(null);
    setEmptyEntries(null);

    fetch(`${baseUrl}/graph/trace?${key}`)
      .then(async (r) => {
        const json: ApiEnvelope<TraceResponse> = await r.json();
        if (!r.ok || !json.success) {
          if (json.error?.code === 'TRACE_EMPTY_ENTRY') {
            return { empty: json.error.details?.entries ?? [] };
          }
          throw new TraceApiError(json.error?.message || `HTTP ${r.status}`, json.error?.code ?? null);
        }
        return { data: json.data };
      })
      .then((res) => {
        if (cancelled) return;
        if ('empty' in res) {
          setData(null);
          setEmptyEntries(res.empty ?? []);
        } else {
          setData(res.data);
        }
      })
      .catch((err) => {
        if (cancelled) return;
        setData(null);
        setError(err instanceof Error ? err.message : String(err));
        setErrorCode(err instanceof TraceApiError ? err.code : null);
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

  return { data, emptyEntries, loading, error, errorCode };
}

class TraceApiError extends Error {
  code: string | null;
  constructor(message: string, code: string | null) {
    super(message);
    this.code = code;
  }
}

type FlowMermaidSet = {
  ways: { down: Map<number, WayMermaid>; up: Map<number, WayMermaid> };
  overview: { down: WayMermaid; up: WayMermaid };
};

const flowMermaidCache = new Map<string, Promise<FlowMermaidSet>>();

async function fetchFlowTraceMermaid(p: TraceParams): Promise<FlowMermaidSet> {
  type Resp = {
    trace: {
      ways: (FlowWay & { mermaid?: string; mermaidIds?: Record<string, string> })[];
      overviewMermaid?: { down?: string; up?: string };
      overviewMermaidIds?: { down?: Record<string, string>; up?: Record<string, string> };
    };
  };
  const r = await fetch(`${baseUrl}/graph/trace?${buildTraceQuery(p, { ways_mermaid: 'true' })}`);
  const json: ApiEnvelope<Resp> = await r.json();
  if (!r.ok || !json.success) throw new Error(json.error?.message || `HTTP ${r.status}`);
  const t = json.data.trace;
  const ways = { down: new Map<number, WayMermaid>(), up: new Map<number, WayMermaid>() };
  for (const w of t.ways) {
    if (w.mermaid) ways[w.dir].set(w.wayNo, { text: w.mermaid, ids: w.mermaidIds ?? {} });
  }
  return {
    ways,
    overview: {
      down: { text: t.overviewMermaid?.down ?? '', ids: t.overviewMermaidIds?.down ?? {} },
      up: { text: t.overviewMermaid?.up ?? '', ids: t.overviewMermaidIds?.up ?? {} },
    },
  };
}

/**
 * Mermaid source of one way of the flow trace (0 = overview of the direction).
 * Ways number per direction. All ways come in one `ways_mermaid=true` fetch,
 * kept for the page life per trace params.
 */
export function loadFlowTraceWayMermaid(p: TraceParams, wayNo: number, dir: 'up' | 'down'): Promise<WayMermaid | null> {
  const key = buildTraceQuery(p);
  let all = flowMermaidCache.get(key);
  if (!all) {
    all = fetchFlowTraceMermaid(p);
    // A failed fetch must not stick in the cache.
    all.catch(() => flowMermaidCache.delete(key));
    flowMermaidCache.set(key, all);
  }
  return all.then((m) => (wayNo === 0 ? m.overview[dir] : m.ways[dir].get(wayNo) ?? null));
}

/**
 * Entry-preset preview (`GET /api/graph/trace/entries`). Drives the layout
 * preset chooser BEFORE the first trace fetch; a script start answers with the
 * trivial 'script' preset. `start = null` disables the hook.
 */
export function useTraceEntries(start: string | null, startFile?: string | null) {
  const [entries, setEntries] = useState<TraceEntry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!start) {
      setEntries(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);

    const q = new URLSearchParams({ start });
    if (startFile) q.set('start_file', startFile);
    fetch(`${baseUrl}/graph/trace/entries?${q.toString()}`)
      .then(async (r) => {
        const json: ApiEnvelope<{ entries: TraceEntry[] }> = await r.json();
        if (!r.ok || !json.success) {
          throw new Error(json.error?.message || `HTTP ${r.status}`);
        }
        return json.data.entries;
      })
      .then((e) => {
        if (!cancelled) setEntries(e);
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
  }, [start, startFile]);

  return { entries, loading, error };
}
