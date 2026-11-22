/**
 * Formatter Registry
 * Dispatches formatting based on format parameter
 */

const jsonFormatter = require('./json.formatter');
const rawFormatter = require('./raw.formatter');
const textFormatter = require('./text.formatter');
const shortFormatter = require('./short.formatter');
const detailedFormatter = require('./detailed.formatter');
const htmlFormatter = require('./html.formatter');
const markdownFormatter = require('./markdown.formatter');
const contentFormatter = require('./content.formatter');
const mermaidFormatter = require('./mermaid.formatter');
const tokensFormatter = require('./tokens.formatter');

/**
 * Formatter registry
 * Maps format names to formatter modules
 */
const formatters = {
  json: jsonFormatter,
  raw: rawFormatter,
  text: textFormatter,
  short: shortFormatter,
  detailed: detailedFormatter,
  html: htmlFormatter,
  markdown: markdownFormatter,
  content: contentFormatter,
  mermaid: mermaidFormatter,
  tokens: tokensFormatter,
};

/**
 * Format data using the specified formatter
 * @param {Array|Object} data - Data to format
 * @param {string} format - Format type (json, raw, text, short, detailed, html, markdown, mermaid, mermaid-raw, svg)
 * @param {Object} options - Formatter options (for formatters that support options)
 * @returns {*} Formatted data — a Promise for `svg`
 */
function format(data, formatType = 'json', options = {}) {
  // Normalize format to lowercase for case-insensitive lookup
  const normalizedFormat = formatType.toLowerCase();

  // Variants of the mermaid formatter: source only, or SVG drawn on the server.
  // `svg` returns a Promise — callers await the result of format().
  if (normalizedFormat === 'mermaid-raw') {
    return formatters.mermaid.format(data, { ...options, raw: true });
  }
  if (normalizedFormat === 'svg') {
    return formatters.mermaid.format(data, { ...options, svg: true });
  }

  const formatter = formatters[normalizedFormat];

  if (!formatter) {
    throw new Error(`Unknown format: ${formatType}. Supported formats: ${Object.keys(formatters).join(', ')}, mermaid-raw, svg`);
  }

  // Pass options to formatters that support them (mermaid, html, etc.)
  // Other formatters will ignore the options parameter
  return formatter.format(data, options);
}

/**
 * Check if a format is supported
 * @param {string} formatType - Format type to check
 * @returns {boolean} True if supported
 */
function isSupported(formatType) {
  const normalized = formatType.toLowerCase();
  return !!formatters[normalized] || normalized === 'mermaid-raw' || normalized === 'svg';
}

module.exports = {
  format,
  isSupported,
};
