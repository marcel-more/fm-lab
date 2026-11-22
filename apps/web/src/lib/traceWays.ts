/**
 * Pure helpers of the trace way lists (flow and data mode): the way tree,
 * the search, the full path of a flow way and the jump target of a step reference.
 * No React, no fetch — unit-tested under `tests/traceWays.test.ts`.
 */

/** Mermaid text of one way plus the map Mermaid node id → graph id / key. */
export type WayMermaid = { text: string; ids: Record<string, string> };

/** Minimal shape of a way for the tree (both trace modes). */
export type TreeWay = { wayId: string; parentWayId: string | null };

/**
 * Ways as a tree: a way whose parent is in the list nests under it, every other
 * way is a root. Order inside each level follows the input order (the server
 * already sorts deterministically).
 */
export function buildWayTree<W extends TreeWay>(ways: W[]): { roots: W[]; children: Map<string, W[]> } {
  const ids = new Set(ways.map((w) => w.wayId));
  const children = new Map<string, W[]>();
  const roots: W[] = [];
  for (const w of ways) {
    if (w.parentWayId && ids.has(w.parentWayId) && w.parentWayId !== w.wayId) {
      const list = children.get(w.parentWayId) ?? [];
      list.push(w);
      children.set(w.parentWayId, list);
    } else {
      roots.push(w);
    }
  }
  return { roots, children };
}

/**
 * Search in a way list: a hit is a way whose name (target script down, entry
 * script up — the caller supplies it) contains the needle, case-insensitive;
 * `keep` adds every ancestor of a hit along `parentWayId`, so the tree stays
 * readable. An empty needle returns null (no filter).
 */
export function searchWays<W extends TreeWay>(
  ways: W[],
  nameOf: (way: W) => string,
  needle: string,
): { hits: Set<string>; keep: Set<string> } | null {
  const q = needle.trim().toLocaleLowerCase();
  if (!q) return null;
  const byId = new Map(ways.map((w) => [w.wayId, w]));
  const hits = new Set<string>();
  const keep = new Set<string>();
  for (const w of ways) {
    if (!nameOf(w).toLocaleLowerCase().includes(q)) continue;
    hits.add(w.wayId);
    for (let cur: W | undefined = w; cur && !keep.has(cur.wayId); cur = cur.parentWayId ? byId.get(cur.parentWayId) : undefined) {
      keep.add(cur.wayId);
    }
  }
  return { hits, keep };
}

/** Way of the flow trace as far as the path reconstruction needs it. */
export type PathWay = {
  wayId: string;
  dir: 'up' | 'down';
  target: string;
  pathPrefix?: string | null;
  /** Upward ways of "follow source": the full path of this way follows the section. */
  pathSuffix?: string | null;
  pathNodes: string[];
  event?: string | null;
  eventOwner?: string | null;
};

export type PathEdge = {
  source: string;
  target: string;
  kind: 'step' | 'call' | 'navigate' | 'event';
  event?: string;
  owner?: string;
  precision?: 'approx';
};

const isStepType = (t: string | null | undefined) => t === 'ScriptStep' || t === 'DynamicCall';

/**
 * Full path of a flow way (port of the server's `expandWayPath`): the sections
 * along `pathPrefix` (before) and `pathSuffix` (after) joined, the edges derived
 * from node order and types — Script → step `step`, step → Script `call`,
 * step → Layout `navigate`, Layout → Script `event` (event of the way whose
 * section holds the layout, else of the way the edge closes), Script → Script
 * `call` without a step anchor (`approx`).
 */
export function expandWayPath(
  ways: PathWay[],
  way: PathWay,
  typeOf: (id: string) => string | null | undefined,
): { pathNodes: string[]; pathEdges: PathEdge[] } {
  const byId = new Map(ways.filter((w) => w.dir === way.dir).map((w) => [w.wayId, w]));
  const seen = new Set<string>([way.wayId]);
  const before: PathWay[] = [];
  let p: PathWay | undefined = way.pathPrefix ? byId.get(way.pathPrefix) : undefined;
  while (p && !seen.has(p.wayId)) {
    seen.add(p.wayId);
    before.unshift(p);
    p = p.pathPrefix ? byId.get(p.pathPrefix) : undefined;
  }
  const after: PathWay[] = [];
  let q: PathWay | undefined = way.pathSuffix ? byId.get(way.pathSuffix) : undefined;
  while (q && !seen.has(q.wayId)) {
    seen.add(q.wayId);
    after.push(q);
    q = q.pathSuffix ? byId.get(q.pathSuffix) : undefined;
  }
  const chain = [...before, way, ...after];
  const pathNodes: string[] = [];
  const ownerAt: PathWay[] = [];
  for (const w of chain) {
    for (const id of w.pathNodes) {
      pathNodes.push(id);
      ownerAt.push(w);
    }
  }
  const pathEdges: PathEdge[] = [];
  for (let i = 1; i < pathNodes.length; i += 1) {
    const source = pathNodes[i - 1];
    const target = pathNodes[i];
    const ts = typeOf(source);
    const tt = typeOf(target);
    if (isStepType(tt)) pathEdges.push({ source, target, kind: 'step' });
    else if (isStepType(ts)) pathEdges.push({ source, target, kind: tt === 'Layout' ? 'navigate' : 'call' });
    else if (ts === 'Layout') {
      const own = ownerAt[i - 1];
      const owner = own?.event ? own : chain.find((w) => w.target === target && w.event);
      const edge: PathEdge = { source, target, kind: 'event' };
      if (owner?.event) edge.event = owner.event;
      if (owner?.eventOwner) edge.owner = owner.eventOwner;
      pathEdges.push(edge);
    } else pathEdges.push({ source, target, kind: 'call', precision: 'approx' });
  }
  return { pathNodes, pathEdges };
}

/**
 * Jump target of a step or DynamicCall reference of the flow trace: the
 * reference carries only its script UUID (`refs[id].script`); step UUID and
 * file live in the key `<Step_UUID>[#dyncall]::<file>`. The script lives in
 * the same file as its step.
 */
export function stepRefTarget(
  id: string,
  scriptUuid: string,
): { type: 'Script'; uuid: string; file: string | null; step: string } {
  const sep = id.indexOf('::');
  const head = sep === -1 ? id : id.slice(0, sep);
  const file = sep === -1 ? null : id.slice(sep + 2);
  const hash = head.indexOf('#');
  return { type: 'Script', uuid: scriptUuid, file, step: hash === -1 ? head : head.slice(0, hash) };
}

/** Node info as far as {@link diagramPreviewTarget} needs it (see `WayNodeInfo`). */
export type PreviewNodeInfo = {
  id: string;
  file: string | null;
  inGraph: boolean;
  scriptUuid: string | null;
  ownerUuid: string | null;
};

/**
 * Canvas node to highlight while the pointer rests on a node of a way diagram.
 * The diagram maps its nodes to graph ids, flow-trace step keys or entry-group
 * keys; only some of them stand in the canvas:
 *
 * - a node of the loaded graph → itself;
 * - a step outside the canvas (flow trace) → its script;
 * - a calculation / pseudo node outside the canvas (data trace) → its owner;
 * - an entry group (`<script>#entry:<kind>:<event>`) or anything else → none.
 *
 * Script and owner live in the step's file; graph ids read `<uuid>::<file>`.
 */
export function diagramPreviewTarget(
  id: string,
  info: (id: string) => PreviewNodeInfo | null,
  inCanvas: (graphId: string) => boolean,
): string | null {
  if (id.includes('#entry:')) return null;
  const i = info(id);
  if (!i) return null;
  if (i.inGraph) return i.id;
  for (const anchor of [i.scriptUuid, i.ownerUuid]) {
    if (!anchor) continue;
    const graphId = i.file ? `${anchor}::${i.file}` : anchor;
    if (inCanvas(graphId)) return graphId;
  }
  return null;
}

/** Call site as far as its label needs it (see `CallSite` in hooks/useTrace). */
export type CallSiteLike = {
  stepIndex: number;
  stepId: number;
  enabled?: boolean;
  guard?: { kind: string; text?: string; textFull?: string } | null;
  inLoop?: boolean;
  unreachable?: boolean;
};

/** Catalog step names of the call-site step ids (as in the way list and Mermaid). */
export const CALL_STEP_NAMES: Readonly<Record<number, string>> = Object.freeze({
  1: 'Perform Script',
  6: 'Go to Layout',
  164: 'Perform Script on Server',
  210: 'Perform Script on Server with Callback',
});

/**
 * One line per call site: `#12 Perform Script · If $mode = "new" · ↻ · Server`.
 * Missing fields mean 0 / false (the server drops empty fields); the condition
 * keeps the catalog's step names (If / Else If / Else).
 */
export function callSiteText(c: CallSiteLike, words: { unreachable: string; disabled: string }): string {
  const parts = [`#${c.stepIndex + 1} ${CALL_STEP_NAMES[c.stepId] ?? `Step ${c.stepId}`}`];
  const g = c.guard;
  if (g) {
    parts.push(g.kind === 'else' ? 'Else' : `${g.kind === 'elseif' ? 'Else If' : 'If'} ${g.textFull ?? g.text ?? ''}`.trim());
  }
  if (c.inLoop) parts.push('↻');
  if (c.stepId === 164 || c.stepId === 210) parts.push('Server');
  if (c.unreachable) parts.push(words.unreachable);
  if (c.enabled === false) parts.push(words.disabled);
  return parts.join(' · ');
}
