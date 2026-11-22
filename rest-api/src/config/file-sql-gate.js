const { StatementType } = require('@duckdb/node-api');

/**
 * Statement gate for SQL from files (query/report templates, dashboard
 * datasets, the DESCRIBE of server paging): such SQL may only query.
 *
 * Why: the catalog instance is restricted to a few paths (config/database.js
 * restrictFileAccess) — but a path it may open it may also write, so COPY … TO
 * could write into any path the instance may open. The gate runs before the
 * statement does:
 *
 *   1. A statement that starts with EXPORT is rejected before `prepare`:
 *      preparing EXPORT DATABASE already creates its target directory.
 *   2. `prepare` (binds, executes nothing; takes exactly one statement —
 *      "Cannot prepare multiple statements at once", answered as a
 *      VALIDATION_ERROR "one statement per file") yields the statement type,
 *      which must be in FILE_SQL_STATEMENT_TYPES.
 *   3. EXPLAIN ANALYZE executes the statement it explains (EXPLAIN ANALYZE
 *      COPY … TO writes the file). An EXPLAIN therefore passes only when the
 *      explained statement, prepared on its own, is in EXPLAINABLE_TYPES. The
 *      explained text is derived lexically; whenever that fails the statement
 *      is rejected (fail-closed) — the prepared types stay the authority.
 *
 * Extending the list later: SET (SET VARIABLE, but also USE), CREATE/INSERT
 * (TEMP objects — they outlive the request on the shared connection, so they
 * need a cleanup rule first). Never: COPY, EXPORT (the ways to write files),
 * ATTACH, DETACH, LOAD.
 * Internal SQL of the services does not pass through here.
 */
const FILE_SQL_STATEMENT_TYPES = Object.freeze(['SELECT', 'MULTI', 'EXPLAIN']);
const EXPLAINABLE_TYPES = Object.freeze(['SELECT', 'MULTI']);

function typeName(stmt) {
  return StatementType[stmt.statementType] || String(stmt.statementType);
}

function gateError(type, reason) {
  const { createError } = require('../middleware/error-handler');
  const err = createError(
    'VALIDATION_ERROR',
    `SQL from a template file may only query data: statement type ${type} is not allowed`
      + (reason ? ` (${reason})` : '')
      + ` — allowed: ${FILE_SQL_STATEMENT_TYPES.join(', ')}`,
    { statement_type: type, allowed: [...FILE_SQL_STATEMENT_TYPES] }
  );
  err.statementGate = true;
  return err;
}

/** Several statements in one text: DuckDB refuses to prepare them, nothing ran. */
function multipleStatementsError() {
  const { createError } = require('../middleware/error-handler');
  const err = createError(
    'VALIDATION_ERROR',
    'SQL from a template file must hold exactly one statement (one statement per file):'
      + ' it contains several — check for a \';\' that ends a statement early',
    { statement_type: 'MULTIPLE', allowed: [...FILE_SQL_STATEMENT_TYPES] }
  );
  err.statementGate = true;
  return err;
}

const MULTIPLE_STATEMENTS_RE = /cannot prepare multiple statements/i;

/** Index after whitespace and comments from `i` on; -1 for an unterminated block comment. */
function skipTrivia(sql, i) {
  for (;;) {
    while (i < sql.length && /\s/.test(sql[i])) i += 1;
    if (sql.startsWith('--', i)) {
      const nl = sql.indexOf('\n', i);
      i = nl < 0 ? sql.length : nl + 1;
    } else if (sql.startsWith('/*', i)) {
      const end = sql.indexOf('*/', i + 2);
      if (end < 0) return -1;
      i = end + 2;
    } else {
      return i;
    }
  }
}

function wordAt(sql, i) {
  const m = /^[A-Za-z_]+/.exec(sql.slice(i, i + 64));
  return m ? m[0] : '';
}

/** First keyword of the statement, upper case ('' when there is none to read). */
function leadingKeyword(sql) {
  const i = skipTrivia(String(sql), 0);
  return i < 0 ? '' : wordAt(sql, i).toUpperCase();
}

/**
 * Text of the statement an EXPLAIN explains:
 * EXPLAIN [ANALYZE] [(options)] [ANALYZE] <statement>. null when the text does
 * not read that way (the caller rejects).
 */
function explainedStatement(sql) {
  const s = String(sql);
  let i = skipTrivia(s, 0);
  if (i < 0 || wordAt(s, i).toUpperCase() !== 'EXPLAIN') return null;
  i = skipTrivia(s, i + 'EXPLAIN'.length);
  const analyze = () => {
    if (i < 0) return;
    const w = wordAt(s, i);
    if (/^ANALY[SZ]E$/i.test(w)) i = skipTrivia(s, i + w.length);
  };
  analyze();
  if (i >= 0 && s[i] === '(') {
    let depth = 0;
    for (; i < s.length; i += 1) {
      const ch = s[i];
      if (ch === "'" || ch === '"') {
        const end = s.indexOf(ch, i + 1);
        if (end < 0) return null;
        i = end;
      } else if (ch === '(') {
        depth += 1;
      } else if (ch === ')') {
        depth -= 1;
        if (depth === 0) { i += 1; break; }
      }
    }
    if (depth !== 0) return null;
    i = skipTrivia(s, i);
    analyze();
  }
  if (i < 0) return null;
  const inner = s.slice(i);
  return inner.trim() ? inner : null;
}

/**
 * Prepares `sql` on `connection` behind the gate and returns the prepared
 * statement (the caller binds, runs and destroys it). Throws a VALIDATION_ERROR
 * (`statementGate: true`) for anything that is not a query.
 */
async function prepareFileSql(connection, sql) {
  if (leadingKeyword(sql) === 'EXPORT') throw gateError('EXPORT');
  let stmt;
  try {
    stmt = await connection.prepare(sql);
  } catch (err) {
    if (MULTIPLE_STATEMENTS_RE.test(String(err && err.message))) throw multipleStatementsError();
    throw err;
  }
  try {
    const type = typeName(stmt);
    if (!FILE_SQL_STATEMENT_TYPES.includes(type)) throw gateError(type);
    if (type === 'EXPLAIN') await checkExplained(connection, sql);
    return stmt;
  } catch (err) {
    try { stmt.destroySync(); } catch { /* released */ }
    throw err;
  }
}

async function checkExplained(connection, sql) {
  const inner = explainedStatement(sql);
  if (inner === null) throw gateError('EXPLAIN', 'the explained statement could not be read');
  let innerStmt = null;
  try {
    innerStmt = await connection.prepare(inner);
  } catch {
    throw gateError('EXPLAIN', 'the explained statement could not be checked');
  }
  try {
    const innerType = typeName(innerStmt);
    if (!EXPLAINABLE_TYPES.includes(innerType)) {
      throw gateError('EXPLAIN', `it explains a statement of type ${innerType}; EXPLAIN ANALYZE would run it`);
    }
  } finally {
    try { innerStmt.destroySync(); } catch { /* released */ }
  }
}

module.exports = {
  FILE_SQL_STATEMENT_TYPES,
  EXPLAINABLE_TYPES,
  prepareFileSql,
  leadingKeyword,
  explainedStatement,
};
