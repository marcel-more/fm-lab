/**
 * Mermaid formatter — thin facade over src/formatters/mermaid/.
 *
 * Two input modes, detected from the first row:
 * 1. Graph mode: rows carry `source_uuid` and `target_uuid` (any case), plus
 *    optional `source_name`/`target_name` (labels), `source_type`/`target_type`
 *    (node class → border colour), `source_file`/`target_file` (keeps clones
 *    with the same UUID in different files apart) and `edge_label` or
 *    `edge_kind` (edge text). The builder writes a `flowchart`.
 * 2. Content mode: rows carry a `content` column with ready-made Mermaid
 *    source; the lines are joined unchanged.
 *
 * Outputs:
 * - format=mermaid      → HTML page, pele served locally (mermaid/html.js)
 * - format=mermaid-raw  → Mermaid source as text
 * - format=svg          → standalone SVG drawn on the server (Promise)
 */

const { buildFlowchart } = require('./mermaid/builder');
const { buildHtmlPage } = require('./mermaid/html');
const { TYPE_BORDER_COLORS } = require('./mermaid/palette');
const { createError } = require('../middleware/error-handler');

/** Case-insensitive column access. */
function columnReader(row) {
  const keys = new Map(Object.keys(row).map((k) => [k.toLowerCase(), k]));
  return (name) => {
    const key = keys.get(name);
    if (key === undefined) return undefined;
    const value = row[key];
    return value === null || value === undefined ? undefined : value;
  };
}

/**
 * @param {Array} data
 * @returns {'graph'|'content'|null}
 */
function detectDataMode(data) {
  const keys = Object.keys(data[0] || {}).map((k) => k.toLowerCase());
  if (keys.includes('source_uuid') && keys.includes('target_uuid')) return 'graph';
  if (keys.includes('content')) return 'content';
  return null;
}

/**
 * Turns edge rows into builder nodes and edges.
 * @param {Array<Object>} rows
 * @returns {{nodes:Array, edges:Array}}
 */
function rowsToGraph(rows) {
  const nodes = [];
  const edges = [];
  const nodeKey = (uuid, file) => (file === undefined ? String(uuid) : `${uuid}\u0000${file}`);

  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const col = columnReader(row);
    const sourceUuid = col('source_uuid');
    const targetUuid = col('target_uuid');
    if (sourceUuid === undefined || targetUuid === undefined) continue;

    const from = nodeKey(sourceUuid, col('source_file'));
    const to = nodeKey(targetUuid, col('target_file'));
    nodes.push({ key: from, label: col('source_name') ?? String(sourceUuid), kind: col('source_type') });
    nodes.push({ key: to, label: col('target_name') ?? String(targetUuid), kind: col('target_type') });
    edges.push({ from, to, label: col('edge_label') ?? col('edge_kind') ?? '' });
  }
  return { nodes, edges };
}

/** Lines of the `content` column, joined unchanged. */
function extractContentColumn(rows) {
  return rows
    .map((row) => {
      const value = row && typeof row === 'object' ? columnReader(row)('content') : undefined;
      return value === undefined ? '' : String(value);
    })
    .join('\n')
    .trim();
}

/**
 * Mermaid source of a result set.
 * @param {Array|Object} data
 * @param {Object} [options] - direction, nodeLimit
 * @returns {string}
 * @throws DIAGRAM_ERROR when the data has no diagram shape
 */
function buildSource(data, options = {}) {
  const rows = Array.isArray(data) ? data : [data];
  if (rows.length === 0 || !rows[0] || typeof rows[0] !== 'object') {
    throw createError('DIAGRAM_ERROR', 'Mermaid formatter: no data to draw', { reason: 'empty' });
  }

  const mode = detectDataMode(rows);
  if (mode === 'graph') {
    const graph = rowsToGraph(rows);
    return buildFlowchart(graph, {
      direction: options.direction || options.meta?.mermaid_direction,
      classes: TYPE_BORDER_COLORS,
      nodeLimit: options.nodeLimit,
    }).text;
  }
  if (mode === 'content') {
    const text = extractContentColumn(rows);
    if (!text) throw createError('DIAGRAM_ERROR', 'Mermaid formatter: the content column is empty', { reason: 'empty' });
    return text;
  }
  throw createError(
    'DIAGRAM_ERROR',
    'Mermaid formatter: the result has neither source_uuid/target_uuid columns nor a content column',
    { reason: 'shape' },
  );
}

/**
 * @param {Array|Object} data - query result rows
 * @param {Object} [options]
 * @param {boolean} [options.raw] - Mermaid source only (format=mermaid-raw)
 * @param {boolean} [options.svg] - standalone SVG (format=svg); returns a Promise
 * @param {string} [options.theme] - default | dark | forest | neutral (HTML page)
 * @param {string} [options.direction] - TD | TB | BT | LR | RL (graph mode)
 * @param {string} [options.title] - page title (HTML page)
 * @param {Object} [options.meta] - template metadata (template_description, mermaid_direction)
 * @returns {string|Promise<string>}
 */
function format(data, options = {}) {
  const source = buildSource(data, options);
  if (options.svg) {
    // Loaded lazily: the SVG path pulls pele in through a dynamic import.
    return require('./mermaid/svg').renderSvg(source);
  }
  if (options.raw) return source;
  return buildHtmlPage(source, {
    title: options.title,
    description: options.meta?.template_description,
    theme: options.theme,
  });
}

module.exports = { format, buildSource, detectDataMode, rowsToGraph };
