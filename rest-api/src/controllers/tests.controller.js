const testsService = require('../services/tests.service');
const environment = require('../config/environment');
const { SUPPORTED_LANGUAGE_CODES, DEFAULT_LANGUAGE, resolveLanguage } = require('../config/languages');

/**
 * Analysis Tests Controller
 *
 *   GET /api/tests                       List (filters: objectType, testType, scope, keyword, q, folder, lang)
 *   GET /api/tests/:id                   Definition + resolved members + validation report
 *   GET /api/tests/:id/run               Run all default results (scope params like dashboard params)
 *   GET /api/tests/:id/run/:memberIndex  Run a single member (incremental tab loading)
 */

function pickLang(query) {
  const raw = query && typeof query.lang === 'string' ? query.lang : null;
  if (!raw) {
    return resolveLanguage(environment.reference.defaultLang) || DEFAULT_LANGUAGE;
  }
  if (!SUPPORTED_LANGUAGE_CODES.includes(raw)) {
    return resolveLanguage(raw);
  }
  return raw;
}

/**
 * Projection of a test for the list/detail responses. Expects the test ALREADY
 * localised (`testsService.localizeTest`) — resolution happens at the read
 * edge because the loader caches per id, not per language.
 */
function toListRow(test) {
  return {
    id: test.id,
    title: test.definition.title,
    description: test.definition.description || null,
    testType: test.definition.testType,
    keywords: test.definition.keywords || [],
    objectTypes: test.definition.objectTypes || [],
    scopes: test.definition.scopes || [],
    outputs: test.definition.outputs || [],
    memberCount: (test.definition.members || []).length,
    // Shipped profiles (member subsets); memberCount echoes the subset
    // size so the UI can label "Quick (3/12)" without resolving members.
    // `members` carries the actual refs (null = all members, i.e. the declared
    // full check) — without it neither the detail view nor the skill can say
    // WHICH rules a profile covers.
    profiles: (test.definition.profiles || []).map(p => ({
      id: p.id,
      title: p.title,
      description: p.description || null,
      memberCount: p.members ? p.members.length : (test.definition.members || []).length,
      members: p.members ? [...p.members] : null,
    })),
    folder: test.folder || null,
    area: test.area,
    tier: test.tier,
    overrides: test.overrides === true,
    overridesSystem: test.overridesSystem === true,
    version: test.definition.version || null,
    validation: {
      status: test.validation.status,
      errors: test.validation.errors,
      warnings: test.validation.warnings,
    },
  };
}

async function listTests(req, res, next) {
  try {
    const lang = pickLang(req.query);
    // Localise BEFORE filtering: the `q` text search must match the titles and
    // descriptions the caller actually sees, not their English originals.
    const all = (await testsService.listTests()).map(t => testsService.localizeTest(t, lang));
    const filtered = testsService.filterTests(all, {
      objectType: req.query.objectType,
      testType: req.query.testType,
      scope: req.query.scope,
      keyword: req.query.keyword,
      q: req.query.q,
      folder: req.query.folder,
    });
    const data = await Promise.all(filtered.map(async t => ({
      ...toListRow(t),
      folder_label: await testsService.resolveFolderLabel(t.folder, lang),
      folder_order: await testsService.resolveFolderOrder(t.folder),
    })));
    // F1 — deliberate order instead of the discovery-scan artefact: section
    // order (folder.json `order`) first, then folder path, then title.
    data.sort((a, b) => (a.folder_order - b.folder_order)
      || String(a.folder || '').localeCompare(String(b.folder || ''), lang)
      || a.title.localeCompare(b.title, lang));
    res.json({
      success: true,
      data,
      meta: {
        count: data.length,
        lang,
        vocabularies: {
          testTypes: testsService.TEST_TYPES,
          outputTypes: testsService.OUTPUT_TYPES,
          scopes: testsService.SCOPES,
        },
      },
    });
  } catch (err) {
    next(err);
  }
}

async function getTest(req, res, next) {
  try {
    const lang = pickLang(req.query);
    const test = testsService.localizeTest(await testsService.getTest(req.params.id), lang);
    // Member resolution (title/icon/severity/analysis) lives in the service —
    // same function the detail view's builtin datasets use. NOT a bare `.map`
    // callback: Array.map would pass the element index in as the language.
    const members = await Promise.all(
      test.definition.members.map(m => testsService.resolveMemberSummary(m, lang)),
    );
    res.json({
      success: true,
      data: {
        ...toListRow(test),
        folder_label: await testsService.resolveFolderLabel(test.folder, lang),
        // Additive next to folder_label: the same cascade, but per segment and
        // with the partial path. The route carries only the flat test id, so
        // without this the detail view cannot render a navigable rubric path.
        folder_crumbs: await testsService.resolveFolderCrumbs(test.folder, lang),
        members,
      },
      meta: { lang },
    });
  } catch (err) {
    next(err);
  }
}

async function runTest(req, res, next) {
  try {
    const lang = pickLang(req.query);
    const test = await testsService.getTest(req.params.id);
    // Canonical test into the runner (its result envelopes feed a
    // language-blind cache), translation strictly on the way out.
    const result = await testsService.runTest(req.solutionContext, test, req.query, null);
    result.meta.lang = lang;
    res.json({ success: true, data: await testsService.localizeRunResult(result, test, lang) });
  } catch (err) {
    next(err);
  }
}

async function runTestMember(req, res, next) {
  try {
    const lang = pickLang(req.query);
    const test = await testsService.getTest(req.params.id);
    const result = await testsService.runTest(
      req.solutionContext, test, req.query, req.params.memberIndex,
    );
    result.meta.lang = lang;
    res.json({ success: true, data: await testsService.localizeRunResult(result, test, lang) });
  } catch (err) {
    next(err);
  }
}

/**
 * Lightweight cache-key endpoint: effective solution + catalog
 * fingerprint (mtime+size of the read copy). Client caches compare this
 * before showing stored results; a new XML import changes it automatically.
 */
async function getContext(req, res, next) {
  try {
    res.json({ success: true, data: testsService.catalogMeta(req.solutionContext) });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listTests,
  getTest,
  runTest,
  runTestMember,
  getContext,
};
