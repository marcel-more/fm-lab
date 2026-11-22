/**
 * `format=svg`: draws Mermaid source on the server with pele.
 *
 * pele is ESM-only and this API is CommonJS, so it is loaded once through a
 * dynamic `import()` and cached. Same settings as the web client's renderer
 * (no links, no images, same source limit). The result is a standalone SVG
 * file: XML header plus a white rectangle behind the drawing — pele draws no
 * background, and its colour variables fall back to the light theme.
 *
 * Note for tests: Jest runs modules in a VM without `--experimental-vm-modules`,
 * where `import()` is unavailable; the SVG tests run this module in a child
 * Node process (tests/helpers/mermaid-child.js).
 */

const { MERMAID_SOURCE_LIMIT } = require('../../config/constants');
const { createError } = require('../../middleware/error-handler');

let pelePromise;

function loadPele() {
  if (!pelePromise) {
    pelePromise = import('pele').catch((err) => {
      pelePromise = undefined;
      throw err;
    });
  }
  return pelePromise;
}

/** XML header and a white background rectangle over the viewBox. */
function standaloneSvg(svg) {
  const body = String(svg).trim();
  const open = /^<svg\b[^>]*>/.exec(body);
  if (!open) return body;
  const box = /viewBox="\s*([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)\s*"/.exec(open[0]);
  const rect = box
    ? `<rect x="${box[1]}" y="${box[2]}" width="${box[3]}" height="${box[4]}" fill="#fff"/>`
    : '<rect width="100%" height="100%" fill="#fff"/>';
  return `<?xml version="1.0" encoding="UTF-8"?>\n${open[0]}${rect}${body.slice(open[0].length)}`;
}

/**
 * Renders Mermaid source to a standalone SVG document.
 * @param {string} source
 * @returns {Promise<string>}
 * @throws DIAGRAM_ERROR (422) with details { reason, line, column } when pele rejects the source
 */
async function renderSvg(source) {
  const pele = await loadPele();
  let rendered;
  try {
    rendered = pele.render(String(source), { links: false, images: false, limit: MERMAID_SOURCE_LIMIT });
  } catch (err) {
    const details = { reason: err && err.code ? String(err.code) : 'render' };
    if (err && Number.isFinite(err.line)) details.line = err.line;
    if (err && Number.isFinite(err.column)) details.column = err.column;
    throw createError('DIAGRAM_ERROR', `Diagram could not be drawn: ${err && err.message ? err.message : err}`, details);
  }
  return standaloneSvg(rendered.svg);
}

module.exports = { renderSvg, standaloneSvg, loadPele };
