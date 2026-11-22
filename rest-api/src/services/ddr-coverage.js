/**
 * DDR coverage of a solution: which files were exported without "Include details
 * for analysis tools" (FilesCatalog.Has_DDR_INFO = false).
 *
 * Without DDR info the export carries the formula texts but not their resolved
 * references, so every dataflow edge that comes from a formula reference is
 * missing or reduced for that file. The trace answers stay correct for what
 * they show, but ways can end early — the blind-spot fields below say where.
 *
 * The kind lists were measured on the coverage fixture (FileMaker 22, main file
 * with vs. without DDR info): `missing` drops to zero, `reduced` keeps only the
 * edges that do not need a formula reference.
 */
const db = require('../config/database');

const MISSING_KINDS = Object.freeze([
  'field_value_to_step',
  'param_to_step',
  'result_to_step',
  'param_ctl_to_step',
  'param_guards_step',
  'variable_ctl_to_step',
]);

const REDUCED_KINDS = Object.freeze([
  'field_to_calc',
  'field_sql_select_to_step',
  'field_sql_filter_to_step',
  'field_guards_step',
  'sink_display',
]);

/**
 * Files of the solution and their DDR flag.
 * @returns {Promise<{files: string[], noDdr: string[], state: 'all'|'partial'|'none'|'unknown'}>}
 */
async function loadDdrCoverage(ctx) {
  let rows = [];
  try {
    rows = (await db.executeQuery(
      ctx,
      'SELECT File_Name, Has_DDR_INFO FROM FilesCatalog ORDER BY File_Name'
    )).rows;
  } catch {
    // Catalog without FilesCatalog or without the flag: no statement possible.
    return { files: [], noDdr: [], state: 'unknown' };
  }
  const files = rows.map((r) => r.File_Name);
  const noDdr = rows.filter((r) => r.Has_DDR_INFO === false).map((r) => r.File_Name);
  let state = 'all';
  if (files.length === 0) state = 'unknown';
  else if (noDdr.length === files.length) state = 'none';
  else if (noDdr.length > 0) state = 'partial';
  return { files, noDdr, state };
}

/** File part of a graph id (`<uuid>[#suffix]::<file>`), or null. */
function fileOfId(id) {
  if (typeof id !== 'string') return null;
  const sep = id.lastIndexOf('::');
  return sep === -1 ? null : id.slice(sep + 2);
}

/**
 * Blind-spot block for a trace answer: the DDR-less files among `touchedFiles`
 * and the edge kinds that are missing or reduced there. Empty `files` = nothing
 * to report.
 * @param {string[]} noDdr - DDR-less files of the solution
 * @param {Iterable<?string>} touchedFiles - files the trace touches (start, nodes, ways)
 */
function noDdrBlindSpot(noDdr, touchedFiles) {
  const set = new Set(noDdr);
  const hit = new Set();
  for (const f of touchedFiles) if (f && set.has(f)) hit.add(f);
  return {
    files: [...hit].sort(),
    missingKinds: hit.size ? [...MISSING_KINDS] : [],
    reducedKinds: hit.size ? [...REDUCED_KINDS] : [],
  };
}

module.exports = {
  MISSING_KINDS,
  REDUCED_KINDS,
  loadDdrCoverage,
  fileOfId,
  noDdrBlindSpot,
};
