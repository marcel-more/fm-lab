import { useEffect, useState } from 'react';
import { API_BASE } from '../config/apiBase';
import type { GraphNode, GraphEdge, SubgraphStats } from './useSubgraph';

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
    stats: { dynamicCalls: number };
  };
  truncated: boolean;
  stats: TraceStats;
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
};

/**
 * Exclude-fähige Typen (geteilt von InspectPanel + Typ-Objektliste) —
 * getrennt vom v1-Trace-Start-Gate (Script/Layout): Felder sind keine
 * Startobjekte, schalten aber über fields0/1/2 die selektiven Objekt-Trigger
 * der Stufe 3 scharf und sind deshalb ausschließbar.
 */
export const EXCLUDABLE_TYPES = new Set(['Script', 'Layout', 'Field']);

export const TRACE_DEFAULTS = {
  upDepth: 3,
  downDepth: 6,
  triggerDepth: 1,
  expandUp: false,
  includeLocalVars: false,
  includeButtons: false,
  includeInteractionTriggers: false,
} as const;

type ApiEnvelope<T> = {
  success: boolean;
  data: T;
  error?: { code?: string; message: string; details?: { entries?: TraceEntry[] } };
};

const baseUrl = `${API_BASE}/api`;

function buildTraceQuery(p: TraceParams): string {
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

  const key = params ? buildTraceQuery(params) : null;

  useEffect(() => {
    if (!key) {
      setData(null);
      setEmptyEntries(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setEmptyEntries(null);

    fetch(`${baseUrl}/graph/trace?${key}`)
      .then(async (r) => {
        const json: ApiEnvelope<TraceResponse> = await r.json();
        if (!r.ok || !json.success) {
          if (json.error?.code === 'TRACE_EMPTY_ENTRY') {
            return { empty: json.error.details?.entries ?? [] };
          }
          throw new Error(json.error?.message || `HTTP ${r.status}`);
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

  return { data, emptyEntries, loading, error };
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
