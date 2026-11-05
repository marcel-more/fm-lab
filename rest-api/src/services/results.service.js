const fsSync = require('fs');
const fs = require('fs').promises;
const path = require('path');
const { createError } = require('../middleware/error-handler');
const solutions = require('../config/solutions');
const dashboardService = require('./dashboard.service');

/**
 * Results Service — the shared result layer (Result Envelope v1).
 *
 * One normative result shape for every result-capable unit, regardless of
 * origin (`kind:id` with kind ∈ dashboard | test; dashboards are bundles or
 * single-file dashboards, `query` is accepted as a read alias of `dashboard`). The two-axis model
 * (`runStatus` × `resultState`) and its derivation move HERE from
 * tests.service; the tests runner is a consumer of this service, not a second
 * producer.
 *
 * Three deliberate layers:
 *  1. Registry     — which units carry a result declaration, and where they
 *                    hang in the folder/category hierarchy (union of the
 *                    existing catalogs, no new registration file).
 *  2. Runner       — runOne/runMany execute a unit's default result (value
 *                    source cascade for dashboards: analysis.defaultResult →
 *                    summary/finding_count convention).
 *  3. Server cache — in-memory envelope map keyed by
 *                    solution|catalogFingerprint|kind:id. Read endpoints only
 *                    ever read the cache; runs are explicit triggers. A test
 *                    run (solution scope) writes through, so tests pre-warm
 *                    the dashboard chips and vice versa.
 */

// Findings sort order (worst first) — shared with tests.service.
const SEVERITY_ORDER = { critical: 0, error: 1, warning: 2, info: 3 };

// Ranking for worst-state aggregation (R4.1).
const STATE_RANK = { error: 0, warning: 1, failed: 2, neutral: 3, ok: 4, pending: 5 };

const DEFAULT_CONCURRENCY = 6;
const DEFAULT_TIMEOUT_MS = 30000;
const MAX_RUN_TARGETS = 500;

function severityRank(value) {
  const key = String(value || '').toLowerCase();
  return key in SEVERITY_ORDER ? SEVERITY_ORDER[key] : 9;
}

/**
 * Result-state axis of the two-axis model (`runStatus` = ran|failed|skipped|
 * pending says whether the unit ran; `resultState` judges what a successful
 * run found). Single truth for tests tab, /tests page, dashboard chips and
 * the fm-test skill.
 *
 * Prefers the worst per-row severity when findings were fetched — platform
 * members mix error (No) and warning (Partial) rows under one member severity.
 * Units without a judging severity (inventory counts, info rules) are
 * `neutral`: their value is information, not a defect.
 */
function deriveResultState(value, memberSeverity, findingsRows) {
  const hit = typeof value === 'boolean' ? value : Number(value) > 0;
  if (!hit) return 'ok';
  if (Array.isArray(findingsRows) && findingsRows.length) {
    let worst = 9;
    for (const row of findingsRows) worst = Math.min(worst, severityRank(row.severity));
    if (worst <= SEVERITY_ORDER.error) return 'error';
    if (worst === SEVERITY_ORDER.warning) return 'warning';
    return 'neutral';
  }
  const sev = String(memberSeverity || '').toLowerCase();
  if (sev === 'critical' || sev === 'error') return 'error';
  if (sev === 'warning') return 'warning';
  return 'neutral';
}

/**
 * Cheap invalidation signal for result caches: mtime+size of the solution's
 * read copy. The converter replaces the copy atomically, so a new XML import
 * changes the fingerprint without any bookkeeping here.
 */
function catalogMeta(ctx) {
  const solution = (ctx && ctx.solution) || null;
  try {
    const st = fsSync.statSync(solutions.resolveDbPath(solution));
    return {
      solution,
      catalogFingerprint: `${Math.round(st.mtimeMs)}-${st.size}`,
      catalogMtimeMs: Math.round(st.mtimeMs),
    };
  } catch {
    return { solution, catalogFingerprint: null, catalogMtimeMs: null };
  }
}

function firstRowValue(rows, column) {
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const row = rows[0];
  if (column && column in row) return row[column];
  const keys = Object.keys(row);
  return keys.length ? row[keys[0]] : null;
}

function refKey(ref) {
  return `${canonicalKind(ref.kind)}:${ref.id}`;
}

function normalizeValue(v) {
  return typeof v === 'bigint' ? Number(v) : v;
}

// ---------------------------------------------------------------------------
// Declarations — value source per unit
// ---------------------------------------------------------------------------

/**
 * Unit hint for consolidation sums (R4.2): explicit `defaultResult.unit`
 * wins; `finding_count` implies "findings"; anything else has no unit and
 * never enters a sum.
 */
function resolveUnit(dr) {
  if (dr && typeof dr.unit === 'string' && dr.unit.length) return dr.unit;
  if (dr && dr.name === 'finding_count') return 'findings';
  return null;
}

/**
 * Value-source cascade for a dashboard bundle:
 *  1. analysis.defaultResult (declared)
 *  2. summary/finding_count convention: a dataset `summary` whose SQL emits a
 *     `finding_count` column → counted as source "summary-convention".
 *  3. null → the unit has no result declaration (stays chipless).
 */
async function resolveDashboardDeclaration(bundle) {
  const analysis = bundle.manifest.analysis;
  if (analysis && analysis.defaultResult) {
    const dr = analysis.defaultResult;
    return {
      source: 'defaultResult',
      dataset: dr.dataset || 'summary',
      column: dr.column || null,
      // 'row_count' | 'first_row:<column>' (single-file dashboards); absent =
      // the column value of the first row.
      aggregate: dr.aggregate || null,
      type: dr.type || 'number',
      name: dr.name,
      meaning: dr.meaning || null,
      unit: resolveUnit(dr),
    };
  }
  const spec = (bundle.manifest.datasets || []).find(d => d.id === 'summary');
  if (!spec) return null;
  const m = /^bundle:(.+)$/.exec(String(spec.source));
  if (!m) return null;
  try {
    const sql = await fs.readFile(path.join(bundle.dir, path.normalize(m[1])), 'utf-8');
    if (!/finding_count/i.test(sql)) return null;
  } catch {
    return null;
  }
  return {
    source: 'summary-convention',
    dataset: 'summary',
    column: 'finding_count',
    type: 'number',
    name: 'finding_count',
    meaning: null,
    unit: 'findings',
  };
}

/** Read alias: `query` refs address the dashboard of the same id. */
function canonicalKind(kind) {
  return kind === 'query' ? 'dashboard' : kind;
}

// ---------------------------------------------------------------------------
// Registry (R2) — union of the existing catalogs, filtered to "declared"
// ---------------------------------------------------------------------------

/**
 * One row per result-capable unit:
 * { ref: {kind,id}, rubric, title, icon, severity, unit, source }.
 * `rubric` is the folder path of the unit: relative to the shipped tree for
 * builtin content, prefixed `custom/…` / `community/…` for those areas, null
 * for system and module bundles. Single-file dashboards are dashboards like
 * any other. Units without a declaration are absent by design (display-only
 * dashboards) — they stay chipless.
 */
async function listRegistry({ kinds } = {}) {
  const wanted = new Set((kinds && kinds.length ? kinds : ['dashboard', 'test']).map(canonicalKind));
  const rows = [];
  if (wanted.has('dashboard')) {
    const bundles = await dashboardService.listBundles();
    for (const bundle of bundles) {
      const decl = await resolveDashboardDeclaration(bundle);
      if (!decl) continue;
      rows.push({
        ref: { kind: 'dashboard', id: bundle.id },
        rubric: bundle.folder || null,
        title: bundle.manifest.title || bundle.id,
        icon: bundle.manifest.icon || null,
        severity: (bundle.manifest.rule && bundle.manifest.rule.severity) || null,
        unit: decl.unit,
        name: decl.name,
        meaning: decl.meaning,
        source: decl.source,
        tags: bundle.manifest.tags || [],
      });
    }
  }
  if (wanted.has('test')) {
    // Read-only (O6): tests appear in the registry and the aggregate, but the
    // trigger endpoint never runs them — their envelopes come from test runs
    // writing through (putEnvelope in tests.service.runTest).
    const testsService = require('./tests.service');
    const tests = await testsService.listTests();
    for (const t of tests) {
      rows.push({
        ref: { kind: 'test', id: t.id },
        rubric: t.folder || null,
        title: t.definition.title || t.id,
        icon: null,
        severity: null,
        unit: null,
        name: 'test_summary',
        meaning: t.definition.description || null,
        source: 'test',
        tags: [],
      });
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Server cache (R7 layer 1) — the one truth
// ---------------------------------------------------------------------------

// solutionKey → { fingerprint, map: Map<'kind:id', envelope> }
const cacheBySolution = new Map();

function solutionKey(meta) {
  return meta.solution || '__default__';
}

/**
 * Cache generation for the context's CURRENT fingerprint. A fingerprint
 * change (new XML import) discards the previous generation completely —
 * envelopes against an old catalog are wrong, not weaker.
 */
function getGeneration(ctx) {
  const meta = catalogMeta(ctx);
  const key = solutionKey(meta);
  let gen = cacheBySolution.get(key);
  if (!gen || gen.fingerprint !== meta.catalogFingerprint) {
    gen = { fingerprint: meta.catalogFingerprint, map: new Map() };
    cacheBySolution.set(key, gen);
  }
  return { meta, gen };
}

/**
 * Stores an envelope in the server cache — also called by tests.service after
 * solution-scope runs (write-through: a test run pre-warms the dashboard
 * chips of its members and vice versa).
 */
function putEnvelope(ctx, envelope) {
  const { meta, gen } = getGeneration(ctx);
  if (!meta.catalogFingerprint) return;
  // Findings rows stay out of the cache — the summary layer only ever needs
  // the count + state; row-level detail belongs to the test/detail level.
  const { findings, ...lean } = envelope;
  gen.map.set(refKey(envelope.ref), lean);
}

function getEnvelope(ctx, ref) {
  const { gen } = getGeneration(ctx);
  return gen.map.get(refKey(ref)) || null;
}

function clearCache() {
  cacheBySolution.clear();
}

// ---------------------------------------------------------------------------
// Runner (R3) — one execution logic, two consumers (results API + tests)
// ---------------------------------------------------------------------------

/**
 * Executes ONE unit's default result and returns the Result Envelope.
 *
 * Options:
 *  - params           extra SQL params (scope params from a test run)
 *  - includeFindings  fetch the findings-shaped rows when the value signals
 *                     hits (tests only; the summary path never loads rows)
 *  - findingsLimit    cap for the findings rows
 *  - cacheable        write the envelope into the server cache (only for
 *                     unscoped/solution runs — scoped values must never warm
 *                     the global chips)
 *
 * Errors never throw — they yield `runStatus: "failed"` for this unit.
 */
async function runOne(ctx, ref, options = {}) {
  const started = Date.now();
  const meta = catalogMeta(ctx);
  const params = { ...(options.params || {}) };
  const kind = canonicalKind(ref.kind);
  const base = {
    ref: { kind, id: ref.id },
    rubric: null,
    fingerprint: meta.catalogFingerprint,
    at: started,
  };
  try {
    let envelope;
    if (kind === 'dashboard') {
      envelope = await runDashboard(ctx, ref.id, params, options, base);
    } else {
      throw createError('VALIDATION_ERROR', `Cannot run kind '${ref.kind}' via results runner`);
    }
    envelope.durationMs = Date.now() - started;
    if (options.cacheable) putEnvelope(ctx, envelope);
    return envelope;
  } catch (err) {
    const envelope = {
      ...base,
      title: ref.id,
      runStatus: 'failed',
      resultState: null,
      value: null,
      unit: null,
      name: null,
      meaning: null,
      severity: null,
      source: null,
      error: err.message,
      durationMs: Date.now() - started,
    };
    if (options.cacheable) putEnvelope(ctx, envelope);
    return envelope;
  }
}

/**
 * `row_count` aggregate. A server-paged dataset delivers only its first page;
 * the shared paging window block carries the full count as `_row_total` on
 * every row, so that wins over the page length.
 */
function rowCount(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return 0;
  const total = rows[0]._row_total;
  return total != null && Number.isFinite(Number(total)) ? Number(total) : rows.length;
}

async function runDashboard(ctx, id, params, options, base) {
  const bundle = await dashboardService.getBundle(id);
  const decl = await resolveDashboardDeclaration(bundle);
  const severity = (bundle.manifest.rule && bundle.manifest.rule.severity) || null;
  const common = {
    ...base,
    rubric: bundle.folder || null,
    title: bundle.manifest.title || id,
    severity,
  };
  if (!decl) {
    return {
      ...common,
      runStatus: 'failed',
      resultState: null,
      value: null,
      unit: null,
      name: null,
      meaning: null,
      source: null,
      error: 'unit has no result declaration (analysis.defaultResult or summary/finding_count)',
    };
  }
  const result = await dashboardService.executeSingleDataset(ctx, bundle, decl.dataset, { ...params });
  let value;
  if (decl.aggregate === 'row_count') {
    value = rowCount(result.data);
  } else if (decl.aggregate && decl.aggregate.startsWith('first_row:')) {
    value = normalizeValue(firstRowValue(result.data, decl.aggregate.slice('first_row:'.length)));
  } else {
    value = normalizeValue(firstRowValue(result.data, decl.column));
  }
  const envelope = {
    ...common,
    runStatus: 'ran',
    value,
    type: decl.type,
    unit: decl.unit,
    name: decl.name || id,
    meaning: decl.meaning,
    source: decl.source,
  };
  // Findings mode (tests): fetch the findings-shaped dataset when the default
  // result signals hits. Convention: dataset id 'findings'; a single-file
  // dashboard has none — its result rows are the findings.
  if (options.includeFindings && Number(value) > 0) {
    const findingsSpec = (bundle.manifest.datasets || []).find(d => d.id === 'findings');
    if (!findingsSpec && decl.aggregate && Array.isArray(result.data)) {
      const limit = options.findingsLimit || 20;
      const rows = [...result.data];
      rows.sort((a, b) => severityRank(a.severity) - severityRank(b.severity));
      envelope.findings = { truncated: rows.length > limit, rows: rows.slice(0, limit) };
    } else if (findingsSpec) {
      const limit = options.findingsLimit || 20;
      const findings = await dashboardService.executeSingleDataset(ctx, bundle, 'findings', { ...params });
      const rows = [...(findings.data || [])];
      rows.sort((a, b) => severityRank(a.severity) - severityRank(b.severity));
      envelope.findings = { truncated: rows.length > limit, rows: rows.slice(0, limit) };
    }
  }
  envelope.resultState = deriveResultState(
    value, severity, envelope.findings && envelope.findings.rows,
  );
  return envelope;
}

function withTimeout(promise, ms, onTimeoutValue) {
  let timer;
  const timeout = new Promise(resolve => {
    timer = setTimeout(() => resolve(onTimeoutValue()), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * Fan-out with a concurrency cap (same mechanic as the tests runner). One
 * failing element yields `runStatus:"failed"` for that element only — never
 * a total abort.
 */
async function runMany(ctx, refs, options = {}) {
  const concurrency = Math.max(1, options.concurrency || DEFAULT_CONCURRENCY);
  const timeoutMs = options.timeoutMs || DEFAULT_TIMEOUT_MS;
  const meta = catalogMeta(ctx);
  const queue = [...refs];
  const out = [];
  async function worker() {
    while (queue.length) {
      const ref = queue.shift();
      if (!ref) break;
      const envelope = await withTimeout(
        runOne(ctx, ref, options),
        timeoutMs,
        () => {
          const failed = {
            ref: { kind: ref.kind, id: ref.id },
            rubric: null,
            title: ref.id,
            runStatus: 'failed',
            resultState: null,
            value: null,
            unit: null,
            name: null,
            meaning: null,
            severity: null,
            source: null,
            error: `timeout after ${timeoutMs} ms`,
            fingerprint: meta.catalogFingerprint,
            at: Date.now(),
            durationMs: timeoutMs,
          };
          if (options.cacheable) putEnvelope(ctx, failed);
          return failed;
        },
      );
      out.push(envelope);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, refs.length || 1) }, worker));
  return out;
}

// ---------------------------------------------------------------------------
// Read API (R5) — reads compute NOTHING; not-yet-run units appear as pending
// ---------------------------------------------------------------------------

function pendingEnvelope(entry, fingerprint) {
  return {
    ref: entry.ref,
    rubric: entry.rubric,
    title: entry.title,
    runStatus: 'pending',
    resultState: null,
    value: null,
    unit: entry.unit,
    name: entry.name,
    meaning: entry.meaning,
    severity: entry.severity,
    source: entry.source,
    fingerprint,
    at: null,
    durationMs: null,
  };
}

/**
 * Flat envelope map over the registry: cached envelope when the unit ran
 * under the current fingerprint, `pending` stub otherwise.
 */
async function getSummary(ctx, { kinds } = {}) {
  const { meta, gen } = getGeneration(ctx);
  const registry = await listRegistry({ kinds });
  const results = {};
  for (const entry of registry) {
    const cached = gen.map.get(refKey(entry.ref));
    results[refKey(entry.ref)] = cached || pendingEnvelope(entry, meta.catalogFingerprint);
  }
  return { meta: { solution: meta.solution, catalogFingerprint: meta.catalogFingerprint }, results };
}

// ---------------------------------------------------------------------------
// Aggregation (R4) — a pure fold over registry + cache; executes nothing
// ---------------------------------------------------------------------------

function nodePaths(rubric) {
  if (!rubric) return [''];
  const segs = String(rubric).split('/');
  const out = [''];
  let prefix = '';
  for (const seg of segs) {
    prefix = prefix ? `${prefix}/${seg}` : seg;
    out.push(prefix);
  }
  return out;
}

/**
 * Folds the cached envelopes over the folder hierarchy. Per node:
 * counts per state + worst (the folder traffic light), sums only within the
 * same `unit` (heterogeneous metrics never mix), and covered/declared/total
 * so partial coverage is visible — green over 3/16 runs is no all-clear.
 */
async function aggregate(ctx, { root = '', roots, kinds } = {}) {
  const { meta, gen } = getGeneration(ctx);
  const registry = await listRegistry({ kinds });
  // `roots` (list or comma-separated) scopes to SEVERAL subtrees at once and
  // keeps the '' node as the combined aggregate over all of them — the natural
  // binding for a page-level KPI strip spanning e.g. static-code-analysis +
  // metadata-integrity. Single `root` keeps its exact behavior (no '' node —
  // it would duplicate the root node). `roots` wins when both are set.
  const rootList = (Array.isArray(roots) ? roots : String(roots || '').split(','))
    .map(s => String(s).trim()).filter(Boolean);
  const under = (p, r) => p === r || p.startsWith(`${r}/`);
  let entryInScope, nodeInScope;
  if (rootList.length) {
    entryInScope = rubric => rootList.some(r => under(rubric, r));
    nodeInScope = p => p === '' || rootList.some(r => under(p, r));
  } else if (root) {
    entryInScope = rubric => under(rubric, root);
    // Under a root, the '' node would duplicate the root node — skip it.
    nodeInScope = p => p !== '' && under(p, root);
  } else {
    entryInScope = () => true;
    nodeInScope = () => true;
  }
  const inScope = registry.filter(e => entryInScope(e.rubric || ''));
  const nodes = new Map();
  const ensureNode = p => {
    if (!nodes.has(p)) {
      nodes.set(p, {
        path: p || null,
        counts: { ok: 0, warning: 0, error: 0, neutral: 0, failed: 0, pending: 0 },
        worst: null,
        sums: {},
        covered: 0,
        declared: 0,
        total: 0,
      });
    }
    return nodes.get(p);
  };
  for (const entry of inScope) {
    const cached = gen.map.get(refKey(entry.ref));
    const envelope = cached || pendingEnvelope(entry, meta.catalogFingerprint);
    const state = envelope.runStatus === 'ran' ? envelope.resultState
      : envelope.runStatus === 'failed' ? 'failed' : 'pending';
    for (const p of nodePaths(entry.rubric)) {
      if (!nodeInScope(p)) continue;
      const node = ensureNode(p);
      node.total += 1;
      node.declared += 1;
      if (envelope.runStatus !== 'pending') node.covered += 1;
      if (state in node.counts) node.counts[state] += 1;
      if (envelope.runStatus === 'ran' && envelope.unit != null && typeof envelope.value === 'number') {
        node.sums[envelope.unit] = (node.sums[envelope.unit] || 0) + envelope.value;
      }
      if (node.worst === null || STATE_RANK[state] < STATE_RANK[node.worst]) node.worst = state;
    }
  }
  const list = [...nodes.values()].sort((a, b) => String(a.path || '').localeCompare(String(b.path || '')));
  return {
    meta: { solution: meta.solution, catalogFingerprint: meta.catalogFingerprint },
    nodes: list,
  };
}

// ---------------------------------------------------------------------------
// Trigger (R5) — explicit runs; folder targets expand via the registry
// ---------------------------------------------------------------------------

const RUNNABLE_KINDS = new Set(['dashboard']);

/**
 * POST /api/results/run — body { targets, mode }.
 * Targets: { kind, id } singles or { kind:'folder', path, kinds } subtrees.
 * mode 'missing' (default) runs only units without a cached envelope under
 * the current fingerprint — idempotent against the cache; 'refresh' re-runs
 * everything addressed.
 */
async function runTargets(ctx, { targets, mode = 'missing', concurrency, timeoutMs } = {}) {
  if (!Array.isArray(targets) || targets.length === 0) {
    throw createError('VALIDATION_ERROR', 'targets must be a non-empty array');
  }
  const started = Date.now();
  const { gen } = getGeneration(ctx);
  const registry = await listRegistry({});
  const byKey = new Map(registry.map(e => [refKey(e.ref), e]));
  const refs = new Map(); // key → ref (dedup)
  for (const target of targets) {
    if (target && target.kind === 'folder') {
      const p = String(target.path || '');
      const prefix = p ? `${p}/` : '';
      const kindsFilter = Array.isArray(target.kinds) && target.kinds.length
        ? new Set(target.kinds.map(canonicalKind)) : RUNNABLE_KINDS;
      for (const entry of registry) {
        if (!RUNNABLE_KINDS.has(entry.ref.kind) || !kindsFilter.has(entry.ref.kind)) continue;
        const rubric = entry.rubric || '';
        if (p ? (rubric === p || rubric.startsWith(prefix)) : true) {
          refs.set(refKey(entry.ref), entry.ref);
        }
      }
    } else if (target && RUNNABLE_KINDS.has(canonicalKind(target.kind)) && target.id) {
      // Singles run even without a registry entry — the runner then reports
      // the missing declaration as a per-unit failure, not a 400.
      const ref = { kind: canonicalKind(target.kind), id: String(target.id) };
      refs.set(refKey(ref), ref);
    } else {
      throw createError('VALIDATION_ERROR', `Invalid target: ${JSON.stringify(target)}`);
    }
  }
  let toRun = [...refs.values()];
  if (mode === 'missing') {
    toRun = toRun.filter(ref => !gen.map.has(refKey(ref)));
  } else if (mode !== 'refresh') {
    throw createError('VALIDATION_ERROR', `Invalid mode '${mode}' (missing | refresh)`);
  }
  if (toRun.length > MAX_RUN_TARGETS) {
    throw createError('VALIDATION_ERROR',
      `Too many targets (${toRun.length}, cap ${MAX_RUN_TARGETS}) — chunk the run per top-level folder`);
  }
  const results = await runMany(ctx, toRun, { cacheable: true, concurrency, timeoutMs });
  // Annotate skipped-because-cached count so idempotent re-triggers are visible.
  const metaOut = catalogMeta(ctx);
  return {
    meta: {
      solution: metaOut.solution,
      catalogFingerprint: metaOut.catalogFingerprint,
      durationMs: Date.now() - started,
      requested: refs.size,
      executed: results.length,
      skippedCached: refs.size - results.length,
    },
    results,
  };
}

module.exports = {
  SEVERITY_ORDER,
  STATE_RANK,
  severityRank,
  deriveResultState,
  catalogMeta,
  firstRowValue,
  resolveDashboardDeclaration,
  listRegistry,
  runOne,
  runMany,
  runTargets,
  getSummary,
  aggregate,
  putEnvelope,
  getEnvelope,
  clearCache,
};
