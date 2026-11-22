import { useEffect, useState } from 'react';
import { API_BASE } from '../config/apiBase';
import { getSelectedSolution } from '../lib/solutionStore';
import type { GraphNode, GraphEdge, SubgraphStats, GraphActivityHead, OpenTarget } from './useSubgraph';
import type { TraceExcludedItem } from './useTrace';
import type { WayMermaid } from '../lib/traceWays';

/**
 * Data-trace layer — the dataflow mode of `GET /api/graph/trace?mode=data`
 * (sister of {@link useTrace}, which serves the flow mode).
 *
 * Start object is a Field; `dir=up` answers "where does the value come from"
 * (origin), `dir=down` "where does it flow to" (usage). Besides the usual
 * nodes/edges the response carries the ways (field × writer resp. reader), the
 * entry groups per way, the reset group (up), the usage groups (down), the
 * blind spots and the applied solution profile. Nodes and edges ride on the
 * shared GraphNode/GraphEdge types (optional `flowRole`/`flowKind` members), so
 * the Explorer canvas renders them unchanged.
 */

export type DataTraceDir = 'up' | 'down';

/** Frontend view of the data-trace params (URL ↔ API translation lives here). */
export type DataTraceParams = {
  start: string;
  startFile?: string | null;
  dir: DataTraceDir;
  /** Field-to-field transitions (default 1). */
  fieldLevels: number;
  includeControl: boolean;
  includeSinks: boolean;
  includeReset: boolean;
  /** Apply the confirmed solution profile (`profile=on|off`). */
  profile: boolean;
  /** "Follow source": way ids whose source fields get one level more. */
  expandWay: string[];
  /** Boundary exclusions (composite node ids). */
  exclude: string[];
  /** Step anchor of a local variable start: step UUID + its role. */
  startStep?: string | null;
  startRole?: 'read' | 'set' | null;
};

/** Resolved step anchor of the response (`trace.start.step`). */
export type DataTraceStartStep = {
  uuid: string;
  file: string | null;
  role: 'read' | 'set';
  roles: ('read' | 'set')[];
  stepIndex: number | null;
  stepName: string | null;
  scriptUuid: string | null;
  scriptName: string | null;
};

export const DATA_TRACE_DEFAULTS = {
  dir: 'up' as DataTraceDir,
  fieldLevels: 1,
  includeControl: false,
  includeSinks: true,
  includeReset: false,
  profile: true,
} as const;

/** Validator bounds (graphTrace schema). */
export const DATA_TRACE_FIELD_LEVELS_MAX = 10;
export const DATA_TRACE_EXPAND_MAX = 20;

export type DataEntryGroup = {
  /** button · trigger · event · input · import · auto_enter · file · menu · … */
  kind: string;
  /** Trigger event, auto-enter kind or import source kind; null for the rest. */
  event: string | null;
  n: number;
  nLayouts: number;
  layouts: { uuid: string; name: string; file: string | null }[];
  /** Up to three entry node ids (composite) — labels via nodes or refs. */
  sample: string[];
};

export type DataWayField = { id: string; via: string; kind?: 'writes' | 'calc' };

export type DataWay = {
  wayNo: number;
  /** Stable over expansion and params (md5 of field > writer). */
  wayId: string;
  level: number;
  /** Field of the level (composite id). */
  field: string;
  /** Writer (up) resp. reader (down); null = manual entry (one way per field). */
  writer: string | null;
  writerFlowKind: string;
  /** Writer_Kind of the step (calc · constant · reset · input · …); null for non-steps. */
  writerKind: string | null;
  isReset: boolean;
  parentWayId: string | null;
  precision: 'exact' | 'approx' | string;
  nEntries: number;
  entryGroups: DataEntryGroup[];
  /** up: source fields of the writer · down: reached fields (kind writes/calc). */
  fields: DataWayField[];
  pathNodes: string[];
  pathEdges: { source: string; target: string; kind: string }[];
  /** The way touches a file exported without DDR info — it can end early. */
  noDdr?: boolean;
};

export type DataUsageGroup = {
  /** display · sort · export · find · navigate · relationship · valuelist · writes · calc · infrastructure */
  kind: string;
  n: number;
  nSources: number;
  sample: string[];
};

export type DataResetGroup = {
  n: number;
  ways: { wayId: string; level: number; field: string; writer: string | null }[];
};

/** Label info of nodes outside node_limit that ways/groups mention. */
export type DataTraceRef = {
  label: string;
  type: string;
  file: string | null;
  flowRole: string | null;
  depth: number | null;
  ownerUuid: string | null;
  ownerType: string | null;
  stepIndex: number | null;
  stepId: number | null;
  scriptUuid: string | null;
  open?: OpenTarget;
};

export type DataProfileCandidate = {
  key: string;
  heuristic: 'H1' | 'H2' | 'H3' | 'H4' | string;
  kind: string;
  name: string;
  uncertain: boolean;
  pattern?: string;
  uuid?: string;
  file?: string;
};

export type DataTraceProfile = {
  enabled: boolean;
  hash: string;
  confirmed: number;
  orphaned: number;
  applied: {
    technicalLayout: number;
    boundaryScript: number;
    uiStateVariable: number;
    hubVariable: number;
    hubReaders: number;
  };
  candidates: DataProfileCandidate[];
  candidatesError?: string;
};

export type DataTraceStats = {
  states: number;
  truncatedBy: string[];
  cutFieldLevels: number;
  cutVarLevels: number;
  cutStepLimit: number;
  disabledSteps: number;
  contextOpen: number;
  maxFieldLevel: number;
  maxVarLevel: number;
  ways: number;
  waysTotal: number;
  resetWays: number;
  entries: number;
  reachedFields: number;
};

/** Files without DDR info the trace touches; missing / reduced edge kinds there. */
export type NoDdrBlindSpot = {
  files: string[];
  missingKinds: string[];
  reducedKinds: string[];
};

export type DataTraceBlindSpots = {
  uninitialized: number;
  dynamicWrites: number;
  dynamicCalls: number;
  dynamicSql: number;
  approxEdges: number;
  /** Absent on an older API. */
  noDdr?: NoDdrBlindSpot;
};

export type DataTraceResponse = {
  start: string;
  params: Record<string, unknown>;
  trace: {
    mode: 'data';
    dir: DataTraceDir;
    start: { uuid: string; file: string | null; type: string; step?: DataTraceStartStep | null };
    excluded: TraceExcludedItem[];
    stats: DataTraceStats;
    blindSpots: DataTraceBlindSpots;
    ways: DataWay[];
    resetGroup: DataResetGroup | null;
    usageGroups: DataUsageGroup[] | null;
    overview: { fields: string[]; links: { source: string; target: string; wayNo?: number }[] };
    refs: Record<string, DataTraceRef>;
    profile: DataTraceProfile;
  };
  truncated: boolean;
  stats: SubgraphStats;
  /** Not sent by the data trace today; typed for the shared canvas contract. */
  activity?: GraphActivityHead;
  nodes: GraphNode[];
  edges: GraphEdge[];
};

/** Error codes the host turns into a hint instead of an error wall. */
export type DataTraceErrorCode = 'DATAFLOW_NOT_BUILT' | 'SCHEMA_DRIFT' | string;

type ApiEnvelope<T> = {
  success: boolean;
  data: T;
  error?: { code?: string; message: string };
};

const baseUrl = `${API_BASE}/api`;

export function buildDataTraceQuery(p: DataTraceParams, extra?: Record<string, string>): string {
  const q = new URLSearchParams();
  q.set('mode', 'data');
  q.set('start', p.start);
  if (p.startFile) q.set('start_file', p.startFile);
  q.set('dir', p.dir);
  q.set('field_levels', String(p.fieldLevels));
  if (p.includeControl) q.set('include_control', 'true');
  if (!p.includeSinks) q.set('include_sinks', 'false');
  if (p.includeReset) q.set('include_reset', 'true');
  if (!p.profile) q.set('profile', 'off');
  if (p.expandWay.length > 0) q.set('expand_way', p.expandWay.join(','));
  if (p.exclude.length > 0) q.set('exclude', p.exclude.join(','));
  if (p.startStep) {
    q.set('start_step', p.startStep);
    if (p.startRole) q.set('start_role', p.startRole);
  }
  for (const [k, v] of Object.entries(extra ?? {})) q.set(k, v);
  return q.toString();
}

class ApiError extends Error {
  code: string | null;
  constructor(message: string, code: string | null) {
    super(message);
    this.code = code;
  }
}

async function getJson<T>(url: string, init?: RequestInit): Promise<T> {
  const r = await fetch(url, init);
  const json: ApiEnvelope<T> = await r.json();
  if (!r.ok || !json.success) {
    throw new ApiError(json.error?.message || `HTTP ${r.status}`, json.error?.code ?? null);
  }
  return json.data;
}

/**
 * Fetches the data trace. `params = null` disables the hook. `reloadToken`
 * forces a refetch with unchanged params (after a profile change the server
 * cache key changes with the profile hash, the URL does not).
 */
export function useDataTrace(params: DataTraceParams | null, reloadToken = 0) {
  const [data, setData] = useState<DataTraceResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errorCode, setErrorCode] = useState<DataTraceErrorCode | null>(null);

  const key = params ? buildDataTraceQuery(params) : null;

  useEffect(() => {
    if (!key) {
      setData(null);
      setError(null);
      setErrorCode(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setErrorCode(null);
    getJson<DataTraceResponse>(`${baseUrl}/graph/trace?${key}`)
      .then((d) => {
        if (!cancelled) setData(d);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setData(null);
        setError(err instanceof Error ? err.message : String(err));
        setErrorCode(err instanceof ApiError ? err.code : null);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [key, reloadToken]);

  return { data, loading, error, errorCode };
}

export type { WayMermaid };

/**
 * Mermaid source of all ways (`ways_mermaid=true`), built by the server.
 * Loaded on demand — the first open of a way diagram — and keyed by the same
 * params as the trace, so it matches the ways on screen.
 */
export async function fetchDataTraceMermaid(
  p: DataTraceParams,
): Promise<{ ways: Map<number, WayMermaid>; overview: WayMermaid }> {
  type Resp = {
    trace: {
      ways: (DataWay & { mermaid?: string; mermaidIds?: Record<string, string> })[];
      overviewMermaid?: string;
      overviewMermaidIds?: Record<string, string>;
    };
  };
  const d = await getJson<Resp>(`${baseUrl}/graph/trace?${buildDataTraceQuery(p, { ways_mermaid: 'true' })}`);
  const ways = new Map<number, WayMermaid>();
  for (const w of d.trace.ways) {
    if (w.mermaid) ways.set(w.wayNo, { text: w.mermaid, ids: w.mermaidIds ?? {} });
  }
  return {
    ways,
    overview: { text: d.trace.overviewMermaid ?? '', ids: d.trace.overviewMermaidIds ?? {} },
  };
}

const mermaidCache = new Map<string, Promise<{ ways: Map<number, WayMermaid>; overview: WayMermaid }>>();

/**
 * Mermaid source of one way (0 = overview) for the way diagram; the whole set
 * is fetched once per trace params and kept for the page life.
 */
export function loadDataTraceWayMermaid(p: DataTraceParams, wayNo: number): Promise<WayMermaid | null> {
  const key = buildDataTraceQuery(p);
  let all = mermaidCache.get(key);
  if (!all) {
    all = fetchDataTraceMermaid(p);
    // A failed fetch must not stick in the cache.
    all.catch(() => mermaidCache.delete(key));
    mermaidCache.set(key, all);
  }
  return all.then((m) => (wayNo === 0 ? m.overview : m.ways.get(wayNo) ?? null));
}

// ── Capability per solution ────────────────────────────────────────────────

export type DataflowCapability = 'available' | 'not_built' | 'schema_drift' | 'unknown';

/** DDR coverage of the solution: files exported without "Include details for analysis tools". */
export type DdrCoverage = 'all' | 'partial' | 'none' | 'unknown';

type CapabilityInfo = { dataflow: DataflowCapability; ddr: DdrCoverage; noDdrFiles: string[] };

/** One probe per solution and page life (a solution switch reloads the app). */
const capabilityCache = new Map<string, Promise<CapabilityInfo>>();

function probeCapabilityInfo(): Promise<CapabilityInfo> {
  const key = getSelectedSolution() ?? '';
  let p = capabilityCache.get(key);
  if (!p) {
    p = getJson<Partial<CapabilityInfo>>(`${baseUrl}/graph/trace/capability`)
      .then((d) => ({
        dataflow: d.dataflow ?? 'unknown',
        ddr: d.ddr ?? 'unknown',
        noDdrFiles: Array.isArray(d.noDdrFiles) ? d.noDdrFiles : [],
      }))
      // An older API without the probe: assume available, the trace itself
      // still answers 422/409 with a readable message.
      .catch(() => ({ dataflow: 'unknown' as DataflowCapability, ddr: 'unknown' as DdrCoverage, noDdrFiles: [] }));
    capabilityCache.set(key, p);
  }
  return p;
}

function probeCapability(): Promise<DataflowCapability> {
  return probeCapabilityInfo().then((c) => c.dataflow);
}

/**
 * Files of the active solution exported without DDR info (formula references
 * missing there); `null` while probing, `[]` when all files carry DDR info.
 */
export function useNoDdrFiles(): string[] | null {
  const [files, setFiles] = useState<string[] | null>(null);
  useEffect(() => {
    let cancelled = false;
    probeCapabilityInfo().then((c) => {
      if (!cancelled) setFiles(c.noDdrFiles);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return files;
}

/**
 * Can the active solution run the data trace? `null` while probing. Hosts hide
 * "Origin/Usage" for `not_built` and `schema_drift` instead of letting
 * every click fail.
 */
export function useDataflowCapability(): DataflowCapability | null {
  const [cap, setCap] = useState<DataflowCapability | null>(null);
  useEffect(() => {
    let cancelled = false;
    probeCapability().then((c) => {
      if (!cancelled) setCap(c);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return cap;
}

export function dataflowUsable(cap: DataflowCapability | null): boolean {
  return cap === 'available' || cap === 'unknown';
}

// ── Solution profile ───────────────────────────────────────────────────────

export type ProfileCandidateFull = DataProfileCandidate & {
  status: 'open' | 'confirmed' | 'rejected';
  metrics?: Record<string, number>;
  sample?: string[];
};

export type ProfileHeuristic = {
  kind: string;
  open: number;
  confirmed: number;
  rejected: number;
  candidates: ProfileCandidateFull[];
};

export type ProfileRule = {
  key?: string;
  kind: string;
  uuid?: string;
  file?: string;
  pattern?: string;
  name?: string;
  status: 'confirmed' | 'rejected';
  source?: string;
  acts?: boolean;
  matches?: number;
  orphaned?: boolean;
};

export type DataflowProfile = {
  solution: string;
  exists: boolean;
  updatedAt: string | null;
  hash: string;
  summary: { rules: number; confirmed: number; rejected: number; orphaned: number };
  rules: ProfileRule[];
  heuristics: Record<string, ProfileHeuristic>;
};

export function fetchDataflowProfile(): Promise<DataflowProfile> {
  return getJson<DataflowProfile>(`${baseUrl}/graph/trace/profile`);
}

export type ProfileRuleChange = {
  kind: string;
  uuid?: string;
  file?: string;
  pattern?: string;
  name?: string;
  status: 'confirmed' | 'rejected' | 'none';
  source?: string;
};

export type ProfileChange =
  | { rules: ProfileRuleChange[] }
  | { heuristic: { id: string; status: 'confirmed' | 'rejected'; except?: string[]; include_uncertain?: boolean } };

export function putDataflowProfile(change: ProfileChange): Promise<DataflowProfile> {
  return getJson<DataflowProfile>(`${baseUrl}/graph/trace/profile`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(change),
  });
}

/** Rule change from a candidate (pattern or uuid + file carry the rule key). */
export function candidateRule(c: DataProfileCandidate, status: 'confirmed' | 'rejected'): ProfileRuleChange {
  const base = { kind: c.kind, name: c.name, status, source: c.heuristic };
  return c.pattern !== undefined ? { ...base, pattern: c.pattern } : { ...base, uuid: c.uuid, file: c.file };
}
