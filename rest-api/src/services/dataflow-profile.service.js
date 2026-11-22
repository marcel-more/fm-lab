/**
 * Solution profile of the field data trace.
 *
 * The profile holds solution knowledge the catalog cannot decide statically —
 * technical layouts, infrastructure scripts, UI-state and hub variables — as
 * declarative rules. Only `confirmed` rules act, and only at walk time
 * (graph_trace_data.sql): they never change v_dataflow_edges, and `profile=off`
 * shows the generic view. `rejected` rules suppress a candidate for good.
 *
 * Storage: solutions/<id>/state/dataflow_profile.json — part of the bundle,
 * survives re-imports (the catalog DB is replaced, state/ is not) and travels
 * with `solution.sh export`. A rule is keyed by (kind, uuid, file) or
 * (kind, pattern); a rule whose object is missing after a re-import is reported
 * as `orphaned`, never dropped silently.
 *
 * Candidates (H1–H4, graph_trace_profile_candidates.sql) are suggestions only;
 * a rule comes into being only through PUT /api/graph/trace/profile.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Joi = require('joi');
const { LRUCache } = require('lru-cache');
const db = require('../config/database');
const solutions = require('../config/solutions');
const templateService = require('./template.service');
const { createError } = require('../middleware/error-handler');

const PROFILE_FILE = 'dataflow_profile.json';
const PROFILE_VERSION = 1;

/** Rule kinds; `walk` = acts in the trace walk (table_naming is stored only). */
const RULE_KINDS = Object.freeze({
  technical_layout: { target: 'Layout', pattern: 'glob', walk: true },
  boundary_script: { target: 'Script', pattern: null, walk: true },
  ui_state_variable: { target: 'Variable', pattern: 'glob', walk: true },
  hub_variable: { target: 'Variable', pattern: 'glob', walk: true },
  table_naming: { target: null, pattern: 'regex', walk: false },
});

const HEURISTIC_KINDS = Object.freeze({
  H1: 'technical_layout',
  H2: 'boundary_script',
  H3: 'ui_state_variable',
  H4: 'hub_variable',
});

const ID_PATTERN = /^[0-9A-Za-z][0-9A-Za-z-]{7,63}$/;

const ruleSchema = Joi.object({
  kind: Joi.string().valid(...Object.keys(RULE_KINDS)).required(),
  uuid: Joi.string().pattern(ID_PATTERN),
  file: Joi.string().max(255),
  pattern: Joi.string().min(1).max(255),
  name: Joi.string().allow('').max(500),
  status: Joi.string().valid('confirmed', 'rejected').required(),
  source: Joi.string().valid('H1', 'H2', 'H3', 'H4', 'manual').default('manual'),
  note: Joi.string().allow('').max(2000),
  confirmed_at: Joi.string().isoDate(),
})
  .xor('uuid', 'pattern')
  .with('uuid', 'file')
  .custom((rule, helpers) => {
    const problem = ruleKindProblem(rule);
    return problem ? helpers.message({ custom: problem }) : rule;
  }, 'rule kind check');

/** Does the rule address its object the way its kind allows? */
function ruleKindProblem(rule) {
  const spec = RULE_KINDS[rule.kind];
  if (!spec) return `unknown rule kind '${rule.kind}'`;
  if (rule.pattern !== undefined && !spec.pattern) return `${rule.kind} takes uuid + file, not a pattern`;
  if (rule.uuid !== undefined && !spec.target) return `${rule.kind} takes a pattern, not uuid + file`;
  if (rule.pattern !== undefined && spec.pattern === 'regex') {
    try {
      new RegExp(rule.pattern);
    } catch {
      return `${rule.kind}: pattern is not a valid regular expression`;
    }
  }
  return null;
}

const profileSchema = Joi.object({
  version: Joi.number().integer().valid(PROFILE_VERSION).default(PROFILE_VERSION),
  updated_at: Joi.string().isoDate(),
  rules: Joi.array().items(ruleSchema).default([]),
});

/** PUT body: rule changes and/or a bulk decision per heuristic. */
const changeSchema = Joi.object({
  rules: Joi.array().items(
    Joi.object({
      kind: Joi.string().valid(...Object.keys(RULE_KINDS)).required(),
      uuid: Joi.string().pattern(ID_PATTERN),
      file: Joi.string().max(255),
      pattern: Joi.string().min(1).max(255),
      name: Joi.string().allow('').max(500),
      // none = remove the rule (the candidate becomes open again)
      status: Joi.string().valid('confirmed', 'rejected', 'none').required(),
      source: Joi.string().valid('H1', 'H2', 'H3', 'H4', 'manual'),
      note: Joi.string().allow('').max(2000),
    }).xor('uuid', 'pattern').with('uuid', 'file'),
  ).min(1).max(5000),
  // Sammelbestätigung: every open candidate of the heuristic, except the keys listed
  heuristic: Joi.object({
    id: Joi.string().valid(...Object.keys(HEURISTIC_KINDS)).required(),
    status: Joi.string().valid('confirmed', 'rejected').required(),
    except: Joi.array().items(Joi.string().max(600)).max(5000).default([]),
    include_uncertain: Joi.boolean().default(false),
  }),
}).or('rules', 'heuristic');

/** Stable key of a rule or candidate. */
function ruleKey(r) {
  return r.pattern !== undefined && r.pattern !== null
    ? `${r.kind}|pattern:${r.pattern}`
    : `${r.kind}|${r.uuid}::${r.file ?? ''}`;
}

function profilePath(ctx) {
  return path.join(solutions.stateDir(ctx.solution), PROFILE_FILE);
}

/**
 * Reads and validates a profile file; a missing file is an empty profile.
 * @throws PROFILE_INVALID (409) on unreadable JSON or a schema violation
 */
function readProfileFile(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf-8');
  } catch (err) {
    if (err.code === 'ENOENT') return { version: PROFILE_VERSION, rules: [] };
    throw err;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw createError('PROFILE_INVALID', `${PROFILE_FILE} is not valid JSON: ${err.message}`, { file });
  }
  const { error, value } = profileSchema.validate(parsed, { abortEarly: false, stripUnknown: true });
  if (error) {
    throw createError('PROFILE_INVALID', `${PROFILE_FILE} does not match the profile schema`, {
      file,
      errors: error.details.map((d) => ({ field: d.path.join('.'), message: d.message })),
    });
  }
  // Duplicate keys: the last one wins (same as a PUT would do).
  const byKey = new Map();
  for (const r of value.rules) byKey.set(ruleKey(r), r);
  value.rules = [...byKey.values()];
  return value;
}

/** Atomic write (temp file + rename), rules sorted by key. */
function writeProfileFile(file, profile) {
  const out = {
    version: PROFILE_VERSION,
    updated_at: new Date().toISOString(),
    rules: [...profile.rules].sort((a, b) => (ruleKey(a) < ruleKey(b) ? -1 : ruleKey(a) > ruleKey(b) ? 1 : 0)),
  };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(out, null, 2)}\n`, 'utf-8');
  fs.renameSync(tmp, file);
  return out;
}

/** Hash of the confirmed rules — part of the trace cache key. */
function profileHash(profile) {
  const confirmed = profile.rules
    .filter((r) => r.status === 'confirmed' && RULE_KINDS[r.kind].walk)
    .map((r) => ruleKey(r))
    .sort();
  if (confirmed.length === 0) return 'none';
  return crypto.createHash('sha1').update(confirmed.join('\n')).digest('hex').slice(0, 12);
}

/**
 * Applies a PUT body to a profile (pure).
 * @param {Object} profile
 * @param {Object} change - validated changeSchema value
 * @param {Array} candidates - open + decided candidates (for the heuristic bulk)
 * @param {string} now - ISO timestamp
 * @returns {{profile:Object, changed:number}}
 */
function applyChanges(profile, change, candidates, now) {
  const byKey = new Map(profile.rules.map((r) => [ruleKey(r), r]));
  let changed = 0;
  const put = (r) => {
    const key = ruleKey(r);
    if (r.status === 'none') {
      if (byKey.delete(key)) changed++;
      return;
    }
    const prev = byKey.get(key);
    const next = {
      kind: r.kind,
      ...(r.pattern !== undefined ? { pattern: r.pattern } : { uuid: r.uuid, file: r.file }),
      ...(r.name !== undefined ? { name: r.name } : prev?.name !== undefined ? { name: prev.name } : {}),
      status: r.status,
      source: r.source ?? prev?.source ?? 'manual',
      ...(r.note !== undefined ? { note: r.note } : prev?.note !== undefined ? { note: prev.note } : {}),
      confirmed_at: prev && prev.status === r.status && prev.confirmed_at ? prev.confirmed_at : now,
    };
    const { error } = ruleSchema.validate(next);
    if (error) throw createError('VALIDATION_ERROR', `Rule ${key}: ${error.message}`, { rule: key });
    if (!prev || JSON.stringify(prev) !== JSON.stringify(next)) changed++;
    byKey.set(key, next);
  };

  for (const r of change.rules || []) put(r);

  if (change.heuristic) {
    const h = change.heuristic;
    const except = new Set(h.except || []);
    for (const c of candidates) {
      if (c.heuristic !== h.id || c.status !== 'open' || except.has(c.key)) continue;
      if (c.uncertain && !h.include_uncertain) continue;
      put({
        kind: c.kind,
        ...(c.pattern ? { pattern: c.pattern } : { uuid: c.uuid, file: c.file }),
        name: c.name,
        status: h.status,
        source: c.heuristic,
      });
    }
  }
  return { profile: { ...profile, rules: [...byKey.values()] }, changed };
}

// ── catalog side ────────────────────────────────────────────────────────────

const candidateCache = new LRUCache({ max: 50, ttl: 1000 * 60 * 10 });
const resolveCache = new LRUCache({ max: 100, ttl: 1000 * 60 * 10 });

function lit(v) {
  return `'${String(v).replace(/'/g, "''")}'`;
}

/** Glob (`*`, `?`) → SQL LIKE pattern with `\` escape. */
function globToLike(glob) {
  return String(glob)
    .replace(/[\\%_]/g, (ch) => `\\${ch}`)
    .replace(/\*/g, '%')
    .replace(/\?/g, '_');
}

async function catalogStamp(ctx) {
  try {
    return String(fs.statSync(solutions.masterDbPath(ctx.solution)).mtimeMs);
  } catch {
    return 'na';
  }
}

/**
 * Candidates H1–H4 with their status against the profile
 * (open · confirmed · rejected), cached per solution and catalog file.
 */
async function getCandidates(ctx, profile) {
  const stamp = await catalogStamp(ctx);
  const cacheKey = `${ctx.solution}|${stamp}`;
  let raw = candidateCache.get(cacheKey);
  if (!raw) {
    const result = await templateService.executeTemplate(ctx, 'graph_trace_profile_candidates', {}, 'report');
    raw = result.data.map((r) => {
      const c = {
        heuristic: r.heuristic,
        kind: r.kind,
        ...(r.pattern ? { pattern: r.pattern } : { uuid: r.uuid, file: r.file }),
        name: r.name,
        metrics: { a: Number(r.metric_a), b: Number(r.metric_b) },
        uncertain: r.uncertain === true,
        sample: Array.isArray(r.sample) ? r.sample : [],
      };
      c.key = ruleKey(c);
      return c;
    });
    candidateCache.set(cacheKey, raw);
  }
  const byKey = new Map(profile.rules.map((r) => [ruleKey(r), r]));
  return raw.map((c) => ({ ...c, status: byKey.get(c.key)?.status ?? 'open' }));
}

/**
 * Resolves the confirmed walk rules to node ids for graph_trace_data.sql and
 * marks orphaned rules (object missing, pattern without match).
 * @returns {Promise<{layouts:string[], scripts:string[], uiVars:string[], hubVars:string[],
 *   matches:Object<string,number>, orphaned:string[]}>}
 */
async function resolveRules(ctx, profile) {
  const stamp = await catalogStamp(ctx);
  const cacheKey = `${ctx.solution}|${stamp}|${profileHash(profile)}|${profile.rules.length}`;
  const hit = resolveCache.get(cacheKey);
  if (hit) return hit;

  const out = { layouts: [], scripts: [], uiVars: [], hubVars: [], matches: {}, orphaned: [] };
  const rules = profile.rules.filter((r) => r.status === 'confirmed');
  const bucket = { technical_layout: 'layouts', boundary_script: 'scripts', ui_state_variable: 'uiVars', hub_variable: 'hubVars' };
  const sets = { layouts: new Set(), scripts: new Set(), uiVars: new Set(), hubVars: new Set() };

  for (const r of rules) {
    const key = ruleKey(r);
    const target = bucket[r.kind];
    let ids = [];
    if (r.kind === 'table_naming') {
      out.matches[key] = null; // stored only, no walk effect
      continue;
    }
    if (r.kind === 'technical_layout') {
      const where = r.pattern !== undefined
        ? `L_Name LIKE ${lit(globToLike(r.pattern))} ESCAPE '\\'`
        : `L_UUID = ${lit(r.uuid)} AND File_Name = ${lit(r.file)}`;
      const res = await db.executeQuery(ctx, `SELECT L_UUID || '::' || File_Name AS id FROM Layouts WHERE ${where}`);
      ids = res.rows.map((x) => x.id);
    } else if (r.kind === 'boundary_script') {
      const res = await db.executeQuery(ctx,
        `SELECT Script_UUID || '::' || File_Name AS id FROM ScriptCatalog WHERE Script_UUID = ${lit(r.uuid)} AND File_Name = ${lit(r.file)}`);
      ids = res.rows.map((x) => x.id);
    } else {
      const varId = `md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name)`;
      const where = r.pattern !== undefined
        ? `Variable_Name LIKE ${lit(globToLike(r.pattern))} ESCAPE '\\'`
        : `${varId} = ${lit(r.uuid)} AND Scope_Anchor = ${lit(r.file)}`;
      const res = await db.executeQuery(ctx,
        `SELECT DISTINCT ${varId} || '::' || Scope_Anchor AS id FROM VariablesCatalog
         WHERE Variable_Scope IN ('global', 'superglobal') AND ${where}`);
      ids = res.rows.map((x) => x.id);
    }
    out.matches[key] = ids.length;
    if (ids.length === 0) out.orphaned.push(key);
    for (const id of ids) sets[target].add(id);
  }
  for (const [k, s] of Object.entries(sets)) out[k] = [...s].sort();
  resolveCache.set(cacheKey, out);
  return out;
}

/** Profile of a solution (file, rules with match counts and orphaned flag). */
function loadProfile(ctx) {
  return readProfileFile(profilePath(ctx));
}

/** GET payload: rules + candidates + summary. */
async function describeProfile(ctx) {
  const file = profilePath(ctx);
  const profile = readProfileFile(file);
  const resolved = await resolveRules(ctx, profile);
  const candidates = await getCandidates(ctx, profile);
  const orphaned = new Set(resolved.orphaned);
  const rules = profile.rules.map((r) => {
    const key = ruleKey(r);
    return {
      ...r,
      key,
      acts: r.status === 'confirmed' && RULE_KINDS[r.kind].walk,
      matches: Object.prototype.hasOwnProperty.call(resolved.matches, key) ? resolved.matches[key] : null,
      orphaned: orphaned.has(key),
    };
  });
  const byHeuristic = {};
  for (const id of Object.keys(HEURISTIC_KINDS)) {
    const list = candidates.filter((c) => c.heuristic === id);
    byHeuristic[id] = {
      kind: HEURISTIC_KINDS[id],
      open: list.filter((c) => c.status === 'open').length,
      confirmed: list.filter((c) => c.status === 'confirmed').length,
      rejected: list.filter((c) => c.status === 'rejected').length,
      candidates: list,
    };
  }
  return {
    solution: ctx.solution,
    file: path.join('solutions', ctx.solution, 'state', PROFILE_FILE),
    exists: fs.existsSync(file),
    updatedAt: profile.updated_at ?? null,
    hash: profileHash(profile),
    summary: {
      rules: rules.length,
      confirmed: rules.filter((r) => r.status === 'confirmed').length,
      rejected: rules.filter((r) => r.status === 'rejected').length,
      orphaned: orphaned.size,
    },
    rules,
    heuristics: byHeuristic,
  };
}

/** PUT: apply changes, write the file, return the new description. */
async function updateProfile(ctx, body) {
  const { error, value } = changeSchema.validate(body ?? {}, { abortEarly: false, stripUnknown: true });
  if (error) {
    throw createError('VALIDATION_ERROR', 'Invalid profile change', {
      errors: error.details.map((d) => ({ field: d.path.join('.'), message: d.message })),
    });
  }
  const file = profilePath(ctx);
  const profile = readProfileFile(file);
  const candidates = value.heuristic ? await getCandidates(ctx, profile) : [];
  const { profile: next, changed } = applyChanges(profile, value, candidates, new Date().toISOString());
  if (changed > 0) writeProfileFile(file, next);
  const described = await describeProfile(ctx);
  return { ...described, changed };
}

module.exports = {
  PROFILE_FILE,
  RULE_KINDS,
  HEURISTIC_KINDS,
  ruleKey,
  profileHash,
  readProfileFile,
  writeProfileFile,
  applyChanges,
  globToLike,
  changeSchema,
  loadProfile,
  resolveRules,
  getCandidates,
  describeProfile,
  updateProfile,
};
