const dashboardService = require('../services/dashboard.service');
const dashboardI18nService = require('../services/dashboard-i18n.service');
const environment = require('../config/environment');
const solutionsConfig = require('../config/solutions');
const { SUPPORTED_LANGUAGE_CODES, DEFAULT_LANGUAGE, resolveLanguage } = require('../config/languages');

/**
 * Dashboard Controller
 *
 *   GET /api/dashboards                       List available bundles
 *   GET /api/dashboards/:id                   Manifest + layout (localised)
 *   GET /api/dashboards/:id/data              All datasets in parallel
 *   GET /api/dashboards/:id/data/:dataset     A single dataset
 */

/**
 * Query keys that are not forwarded to SQL templates as parameters.
 */
const RESERVED_QUERY_PARAMS = new Set(['format', 'meta', 'debug', 'lang']);

function extractDashboardParams(query) {
  const out = {};
  for (const [k, v] of Object.entries(query || {})) {
    if (!RESERVED_QUERY_PARAMS.has(k)) {
      out[k] = v;
    }
  }
  return out;
}

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

async function listDashboards(req, res, next) {
  try {
    const lang = pickLang(req.query);
    const bundles = await dashboardService.listBundles();
    const localised = await Promise.all(
      bundles.map(async (b) => {
        const { manifest } = await dashboardI18nService.resolveBundleForLanguage(b, lang);
        return { manifest, bundle: b };
      }),
    );
    const data = localised.map(({ manifest: m, bundle }) => ({
      id: m.id,
      title: m.title,
      description: m.description || null,
      icon: m.icon || null,
      tags: m.tags || [],
      category: m.category || null,
      area: bundle.area,
      overrides: bundle.overrides === true,
      folder: bundle.folder || null,
      author: m.author || null,
      version: m.version || null,
    }));
    data.sort((a, b) => a.title.localeCompare(b.title, lang));
    res.json({ success: true, data, meta: { count: data.length, lang } });
  } catch (err) {
    next(err);
  }
}

/**
 * Multi-Solution: die Hero-Kachel des Home-Dashboards (`project_summary`)
 * trägt statt des generischen „Projektüberblick" den Anzeigenamen der
 * KONTEXT-Lösung (Ausbaustufe M: die Lösung, die DIESER Aufrufer sieht —
 * X-Solution-Header, sonst Server-Default). Die `default`-Lösung nutzt ihren
 * `display_name` ebenfalls, sofern gesetzt — nur ohne Display-Name behält sie
 * den lokalisierten Bundle-Titel.
 * Liefert bei Override ein GEKLONTES Layout (die i18n-Auflösung gibt gecachte/
 * geteilte Objekte zurück, die nie mutiert werden dürfen). Nie fatal.
 */
function withContextSolutionTitle(id, layout, ctx) {
  if (id !== 'home' || !layout || !Array.isArray(layout.root && layout.root.children)) {
    return layout;
  }
  try {
    const solution = (ctx && ctx.solution) || solutionsConfig.getActiveSolutionId();
    const manifest = solutionsConfig.readManifest(solution);
    const displayName = manifest && manifest.display_name;
    // Default-Lösung ohne Display-Name → statischen Kachel-Titel behalten.
    if (solution === solutionsConfig.DEFAULT_ID && !displayName) return layout;
    const name = displayName || solution;
    const cloned = JSON.parse(JSON.stringify(layout));
    const card = cloned.root.children.find((c) => c && c.id === 'project_summary');
    if (!card || !card.props) return layout;
    card.props.title = name;
    return cloned;
  } catch {
    return layout;
  }
}

async function getDashboard(req, res, next) {
  try {
    const { id } = req.params;
    const lang = pickLang(req.query);
    const bundle = await dashboardService.getBundle(id);
    const { manifest, layout } = await dashboardI18nService.resolveBundleForLanguage(bundle, lang);
    // `nav` ist additiv: Bereich und Ordnerpfad des Bundles plus die
    // lokalisierten Krumen mit ihren Teilpfaden. Ohne ihn kennt die
    // Detailansicht ihre Rubrik gar nicht (die Route trägt nur die flache
    // Bundle-ID) und müsste die komplette Bundle-Liste ziehen, um ein paar
    // Felder zu erfahren. Custom-/Community-Krumen beginnen mit der
    // Zwischenebene „Custom“/„Community“ (virtuelles Präfix des Ordnerpfads);
    // system/module-Bundles haben keinen Ordner und damit keine Krumen.
    const nav = {
      area: bundle.area,
      favoritable: dashboardService.isFavoritableArea(bundle.area),
      folder: bundle.folder || null,
      crumbs: await dashboardService.resolveFolderCrumbs(bundle.folder, lang),
    };
    res.json({
      success: true,
      data: { manifest, layout: withContextSolutionTitle(id, layout, req.solutionContext), nav },
      meta: { lang },
    });
  } catch (err) {
    next(err);
  }
}

async function getDashboardData(req, res, next) {
  try {
    const { id } = req.params;
    const bundle = await dashboardService.getBundle(id);
    const params = extractDashboardParams(req.query);
    // i18n language is filtered out of the user-facing param list but kept as
    // `_lang` so builtin resolvers (e.g. localized doc categories) can use it.
    params._lang = pickLang(req.query);
    const { datasets, catalogEmpty } = await dashboardService.executeAllDatasets(req.solutionContext, bundle, params);
    res.json({
      success: true,
      data: { datasets, catalogEmpty },
      meta: { dashboard_id: id, params_used: params },
    });
  } catch (err) {
    next(err);
  }
}

async function getDashboardDataset(req, res, next) {
  try {
    const { id, dataset } = req.params;
    const bundle = await dashboardService.getBundle(id);
    const params = extractDashboardParams(req.query);
    params._lang = pickLang(req.query);
    const result = await dashboardService.executeSingleDataset(req.solutionContext, bundle, dataset, params);
    res.json({
      success: true,
      data: result.data,
      meta: { ...result.meta, dashboard_id: id, dataset_id: dataset, params_used: params },
    });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listDashboards,
  getDashboard,
  getDashboardData,
  getDashboardDataset,
};
