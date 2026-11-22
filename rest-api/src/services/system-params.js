const fs = require('fs');
const path = require('path');
const { resolveRepoRoot } = require('../plugins/settings-store');

/**
 * System parameters for SQL from files — read in SQL with
 * `getvariable('fmlab_solution')` etc. They reach the SQL like every other
 * parameter: `interpolateTemplate` replaces the `getvariable('…')` text with an
 * escaped literal. There is no DuckDB session variable (`SET VARIABLE` is
 * refused by the statement gate, config/file-sql-gate.js).
 *
 *   fmlab_solution  id of the solution of the request (pin, X-Solution header
 *                   or server default — the request context)
 *   fmlab_lang      UI language of the request (`lang`), as for the locales
 *   fmlab_today     date YYYY-MM-DD in server time (file names, headers)
 *   fmlab_version   fm-lab version (version.json)
 *
 * The prefix `fmlab_` is reserved: request and manifest params with this
 * prefix are dropped, so a client cannot fake a value.
 */

const RESERVED_PREFIX = 'fmlab_';

let cachedVersion;

function fmlabVersion() {
  if (cachedVersion !== undefined) return cachedVersion;
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(resolveRepoRoot(), 'version.json'), 'utf-8'));
    cachedVersion = typeof manifest.version === 'string' ? manifest.version : null;
  } catch {
    cachedVersion = null;
  }
  return cachedVersion;
}

function today(now = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

/** The system parameters for request context `ctx` and UI language `lang`. */
function systemParams(ctx, lang) {
  return {
    fmlab_solution: ctx && typeof ctx.solution === 'string' ? ctx.solution : null,
    fmlab_lang: typeof lang === 'string' && lang ? lang : null,
    fmlab_today: today(),
    fmlab_version: fmlabVersion(),
  };
}

/**
 * Copy of `params` without reserved keys, plus the system parameters. The
 * language comes from `_lang` (dashboard requests) or `lang`.
 */
function withSystemParams(ctx, params = {}) {
  const out = {};
  for (const [k, v] of Object.entries(params || {})) {
    if (!k.startsWith(RESERVED_PREFIX)) out[k] = v;
  }
  const lang = params && (params._lang || params.lang);
  return Object.assign(out, systemParams(ctx, lang));
}

module.exports = {
  RESERVED_PREFIX,
  systemParams,
  withSystemParams,
  today,
};
