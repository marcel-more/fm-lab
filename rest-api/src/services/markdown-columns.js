const docsContent = require('./docs-content');

/**
 * Markdown columns of a dataset rendered to HTML on the server.
 *
 * Manifest dataset spec: `"render": { "text_md": "markdown" }` adds the column
 * `text_md_html` to every row (an existing column of that name is replaced) —
 * rendered with the docs pipeline (marked, GFM, sanitized), shown with
 * `HtmlContent`. The Markdown column itself stays, e.g. for an export — unless
 * the object form `{ "format": "markdown", "keepSource": false }` drops it once
 * rendered (a display-only column the client never reads as Markdown).
 *
 * Rendering costs time per row: above MAX_ROWS rows (or the dataset's own
 * `renderMaxRows`, at most MAX_ROWS_LIMIT) nothing is rendered and `meta.render`
 * says so, so a large dataset never stalls the request.
 */

const MAX_ROWS = 500;
// Upper bound for a dataset's own `renderMaxRows`.
const MAX_ROWS_LIMIT = 2000;
const FORMATS = Object.freeze(['markdown']);

/** `"markdown"` or `{ format, keepSource }` → `{ format, keepSource }`. */
function normalizeSpec(spec) {
  if (spec && typeof spec === 'object') return { format: spec.format, keepSource: spec.keepSource !== false };
  return { format: spec, keepSource: true };
}

/**
 * @param {object[]} rows dataset rows (modified copies are returned)
 * @param {Record<string, string|{format: string, keepSource?: boolean}>|undefined} render column → format
 * @param {(md: string) => string} [toHtml] Markdown renderer (tests inject one;
 *   `marked` is ESM-only and loads at server start)
 * @returns {{ rows: object[], meta: object|null }}
 */
function renderColumns(rows, render, toHtml = docsContent.renderMarkdownFragment, maxRows = MAX_ROWS) {
  const columns = Object.entries(render || {})
    .map(([column, spec]) => [column, normalizeSpec(spec)])
    .filter(([, spec]) => FORMATS.includes(spec.format));
  if (columns.length === 0 || !Array.isArray(rows)) return { rows, meta: null };
  const limit = Math.min(Math.max(1, Number(maxRows) || MAX_ROWS), MAX_ROWS_LIMIT);
  // Above the cap the source stays even with keepSource=false: it is all the row has.
  if (rows.length > limit) {
    return {
      rows,
      meta: {
        skipped: true,
        reason: `more than ${limit} rows (${rows.length}) — Markdown columns not rendered`,
        columns: columns.map(([c]) => c),
      },
    };
  }
  const out = rows.map((row) => {
    if (row === null || typeof row !== 'object') return row;
    const next = { ...row };
    for (const [column, spec] of columns) {
      const value = row[column];
      next[`${column}_html`] = value == null || value === '' ? '' : toHtml(String(value));
      if (!spec.keepSource) delete next[column];
    }
    return next;
  });
  return { rows: out, meta: { columns: columns.map(([c]) => `${c}_html`) } };
}

module.exports = {
  MAX_ROWS,
  MAX_ROWS_LIMIT,
  FORMATS,
  renderColumns,
};
