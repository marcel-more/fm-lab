const fs = require('fs').promises;
const path = require('path');
const { LRUCache } = require('lru-cache');
const environment = require('../config/environment');
const { createError } = require('../middleware/error-handler');
const db = require('../config/database');
const dashboardService = require('./dashboard.service');
const dashboardI18nService = require('./dashboard-i18n.service');
const templateService = require('./template.service');
const resultsService = require('./results.service');
const {
  schemas: testsSchemas, TEST_TYPES, OUTPUT_TYPES, SCOPES, ID_PATTERN,
} = require('./tests-schemas');
const { SUPPORTED_LANGUAGE_CODES } = require('../config/languages');

/**
 * Analysis Tests Service
 *
 * A Test is a declared, executable collection of dashboards / custom queries
 * (templates/tests/<id>/test.json — system tier; templates/tests-custom/… —
 * user tier, custom-first override) with a compact result model: one named
 * default result per member, optionally enriched with the member's findings
 * rows (`include=findings`).
 *
 * Discovery / cache follow dashboard.service 1:1; consistency rules M1–M6
 * (+M5a/M5b) are checked at load time and reported as a `validation` block.
 * Scope normalisation (object / object-list / cluster → `file` + `scope_uuids`)
 * happens HERE at the run boundary — member SQLs only ever see the two params.
 */

// Custom first → overrides system tier on id collision.
const TESTS_DIRS = [
  { base: environment.templates.testsCustomDir, tier: 'custom' },
  { base: environment.templates.testsDir, tier: 'system' },
];

const MAX_FOLDER_DEPTH = 4;

// Guard for the run boundary: scope_uuids is interpolated as a literal —
// cap the list so the generated SQL text stays bounded (~190 KB at 5000).
const MAX_SCOPE_UUIDS = 5000;

// Findings mode defaults: severity-ordered, capped per member.
const DEFAULT_FINDINGS_LIMIT = 20;

// The canonical S-Block / file-filter markers for the textual M5 checks.
const RE_SCOPE_VAR = /getvariable\('scope_uuids'\)/g;
const RE_FILE_VAR = /getvariable\('file'\)/g;

const testCache = new LRUCache({
  max: 200,
  ttl: 1000 * 60 * 60, // 1h
  updateAgeOnGet: true,
});

// id → { id, dir, tier, folder, overridesSystem }
let discoveryPromise = null;

// folderPath → { mtime, title, icon, description, order, locales }
const folderMetaCache = new Map();

function clearCache() {
  testCache.clear();
  discoveryPromise = null;
  folderMetaCache.clear();
}

async function readJsonFile(filePath) {
  const raw = await fs.readFile(filePath, 'utf-8');
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`Invalid JSON in ${filePath}: ${err.message}`);
  }
}

async function tryStatMtime(filePath) {
  try {
    return (await fs.stat(filePath)).mtimeMs;
  } catch {
    return 0;
  }
}

/**
 * Recursive walk: collects test bundle dirs (= dirs containing test.json).
 * Folders without test.json are category folders (optional folder.json).
 */
async function walkTestsDir(base, relDir, depth, out) {
  const absDir = path.join(base, relDir);
  let entries;
  try {
    entries = await fs.readdir(absDir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return;
    throw err;
  }
  for (const e of entries) {
    if (!e.isDirectory() || e.name.startsWith('.')) continue;
    const childRel = relDir ? path.join(relDir, e.name) : e.name;
    const childAbs = path.join(base, childRel);
    let isTest = false;
    try {
      isTest = (await fs.stat(path.join(childAbs, 'test.json'))).isFile();
    } catch {
      // category folder or unrelated dir
    }
    if (isTest) {
      out.push({ id: e.name, dir: childAbs, folder: relDir || null });
    } else if (depth < MAX_FOLDER_DEPTH) {
      await walkTestsDir(base, childRel, depth + 1, out);
    }
  }
}

async function buildDiscovery() {
  const map = new Map();
  const systemIds = new Set();
  // Scan system tier first only to know which ids exist there (override flag);
  // precedence is still custom-first below.
  {
    const sys = [];
    await walkTestsDir(environment.templates.testsDir, '', 0, sys);
    for (const e of sys) systemIds.add(e.id);
  }
  for (const { base, tier } of TESTS_DIRS) {
    const found = [];
    await walkTestsDir(base, '', 0, found);
    for (const entry of found) {
      if (map.has(entry.id)) {
        if (tier === 'custom') {
          console.warn(`[tests:${entry.id}] duplicate test id at "${entry.dir}" — keeping first`);
        }
        continue; // custom tier scanned first → wins
      }
      map.set(entry.id, {
        ...entry,
        tier,
        overridesSystem: tier === 'custom' && systemIds.has(entry.id),
      });
    }
  }
  return map;
}

function getDiscovery() {
  if (!discoveryPromise) {
    discoveryPromise = buildDiscovery().catch(err => {
      discoveryPromise = null;
      throw err;
    });
  }
  return discoveryPromise;
}

// ---------------------------------------------------------------------------
// Consistency mapping M1–M6
// ---------------------------------------------------------------------------

function pushIssue(validation, severity, rule, message) {
  validation[severity === 'error' ? 'errors' : 'warnings'].push({ rule, message });
}

/**
 * Resolves a member to its metadata surface:
 *  - dashboard → { analysis, datasets, sqlByDataset (raw text) }
 *  - query     → { meta (incl. default_result/object_types/…), content }
 * Returns null when the ref does not resolve (M1).
 */
async function resolveMember(member) {
  if (member.kind === 'dashboard') {
    let bundle;
    try {
      bundle = await dashboardService.getBundle(member.ref);
    } catch {
      return null;
    }
    const sqlByDataset = {};
    for (const spec of bundle.manifest.datasets || []) {
      const m = /^bundle:(.+)$/.exec(String(spec.source));
      if (!m) continue;
      try {
        sqlByDataset[spec.id] = await fs.readFile(path.join(bundle.dir, path.normalize(m[1])), 'utf-8');
      } catch {
        sqlByDataset[spec.id] = null;
      }
    }
    return { kind: 'dashboard', bundle, analysis: bundle.manifest.analysis || null, sqlByDataset };
  }
  const source = await templateService.getTemplateSource(member.ref, 'query');
  if (!source) return null;
  return { kind: 'query', meta: source.metadata, content: source.content };
}

/**
 * M5/M5a/M5b — textual scope checks on one SQL text.
 * `anchor` is the declared anchor column (analysis.scope.anchor / nav_uuid).
 */
function checkScopeSql(sqlText, anchor, label, validation) {
  if (typeof sqlText !== 'string') return;
  const scopeCount = (sqlText.match(RE_SCOPE_VAR) || []).length;
  const fileCount = (sqlText.match(RE_FILE_VAR) || []).length;
  if (scopeCount === 0) {
    pushIssue(validation, 'warning', 'M5',
      `${label}: declared object scope but no S-Block (getvariable('scope_uuids')) in the SQL`);
    return;
  }
  // M5a — 1:1 coupling: every file filter must carry its S-Block twin
  // (catches the forgotten embedded core copy in summary.sql).
  if (fileCount !== scopeCount) {
    pushIssue(validation, 'warning', 'M5a',
      `${label}: ${fileCount}× file filter but ${scopeCount}× S-Block — copies out of sync`);
  }
  // M5b — anchor consistency: the S-Block must reference the declared anchor
  // column (…<anchor> IN (SELECT unnest(string_split(getvariable('scope_uuids')…).
  if (anchor) {
    const re = new RegExp(`[A-Za-z0-9_."]*${anchor}[A-Za-z0-9_"]*\\s+IN\\s*\\(\\s*SELECT\\s+unnest`, 'i');
    // Fallback: any *_UUID column in front of the IN(SELECT unnest…) pattern.
    const generic = /([A-Za-z_][\w."]*)\s+IN\s*\(\s*SELECT\s+unnest/i;
    const m = generic.exec(sqlText);
    if (m && anchor !== 'nav_uuid' && !re.test(sqlText)) {
      pushIssue(validation, 'warning', 'M5b',
        `${label}: S-Block anchors on "${m[1]}" but analysis.scope.anchor is "${anchor}"`);
    }
  }
}

/**
 * Validates a test definition against its members (M1–M6).
 * Returns { status: 'ok'|'warnings'|'errors', errors: [], warnings: [] }.
 */
async function validateTest(test) {
  const validation = { status: 'ok', errors: [], warnings: [] };
  const memberObjectTypeSets = [];
  let universalMembers = 0; // members without a declared type list
  const memberOutputTypes = new Set();

  for (let i = 0; i < test.members.length; i++) {
    const member = test.members[i];
    const label = `member[${i}] ${member.kind}:${member.ref}`;
    const resolved = await resolveMember(member);
    if (!resolved) {
      pushIssue(validation, 'error', 'M1', `${label}: reference does not resolve`);
      continue;
    }
    if (resolved.kind === 'dashboard') {
      const analysis = resolved.analysis;
      if (!analysis) {
        pushIssue(validation, 'error', 'M2', `${label}: manifest has no "analysis" block`);
        continue;
      }
      if (Array.isArray(analysis.objectTypes) && analysis.objectTypes.length) {
        memberObjectTypeSets.push(new Set(analysis.objectTypes));
      } else {
        universalMembers += 1;
      }
      for (const t of analysis.outputTypes || []) memberOutputTypes.add(t);
      // M6 — defaultResult.dataset must exist in the manifest's datasets
      const dr = analysis.defaultResult;
      if (dr && dr.dataset) {
        const ds = (resolved.bundle.manifest.datasets || []).find(d => d.id === dr.dataset);
        if (!ds) {
          pushIssue(validation, 'error', 'M6', `${label}: defaultResult.dataset "${dr.dataset}" not declared`);
        } else {
          // defaultResult datasets accept only native scope mode
          const mode = (analysis.scope && analysis.scope.mode && analysis.scope.mode[dr.dataset]) || 'native';
          if (mode !== 'native') {
            pushIssue(validation, 'warning', 'M5', `${label}: defaultResult dataset "${dr.dataset}" must be scope-mode "native"`);
          }
        }
      }
      // M5 family — only when the member declares object-like scope support
      const supported = (analysis.scope && analysis.scope.supported) || [];
      if (supported.some(s => s === 'object' || s === 'object-list' || s === 'cluster')) {
        const anchor = (analysis.scope && analysis.scope.anchor) || 'nav_uuid';
        const modeMap = (analysis.scope && analysis.scope.mode) || {};
        for (const [dsId, sqlText] of Object.entries(resolved.sqlByDataset)) {
          const mode = modeMap[dsId] || 'native';
          if (mode === 'native') {
            checkScopeSql(sqlText, anchor, `${label}/${dsId}`, validation);
          } else if (mode === 'post-filter') {
            if (typeof sqlText === 'string' && !/\bAS\s+nav_uuid\b/i.test(sqlText)) {
              pushIssue(validation, 'warning', 'M5', `${label}/${dsId}: post-filter mode but no "AS nav_uuid" column in SELECT`);
            }
          }
          // 'static': declared scope-independent (no catalog evidence rows,
          // e.g. a select-options list from a reference DB) — no scope checks.
        }
      }
    } else {
      const meta = resolved.meta;
      if (!meta.default_result) {
        pushIssue(validation, 'error', 'M2', `${label}: SQL frontmatter has no @default_result`);
        continue;
      }
      if (Array.isArray(meta.object_types) && meta.object_types.length) {
        memberObjectTypeSets.push(new Set(meta.object_types));
      } else {
        universalMembers += 1;
      }
      for (const t of meta.output_types || []) memberOutputTypes.add(t);
      const scopes = meta.scope || [];
      if (scopes.some(s => s === 'object' || s === 'object-list' || s === 'cluster')) {
        checkScopeSql(resolved.content, 'nav_uuid', label, validation);
      }
    }
  }

  // M3 — test.objectTypes ⊆ ∪ member.objectTypes: every declared type needs at
  // least ONE member that supports it. The intersection is deliberately NOT
  // required — a test may bundle members with disjoint type sets (a marker
  // family across scripts, layouts and calculations); in object scope the
  // runner skips the members that do not declare the object's type
  // (memberObjectTypeSkip, skipReason 'object-type'). Members without a
  // declared list are universal: they support every type.
  if (test.objectTypes.length && memberObjectTypeSets.length && universalMembers === 0) {
    for (const t of test.objectTypes) {
      const inAny = memberObjectTypeSets.some(s => s.has(t));
      if (!inAny) {
        pushIssue(validation, 'error', 'M3',
          `test.objectTypes contains "${t}" but no member supports it`);
      }
    }
  }
  // M4 — test.outputs ⊆ ∪ member.outputTypes
  for (const o of test.outputs || []) {
    if (memberOutputTypes.size && !memberOutputTypes.has(o)) {
      pushIssue(validation, 'warning', 'M4', `test.outputs contains "${o}" but no member declares it`);
    }
  }
  // M7 — profiles narrow, never extend: every profile member ref must exist
  // in members[], profile ids must be unique.
  const memberRefs = new Set(test.members.map(m => m.ref));
  const seenProfileIds = new Set();
  for (const profile of test.profiles || []) {
    if (seenProfileIds.has(profile.id)) {
      pushIssue(validation, 'error', 'M7', `duplicate profile id "${profile.id}"`);
    }
    seenProfileIds.add(profile.id);
    for (const ref of profile.members || []) {
      if (!memberRefs.has(ref)) {
        pushIssue(validation, 'error', 'M7',
          `profile "${profile.id}" references unknown member "${ref}"`);
      }
    }
  }

  // M8 — locale overrides must address something that exists. An override the
  // resolver silently drops is worse than a missing one: the English original
  // renders and nothing anywhere says the translation never arrived.
  for (const [lang, overrides] of Object.entries(test.locales || {})) {
    if (!SUPPORTED_LANGUAGE_CODES.includes(lang)) {
      pushIssue(validation, 'warning', 'M8', `locales: unsupported language "${lang}"`);
    }
    for (const key of Object.keys(overrides || {})) {
      const target = parseLocaleKey(key);
      if (!target) {
        pushIssue(validation, 'warning', 'M8', `locales.${lang}: unknown override path "${key}"`);
      } else if (target.profileId && !seenProfileIds.has(target.profileId)) {
        pushIssue(validation, 'warning', 'M8',
          `locales.${lang}: override "${key}" targets unknown profile "${target.profileId}"`);
      }
    }
  }

  validation.status = validation.errors.length ? 'errors'
    : validation.warnings.length ? 'warnings' : 'ok';
  return validation;
}

// ---------------------------------------------------------------------------
// Loading & listing
// ---------------------------------------------------------------------------

async function loadTest(id) {
  const map = await getDiscovery();
  const entry = map.get(id);
  if (!entry) return null;
  const defPath = path.join(entry.dir, 'test.json');
  const mtime = await tryStatMtime(defPath);

  if (environment.templates.cacheEnabled) {
    const cached = testCache.get(id);
    if (cached && cached.mtime === mtime) return cached;
  }

  try {
    const raw = await readJsonFile(defPath);
    const { error, value: definition } = testsSchemas.testDefinition.validate(raw, {
      abortEarly: false,
      stripUnknown: false,
      convert: true,
    });
    if (error) {
      console.warn(`[tests:${id}] test.json invalid: ${error.message}`);
      return null;
    }
    if (definition.id !== id) {
      console.warn(`[tests:${id}] test.json id="${definition.id}" differs from directory name`);
      return null;
    }
    const validation = await validateTest(definition);
    const test = {
      id,
      dir: entry.dir,
      folder: entry.folder,
      tier: entry.tier,
      overridesSystem: entry.overridesSystem,
      definition,
      validation,
      mtime,
    };
    if (environment.templates.cacheEnabled) testCache.set(id, test);
    return test;
  } catch (err) {
    console.warn(`[tests:${id}] failed to load: ${err.message}`);
    return null;
  }
}

async function listTests() {
  const map = await getDiscovery();
  const tests = await Promise.all([...map.keys()].map(loadTest));
  return tests.filter(t => t !== null);
}

/**
 * Fetch a test by id. Throws TEMPLATE_NOT_FOUND when absent/invalid.
 */
async function getTest(id) {
  if (!ID_PATTERN.test(id)) {
    throw createError('VALIDATION_ERROR', `Invalid test id: ${id}`);
  }
  const test = await loadTest(id);
  if (!test) {
    throw createError('TEMPLATE_NOT_FOUND', `Test '${id}' not found or invalid`, { testId: id });
  }
  return test;
}

/**
 * Localised copy of a member's `analysis` block — only the one display string
 * it carries (`defaultResult.meaning`) is language-dependent; datasets, scope
 * declarations and the result NAME are machine keys and stay canonical.
 *
 * Copy-on-write: without a locale file `resolveBundleForLanguage` hands back
 * the shared cached manifest, so writing into it would poison the cache for
 * every other language.
 */
function localizeAnalysis(analysis, localizedTitle, lang) {
  const defaultResult = analysis && analysis.defaultResult;
  if (!defaultResult || !defaultResult.meaning) return analysis || null;
  const meaning = dashboardI18nService.deriveFindingsMeaning(
    defaultResult.meaning, localizedTitle, lang,
  );
  if (meaning === defaultResult.meaning) return analysis;
  return { ...analysis, defaultResult: { ...defaultResult, meaning } };
}

/**
 * Resolves one member against its source of truth (dashboard bundle manifest
 * resp. SQL-template frontmatter): title, icon, severity and the analysis
 * block. `resolved: false` marks a member whose ref points nowhere — the same
 * condition validation rule M2 reports; callers keep such members visible
 * instead of dropping them.
 *
 * Single source for every read path: the REST detail response
 * (`GET /api/tests/:id`) and the `test_detail`/`test_members` builtin datasets
 * of the detail view both call this — no second resolution logic.
 *
 * `lang` resolves the member bundle's own translations (`locales/<lang>.json`)
 * — they already ship with every rule bundle, the tests layer just never read
 * them. CAUTION at the call sites: never pass this as a bare `.map()` callback,
 * Array.map would hand the element INDEX in as the language.
 *
 * Query members carry no locale layer (SQL frontmatter has none) — they stay
 * English by construction; the shipped test sets currently declare none.
 */
async function resolveMemberSummary(member, lang) {
  if (member.kind === 'dashboard') {
    try {
      const bundle = await dashboardService.getBundle(member.ref);
      const { manifest } = await dashboardI18nService.resolveBundleForLanguage(bundle, lang);
      return {
        ...member,
        title: manifest.title,
        icon: manifest.icon || null,
        severity: (manifest.rule && manifest.rule.severity) || null,
        analysis: localizeAnalysis(manifest.analysis, manifest.title, lang),
        folder: bundle.folder || null,
        resolved: true,
      };
    } catch {
      return { ...member, resolved: false };
    }
  }
  const meta = await templateService.getTemplateMeta(member.ref, 'query');
  if (!meta) return { ...member, resolved: false };
  return {
    ...member,
    title: meta.title || member.ref,
    icon: meta.icon || null,
    severity: null,
    analysis: {
      objectTypes: meta.object_types || [],
      outputTypes: meta.output_types || [],
      scope: { supported: meta.scope || [] },
      defaultResult: meta.default_result || null,
    },
    category: meta.category || null,
    resolved: true,
  };
}

/**
 * List filters: objectType, testType, scope, keyword, q (title+keywords
 * text search), folder. All AND-combined.
 */
function filterTests(tests, filters = {}) {
  let out = tests;
  if (filters.objectType) {
    out = out.filter(t => {
      const types = t.definition.objectTypes || [];
      return types.length === 0 || types.includes(filters.objectType);
    });
  }
  if (filters.testType) {
    out = out.filter(t => t.definition.testType === filters.testType);
  }
  if (filters.scope) {
    out = out.filter(t => (t.definition.scopes || []).includes(filters.scope));
  }
  if (filters.keyword) {
    const kw = String(filters.keyword).toLowerCase();
    out = out.filter(t => (t.definition.keywords || []).some(k => k.toLowerCase() === kw));
  }
  if (filters.q) {
    const q = String(filters.q).toLowerCase();
    out = out.filter(t =>
      t.definition.title.toLowerCase().includes(q)
      || (t.definition.description || '').toLowerCase().includes(q)
      || (t.definition.keywords || []).some(k => k.toLowerCase().includes(q)));
  }
  if (filters.folder) {
    out = out.filter(t => (t.folder || '') === filters.folder || (t.folder || '').startsWith(`${filters.folder}/`));
  }
  return out;
}

// Optional folder.json display metadata (same layered fallback as dashboards).
async function loadFolderMeta(folderPath) {
  for (const { base } of TESTS_DIRS) {
    const fp = path.join(base, folderPath, 'folder.json');
    const mtime = await tryStatMtime(fp);
    if (!mtime) continue;
    const cached = folderMetaCache.get(folderPath);
    if (cached && cached.mtime === mtime) return cached;
    let raw = null;
    try { raw = await readJsonFile(fp); } catch { raw = null; }
    const { value } = testsSchemas.testFolder.validate(raw || {}, { convert: true });
    const meta = { mtime, ...(value || {}) };
    folderMetaCache.set(folderPath, meta);
    return meta;
  }
  return null;
}

function humanizeFolderSegment(seg) {
  return seg.replace(/[-_]/g, ' ').replace(/\b\w/g, ch => ch.toUpperCase());
}

// Splits a folder path into localized crumbs: "a/b" → [{path:"a",label},
// {path:"a/b",label}]. Each crumb carries its PARTIAL path so the breadcrumb of
// a single test can link back into the overview (`/tests?folder=<partial>`),
// segment by segment. Same cascade as the dashboard side:
// folder.json locales[lang] → title → humanized segment.
async function resolveFolderCrumbs(folderPath, lang) {
  if (!folderPath) return [];
  const crumbs = [];
  let prefix = '';
  for (const seg of String(folderPath).split('/')) {
    prefix = prefix ? `${prefix}/${seg}` : seg;
    const meta = await loadFolderMeta(prefix);
    const label = (lang && meta?.locales && meta.locales[lang]) || meta?.title || humanizeFolderSegment(seg);
    crumbs.push({ path: prefix, label });
  }
  return crumbs;
}

// Joined display name of a folder path ("a/b" → "A-Label / B-Label").
// Deliberately routed through resolveFolderCrumbs so there is exactly ONE
// label cascade — crumbs and joined label cannot drift apart.
async function resolveFolderLabel(folderPath, lang) {
  if (!folderPath) return null;
  return (await resolveFolderCrumbs(folderPath, lang)).map(c => c.label).join(' / ');
}

// ---------------------------------------------------------------------------
// Display-text localisation (test.json `locales`)
//
// Resolution happens at the READ EDGE, never at load time: `loadTest` caches
// per id (not per language), and the run layer's result envelopes are cached
// language-blind by design. So every consumer that renders a test's texts
// calls `localizeTest` itself — the cached English original stays the one
// canonical object.
// ---------------------------------------------------------------------------

/** `title` | `description` | `profiles.<id>.<title|description>` → target, or null. */
function parseLocaleKey(key) {
  if (key === 'title' || key === 'description') return { field: key, profileId: null };
  const m = /^profiles\.([a-zA-Z0-9_-]+)\.(title|description)$/.exec(key);
  return m ? { field: m[2], profileId: m[1] } : null;
}

/**
 * Returns the test with its display texts (title, description and the same two
 * per profile) replaced by the translations declared for `lang`. English, a
 * missing language block and an empty override string all keep the original —
 * a partly translated test renders the rest in English rather than blanking.
 *
 * The input object is never mutated: only the touched levels are copied, so
 * the shared cache entry stays pristine for the next reader.
 */
function localizeTest(test, lang) {
  const overrides = test?.definition?.locales?.[lang];
  if (!lang || lang === 'en' || !overrides) return test;

  const definition = { ...test.definition };
  let profiles = null; // copied lazily — most tests declare none
  for (const [key, value] of Object.entries(overrides)) {
    if (typeof value !== 'string' || value === '') continue;
    const target = parseLocaleKey(key);
    if (!target) continue;
    if (!target.profileId) {
      definition[target.field] = value;
      continue;
    }
    if (!profiles) profiles = (definition.profiles || []).map(p => ({ ...p }));
    const profile = profiles.find(p => p.id === target.profileId);
    if (profile) profile[target.field] = value;
  }
  if (profiles) definition.profiles = profiles;
  return { ...test, definition };
}

// ---------------------------------------------------------------------------
// Scope normalisation — logical scope → { file, scope_uuids }
// ---------------------------------------------------------------------------

/**
 * Expands a cluster reference (numeric community id or a name matched against
 * Semantic_Name/Heuristic_Name) into member UUIDs. Soft requirements: cluster
 * tables must exist (else a clear error pointing to fm-graph-cluster).
 */
async function expandCluster(ctx, clusterRef) {
  let present = false;
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT COUNT(*) AS cnt FROM information_schema.tables
        WHERE table_name IN ('ObjectClusters', 'CommunityNames')`,
    );
    present = Number(r.rows[0]?.cnt) === 2;
  } catch {
    present = false;
  }
  if (!present) {
    throw createError('VALIDATION_ERROR',
      'Cluster scope requires a clustered catalog — run fm-graph-cluster first '
      + '(note: convert-xml --force-rebuild wipes the cluster layer)');
  }
  const engineRow = await db.executeQuery(
    ctx,
    `SELECT Engine FROM ObjectClusters WHERE Engine IS NOT NULL
      GROUP BY Engine ORDER BY COUNT(*) DESC LIMIT 1`,
  );
  const engine = engineRow.rows[0]?.Engine;
  if (!engine) {
    throw createError('VALIDATION_ERROR', 'Cluster scope: no cluster partition found');
  }
  const refStr = String(clusterRef).trim();
  let communityId = null;
  if (/^\d+$/.test(refStr)) {
    communityId = Number(refStr);
  } else {
    const esc = refStr.replace(/'/g, "''");
    const byName = await db.executeQuery(
      ctx,
      `SELECT Community FROM CommunityNames
        WHERE Engine = '${engine.replace(/'/g, "''")}'
          AND (lower(Semantic_Name) = lower('${esc}') OR lower(Heuristic_Name) = lower('${esc}'))
        LIMIT 2`,
    );
    if (byName.rows.length === 0) {
      throw createError('TEMPLATE_NOT_FOUND', `Cluster '${clusterRef}' not found`);
    }
    if (byName.rows.length > 1) {
      throw createError('VALIDATION_ERROR', `Cluster name '${clusterRef}' is ambiguous — use the community id`);
    }
    communityId = Number(byName.rows[0].Community);
  }
  const members = await db.executeQuery(
    ctx,
    `SELECT Object_UUID FROM ObjectClusters
      WHERE Engine = '${engine.replace(/'/g, "''")}' AND Community = ${communityId}`,
  );
  const uuids = members.rows.map(r => r.Object_UUID).filter(Boolean);
  if (uuids.length === 0) {
    throw createError('TEMPLATE_NOT_FOUND', `Cluster '${clusterRef}' has no members`);
  }
  return { uuids, communityId, engine };
}

/**
 * Normalises the request context into the two SQL params + a context echo.
 * Accepted inputs: uuid (single object), uuids (CSV list), file, cluster.
 */
async function normalizeScope(ctx, query = {}) {
  const context = {};
  const params = {};
  const uuid = query.uuid ? String(query.uuid) : null;
  const uuidsCsv = query.uuids ? String(query.uuids) : null;
  const file = query.file ? String(query.file) : null;
  const cluster = query.cluster != null && query.cluster !== '' ? String(query.cluster) : null;

  if (cluster) {
    const { uuids, communityId } = await expandCluster(ctx, cluster);
    if (uuids.length > MAX_SCOPE_UUIDS) {
      throw createError('VALIDATION_ERROR',
        `Scope too large (${uuids.length} objects, cap ${MAX_SCOPE_UUIDS}) — use file or solution scope`);
    }
    params.scope_uuids = uuids.join(',');
    context.scope = 'cluster';
    context.cluster = cluster;
    context.community = communityId;
  } else if (uuidsCsv) {
    const list = uuidsCsv.split(',').map(s => s.trim()).filter(Boolean);
    if (list.length > MAX_SCOPE_UUIDS) {
      throw createError('VALIDATION_ERROR',
        `Scope too large (${list.length} objects, cap ${MAX_SCOPE_UUIDS}) — use file or solution scope`);
    }
    params.scope_uuids = list.join(',');
    context.scope = 'object-list';
    // Only forward `file` when the whole list is from one file (clone guard).
    if (file) params.file = file;
  } else if (uuid) {
    params.scope_uuids = uuid;
    // Identity is (UUID, File_Name) — file qualifies clones.
    if (file) params.file = file;
    context.scope = 'object';
    context.uuid = uuid;
  } else if (file) {
    params.file = file;
    context.scope = 'file';
  } else {
    context.scope = 'solution';
  }
  if (file) context.file = file;
  if (query.object_type) {
    context.object_type = String(query.object_type);
  } else if (context.scope === 'object' && ctx) {
    // Object scope without a declared type: resolve it from the catalog so the
    // object-type skip (runMember) works for every client, not only the tab.
    const resolved = await lookupObjectType(ctx, uuid, file);
    if (resolved) context.object_type = resolved;
  }
  return { context, params };
}

// ---------------------------------------------------------------------------
// Run engine
// ---------------------------------------------------------------------------

function applyParamMap(member, params) {
  if (!member.paramMap) return { ...params };
  const out = { ...params };
  for (const [from, to] of Object.entries(member.paramMap)) {
    if (from in out && to !== from) {
      out[to] = out[from];
      delete out[from];
    }
  }
  return out;
}

function buildOpenTarget(member, params) {
  const search = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || k.startsWith('_')) continue;
    search.set(k, String(v));
  }
  const qs = search.toString();
  const base = member.kind === 'dashboard' ? `/dashboard/${member.ref}` : `/query/${member.ref}`;
  return qs ? `${base}?${qs}` : base;
}

/**
 * Row-click action of the bundle's findings table: the `onRowClick` spec of
 * the Table component whose enclosing data binding is the `findings` dataset
 * (the same dataset-id convention the findings fetch in results.service uses).
 * The tests tab replays this spec per finding row so a finding click jumps
 * straight to the object deep link the dashboard row click would produce.
 * Null when the bundle declares none (query members, aggregate-only tables).
 */
function findingsRowAction(layout) {
  if (!layout || typeof layout !== 'object') return null;
  let found = null;
  const walk = (node, dataset) => {
    if (found || !node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const child of node) walk(child, dataset);
      return;
    }
    const bound = node.data && node.data.dataset ? node.data.dataset : dataset;
    if (node.type === 'Table' && bound === 'findings' && node.props && node.props.onRowClick) {
      found = node.props.onRowClick;
      return;
    }
    if (node.children) walk(node.children, bound);
  };
  walk(layout.root, null);
  return found;
}

// Two-axis derivation and the catalog fingerprint moved to results.service
// (Result Envelope v1) — re-exported below so existing consumers keep working.
const { deriveResultState, catalogMeta } = resultsService;

/**
 * Object-scope applicability of one member — the runtime half of the M3
 * union rule. A member that declares object types (`analysis.objectTypes`
 * resp. `@object_types`) is not applicable to an object of another type: its
 * SQL would run against that UUID and return a meaningless 0, which the tab
 * renders as "passed". Returns null when the member applies or the object's
 * type is unknown, otherwise the skip payload. Members without a declared
 * list are universal.
 */
function memberObjectTypeSkip(declaredTypes, objectType) {
  if (!objectType) return null;
  const types = Array.isArray(declaredTypes) ? declaredTypes.filter(Boolean) : [];
  if (types.length === 0 || types.includes(objectType)) return null;
  return {
    skipReason: 'object-type',
    skipMessage: `Not applicable to a ${objectType} — this member checks ${types.join(', ')} objects.`,
  };
}

/** Declared object types of a member (manifest / SQL frontmatter); [] = universal. */
async function resolveMemberObjectTypes(member, bundle) {
  try {
    if (member.kind === 'dashboard') {
      const b = bundle || await dashboardService.getBundle(member.ref);
      return (b.manifest.analysis && b.manifest.analysis.objectTypes) || [];
    }
    const meta = await templateService.getTemplateMeta(member.ref, 'query');
    return (meta && meta.object_types) || [];
  } catch {
    return [];
  }
}

/**
 * Catalog type of one object. The tests tab sends `object_type` along with
 * the UUID; the skill/CLI path sends only the UUID — resolve it so the
 * object-type skip works for every client. Best effort: an unknown UUID (or
 * a catalog without the row) yields null → no member is skipped.
 */
async function lookupObjectType(ctx, uuid, file) {
  const esc = s => String(s).replace(/'/g, "''");
  const fileFilter = file ? ` AND File_Name = '${esc(file)}'` : '';
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT Object_Type FROM ObjectCatalog WHERE Object_UUID = '${esc(uuid)}'${fileFilter} LIMIT 1`,
    );
    const row = r && r.rows && r.rows[0];
    return row && row.Object_Type ? String(row.Object_Type) : null;
  } catch {
    return null;
  }
}

/** Best-effort member title for run/skipped rows (bundle caches make this cheap). */
async function resolveMemberTitle(member) {
  try {
    if (member.kind === 'dashboard') {
      const bundle = await dashboardService.getBundle(member.ref);
      return bundle.manifest.title || member.ref;
    }
    const meta = await templateService.getTemplateMeta(member.ref, 'query');
    return (meta && meta.title) || member.ref;
  } catch {
    return member.ref;
  }
}

/**
 * Executes ONE member: default result + (optionally) findings rows.
 * Delegates to the shared runner (results.service.runOne — one execution
 * logic for tests, dashboard chips and the results API) and maps the Result
 * Envelope back onto the legacy member-result shape the tests tab consumes.
 * Member errors never abort the test run → status 'error' per member.
 */
async function runMember(ctx, member, scopeParams, options) {
  const params = applyParamMap(member, scopeParams);
  const base = {
    kind: member.kind,
    ref: member.ref,
    openTarget: buildOpenTarget(member, params),
  };
  // Members can declare reference requirements (manifest analysis.requires).
  // A missing plugin-spec DB is an install-state, not an error: skip with an
  // explanatory reason instead of failing the member (pattern: DDR-Info).
  let bundle = null;
  if (member.kind === 'dashboard') {
    try {
      bundle = await dashboardService.getBundle(member.ref);
      const requires = (bundle.manifest.analysis && bundle.manifest.analysis.requires) || [];
      if (requires.includes('plugin-spec') && !db.isPluginSpecAttached()) {
        return {
          ...base,
          title: bundle.manifest.title || member.ref,
          status: 'skipped',
          runStatus: 'skipped',
          skipReason: 'missing-plugin-spec',
          skipMessage: 'Plugin platform map not available — reference/plugin_spec.duckdb is missing. It ships with every fm-lab release; restore the file from the release checkout.',
          resultState: 'skipped',
        };
      }
      // OS-affinity members need fm_spec >= 1.13.0 (step_os_affinity /
      // function_os_affinity / runtime_os_matrix). An older reference DB is a
      // version state, not an error: skip with reason (pattern: plugin-spec).
      if (requires.includes('fm-spec-os') && !db.hasOsAffinityTables()) {
        return {
          ...base,
          title: bundle.manifest.title || member.ref,
          status: 'skipped',
          runStatus: 'skipped',
          skipReason: 'missing-fm-spec-os',
          skipMessage: 'Reference database predates schema 1.13.0 — re-run tools/fm-reference/pull-reference.sh to deploy the OS affinity tables.',
          resultState: 'skipped',
        };
      }
    } catch { /* bundle resolution problems surface in runOne below */ }
  }
  // Object scope: a member declaring other object types than the target's is
  // not applicable — skip it (reason 'object-type') instead of reporting a
  // meaningless 0. The M3 union rule admits such members on purpose (a test
  // may span scripts, layouts and calculations); this is its runtime half and
  // applies to single-member runs as well.
  if (options.objectType) {
    const skip = memberObjectTypeSkip(await resolveMemberObjectTypes(member, bundle), options.objectType);
    if (skip) {
      return {
        ...base,
        title: (bundle && bundle.manifest.title) || await resolveMemberTitle(member),
        status: 'skipped',
        runStatus: 'skipped',
        ...skip,
        resultState: 'skipped',
      };
    }
  }
  const envelope = await resultsService.runOne(ctx, { kind: member.kind, id: member.ref }, {
    params,
    includeFindings: options.includeFindings,
    findingsLimit: options.findingsLimit || DEFAULT_FINDINGS_LIMIT,
    // Solution-scope runs feed the shared server cache (a test run pre-warms
    // the dashboard chips); scoped values must never warm the global chips.
    cacheable: options.cacheable === true,
  });
  if (envelope.runStatus === 'failed') {
    return {
      ...base,
      title: envelope.title || member.ref,
      status: 'error',
      runStatus: 'failed',
      error: envelope.error,
    };
  }
  const memberResult = {
    ...base,
    title: envelope.title || member.ref,
    status: 'ok',
    runStatus: 'ran',
    severity: envelope.severity ?? null,
    defaultResult: {
      type: envelope.type || 'number',
      name: envelope.name || member.ref,
      meaning: envelope.meaning || null,
      value: envelope.value,
    },
  };
  if (envelope.findings) {
    memberResult.findings = envelope.findings;
    const rowAction = findingsRowAction(bundle && bundle.layout);
    if (rowAction) memberResult.rowAction = rowAction;
  }
  memberResult.resultState = envelope.resultState;
  return memberResult;
}

/**
 * Runs a test (all members or one memberIndex). `query` carries the raw HTTP
 * params (uuid/uuids/file/cluster/object_type + include/findingsLimit).
 */
async function runTest(ctx, test, query = {}, memberIndex = null) {
  if (test.validation.status === 'errors') {
    throw createError('VALIDATION_ERROR',
      `Test '${test.id}' has consistency errors and cannot run`, { validation: test.validation });
  }
  const started = Date.now();
  const { context, params } = await normalizeScope(ctx, query);
  // Requested scope must be declared by the test.
  if (!(test.definition.scopes || []).includes(context.scope)) {
    throw createError('VALIDATION_ERROR',
      `Test '${test.id}' does not support scope '${context.scope}' (supported: ${(test.definition.scopes || []).join(', ')})`);
  }
  const options = {
    includeFindings: String(query.include || '') === 'findings',
    findingsLimit: Math.max(1, Math.min(500, Number(query.findingsLimit) || DEFAULT_FINDINGS_LIMIT)),
    // Only unscoped (solution) runs represent the same truth as the dashboard
    // overview chips — those write through into the shared results cache.
    cacheable: context.scope === 'solution',
    // Object scope only: drives the per-member object-type skip (runMember).
    objectType: context.scope === 'object' ? (context.object_type || null) : null,
  };
  // Optional bundle profile narrows the member set. Unknown ids are a
  // hard error, never a silent fallback to "all". Members outside the profile
  // are reported as skipped (index alignment with the definition preserved).
  // Single-member runs (memberIndex) are an explicit choice — profile ignored.
  const profileId = query.profile != null && query.profile !== '' ? String(query.profile) : null;
  let activeRefs = null;
  if (profileId) {
    const profile = (test.definition.profiles || []).find(p => p.id === profileId);
    if (!profile) {
      throw createError('VALIDATION_ERROR',
        `Test '${test.id}' has no profile '${profileId}' (available: ${(test.definition.profiles || []).map(p => p.id).join(', ') || 'none'})`);
    }
    if (profile.members) activeRefs = new Set(profile.members);
    context.profile = profileId;
  }
  let results;
  if (memberIndex !== null) {
    const members = test.definition.members;
    const idx = Number(memberIndex);
    if (!Number.isInteger(idx) || idx < 0 || idx >= members.length) {
      throw createError('VALIDATION_ERROR', `memberIndex ${memberIndex} out of range`);
    }
    results = [await runMember(ctx, members[idx], params, options)];
  } else {
    results = await Promise.all(test.definition.members.map(async m => {
      if (activeRefs && !activeRefs.has(m.ref)) {
        return {
          kind: m.kind,
          ref: m.ref,
          title: await resolveMemberTitle(m),
          status: 'skipped',
          runStatus: 'skipped',
          skipReason: 'profile',
          resultState: 'skipped',
          openTarget: buildOpenTarget(m, applyParamMap(m, params)),
        };
      }
      return runMember(ctx, m, params, options);
    }));
  }
  // Per-test aggregation; one truth for tab badges, /tests page & skill.
  const summary = { error: 0, warning: 0, neutral: 0, ok: 0, skipped: 0, failed: 0 };
  for (const r of results) {
    if (r.runStatus === 'failed') summary.failed += 1;
    else if (r.runStatus === 'skipped') summary.skipped += 1;
    else if (r.resultState && summary[r.resultState] !== undefined) summary[r.resultState] += 1;
  }
  // Test-level envelope (read-only registry entry, O6): a full solution-scope
  // run also records the test's own aggregate state in the results cache.
  if (options.cacheable && memberIndex === null && !activeRefs) {
    const worst = ['error', 'warning', 'neutral', 'ok'].find(k => summary[k] > 0) || 'ok';
    resultsService.putEnvelope(ctx, {
      ref: { kind: 'test', id: test.id },
      rubric: test.folder || null,
      title: test.definition.title,
      runStatus: summary.failed > 0 && summary.failed === results.length ? 'failed' : 'ran',
      resultState: summary.failed > 0 && summary.failed === results.length ? null : worst,
      value: null,
      type: null,
      unit: null,
      name: 'test_summary',
      meaning: null,
      severity: null,
      source: 'test',
      fingerprint: catalogMeta(ctx).catalogFingerprint,
      at: Date.now(),
      durationMs: Date.now() - started,
    });
  }
  return {
    test: {
      id: test.id,
      title: test.definition.title,
      testType: test.definition.testType,
    },
    context,
    results,
    summary,
    meta: { durationMs: Date.now() - started, ...catalogMeta(ctx) },
  };
}

/**
 * Localises the display strings of a finished run: the test's own title, each
 * member's title and its result description.
 *
 * Applied AFTER `runTest` on purpose. The run writes result envelopes into the
 * server cache, and that cache is keyed by ref only — no language. Localising
 * inside the runner would let whichever language happened to run first decide
 * what every later reader sees; adding a language to the key would multiply it
 * by eleven and destroy the sharing that lets a test run pre-warm the
 * dashboard chips. So the cache keeps the canonical English strings and the
 * translation happens on the way out.
 */
async function localizeRunResult(result, test, lang) {
  if (!lang || lang === 'en' || !result) return result;
  const localized = localizeTest(test, lang);
  const summaries = await Promise.all(
    (test.definition.members || []).map(m => resolveMemberSummary(m, lang)),
  );
  const byRef = new Map(summaries.filter(s => s.resolved).map(s => [s.ref, s]));
  return {
    ...result,
    test: { ...result.test, title: localized.definition.title },
    results: (result.results || []).map(row => {
      const summary = byRef.get(row.ref);
      if (!summary) return row;
      const out = { ...row, title: summary.title || row.title };
      const meaning = summary.analysis
        && summary.analysis.defaultResult
        && summary.analysis.defaultResult.meaning;
      if (row.defaultResult && meaning) {
        out.defaultResult = { ...row.defaultResult, meaning };
      }
      return out;
    }),
  };
}

/**
 * Section ordering: the top-level folder.json `order` decides where a
 * section sorts; missing order sorts last.
 */
async function resolveFolderOrder(folderPath) {
  if (!folderPath) return Number.MAX_SAFE_INTEGER;
  const top = String(folderPath).split('/')[0];
  const meta = await loadFolderMeta(top);
  return meta && Number.isFinite(meta.order) ? meta.order : Number.MAX_SAFE_INTEGER;
}

module.exports = {
  TESTS_DIRS,
  TEST_TYPES,
  OUTPUT_TYPES,
  SCOPES,
  MAX_SCOPE_UUIDS,
  listTests,
  filterTests,
  getTest,
  resolveMemberSummary,
  runTest,
  resolveFolderLabel,
  resolveFolderCrumbs,
  resolveFolderOrder,
  loadFolderMeta,
  localizeTest,
  localizeRunResult,
  catalogMeta,
  clearCache,
  // exported for tests
  normalizeScope,
  validateTest,
  memberObjectTypeSkip,
  findingsRowAction,
  deriveResultState,
};
