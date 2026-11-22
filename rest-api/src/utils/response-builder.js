/**
 * Response Builder Utility
 * Creates standardized API responses
 */

/**
 * Build a success response
 * @param {*} data - Response data
 * @param {Object} meta - Optional metadata (execution_time_ms, result_count, etc.)
 * @param {string} debugQuery - Optional SQL query for debugging
 * @returns {Object} Standardized success response
 */
function buildSuccess(data, meta = null, debugQuery = null) {
  const response = {
    success: true,
    data,
  };

  if (meta) {
    response.meta = meta;
  }

  if (debugQuery) {
    response.debug = {
      query: debugQuery,
    };
  }

  return response;
}

/**
 * Build an error response
 * @param {string} code - Error code (from ERROR_CODES)
 * @param {string} message - Error message
 * @param {Object} details - Optional error details
 * @param {string} stack - Optional stack trace (only in debug mode)
 * @returns {Object} Standardized error response
 */
function buildError(code, message, details = {}, stack = null) {
  const response = {
    success: false,
    error: {
      code,
      message,
      details,
    },
    meta: {
      timestamp: new Date().toISOString(),
    },
  };

  if (stack) {
    response.error.stack = stack;
  }

  return response;
}

/**
 * Build a paginated response (for future pagination support)
 * @param {Array} data - Response data
 * @param {number} total - Total count
 * @param {number} limit - Limit per page
 * @param {number} offset - Offset
 * @param {Object} meta - Additional metadata
 * @returns {Object} Paginated response
 */
function buildPaginated(data, total, limit, offset, meta = {}) {
  return {
    success: true,
    data,
    pagination: {
      total,
      limit,
      offset,
      has_more: offset + data.length < total,
    },
    meta,
  };
}

/**
 * Get Content-Type for a given format
 * @param {string} format - Format type
 * @returns {string} Content-Type header value
 */
function getContentType(format) {
  const contentTypes = {
    json: 'application/json',
    raw: 'text/csv',
    text: 'text/plain; charset=utf-8',
    short: 'text/plain; charset=utf-8',
    detailed: 'text/plain; charset=utf-8',
    html: 'text/html; charset=utf-8',
    markdown: 'text/markdown; charset=utf-8',
    content: 'text/plain; charset=utf-8',
    mermaid: 'text/html; charset=utf-8',      // HTML mit Mermaid.js
    'mermaid-raw': 'text/plain; charset=utf-8',  // Nur Mermaid-Code
    svg: 'image/svg+xml; charset=utf-8',         // Diagramm als SVG (pele, serverseitig)
    tokens: 'application/json',                  // Structured token payload
  };

  return contentTypes[format] || 'application/json';
}

/**
 * Trailing comment in the syntax of a non-JSON format: `<!-- … -->` for HTML,
 * Markdown, the Mermaid page and SVG (a `--` inside would end an XML comment),
 * `%%` for Mermaid source, `#` for the text formats.
 * @param {string} format
 * @param {string} text
 * @returns {string}
 */
function trailingComment(format, text) {
  switch (format) {
    case 'html':
    case 'markdown':
    case 'mermaid':
    case 'svg':
      return `\n<!-- ${text.replace(/--/g, '- -')} -->`;
    case 'mermaid-raw':
      return `\n%% ${text.replace(/[\r\n]+/g, ' ')}`;
    default:
      return `\n# ${text}`;
  }
}

/**
 * Send formatted response
 * Handles both JSON and non-JSON formats
 * @param {Object} res - Express response object
 * @param {*} data - Data to send
 * @param {string} format - Format type
 * @param {Object} meta - Optional metadata
 * @param {string} debugQuery - Optional debug query
 */
function sendFormatted(res, data, format = 'json', meta = null, debugQuery = null) {
  // JSON-shaped responses use the standard {success, data, meta} envelope.
  // 'tokens' is structured JSON like 'json', not a text-based format.
  if (format === 'json' || format === 'tokens') {
    const response = buildSuccess(data, meta, debugQuery);
    res.json(response);
    return;
  }

  // For non-JSON formats, send data directly with appropriate Content-Type
  const contentType = getContentType(format);
  res.setHeader('Content-Type', contentType);

  // Optionally append meta/debug info as comments for non-JSON formats
  let output = data;

  if (meta || debugQuery) {
    // Add meta/debug as comments at the end, in the comment syntax of the format
    const comments = [];
    if (meta) comments.push(trailingComment(format, `Metadata: ${JSON.stringify(meta)}`));
    if (debugQuery) comments.push(trailingComment(format, `Debug Query: ${debugQuery}`));
    output = data + comments.join('\n');
  }

  res.send(output);
}

module.exports = {
  buildSuccess,
  buildError,
  buildPaginated,
  getContentType,
  sendFormatted,
};
