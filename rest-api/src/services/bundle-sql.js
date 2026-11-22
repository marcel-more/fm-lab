const fs = require('fs').promises;
const path = require('path');
const { createError } = require('../middleware/error-handler');

/**
 * SQL include for dashboard bundles: a line `--#include <relative path>` in a
 * bundle SQL file is replaced by the content of that file.
 *
 * - Resolved relative to the including file, only inside the bundle directory
 *   (the same traversal guard as for `bundle:` sources). Fragments belong in a
 *   sub-folder of the bundle such as `data/shared/` — a `.sql` file next to
 *   bundles would be discovered as a single-file dashboard.
 * - Nested up to MAX_DEPTH levels; a cycle is an error naming the chain.
 * - A fragment is a PART of one statement (CTE pieces, subqueries): its final
 *   `;` is removed (also when only whitespace or comments follow); any other
 *   `;` outside strings and comments is reported with file and line before
 *   anything runs — the statement gate allows one statement per file.
 * - Not `-- @include`: `-- @` is the header of single-file dashboards.
 * - The `:word` preprocessor runs afterwards, on the composed SQL.
 *
 * composeBundleSql returns the SQL and a line map (output line → file, line)
 * so that DuckDB errors (`LINE n:`) can name the source file.
 */

const MAX_DEPTH = 5;
const INCLUDE_RE = /^[ \t]*--#include[ \t]+(?:"([^"]+)"|'([^']+)'|(\S+))[ \t]*$/;

function includeError(message, details) {
  return createError('VALIDATION_ERROR', message, details);
}

/** Bundle-relative path for messages (forward slashes). */
function rel(bundleDir, file) {
  return path.relative(bundleDir, file).split(path.sep).join('/');
}

/** Absolute path of `relPath` below `baseDir`, guarded to stay inside `bundleDir`. */
function resolveInside(bundleDir, baseDir, relPath) {
  if (!relPath || path.isAbsolute(relPath)) return null;
  const full = path.resolve(baseDir, relPath);
  return full.startsWith(bundleDir + path.sep) ? full : null;
}

/**
 * Positions of `;` outside strings, quoted identifiers, dollar quotes and
 * comments: [{ index, line }] (line 1-based).
 */
function statementSemicolons(sql) {
  const out = [];
  let line = 1;
  let i = 0;
  const n = sql.length;
  const advance = (to) => {
    for (; i < to && i < n; i += 1) if (sql[i] === '\n') line += 1;
  };
  while (i < n) {
    const ch = sql[i];
    if (ch === '\n') { line += 1; i += 1; continue; }
    if (ch === '-' && sql[i + 1] === '-') {
      const nl = sql.indexOf('\n', i);
      advance(nl < 0 ? n : nl);
      continue;
    }
    if (ch === '/' && sql[i + 1] === '*') {
      const end = sql.indexOf('*/', i + 2);
      advance(end < 0 ? n : end + 2);
      continue;
    }
    if (ch === "'" || ch === '"') {
      let j = i + 1;
      while (j < n) {
        if (sql[j] === ch) {
          if (sql[j + 1] === ch) { j += 2; continue; }
          break;
        }
        j += 1;
      }
      advance(j + 1);
      continue;
    }
    if (ch === '$') {
      const m = /^\$([A-Za-z_]\w*)?\$/.exec(sql.slice(i, i + 64));
      if (m) {
        const end = sql.indexOf(m[0], i + m[0].length);
        advance(end < 0 ? n : end + m[0].length);
        continue;
      }
    }
    if (ch === ';') out.push({ index: i, line });
    i += 1;
  }
  return out;
}

/** True when `tail` holds only whitespace and comments. */
function onlyTrivia(tail) {
  return tail.replace(/--[^\n]*|\/\*[\s\S]*?\*\//g, '').trim() === '';
}

/**
 * Removes the final `;` of a fragment and rejects any other one.
 * `file` is bundle-relative for the message.
 */
function prepareFragment(text, file) {
  const semis = statementSemicolons(text);
  if (semis.length === 0) return text;
  const last = semis[semis.length - 1];
  const trailing = onlyTrivia(text.slice(last.index + 1));
  const inner = trailing ? semis.slice(0, -1) : semis;
  if (inner.length > 0) {
    throw includeError(
      `SQL include ${file}:${inner[0].line}: a ';' inside an included fragment ends the statement early`
        + ' — a fragment is part of one statement (one statement per file)',
      { file, line: inner[0].line },
    );
  }
  return text.slice(0, last.index) + text.slice(last.index + 1);
}

/**
 * Reads `relPath` of the bundle and resolves its includes.
 * @returns {Promise<{ sql: string, lines: Array<{file: string, line: number}>, included: boolean }>}
 */
async function composeBundleSql(bundleDir, relPath) {
  const root = path.resolve(bundleDir);
  const entry = resolveInside(root, root, path.normalize(String(relPath)));
  if (!entry) throw new Error(`Bundle SQL path escapes bundle dir: ${relPath}`);
  const out = [];
  let included = false;

  async function expand(file, chain, isFragment) {
    let text;
    try {
      text = await fs.readFile(file, 'utf-8');
    } catch (err) {
      if (!isFragment) throw err;
      const from = chain[chain.length - 2];
      throw includeError(`SQL include not found: ${rel(root, file)} (included from ${from})`,
        { file: rel(root, file), from });
    }
    const name = rel(root, file);
    if (isFragment) text = prepareFragment(text, name);
    const lines = text.split('\n');
    for (let k = 0; k < lines.length; k += 1) {
      const m = INCLUDE_RE.exec(lines[k]);
      if (!m) {
        out.push({ text: lines[k], file: name, line: k + 1 });
        continue;
      }
      included = true;
      const target = m[1] || m[2] || m[3];
      const full = resolveInside(root, path.dirname(file), target);
      const at = `${name}:${k + 1}`;
      if (!full) {
        throw includeError(`SQL include ${at}: '${target}' is outside the bundle directory`, { file: name, line: k + 1, include: target });
      }
      const targetName = rel(root, full);
      if (chain.includes(targetName)) {
        throw includeError(`SQL include cycle: ${[...chain, targetName].join(' → ')}`, { chain: [...chain, targetName] });
      }
      if (chain.length > MAX_DEPTH) {
        throw includeError(`SQL include ${at}: nested deeper than ${MAX_DEPTH} levels (${[...chain, targetName].join(' → ')})`,
          { chain: [...chain, targetName] });
      }
      await expand(full, [...chain, targetName], true);
    }
  }

  await expand(entry, [rel(root, entry)], false);
  return {
    sql: out.map((l) => l.text).join('\n'),
    lines: out.map(({ file, line }) => ({ file, line })),
    included,
  };
}

/**
 * Appends the source position to a DuckDB error that names a line
 * (`LINE n:`) of composed SQL — only when includes were resolved.
 */
function annotateError(err, composed) {
  if (!err || !composed || !composed.included || typeof err.message !== 'string') return err;
  const m = /LINE (\d+):/.exec(err.message);
  const src = m && composed.lines[Number(m[1]) - 1];
  if (src) {
    err.message = `${err.message}\n(source: ${src.file}:${src.line})`;
    err.sqlSource = src;
  }
  return err;
}

module.exports = {
  MAX_DEPTH,
  composeBundleSql,
  annotateError,
  prepareFragment,
  statementSemicolons,
};
