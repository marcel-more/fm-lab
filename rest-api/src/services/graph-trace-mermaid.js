/**
 * Mermaid source of the ways of a trace (GET /api/graph/trace): data trace
 * (mode=data) and flow trace (mode=flow, Script Trace v2 — see buildFlowWayMermaid).
 *
 * Pure functions over the trace payload of graph.service#getDataTrace — no
 * database, no renderer. Used for `ways_mermaid=true` (source per way in the
 * JSON) and for `format=mermaid-raw|svg|mermaid&way=n` (one way).
 *
 * - Way n ≥ 1: the path nodes and path edges of the way (data-flow direction:
 *   entries and sources on the left, the field on the right). Flow edges
 *   (script runs step, step calls script) are dotted.
 * - Way 0: overview field → field over all returned ways, edge text = way number.
 *
 * Labels come from the trace nodes and refs; a node without a label (the way
 * was built without labels_all) falls back to its UUID.
 */

const { buildFlowchart } = require('../formatters/mermaid/builder');
const { TYPE_BORDER_COLORS } = require('../formatters/mermaid/palette');
const { expandWayPath } = require('./graph-trace-flow-ways');

/** Border colours per flow role (mid-tones, readable light and dark). */
const ROLE_COLORS = Object.freeze({
  start: '#f59e0b',
  field: '#22c55e',
  step: '#0ea5e9',
  variable: '#ca8a04',
  param: '#a855f7',
  result: '#a855f7',
  calc: '#8b5cf6',
  entry: '#ec4899',
  control: '#64748b',
  sink: '#94a3b8',
  blind: '#ef4444',
});

/** Node shapes per flow role. */
const ROLE_SHAPES = Object.freeze({
  start: 'stadium',
  field: 'rect',
  step: 'round',
  variable: 'stadium',
  param: 'stadium',
  result: 'stadium',
  calc: 'hexagon',
  entry: 'subroutine',
  control: 'round',
  sink: 'cylinder',
  blind: 'rhombus',
});

/** Pseudo nodes get a role suffix — their label is the owner's name. */
const ROLE_SUFFIX = Object.freeze({
  param: 'parameter',
  result: 'result',
});

const FLOW_KINDS = new Set(['script_runs_step', 'step_calls_script']);

/** id → node info from the trace nodes and refs. */
function nodeIndex(payload) {
  const index = new Map();
  for (const n of payload.nodes || []) index.set(n.id, n);
  const refs = payload.trace?.refs || {};
  for (const [id, n] of Object.entries(refs)) {
    if (!index.has(id)) index.set(id, { id, ...n });
  }
  return index;
}

function nodeLabel(info, id) {
  const base = info?.label || String(id).split('::')[0];
  const suffix = ROLE_SUFFIX[info?.flowRole];
  return suffix ? `${base} (${suffix})` : base;
}

function graphNode(index, id, startId) {
  const info = index.get(id);
  const role = id === startId ? 'start' : (info?.flowRole || 'field');
  return {
    key: id,
    label: nodeLabel(info, id),
    kind: role,
    shape: ROLE_SHAPES[role] || 'rect',
    order: Number.isFinite(info?.depth) ? -info.depth : 0,
  };
}

function startId(payload) {
  const focus = (payload.nodes || []).find((n) => n.isFocus);
  if (focus) return focus.id;
  const start = payload.trace?.start;
  return start ? `${start.uuid}::${start.file ?? ''}` : null;
}

/**
 * Mermaid source of one way of a data trace.
 * @param {Object} payload - data trace payload (nodes, trace.ways, trace.refs, trace.overview)
 * @param {number} wayNo - 0 = overview, n = way n
 * @param {Object} [options] - direction, nodeLimit
 * @returns {{text:string, truncated:Object|null}|null} null when the way does not exist
 */
function buildWayMermaid(payload, wayNo, options = {}) {
  const index = nodeIndex(payload);
  const sid = startId(payload);
  const ways = payload.trace?.ways || [];
  const opts = {
    direction: options.direction || 'LR',
    classes: ROLE_COLORS,
    nodeLimit: options.nodeLimit,
  };

  if (wayNo === 0) {
    const overview = payload.trace?.overview || { fields: [], links: [] };
    const fields = new Set(overview.fields || []);
    if (sid) fields.add(sid);
    const nodes = [...fields].map((id) => graphNode(index, id, sid));
    const edges = (overview.links || []).map((l) => ({ from: l.source, to: l.target, label: `#${l.wayNo}` }));
    return buildFlowchart({ nodes, edges }, {
      ...opts,
      comments: [`overview · ${ways.length} ways · ${payload.trace?.dir === 'down' ? 'usage' : 'origin'}`],
    });
  }

  const way = ways.find((w) => w.wayNo === wayNo);
  if (!way) return null;
  const nodes = (way.pathNodes || []).map((id) => graphNode(index, id, sid));
  const edges = (way.pathEdges || []).map((e) => ({
    from: e.source,
    to: e.target,
    style: FLOW_KINDS.has(e.kind) ? 'dotted' : 'solid',
  }));
  return buildFlowchart({ nodes, edges }, {
    ...opts,
    comments: [`way ${way.wayNo} · level ${way.level} · ${way.precision}`],
  });
}

// ── flow trace (mode=flow) ─────────────────────────────────────────────────

/**
 * Border colours per role of a flow way. Scripts and layouts take their
 * Explorer type colour; steps share the step blue of the data trace — the
 * shapes keep script (rect) and step (round), start (stadium) and layout
 * (subroutine) apart.
 */
const FLOW_ROLE_COLORS = Object.freeze({
  start: ROLE_COLORS.start,
  script: TYPE_BORDER_COLORS.Script,
  step: ROLE_COLORS.step,
  layout: TYPE_BORDER_COLORS.Layout,
  entry: ROLE_COLORS.entry,
  boundary: ROLE_COLORS.control,
  blind: ROLE_COLORS.blind,
});

const FLOW_ROLE_SHAPES = Object.freeze({
  start: 'stadium',
  script: 'rect',
  step: 'round',
  layout: 'subroutine',
  entry: 'subroutine',
  boundary: 'stadium',
  blind: 'rhombus',
});

const SERVER_STEPS = new Set([164, 210]); // Perform Script on Server (with Callback)

/** Flow role of a path node: start, script, step, layout, blind or entry. */
function flowRoleOf(info, id, sid) {
  if (id === sid) return 'start';
  const type = info?.type;
  if (type === 'ScriptStep') return 'step';
  if (type === 'DynamicCall') return 'blind';
  if (type === 'Script') return 'script';
  if (type === 'Layout') return 'layout';
  return info?.flowRole && FLOW_ROLE_SHAPES[info.flowRole] ? info.flowRole : 'entry';
}

function flowNode(index, id, sid, order) {
  const info = index.get(id);
  const role = flowRoleOf(info, id, sid);
  return {
    key: id,
    label: info?.label || String(id).split('::')[0],
    kind: role,
    shape: FLOW_ROLE_SHAPES[role],
    order,
  };
}

/**
 * Edge text of the step a script runs: the innermost condition (If / Else If /
 * Else in FileMaker's step names, as the step labels), ↻ in a loop, ×n for
 * several call sites of the same edge, `unreachable` after Exit Script /
 * Halt Script.
 */
function stepEdgeLabel(site) {
  if (!site) return '';
  const parts = [];
  const g = site.guard;
  if (g) {
    const text = g.text ? ` ${g.text}` : '';
    if (g.kind === 'if') parts.push(`If${text}`);
    else if (g.kind === 'elseif') parts.push(`Else If${text}`);
    else if (g.kind === 'else') parts.push('Else');
  }
  if (site.inLoop) parts.push('↻');
  if (site.sites > 1) parts.push(`×${site.sites}`);
  if (site.unreachable) parts.push('unreachable');
  return parts.join(' · ');
}

/** Event of a Layout → Script edge; UI actions (button, menu item) get a word. */
function eventLabel(event) {
  if (event === 'button_action') return 'Button';
  if (event === 'menu_action') return 'Menu';
  return event || '';
}

/** One path edge → builder edge (label and style by kind). */
function flowEdge(index, e) {
  if (e.kind === 'step') {
    const site = index.get(e.target)?.site;
    return { from: e.source, to: e.target, label: stepEdgeLabel(site), style: 'solid' };
  }
  if (e.kind === 'event') return { from: e.source, to: e.target, label: eventLabel(e.event), style: 'dotted' };
  if (e.precision === 'approx') return { from: e.source, to: e.target, label: 'approx', style: 'dotted' };
  if (e.kind === 'call' && SERVER_STEPS.has(index.get(e.source)?.stepId)) {
    return { from: e.source, to: e.target, label: 'Server', style: 'thick' };
  }
  return { from: e.source, to: e.target, style: 'solid' };
}

/** Label of an entry group node of an upward way. */
function entryGroupLabel(g) {
  const where = g.nLayouts > 0 ? ` · ${g.nLayouts} ${g.nLayouts === 1 ? 'layout' : 'layouts'}` : '';
  switch (g.kind) {
    case 'button': return `Button ×${g.n}${where}`;
    case 'trigger': return `${g.event || 'Trigger'} ×${g.n}${where}`;
    case 'menu': return `Menu ×${g.n}`;
    case 'file': return `${g.event || 'File trigger'} (file)`;
    case 'root': return 'no caller';
    case 'budget': return `${g.n} ${g.n === 1 ? 'caller' : 'callers'} beyond up_depth`;
    case 'excluded': return `excluded · ${g.n} ${g.n === 1 ? 'caller' : 'callers'}`;
    default: return g.kind;
  }
}

/** Key of an entry group node (not a graph id — the group stands for its objects). */
function entryGroupKey(target, g) {
  return `${target}#entry:${g.kind}:${g.event ?? ''}`;
}

function entryGroupNodes(way, order) {
  return (way.entryGroups || []).map((g) => ({
    key: entryGroupKey(way.target, g),
    label: entryGroupLabel(g),
    kind: ['root', 'budget', 'excluded'].includes(g.kind) ? 'boundary' : 'entry',
    shape: ['root', 'budget', 'excluded'].includes(g.kind) ? FLOW_ROLE_SHAPES.boundary : FLOW_ROLE_SHAPES.entry,
    order,
  }));
}

/**
 * Mermaid source of one way of a flow trace (direction `dir`).
 *
 * - Way n ≥ 1: the full path (pathPrefix segments joined, edges derived —
 *   expandWayPath), start or entry on the left. Scripts and steps are nodes;
 *   the edge script → step carries the condition, a server call is thick, an
 *   event edge (layout → script) dotted with the event name, a call without a
 *   step anchor dotted „approx“. Upward ways start with their entry groups.
 * - Way 0 downward: the call tree without steps (previous script → target,
 *   cascades dotted with the event); upward: entry groups → entry scripts →
 *   start, edge text = levels between.
 *
 * @param {Object} payload - flow trace payload (nodes, trace.ways, trace.refs)
 * @param {number} wayNo - 0 = overview, n = way n of the direction
 * @param {Object} [options] - dir ('down' | 'up'), direction, nodeLimit
 * @returns {{text:string, ids:Map, truncated:Object|null}|null} null when the way does not exist
 */
function buildFlowWayMermaid(payload, wayNo, options = {}) {
  const dir = options.dir === 'up' ? 'up' : 'down';
  const index = nodeIndex(payload);
  const sid = startId(payload);
  const all = payload.trace?.ways || [];
  const ways = all.filter((w) => w.dir === dir);
  const typeOf = (id) => index.get(id)?.type ?? null;
  const opts = {
    direction: options.direction || 'LR',
    classes: FLOW_ROLE_COLORS,
    nodeLimit: options.nodeLimit,
  };

  if (wayNo === 0) {
    const byId = new Map(ways.map((w) => [w.wayId, w]));
    const nodes = [flowNode(index, sid, sid, 0)];
    const edges = [];
    if (dir === 'down') {
      for (const w of ways) {
        nodes.push(flowNode(index, w.target, sid, w.level));
        const parent = w.parentWayId ? byId.get(w.parentWayId) : null;
        const from = parent ? parent.target : sid;
        if (w.kind === 'cascade' || w.kind === 'trigger') {
          edges.push({ from, to: w.target, label: eventLabel(w.event), style: 'dotted' });
        } else {
          edges.push({ from, to: w.target, style: w.kind === 'dynamic' ? 'dotted' : 'solid' });
        }
      }
    } else {
      for (const w of ways) {
        // entry groups left of their script, scripts left of the start
        if (w.target !== sid) nodes.push(flowNode(index, w.target, sid, -w.level));
        for (const g of entryGroupNodes(w, -w.level - 1)) {
          nodes.push(g);
          edges.push({ from: g.key, to: w.target, style: 'dotted' });
        }
        // „Quelle verfolgen“: neue Einstiege führen zum Einstieg des Eltern-Wegs
        const parent = w.parentWayId ? byId.get(w.parentWayId) : null;
        const to = parent ? parent.target : sid;
        const levels = parent ? w.level - parent.level : w.level;
        if (w.target !== sid) {
          edges.push({ from: w.target, to, label: levels > 1 ? `${levels} levels` : '', style: parent ? 'dotted' : 'solid' });
        }
      }
    }
    return buildFlowchart({ nodes, edges }, {
      ...opts,
      comments: [`overview · ${ways.length} ways · ${dir === 'down' ? 'calls' : 'reached from'}`],
    });
  }

  const way = ways.find((w) => w.wayNo === wayNo);
  if (!way) return null;
  const path = expandWayPath(all, way, typeOf);
  const nodes = path.pathNodes.map((id, i) => flowNode(index, id, sid, i + 1));
  const edges = path.pathEdges.map((e) => flowEdge(index, e));
  if (dir === 'up') {
    for (const g of entryGroupNodes(way, 0)) {
      nodes.push(g);
      edges.push({ from: g.key, to: way.target, style: 'dotted' });
    }
  }
  const f = way.flags || {};
  const marks = [
    `conditions ${f.conditions ?? 0}`,
    ...['loop', 'server', 'crossFile', 'param', 'cascade', 'unreachable'].filter((k) => f[k]),
  ];
  return buildFlowchart({ nodes, edges }, {
    ...opts,
    comments: [`way ${way.wayNo} · ${dir} · ${way.kind} · level ${way.level} · ${way.precision} · ${marks.join(' · ')}`],
  });
}

/**
 * Way diagram for either trace mode: flow traces (trace.mode = 'flow') count
 * their ways per direction (`options.dir`), data traces have one direction.
 */
function buildTraceWayMermaid(payload, wayNo, options = {}) {
  return payload.trace?.mode === 'flow'
    ? buildFlowWayMermaid(payload, wayNo, options)
    : buildWayMermaid(payload, wayNo, options);
}

module.exports = {
  buildWayMermaid,
  buildFlowWayMermaid,
  buildTraceWayMermaid,
  ROLE_COLORS,
  ROLE_SHAPES,
  FLOW_ROLE_COLORS,
  FLOW_ROLE_SHAPES,
};
