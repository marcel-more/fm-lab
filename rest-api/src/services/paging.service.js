const crypto = require('crypto');
const { LRUCache } = require('lru-cache');
const db = require('../config/database');

/**
 * Server-side paging and sorting for list templates (custom queries and bundle
 * datasets).
 *
 * A paged template reads `getvariable('page')`, `getvariable('page_size')` and
 * `getvariable('q')`, keeps its output columns in a CTE `result AS MATERIALIZED`
 * and ends with
 *
 *   ORDER BY /*@sort*\/ <default order>, <unique tiebreak>
 *   LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
 *
 * This module resolves the page window before interpolation and replaces the
 * sort marker afterwards. The marker is only ever replaced by an identifier the
 * template itself returns (read via DESCRIBE) plus ASC/DESC — request text never
 * becomes SQL. An invalid or absent sort request leaves the marker as a comment,
 * so the default order applies; runs without the server (plain duckdb) see the
 * comment as well.
 */

/** Generic page size when neither the request nor the template declares one. */
const DEFAULT_PAGE_SIZE = 500;
/** Safety cap: `page_size=all` and any number are clamped to this. */
const MAX_PAGE_SIZE = 10000;
const SORT_MARKER = '/*@sort*/';
const PAGE_SIZE_VAR = "getvariable('page_size')";

// Output columns (name → DuckDB type) per template text. The key is a hash of the
// raw template, so an edited template is described again.
const columnCache = new LRUCache({ max: 500 });

/** True when the template takes part in server paging. */
function isPagedTemplate(sqlTemplate) {
  return typeof sqlTemplate === 'string' && sqlTemplate.includes(PAGE_SIZE_VAR);
}

/** Express turns repeated query keys into arrays — the first value counts. */
function first(value) {
  return Array.isArray(value) ? value[0] : value;
}

/** Positive integer from a number or a digit string, else null. */
function toPositiveInt(value) {
  if (typeof value === 'number') return Number.isInteger(value) && value >= 1 ? value : null;
  if (typeof value !== 'string' || !/^\s*\d+\s*$/.test(value)) return null;
  const n = Number.parseInt(value, 10);
  return n >= 1 ? n : null;
}

function isAll(value) {
  return typeof value === 'string' && value.trim().toLowerCase() === 'all';
}

/**
 * Validates a declared page size (frontmatter `@page_size`, manifest `pageSize`).
 * Returns a number in 1…MAX_PAGE_SIZE, the string 'all', or null when absent or
 * invalid.
 */
function normalizeDeclaredPageSize(value) {
  if (value == null || value === '') return null;
  if (isAll(value)) return 'all';
  const n = toPositiveInt(typeof value === 'number' ? value : String(value));
  return n == null ? null : Math.min(n, MAX_PAGE_SIZE);
}

/** URL parameter that carries the sort direction for a given sort parameter. */
function dirParamFor(sortParam) {
  return sortParam === 'sort' ? 'dir' : `${sortParam}_dir`;
}

/**
 * Resolves the page window of a paged template.
 *
 * Precedence: request `page_size` → declared page size → DEFAULT_PAGE_SIZE.
 * `all` switches paging off: page 1 with MAX_PAGE_SIZE rows. Any number is
 * clamped to 1…MAX_PAGE_SIZE. The template variables `page`, `page_size` and
 * `q` are always set (numbers for the first two), so the SQL never sees `all`.
 *
 * @param {Object} params - request params (merged dataset defaults included)
 * @param {Object} decl - { pageSize, pageParam, searchParam } from the template
 * @returns {{ params: Object, pageSize: number, page: number, pagingOff: boolean }}
 */
function resolvePaging(params = {}, decl = {}) {
  const pageParam = decl.pageParam || 'page';
  const searchParam = decl.searchParam || 'q';
  const requested = first(params.page_size);
  const declared = normalizeDeclaredPageSize(decl.pageSize);
  const raw = requested != null && requested !== '' ? requested : declared;

  const pagingOff = isAll(raw);
  let pageSize;
  if (pagingOff) {
    pageSize = MAX_PAGE_SIZE;
  } else {
    const n = toPositiveInt(typeof raw === 'number' ? raw : raw == null ? null : String(raw));
    pageSize = Math.min(n ?? DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE);
  }
  const page = pagingOff ? 1 : (toPositiveInt(String(first(params[pageParam]) ?? '')) ?? 1);
  // Trimmed like the client-side search, so both modes match the same rows.
  const q = first(params[searchParam]);
  const term = q == null ? '' : String(q).trim();

  const out = { ...params, page, page_size: pageSize };
  if (term !== '') out.q = term;
  else delete out.q;
  return { params: out, pageSize, page, pagingOff };
}

function quoteIdent(name) {
  return `"${String(name).replace(/"/g, '""')}"`;
}

/**
 * ORDER BY term for a sort request, or '' when the request is not valid.
 *
 * Valid means: the key is an output column of the template (from DESCRIBE),
 * does not start with `_`, and — when the template restricts sorting — is
 * listed in `sortColumns`. A hidden companion column `_sort_<key>` (rank or
 * raw value behind a formatted text) takes precedence over the column itself.
 * Text sorts case-insensitively; empty values always come last.
 *
 * @param {Map<string,string>} columns - output column name → DuckDB type
 */
function buildSortTerm(columns, sortKey, dirValue, sortColumns) {
  const key = first(sortKey);
  if (typeof key !== 'string' || key === '' || key.startsWith('_')) return '';
  if (!columns || !columns.has(key)) return '';
  if (Array.isArray(sortColumns) && sortColumns.length > 0 && !sortColumns.includes(key)) return '';
  const companion = `_sort_${key}`;
  const col = columns.has(companion) ? companion : key;
  const dir = String(first(dirValue) ?? '').trim().toLowerCase() === 'desc' ? 'DESC' : 'ASC';
  const collate = /^VARCHAR/i.test(columns.get(col) || '') ? ' COLLATE NOCASE' : '';
  return `${quoteIdent(col)}${collate} ${dir} NULLS LAST, `;
}

/** Replaces the first sort marker; a template carries exactly one. */
function applySortMarker(sql, term) {
  const at = sql.indexOf(SORT_MARKER);
  if (at < 0) return sql;
  return sql.slice(0, at) + term + sql.slice(at + SORT_MARKER.length);
}

function stripTrailingSemicolon(sql) {
  return sql.replace(/;\s*$/, '');
}

/**
 * Output columns of an interpolated template, cached per raw template text.
 */
async function describeColumns(ctx, cacheKeySource, interpolatedSql) {
  const key = crypto.createHash('sha1').update(cacheKeySource).digest('hex');
  const hit = columnCache.get(key);
  if (hit) return hit;
  // The described text is template SQL: it passes the statement gate too.
  const res = await db.executeFileQuery(ctx, `DESCRIBE ${stripTrailingSemicolon(interpolatedSql)}`);
  const columns = new Map(res.rows.map(r => [String(r.column_name), String(r.column_type)]));
  columnCache.set(key, columns);
  return columns;
}

/**
 * Replaces the sort marker of an interpolated template according to the request.
 * Describes the template only when a sort is actually requested.
 *
 * @param {Object} opts - { sortParam, sortColumns }
 */
async function applySort(ctx, rawTemplate, interpolatedSql, params = {}, opts = {}) {
  if (!interpolatedSql.includes(SORT_MARKER)) return interpolatedSql;
  const sortParam = opts.sortParam || 'sort';
  const sortKey = first(params[sortParam]);
  let term = '';
  if (typeof sortKey === 'string' && sortKey !== '') {
    const columns = await describeColumns(ctx, rawTemplate, interpolatedSql);
    term = buildSortTerm(columns, sortKey, params[dirParamFor(sortParam)], opts.sortColumns);
  }
  return applySortMarker(interpolatedSql, term);
}

function clearCache() {
  columnCache.clear();
}

module.exports = {
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
  SORT_MARKER,
  isPagedTemplate,
  normalizeDeclaredPageSize,
  dirParamFor,
  resolvePaging,
  buildSortTerm,
  applySortMarker,
  applySort,
  clearCache,
};
