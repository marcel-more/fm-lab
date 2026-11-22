/**
 * Mermaid flowchart builder — the one place that writes Mermaid source on the
 * server. Every consumer (query/report formats, graph traces, skills) hands it
 * nodes and edges; it escapes the text, numbers the nodes deterministically and
 * keeps the source within the renderer limits.
 *
 * Rules:
 * - Text is escaped with Mermaid entity codes (`#amp; #quot; #lt; #gt; #96;`,
 *   plus `#35;` for `#` and `#124;` for `|`), line breaks become `<br/>`.
 *   Object names from a FileMaker solution are data: nothing in a name can
 *   close a label, start a link or inject a directive.
 * - Node ids are `n<idx>` in sort order (order, label, key), group ids
 *   `g<idx>` — the same input always yields the same text.
 * - Each node kind becomes the class `k_<kind>`; a `classDef` sets only the
 *   border colour, so the diagram stays readable on light and dark surfaces.
 *   Colours must be hex values and come from code, never from data.
 * - Above the node limit or the source limit the diagram is cut (first nodes in
 *   sort order) and a `%%` comment line says how much is shown.
 */

const { MERMAID_SOURCE_LIMIT, MERMAID_NODE_LIMIT } = require('../../config/constants');

const DIRECTIONS = new Set(['TD', 'TB', 'BT', 'LR', 'RL']);
const DEFAULT_DIRECTION = 'LR';

const ENTITIES = {
  '#': '#35;',
  '&': '#amp;',
  '"': '#quot;',
  '<': '#lt;',
  '>': '#gt;',
  '`': '#96;',
  '|': '#124;',
};

/** Node shapes: opening and closing bracket around the quoted label. */
const SHAPES = {
  rect: ['[', ']'],
  round: ['(', ')'],
  stadium: ['([', '])'],
  subroutine: ['[[', ']]'],
  cylinder: ['[(', ')]'],
  hexagon: ['{{', '}}'],
  rhombus: ['{', '}'],
};

/** Edge arrows by style. */
const ARROWS = {
  solid: '-->',
  dotted: '-.->',
  thick: '==>',
};

const HEX_COLOR = /^#[0-9a-fA-F]{3,8}$/;

/**
 * Escapes text for a quoted Mermaid label. All special characters are replaced
 * in one pass (no double escaping); CR/LF become `<br/>`, other control
 * characters a space.
 * @param {*} text
 * @returns {string}
 */
function escapeText(text) {
  if (text === null || text === undefined) return '';
  return String(text)
    .replace(/[#&"<>`|]/g, (ch) => ENTITIES[ch])
    .replace(/\r\n?|\n/g, '<br/>')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, ' ');
}

/** Text of a `%%` comment line: one line, no `%%` inside. */
function commentText(text) {
  return String(text ?? '')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/%%/g, '% %')
    .trim();
}

/** Class name of a node kind: `k_<kind>` with only [A-Za-z0-9_]. */
function className(kind) {
  return `k_${String(kind).replace(/[^A-Za-z0-9_]/g, '_')}`;
}

/** Code-point comparison — independent of the server locale. */
function cmp(a, b) {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

function normalizeDirection(direction) {
  const d = String(direction || '').toUpperCase();
  return DIRECTIONS.has(d) ? d : DEFAULT_DIRECTION;
}

function prepareNodes(nodes) {
  const seen = new Map();
  for (const node of nodes || []) {
    if (!node || node.key === null || node.key === undefined || node.key === '') continue;
    const key = String(node.key);
    if (seen.has(key)) continue;
    seen.set(key, {
      key,
      label: node.label === null || node.label === undefined || node.label === '' ? key : String(node.label),
      kind: node.kind === null || node.kind === undefined || node.kind === '' ? null : String(node.kind),
      group: node.group === null || node.group === undefined || node.group === '' ? null : String(node.group),
      shape: SHAPES[node.shape] ? node.shape : 'rect',
      order: Number.isFinite(node.order) ? node.order : 0,
    });
  }
  return [...seen.values()].sort(
    (a, b) => a.order - b.order || cmp(a.label, b.label) || cmp(a.key, b.key),
  );
}

function prepareEdges(edges, index) {
  const seen = new Set();
  const out = [];
  for (const edge of edges || []) {
    if (!edge) continue;
    const from = index.get(String(edge.from));
    const to = index.get(String(edge.to));
    if (from === undefined || to === undefined) continue;
    const label = edge.label === null || edge.label === undefined ? '' : String(edge.label);
    const style = ARROWS[edge.style] ? edge.style : 'solid';
    const id = `${from}\u0000${to}\u0000${label}\u0000${style}`;
    if (seen.has(id)) continue;
    seen.add(id);
    out.push({ from, to, label, style });
  }
  return out.sort((a, b) => a.from - b.from || a.to - b.to || cmp(a.label, b.label) || cmp(a.style, b.style));
}

function nodeLine(node, id, classes, indent) {
  const [open, close] = SHAPES[node.shape];
  const cls = node.kind !== null && classes.has(node.kind) ? `:::${className(node.kind)}` : '';
  return `${indent}${id}${open}"${escapeText(node.label)}"${close}${cls}`;
}

function edgeLine(edge) {
  const arrow = ARROWS[edge.style];
  return edge.label
    ? `  n${edge.from} ${arrow}|"${escapeText(edge.label)}"| n${edge.to}`
    : `  n${edge.from} ${arrow} n${edge.to}`;
}

/**
 * Writes the flowchart for the first `count` nodes.
 */
function render(sorted, allEdges, opts, count) {
  const shownNodes = sorted.slice(0, count);
  const edges = allEdges.filter((e) => e.from < count && e.to < count);
  const lines = [`flowchart ${opts.direction}`];

  for (const comment of opts.comments) {
    const text = commentText(comment);
    if (text) lines.push(`%% ${text}`);
  }
  if (count < sorted.length || edges.length < allEdges.length) {
    lines.push(
      `%% truncated: ${count} of ${sorted.length} nodes, ${edges.length} of ${allEdges.length} edges shown`,
    );
  }

  // classDef only for kinds that occur and have a valid colour.
  const usedKinds = new Map();
  for (const node of shownNodes) {
    if (node.kind === null) continue;
    const color = opts.classes[node.kind];
    if (typeof color === 'string' && HEX_COLOR.test(color)) usedKinds.set(node.kind, color);
  }
  const defs = new Map();
  for (const [kind, color] of usedKinds) {
    const name = className(kind);
    if (!defs.has(name)) defs.set(name, color);
  }
  for (const name of [...defs.keys()].sort(cmp)) {
    lines.push(`  classDef ${name} stroke:${defs.get(name)},stroke-width:2px`);
  }

  // Nodes: ungrouped at top level, grouped ones inside `subgraph g<idx>`.
  // Groups are numbered by their first node.
  const groupOrder = [];
  const groupNodes = new Map();
  shownNodes.forEach((node, idx) => {
    if (node.group === null) return;
    if (!groupNodes.has(node.group)) {
      groupNodes.set(node.group, []);
      groupOrder.push(node.group);
    }
    groupNodes.get(node.group).push(idx);
  });
  shownNodes.forEach((node, idx) => {
    if (node.group === null) lines.push(nodeLine(node, `n${idx}`, usedKinds, '  '));
  });
  groupOrder.forEach((group, gIdx) => {
    const label = opts.groups[group] ?? group;
    lines.push(`  subgraph g${gIdx}["${escapeText(label)}"]`);
    for (const idx of groupNodes.get(group)) {
      lines.push(nodeLine(shownNodes[idx], `n${idx}`, usedKinds, '    '));
    }
    lines.push('  end');
  });

  for (const edge of edges) lines.push(edgeLine(edge));

  return {
    text: lines.join('\n'),
    shownNodes,
    shownEdges: edges.length,
    groupIds: new Map(groupOrder.map((group, gIdx) => [group, `g${gIdx}`])),
  };
}

/**
 * Builds a Mermaid flowchart.
 *
 * @param {Object} graph
 * @param {Array<{key:string,label?:string,kind?:string,group?:string,shape?:string,order?:number}>} graph.nodes
 *   `key` identifies the node (duplicates: first wins); `label` is the text
 *   (default: key, `\n` = line break); `kind` selects the class; `group` puts
 *   the node into a subgraph; `shape` one of rect, round, stadium, subroutine,
 *   cylinder, hexagon, rhombus; `order` sorts before the label.
 * @param {Array<{from:string,to:string,label?:string,style?:string}>} graph.edges
 *   Edges between node keys (unknown ends are dropped, duplicates collapse);
 *   `style` solid (default), dotted or thick.
 * @param {Object} [options]
 * @param {string} [options.direction='LR'] TD, TB, BT, LR or RL (others → LR)
 * @param {Object<string,string>} [options.classes] kind → hex border colour
 * @param {Object<string,string>} [options.groups] group key → subgraph label
 * @param {string[]} [options.comments] `%%` lines after the header
 * @param {number} [options.nodeLimit] maximum number of nodes
 * @param {number} [options.sourceLimit] maximum length of the source text
 * @returns {{text:string, ids:Map<string,string>, groupIds:Map<string,string>,
 *   truncated:null|{reason:string,nodes:{shown:number,total:number},edges:{shown:number,total:number}}}}
 */
function buildFlowchart(graph = {}, options = {}) {
  const sorted = prepareNodes(graph.nodes);
  const index = new Map(sorted.map((node, idx) => [node.key, idx]));
  const edges = prepareEdges(graph.edges, index);

  const opts = {
    direction: normalizeDirection(options.direction),
    classes: options.classes || {},
    groups: options.groups || {},
    comments: Array.isArray(options.comments) ? options.comments : [],
  };
  const nodeLimit = Number.isInteger(options.nodeLimit) && options.nodeLimit > 0
    ? options.nodeLimit
    : MERMAID_NODE_LIMIT;
  const sourceLimit = Number.isInteger(options.sourceLimit) && options.sourceLimit > 0
    ? options.sourceLimit
    : MERMAID_SOURCE_LIMIT;

  let count = Math.min(sorted.length, nodeLimit);
  let reason = count < sorted.length ? 'nodes' : null;
  let out = render(sorted, edges, opts, count);

  // Too long: shrink proportionally until the text fits (at least one node less per round).
  while (out.text.length > sourceLimit && count > 0) {
    const next = Math.floor(count * 0.9 * (sourceLimit / out.text.length));
    count = Math.max(0, Math.min(count - 1, next));
    reason = 'source';
    out = render(sorted, edges, opts, count);
  }

  const ids = new Map(out.shownNodes.map((node, idx) => [node.key, `n${idx}`]));
  const truncated = count < sorted.length || out.shownEdges < edges.length
    ? {
      reason: reason || 'nodes',
      nodes: { shown: count, total: sorted.length },
      edges: { shown: out.shownEdges, total: edges.length },
    }
    : null;

  return { text: out.text, ids, groupIds: out.groupIds, truncated };
}

module.exports = {
  buildFlowchart,
  escapeText,
  className,
  normalizeDirection,
  DIRECTIONS,
  DEFAULT_DIRECTION,
  SHAPES,
  ARROWS,
};
