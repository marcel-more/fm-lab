#!/usr/bin/env node
/**
 * unused_code_estimate.mjs — rough estimate of the unused code of a solution for
 * fm-deep-research (R3): share per object type plus a small sample spread over the
 * most affected files.
 *
 * The definition of "unused" is NOT repeated here. The script reads the member list
 * of the Analysis Test `unused-code` (test.json) and runs each member's findings
 * dataset directly against the catalog (read-only, same params as the fm-test
 * direct path: no file / scope variables = solution scope). Only the aggregate and
 * the sample reach stdout — the complete list is the test run itself
 * (`/fm-test unused-code`).
 *
 * Usage:
 *   node unused_code_estimate.mjs --db=<path to fm_catalog.duckdb> [--sample=3] [--json]
 *
 * Output (stdout): a Markdown block (default) or one JSON object (--json) with
 *   totals { objects, unused, pct } and per type { type, ref, objects, unused, pct,
 *   files, top_files[], sample[], unverified } (+ to_classes for table occurrences,
 *   + entry_points for members with an `entry_points` dataset: scripts / layouts in
 *   the menus, which are not findings and do not count as unused).
 * Exit 2 = usage / setup error (no DB, no duckdb, test definition missing).
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../../..');
const TEST_ID = 'unused-code';
// Upper bound of the findings datasets' page size; above it the count still comes
// from `_row_total`, only the sample is drawn from the first page.
const PAGE_SIZE = 10000;

// Object type of each member: the candidate set of the rule (every object of the
// type; privilege sets without the three built-in sets — IDs 1–3 — exactly as the rule).
const MEMBER_TYPES = {
  unused_table_occurrence: 'TableOccurrence',
  unused_base_table: 'BaseTable',
  unused_external_data_source: 'ExternalDataSource',
  unused_field: 'Field',
  unused_value_list: 'ValueList',
  unused_script: 'Script',
  unused_custom_function: 'CustomFunction',
  unused_layout: 'Layout',
  unused_privilege_set: 'PrivilegeSet',
};

function parseArgs(argv) {
  const out = {};
  for (const a of argv.slice(2)) {
    const m = a.match(/^--([^=]+)=(.*)$/);
    if (m) out[m[1]] = m[2];
    else if (a.startsWith('--')) out[a.slice(2)] = true;
  }
  return out;
}

function fail(msg) {
  console.error(`ERROR: ${msg}`);
  process.exit(2);
}

const args = parseArgs(process.argv);
if (!args.db) fail('usage: node unused_code_estimate.mjs --db=<path> [--sample=3] [--json]');
const DB_FILE = path.resolve(args.db);
if (!fs.existsSync(DB_FILE)) fail(`catalog not found: ${DB_FILE}`);
const SAMPLE = Math.max(1, Math.min(10, Number(args.sample) || 3));
// DuckDB 2.0 CLI: no agent output mode (truncation) in the child processes.
process.env.DUCKDB_AGENT_MODE = '0';

function findDuckdb() {
  const resolver = path.join(HERE, '../../_shared/scripts/resolve_duckdb_bin.sh');
  const r = spawnSync('bash', [resolver], { encoding: 'utf8' });
  const bin = (r.stdout || '').trim();
  if (r.status !== 0 || !bin) fail('duckdb binary not found (see docs/agents/tooling.md).');
  return bin;
}
const DUCKDB = findDuckdb();

/** Runs SQL (or dot commands) read-only and returns the rows of the last result. */
function query(commands) {
  const argv = [DB_FILE, '-readonly', '-json'];
  for (const c of commands) argv.push('-c', c);
  const r = spawnSync(DUCKDB, argv, { cwd: REPO, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0) throw new Error((r.stderr || r.stdout || '').trim().split('\n').slice(0, 3).join(' '));
  const text = (r.stdout || '').trim();
  if (!text) return [];
  // Several result sets come as consecutive JSON arrays; the last one is the query.
  const parts = text.split(/\n(?=\[)/);
  return JSON.parse(parts[parts.length - 1]);
}

/** Locates a file below the template areas in the documented precedence. */
function findTemplate(areas, rel) {
  for (const area of areas) {
    const root = path.join(REPO, 'rest-api/templates', area);
    if (!fs.existsSync(root)) continue;
    const stack = [root];
    while (stack.length) {
      const dir = stack.pop();
      const hit = path.join(dir, rel);
      if (fs.existsSync(hit)) return hit;
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.isDirectory() && e.name !== 'data' && e.name !== 'locales') stack.push(path.join(dir, e.name));
      }
    }
  }
  return null;
}

const testFile = findTemplate(['tests-custom', 'tests', 'tests-community'], path.join(TEST_ID, 'test.json'));
if (!testFile) fail(`test definition '${TEST_ID}' not found`);
const test = JSON.parse(fs.readFileSync(testFile, 'utf8'));
const members = (test.members || []).map((m) => m.ref).filter((ref) => MEMBER_TYPES[ref]);
if (!members.length) fail(`test '${TEST_ID}' has no known members`);

// Candidate counts per type — one query.
const totals = Object.fromEntries(query([`
  SELECT Object_Type AS type, count(*) AS n
  FROM ObjectCatalog
  WHERE Object_Type IN (${[...new Set(Object.values(MEMBER_TYPES))].map((t) => `'${t}'`).join(', ')})
    AND NOT EXISTS (SELECT 1 FROM PrivilegeSetsCatalog ps
                    WHERE ObjectCatalog.Object_Type = 'PrivilegeSet'
                      AND ps.PrivilegeSet_UUID = ObjectCatalog.Object_UUID
                      AND ps.File_Name = ObjectCatalog.File_Name
                      AND ps.PrivilegeSet_ID <= 3)
  GROUP BY 1`]).map((r) => [r.type, Number(r.n)]));

// Names made of punctuation or blanks only ("---", "   ") are divider scripts or
// layouts; they count as findings but say nothing as a sample.
const READABLE = /[\p{L}\p{N}]/u;
const pick = (list) => {
  const sorted = [...list].sort((a, b) => String(a.object_name).localeCompare(String(b.object_name)));
  return sorted.find((r) => READABLE.test(String(r.object_name ?? ''))) ?? sorted[0];
};

/**
 * Sample spread over the most affected files: one object from each of the
 * `SAMPLE` files with the most findings (first readable name), so the sample shows
 * where the unused code concentrates instead of the first file in alphabetical order.
 */
function summarize(rows, total) {
  const byFile = new Map();
  for (const r of rows) {
    const f = r.file_name ?? '';
    if (!byFile.has(f)) byFile.set(f, []);
    byFile.get(f).push(r);
  }
  const files = [...byFile.entries()]
    .map(([file, list]) => ({ file, n: list.length, list }))
    .sort((a, b) => b.n - a.n || a.file.localeCompare(b.file));
  const sample = files.slice(0, SAMPLE).map(({ file, list }) => {
    const first = pick(list);
    const out = { file, name: first.object_name };
    if (first.reason) out.reason = first.reason_status || first.reason;
    if (first.anchor_to) out.anchor = first.anchor_to;
    return out;
  });
  // Fill up from the largest file when fewer files than sample slots exist.
  if (sample.length < SAMPLE && files.length) {
    const taken = new Set(sample.map((s) => `${s.file}|${s.name}`));
    for (const r of files[0].list) {
      if (sample.length >= SAMPLE) break;
      const k = `${r.file_name}|${r.object_name}`;
      if (!taken.has(k)) { taken.add(k); sample.push({ file: r.file_name, name: r.object_name }); }
    }
  }
  return {
    files: byFile.size,
    top_files: files.slice(0, 3).map(({ file, n }) => ({ file, n, pct: total ? Math.round((n / total) * 100) : 0 })),
    sample,
  };
}

const result = { test: TEST_ID, version: test.version, types: [], totals: { objects: 0, unused: 0, pct: 0 }, errors: [] };
for (const ref of members) {
  const type = MEMBER_TYPES[ref];
  const sql = findTemplate(['dashboards-custom', 'dashboards', 'dashboards-community'], path.join(ref, 'data', 'findings.sql'));
  if (!sql) { result.errors.push({ ref, error: 'findings dataset not found' }); continue; }
  let rows;
  try {
    rows = query([`SET VARIABLE page_size = ${PAGE_SIZE}`, `.read ${path.relative(REPO, sql)}`]);
  } catch (e) {
    // A catalog older than schema 1.38.0 has no table-occurrence usage tables: the
    // member is left out of the totals and the report says so.
    const legacy = /v_table_occurrence_(class|usage)/.test(e.message);
    result.errors.push({ ref, error: legacy ? 'not estimated: catalog older than schema 1.38.0 (re-import)' : e.message });
    continue;
  }
  const unused = rows.length ? Number(rows[0]._row_total ?? rows.length) : 0;
  const objects = totals[type] ?? 0;
  const entry = {
    type, ref, objects, unused,
    pct: objects ? Math.round((unused / objects) * 1000) / 10 : 0,
    ...summarize(rows, unused),
  };
  // Findings in files exported without DDR info (formula references missing there).
  entry.unverified = rows.filter((r) => r.low_confidence).length;
  if (type === 'TableOccurrence') {
    const cls = {};
    for (const r of rows) cls[r.reason] = (cls[r.reason] || 0) + 1;
    entry.to_classes = cls;
  }
  // Entry points (scripts / layouts in the menus): no usage, but reachable by the
  // user — the rule lists them in their own dataset, outside the findings.
  const entrySql = path.join(path.dirname(sql), 'entry_points.sql');
  if (fs.existsSync(entrySql)) {
    try {
      const er = query([`SET VARIABLE page_size = 1`, `.read ${path.relative(REPO, entrySql)}`]);
      entry.entry_points = er.length ? Number(er[0]._row_total ?? er.length) : 0;
    } catch (e) {
      result.errors.push({ ref, error: `entry points: ${e.message}` });
    }
  }
  result.types.push(entry);
  result.totals.objects += objects;
  result.totals.unused += unused;
}
result.totals.pct = result.totals.objects
  ? Math.round((result.totals.unused / result.totals.objects) * 1000) / 10 : 0;

if (args.json) {
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
} else {
  const lines = [];
  lines.push(`Unused code (test \`${TEST_ID}\` ${result.version}, solution scope): `
    + `${result.totals.unused} of ${result.totals.objects} objects = ${result.totals.pct} %`);
  lines.push('');
  lines.push('| Type | Objects | Unused | Share | Files | Most affected files | Sample |');
  lines.push('|---|---:|---:|---:|---:|---|---|');
  for (const t of [...result.types].sort((a, b) => b.unused - a.unused)) {
    const top = t.top_files.map((f) => `${f.file} (${f.n})`).join(', ');
    const sample = t.sample.map((s) => `${s.name} [${s.file}${s.reason ? `, ${s.reason}` : ''}]`).join('; ');
    lines.push(`| ${t.type} | ${t.objects} | ${t.unused} | ${t.pct} % | ${t.files} | ${top} | ${sample} |`);
  }
  const to = result.types.find((t) => t.type === 'TableOccurrence');
  if (to && to.unused) {
    const cls = Object.entries(to.to_classes).map(([k, v]) => `${k} ${v}`).join(' · ');
    lines.push('');
    lines.push(`Table occurrences: ${cls}.`);
  }
  const unverified = result.types.filter((t) => t.unverified)
    .sort((a, b) => b.unverified - a.unverified).map((t) => `${t.type} ${t.unverified}`);
  if (unverified.length) {
    lines.push('');
    lines.push(`Unverified (file exported without DDR info, formula references missing): ${unverified.join(' · ')}.`);
  }
  const entries = result.types.filter((t) => t.entry_points).map((t) => `${t.type} ${t.entry_points}`);
  if (entries.length) {
    lines.push('');
    lines.push(`Entry points (in the Scripts / layout menu, no caller — not counted as unused): ${entries.join(' · ')}.`);
  }
  for (const e of result.errors) lines.push(`${MEMBER_TYPES[e.ref] ?? e.ref}: ${e.error}`);
  process.stdout.write(lines.join('\n') + '\n');
}
