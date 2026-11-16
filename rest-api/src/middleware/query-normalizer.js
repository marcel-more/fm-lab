const querystring = require('querystring');
const { createError } = require('./error-handler');

/**
 * Query Parameter Name Normalizer
 *
 * Installed as the Express `query parser` (see src/index.js), NOT as a
 * middleware — in Express 5 `req.query` is a read-only getter, so the parser is
 * the only place where the shape can still be influenced.
 *
 * Parameter NAMES are case-insensitive on both sides:
 *
 *   - The own keys are lowercased. That is the canonical spelling: everything
 *     that spreads or enumerates `req.query` (validators, the request logger,
 *     the query controller) keeps seeing exactly one spelling per parameter.
 *   - A Proxy resolves reads in ANY casing on top. `req.query.objectType` and
 *     `req.query.objecttype` return the same value, whichever spelling the
 *     client sent.
 *
 * The Proxy is what makes the contract two-sided. With lowercasing alone a
 * camelCase read yields `undefined` — silently, because an absent optional
 * query parameter is legitimate. A filter built on it then degrades into a
 * no-op instead of raising: that is how the `objectType`/`testType` filters of
 * `GET /api/tests` came to return every test for every object type.
 *
 * Parameter VALUES are untouched — only names are case-folded.
 */
function createQueryParser() {
  return (queryString) => {
    const normalized = {};
    for (const [key, value] of Object.entries(querystring.parse(queryString))) {
      normalized[key.toLowerCase()] = value;
    }
    return new Proxy(normalized, {
      get(target, prop, receiver) {
        // Symbols and anything already resolvable (own keys, plus inherited
        // members like toString that consumers may legitimately touch) behave
        // normally; only an unknown string key retries lowercased.
        if (typeof prop !== 'string' || prop in target) return Reflect.get(target, prop, receiver);
        return target[prop.toLowerCase()];
      },
      has(target, prop) {
        if (typeof prop !== 'string') return Reflect.has(target, prop);
        return prop in target || prop.toLowerCase() in target;
      },
    });
  };
}

/**
 * Middleware: rejects a query string that names the same parameter more than
 * once (`?file=a&file=b`, also across spellings like `?File=a&file=b`).
 *
 * `querystring.parse` turns a repeated name into an array. No endpoint takes
 * a list that way — lists travel as one delimited string — so a repeated name
 * is answered with 400 instead of picking one of the values silently.
 */
function rejectRepeatedQueryParams(req, res, next) {
  const raw = typeof req.url === 'string' ? req.url.split('?')[1] : undefined;
  if (!raw) return next();
  const seen = new Set();
  for (const [key, value] of Object.entries(querystring.parse(raw))) {
    const name = key.toLowerCase();
    if (Array.isArray(value) || seen.has(name)) {
      return next(createError(
        'VALIDATION_ERROR',
        `Query parameter '${name}' must not be given more than once`,
        { parameter: name }
      ));
    }
    seen.add(name);
  }
  return next();
}

module.exports = createQueryParser;
module.exports.createQueryParser = createQueryParser;
module.exports.rejectRepeatedQueryParams = rejectRepeatedQueryParams;
