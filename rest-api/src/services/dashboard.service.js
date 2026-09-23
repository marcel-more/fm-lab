const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const Joi = require('joi');
const environment = require('../config/environment');
const { createError } = require('../middleware/error-handler');
const db = require('../config/database');
const templateService = require('./template.service');
const dashboardI18nService = require('./dashboard-i18n.service');
const { schemas: dashboardSchemas } = require('./dashboard-schemas');
const settingsStore = require('../plugins/settings-store');

// API-Filter-Sets (external_apis): eine austauschbare URL→Familie-Klassifikation.
// Der Platzhalter in den Dataset-SQLs wird NACH interpolateTemplate durch den
// generierten CASE-Block ersetzt (bewusst danach → der `:param`-Präprozessor
// sieht die generierte SQL nicht, Muster mit Doppelpunkt/Port bleiben intakt).
// Sets werden aus dem Install-Verzeichnis (user-installiert, gewinnt) bzw. dem
// Bundle (`api-sets/<id>.json`, Default `generic`) geladen.
const API_SET_PLACEHOLDER = '/*__API_SET_CLASSIFICATION__*/';
const API_SETS_INSTALL_DIR = path.join(
  settingsStore.resolveRepoRoot(), '.fmlab', 'dashboards', 'api-sets',
);

/**
 * Dashboard Service
 *
 * Lädt Dashboard-Bundles (manifest.json + layout.json + data/*.sql + style.css + assets/*)
 * aus zwei Verzeichnissen:
 *   - templates/dashboards/         → System-Bundles (home, _generic, Navigation)
 *   - templates/dashboards-custom/  → Custom-/Plugin-Bundles
 *
 * Bei ID-Kollision hat das Custom-Verzeichnis Vorrang (Override-Pattern für lokale Erweiterungen).
 *
 * Dataset-Quellen (manifest.datasets[].source):
 *   bundle:<rel-path>       → SQL im selben Bundle (data/*.sql)
 *   custom:<template-name>  → bestehende sql-custom/<name>.sql
 *   report:<template-name>  → bestehende sql/<name>.sql
 *   builtin:<key>           → server-bereitgestellte Quelle (list_custom_queries, list_dashboards, files)
 */

// Suchreihenfolge: Custom zuerst, damit lokale Bundles System-Bundles bei ID-Kollision überschreiben.
const DASHBOARDS_DIRS = [
  environment.templates.dashboardsCustomDir,
  environment.templates.dashboardsDir,
];

// Discovery-Cache: ID → { manifest, layout, dir, folder, mtime }
const bundleCache = new LRUCache({
  max: 50,
  ttl: 1000 * 60 * 60, // 1h
  updateAgeOnGet: true,
});

// Max. Ordner-Tiefe für die rekursive Bundle-Discovery (Baum ≤4).
const MAX_FOLDER_DEPTH = 4;

// Discovery-Map: id → { id, dir, base, folder }. Einmalig pro Cache-Generation
// aufgebaut (gemeinsame Promise → kein paralleler Doppel-Scan) und in clearCache
// invalidiert. So bleibt findBundleDir O(1) statt pro Lookup den Baum zu scannen.
let discoveryPromise = null;

// Folder-Metadaten-Cache (folder.json je Ordner): folderPath → { mtime, title, locales }.
// Trägt die lokalisierten Ordner-Anzeigenamen für die Übersicht (Datenschicht mit
// Fallback: locales[lang] → title → humanisiertes Segment). mtime-invalidiert.
const folderMetaCache = new Map();

function clearCache() {
  bundleCache.clear();
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
    const stat = await fs.stat(filePath);
    return stat.mtimeMs;
  } catch {
    return 0;
  }
}

/**
 * Rekursiver Verzeichnis-Walk: sammelt alle Bundle-Verzeichnisse (= Ordner mit
 * `manifest.json`) unter `base` bis Tiefe MAX_FOLDER_DEPTH. Ein Bundle-Ordner wird
 * NICHT weiter durchsucht (Bundles verschachteln nicht). `folder` = relativer Pfad
 * des Eltern-Ordners (ohne `<id>`), null an der Wurzel.
 */
async function walkBundleDir(base, relDir, depth, out) {
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
    let isBundle = false;
    try {
      isBundle = (await fs.stat(path.join(childAbs, 'manifest.json'))).isFile();
    } catch {
      // kein manifest.json → entweder Kategorie-Ordner oder Bundle-Unterordner
    }
    if (isBundle) {
      out.push({ id: e.name, dir: childAbs, base, folder: relDir || null });
    } else if (depth < MAX_FOLDER_DEPTH) {
      await walkBundleDir(base, childRel, depth + 1, out);
    }
  }
}

/**
 * Baut die Discovery-Map (id → {id, dir, base, folder}) aus beiden DASHBOARDS_DIRS.
 * Custom-Verzeichnis wird zuerst gescannt → gewinnt bei ID-Kollision (Override-Pattern).
 * Doppelter Basename (innerhalb desselben Scans, anderes Verzeichnis) → Warn + verwerfen.
 */
async function buildDiscovery() {
  const found = [];
  for (const base of DASHBOARDS_DIRS) {
    await walkBundleDir(base, '', 0, found);
  }
  const map = new Map();
  for (const entry of found) {
    const existing = map.get(entry.id);
    if (existing) {
      console.warn(
        `[dashboard:${entry.id}] duplicate bundle id at "${entry.dir}" — keeping "${existing.dir}", discarding`,
      );
      continue;
    }
    map.set(entry.id, entry);
  }
  return map;
}

function getDiscovery() {
  if (!discoveryPromise) {
    discoveryPromise = buildDiscovery().catch(err => {
      // Scan-Fehler nicht cachen — nächster Aufruf versucht es erneut.
      discoveryPromise = null;
      throw err;
    });
  }
  return discoveryPromise;
}

/**
 * Findet das Verzeichnis eines Bundles über die gecachte Discovery-Map (O(1)).
 * Liefert null, wenn die ID nicht bekannt ist.
 */
async function findBundleDir(id) {
  const map = await getDiscovery();
  return map.get(id)?.dir || null;
}

/**
 * Lädt ein einzelnes Bundle (manifest + layout). Validiert beides per Joi.
 * Bei Fehler: gibt null zurück und loggt — App soll nicht crashen.
 */
async function loadBundle(id) {
  const cacheKey = id;
  const map = await getDiscovery();
  const entry = map.get(id);
  if (!entry) return null;
  const dir = entry.dir;
  const folder = entry.folder; // relativer Ordnerpfad (ohne <id>), null = Wurzel
  const manifestPath = path.join(dir, 'manifest.json');
  const layoutPath = path.join(dir, 'layout.json');

  // mtime-Check für Cache-Invalidation
  const [manifestMtime, layoutMtime] = await Promise.all([
    tryStatMtime(manifestPath),
    tryStatMtime(layoutPath),
  ]);
  const combinedMtime = Math.max(manifestMtime, layoutMtime);

  if (environment.templates.cacheEnabled) {
    const cached = bundleCache.get(cacheKey);
    if (cached && cached.mtime === combinedMtime) {
      return cached;
    }
  }

  try {
    const [manifestRaw, layoutRaw] = await Promise.all([
      readJsonFile(manifestPath),
      readJsonFile(layoutPath).catch(err => {
        // Fehlendes layout.json ist tolerabel (z.B. wenn entry-Feld auf anderen Pfad zeigt)
        const entry = null;
        throw err;
      }),
    ]);

    // Manifest validieren
    const { error: manifestErr, value: manifest } = dashboardSchemas.manifest.validate(manifestRaw, {
      abortEarly: false,
      stripUnknown: false,
      convert: true,
    });
    if (manifestErr) {
      console.warn(`[dashboard:${id}] manifest.json invalid: ${manifestErr.message}`);
      return null;
    }

    // Layout validieren
    const { error: layoutErr, value: layout } = dashboardSchemas.layout.validate(layoutRaw, {
      abortEarly: false,
      stripUnknown: false,
      convert: true,
    });
    if (layoutErr) {
      console.warn(`[dashboard:${id}] layout.json invalid: ${layoutErr.message}`);
      return null;
    }

    // ID-Konsistenz: manifest.id muss Verzeichnisname entsprechen
    if (manifest.id !== id) {
      console.warn(`[dashboard:${id}] manifest.id="${manifest.id}" differs from directory name`);
      return null;
    }

    const bundle = {
      id,
      dir,
      folder,
      manifest,
      layout,
      mtime: combinedMtime,
    };

    if (environment.templates.cacheEnabled) {
      bundleCache.set(cacheKey, bundle);
    }
    return bundle;
  } catch (err) {
    console.warn(`[dashboard:${id}] failed to load: ${err.message}`);
    return null;
  }
}

/**
 * Listet alle gefundenen Dashboard-Bundles aus allen DASHBOARDS_DIRS.
 * Custom-Verzeichnis hat Vorrang (gleicher Override wie loadBundle).
 * Fehlerhafte Bundles werden übersprungen.
 */
async function listBundles() {
  const map = await getDiscovery();
  const bundles = await Promise.all([...map.keys()].map(loadBundle));
  return bundles.filter(b => b !== null);
}

/**
 * Holt ein Bundle anhand der ID. Wirft TEMPLATE_NOT_FOUND, wenn nicht vorhanden.
 */
async function getBundle(id) {
  // Pfad-Traversal verhindern
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) {
    throw createError('VALIDATION_ERROR', `Invalid dashboard id: ${id}`);
  }
  const bundle = await loadBundle(id);
  if (!bundle) {
    throw createError('TEMPLATE_NOT_FOUND', `Dashboard '${id}' not found or invalid`, {
      dashboardId: id,
    });
  }
  return bundle;
}

// ---------------------------------------------------------------------------
// Dataset-Resolver: bundle: / custom: / report: / builtin:
// ---------------------------------------------------------------------------

function parseSourceUri(source) {
  const idx = source.indexOf(':');
  if (idx < 1) {
    throw new Error(`Invalid dataset source: ${source}`);
  }
  return {
    scheme: source.substring(0, idx),
    ref: source.substring(idx + 1),
  };
}

async function loadBundleSql(bundle, relPath) {
  // Absicherung gegen Traversal
  const normalized = path.normalize(relPath);
  if (normalized.startsWith('..') || path.isAbsolute(normalized)) {
    throw new Error(`Invalid bundle SQL path: ${relPath}`);
  }
  const fullPath = path.join(bundle.dir, normalized);
  if (!fullPath.startsWith(bundle.dir + path.sep)) {
    throw new Error(`Bundle SQL path escapes bundle dir: ${relPath}`);
  }
  return fs.readFile(fullPath, 'utf-8');
}

// 1-Level BigInt-Konversion auf flachen Result-Rows. Timestamps/Date-Objekte aus
// DuckDB serialisiert Express selbst korrekt (toJSON → ISO), solange wir nicht
// rekursiv in jedes Objekt absteigen und dabei Object.entries() auf einem
// Date-Like-Objekt aufrufen (das liefert {} und zerstört den Wert).
function convertBigInts(value) {
  if (Array.isArray(value)) {
    return value.map(row => {
      if (row === null || typeof row !== 'object') return row;
      const out = {};
      for (const [k, v] of Object.entries(row)) {
        out[k] = typeof v === 'bigint' ? Number(v) : v;
      }
      return out;
    });
  }
  return typeof value === 'bigint' ? Number(value) : value;
}

// ---------------------------------------------------------------------------
// API-Filter-Sets: Klassifikations-Generator + Set-Resolver
// ---------------------------------------------------------------------------

// Einzelne SQL-String-Literal-Escape (verdoppelt einfache Anführungszeichen).
function sqlQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

// Erzeugt den `CASE … END`-Block (url → Familie) aus einer Set-Definition.
// Reihenfolge der `rules` = Priorität (erste Übereinstimmung gewinnt). Feste
// Tail-Regeln (Local Import für Import-Steps ohne http-URL, ELSE 'Other') sind
// generische Mechanik und werden immer angehängt.
function buildClassificationCase(set) {
  const rules = Array.isArray(set && set.rules) ? set.rules : [];
  const lines = [];
  for (const r of rules) {
    if (!r || !r.family) continue;
    // Prädikate werden per AND verknüpft: URL-Muster (ilike ODER-Gruppe / regex)
    // plus optionale semantische Bedingungen source_type / in_comment. So lässt
    // sich z.B. „CustomFunction mit URL im Kommentar" ohne URL-Muster ausdrücken.
    const preds = [];
    if (Array.isArray(r.ilike) && r.ilike.length) {
      preds.push('(' + r.ilike.map(p => `url ILIKE ${sqlQuote(p)}`).join(' OR ') + ')');
    } else if (typeof r.regex === 'string' && r.regex.length) {
      preds.push(`regexp_matches(url, ${sqlQuote(r.regex)})`);
    }
    if (typeof r.source_type === 'string' && r.source_type.length) {
      preds.push(`source_type = ${sqlQuote(r.source_type)}`);
    }
    if (r.in_comment === true) preds.push('in_comment');
    else if (r.in_comment === false) preds.push('NOT in_comment');
    if (!preds.length) continue;
    lines.push(`            WHEN ${preds.join(' AND ')} THEN ${sqlQuote(r.family)}`);
  }
  lines.push(`            WHEN source_type = 'Script (Import)' THEN 'Local Import'`);
  return `CASE\n${lines.join('\n')}\n            ELSE 'Other'\n        END`;
}

// Lädt eine Set-Datei aus einem Verzeichnis (null bei Fehler/Nichtvorhandensein).
async function loadApiSetFile(dir, setId) {
  if (!/^[a-zA-Z0-9_-]+$/.test(setId)) return null; // Traversal-/Injection-Schutz
  try {
    const raw = await fs.readFile(path.join(dir, `${setId}.json`), 'utf-8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// Auflösung: Install-Verzeichnis (user-installiert) gewinnt über Bundle-Default.
async function resolveApiSet(bundle, setId) {
  return (await loadApiSetFile(API_SETS_INSTALL_DIR, setId))
      || (await loadApiSetFile(path.join(bundle.dir, 'api-sets'), setId));
}

async function runBundleQuery(ctx, bundle, relPath, params) {
  const sqlTemplate = await loadBundleSql(bundle, relPath);
  let sql = templateService.interpolateTemplate(sqlTemplate, params);
  // API-Filter-Set injizieren (nur Datasets mit Platzhalter; alle anderen Bundles
  // unberührt). NACH interpolateTemplate → generierte SQL ist präprozessor-sicher.
  if (sql.includes(API_SET_PLACEHOLDER)) {
    const setId = (params && params.api_set && String(params.api_set)) || 'generic';
    const set = (await resolveApiSet(bundle, setId)) || (await resolveApiSet(bundle, 'generic'));
    sql = sql.split(API_SET_PLACEHOLDER).join(buildClassificationCase(set || {}));
  }
  const result = await db.executeQuery(ctx, sql);
  return {
    data: convertBigInts(result.rows),
    meta: { source: `bundle:${relPath}`, ...result.meta },
  };
}

async function runCustomTemplate(ctx, name, params) {
  const result = await templateService.executeTemplate(ctx, name, params, 'query');
  return { data: result.data, meta: { source: `custom:${name}`, ...result.meta } };
}

async function runReportTemplate(ctx, name, params) {
  const result = await templateService.executeTemplate(ctx, name, params, 'report');
  return { data: result.data, meta: { source: `report:${name}`, ...result.meta } };
}

// ---------------------------------------------------------------------------
// builtin: Datasets
// ---------------------------------------------------------------------------

async function builtinListCustomQueries(params = {}) {
  const templates = await templateService.listTemplates('query');
  const rows = templates.map(t => ({
    name: t.name,
    title: t.title || t.name,
    description: t.description || null,
    template_type: t.template_type,
    category: t.category || 'Allgemein',
    icon: t.icon || 'query',
    display: t.display || 'auto',
    // Klick-Konfiguration der Query — technisch ('_'-Präfix): sie beschreibt,
    // was das Ergebnis-Dashboard beim Zeilenklick tut, und gehört nicht in die
    // Suche über den Query-Katalog.
    _click_action: t.click_action || null,
    _click_args: t.click_args || null,
    tags: t.tags || [],
    params: Array.isArray(t.params) ? t.params.join(', ') : (t.params || ''),
  }));

  if (params.category) {
    return rows.filter(r => r.category === params.category);
  }
  // Sortierung: erst Kategorie, dann Titel
  rows.sort((a, b) => {
    const c = String(a.category).localeCompare(String(b.category), 'de');
    if (c !== 0) return c;
    return String(a.title).localeCompare(String(b.title), 'de');
  });
  return rows;
}

/**
 * builtin:query_meta — gibt eine einzelne Zeile mit Metadaten eines sql-custom-Templates
 * zurück. Benötigt Param `query`. Wird vom `_generic`-Bundle genutzt, um Titel,
 * Beschreibung und Klick-Action-Konfiguration an das Layout zu übergeben.
 */
async function builtinQueryMeta(params = {}) {
  const queryName = params.query;
  if (!queryName) {
    throw createError('VALIDATION_ERROR', 'builtin:query_meta requires param "query"');
  }
  // Wichtig: auch Bundle-eigene Templates aus dashboards*/<bundle>/queries/
  // auflösen — listTemplates('query') würde nur sql-custom/ scannen.
  const t = await templateService.getTemplateMeta(queryName, 'query');
  if (!t) {
    // Leere Zeile statt Fehler — Dashboard soll trotzdem rendern können
    return [{
      query: queryName,
      title: queryName,
      description: null,
      template_type: null,
      icon: null,
      category: null,
      display: 'auto',
      click_action: null,
      click_args: null,
      row_action: null,
      row_action_args: null,
      row_action_label: null,
      chip_filter: null,
      chip_param: null,
    }];
  }
  return [{
    query: queryName,
    title: t.title || queryName,
    description: t.description || null,
    template_type: t.template_type || null,
    icon: t.icon || null,
    category: t.category || null,
    display: t.display || 'auto',
    click_action: t.click_action || null,
    click_args: t.click_args || null,
    row_action: t.row_action || null,
    row_action_args: t.row_action_args || null,
    row_action_label: t.row_action_label || null,
    chip_filter: t.chip_filter || null,
    chip_param: t.chip_param || null,
    object_types: t.object_types || [],
    output_types: t.output_types || [],
    scope: t.scope || [],
    default_result: t.default_result || null,
  }];
}

// humanisiert ein Ordner-Segment ("code_style" → "Code Style") — letzter Fallback.
function humanizeFolderSegment(seg) {
  return seg.replace(/[-_]/g, ' ').replace(/\b\w/g, ch => ch.toUpperCase());
}

// Lädt folder.json eines Ordners (relativer Pfad ohne Bundle-ID) aus einem der
// DASHBOARDS_DIRS, mtime-gecacht. Liefert { title, icon, description, order,
// locales } oder null. Joi-validiert (folderManifest) — defekte Dateien
// degradieren zu leeren Metadaten statt die Discovery zu kippen.
async function loadFolderMeta(folderPath) {
  for (const base of DASHBOARDS_DIRS) {
    const fp = path.join(base, folderPath, 'folder.json');
    const mtime = await tryStatMtime(fp);
    if (!mtime) continue;
    const cached = folderMetaCache.get(folderPath);
    if (cached && cached.mtime === mtime) return cached;
    let raw = null;
    try { raw = await readJsonFile(fp); } catch { raw = null; }
    const { value } = dashboardSchemas.folderManifest.validate(raw || {}, { convert: true });
    const meta = {
      mtime,
      title: value?.title || null,
      icon: value?.icon || null,
      description: value?.description || null,
      order: Number.isFinite(value?.order) ? value.order : null,
      locales: value?.locales || null,
    };
    folderMetaCache.set(folderPath, meta);
    return meta;
  }
  return null;
}

// Zerlegt einen Ordner-Pfad in lokalisierte Krumen: "a/b" → [{path:"a",label},
// {path:"a/b",label}]. Pro Segment gilt die Kaskade folder.json locales[lang] →
// folder.json title → humanisiertes Segment. Jede Krume trägt ihren TEILPFAD,
// damit die Breadcrumb im Frontend klickbar wird (`/dashboard?folder=<teilpfad>`).
// Der Pfad-Key bleibt der führende Identifier; Labels sind reine Anzeigeschicht.
async function resolveFolderCrumbs(folderPath, lang) {
  if (!folderPath) return [];
  const crumbs = [];
  let prefix = '';
  for (const seg of String(folderPath).split('/')) {
    prefix = prefix ? `${prefix}/${seg}` : seg;
    const meta = await loadFolderMeta(prefix);
    const label = (lang && meta?.locales && meta.locales[lang])
      || meta?.title
      || humanizeFolderSegment(seg);
    crumbs.push({ path: prefix, label });
  }
  return crumbs;
}

// Baut den lokalisierten Anzeigenamen eines Ordner-Pfads ("a/b" → "A-Label / B-Label").
// Bewusst auf resolveFolderCrumbs zurückgeführt, damit es genau EINE
// Label-Kaskade gibt — Krumen und zusammengefügtes Label können nicht auseinanderlaufen.
async function resolveFolderLabel(folderPath, lang) {
  if (!folderPath) return null;
  return (await resolveFolderCrumbs(folderPath, lang)).map(c => c.label).join(' / ');
}

async function builtinListDashboards(params = {}) {
  const bundles = await listBundles();
  const lang = params._lang || params.lang || 'en';

  let excludeTags = [];
  if (params.excludeTags) {
    excludeTags = Array.isArray(params.excludeTags)
      ? params.excludeTags
      : String(params.excludeTags).split(',').map(s => s.trim()).filter(Boolean);
  }

  const filtered = bundles.filter(b => {
    if (!excludeTags.length) return true;
    const tags = b.manifest.tags || [];
    return !tags.some(t => excludeTags.includes(t));
  });

  // Titel/Beschreibung über die i18n-Schicht auflösen (Fallback = Basis-Manifest);
  // Ordner-Label als zusätzliche Anzeige-Datenschicht (folder bleibt der Identifier).
  const rows = await Promise.all(filtered.map(async b => {
    const { manifest } = await dashboardI18nService.resolveBundleForLanguage(b, lang);
    return {
      id: manifest.id,
      title: manifest.title,
      description: manifest.description || null,
      icon: manifest.icon || null,
      tags: manifest.tags || [],
      category: manifest.category || null,
      folder: b.folder || null,
      folder_label: await resolveFolderLabel(b.folder, lang),
      author: manifest.author || null,
      version: manifest.version || null,
      // Entry-point marker (`featured`) + the folder subtrees its entry count
      // spans — the overview renders such a bundle as a band above the folder
      // grid instead of as an equal tile below it.
      featured: manifest.featured === true,
      _badge_roots: manifest.badgeRoots || null,
    };
  }));

  const collator = lang && lang !== 'en' ? lang : 'en';
  rows.sort((a, b) => a.title.localeCompare(b.title, collator));
  return rows;
}

/**
 * builtin:list_dashboard_folders — die Ordner-Hierarchie der Dashboard-Bundles
 * für die Ordner-Navigation der Übersicht. Eine Zeile je Ordner (auch
 * Zwischenebenen), mit lokalisiertem Label des EIGENEN Segments, Icon,
 * Description, order (folder.json) und Zählern:
 *   direct_count = Bundles direkt im Ordner, total_count = inkl. Teilbaum.
 * Respektiert denselben excludeTags-Filter wie list_dashboards, damit die
 * Zähler exakt das spiegeln, was die Übersicht anzeigt.
 */
async function builtinListDashboardFolders(params = {}) {
  const bundles = await listBundles();
  const lang = params._lang || params.lang || 'en';

  let excludeTags = [];
  if (params.excludeTags) {
    excludeTags = Array.isArray(params.excludeTags)
      ? params.excludeTags
      : String(params.excludeTags).split(',').map(s => s.trim()).filter(Boolean);
  }
  const visible = bundles.filter(b => {
    if (!excludeTags.length) return true;
    const tags = b.manifest.tags || [];
    return !tags.some(t => excludeTags.includes(t));
  });

  // Alle Ordner-Pfade (inkl. Zwischenebenen) + Zähler aufsammeln.
  const folders = new Map(); // path → { direct, total }
  const ensure = p => {
    if (!folders.has(p)) folders.set(p, { direct: 0, total: 0 });
    return folders.get(p);
  };
  for (const b of visible) {
    if (!b.folder) continue;
    const segs = String(b.folder).split('/');
    let prefix = '';
    for (let i = 0; i < segs.length; i++) {
      prefix = prefix ? `${prefix}/${segs[i]}` : segs[i];
      const node = ensure(prefix);
      node.total += 1;
      if (i === segs.length - 1) node.direct += 1;
    }
  }

  const rows = await Promise.all([...folders.entries()].map(async ([folderPath, counts]) => {
    const meta = await loadFolderMeta(folderPath);
    const seg = folderPath.split('/').pop();
    const label = (meta?.locales && meta.locales[lang]) || meta?.title || humanizeFolderSegment(seg);
    const parent = folderPath.includes('/') ? folderPath.slice(0, folderPath.lastIndexOf('/')) : null;
    return {
      path: folderPath,
      parent,
      label,
      // Voll lokalisierter Pfad (für flache Treffer-/Filteransichten).
      path_label: await resolveFolderLabel(folderPath, lang),
      icon: meta?.icon || null,
      description: meta?.description || null,
      order: meta?.order ?? null,
      direct_count: counts.direct,
      total_count: counts.total,
    };
  }));

  // Sortierung je Ebene: order (fehlend = hinten), dann Label.
  rows.sort((a, b) => {
    const depth = a.path.split('/').length - b.path.split('/').length;
    if (depth !== 0) return depth;
    const ao = a.order ?? Number.MAX_SAFE_INTEGER;
    const bo = b.order ?? Number.MAX_SAFE_INTEGER;
    if (ao !== bo) return ao - bo;
    return String(a.label).localeCompare(String(b.label), lang);
  });
  return rows;
}

async function builtinFiles(ctx) {
  const sql = `
    SELECT
      File_Name,
      File_FullName,
      FileMaker_Version,
      Has_DDR_INFO,
      Import_Timestamp
    FROM FilesCatalog
    ORDER BY File_Name
  `;
  const result = await db.executeQuery(ctx, sql);
  return convertBigInts(result.rows);
}

/**
 * builtin:list_docs — listet alle installierten und sichtbaren Dokumentations-Bundles
 * aus dem v2-Manifest (`.fmlab/docs.json`). Backwards-compat alias zu
 * `docs_overview_installed`. Filtert auf catalog.visible == true UND installed.
 */
async function builtinListDocs() {
  const docsManifest = require('./docs-manifest');
  const rows = docsManifest.listVisibleInstalled();
  return rows.map(({ catalog, installed }) => {
    const langs = Array.isArray(installed?.languages) ? installed.languages : (catalog.languages || []);
    return {
      id: catalog.id,
      name: catalog.name || catalog.id,
      description: catalog.description || null,
      directory: installed?.directory || null,
      skill: catalog.skill || null,
      source_url: catalog.source_url || null,
      categories: installed?.stats?.categories ?? null,
      // Manifest-Grenze — siehe docs-source.getDocsetInfo: gespeichert als
      // `stats.functions`, ausgeliefert als `entries`.
      entries: installed?.stats?.entries ?? installed?.stats?.functions ?? null,
      languages: langs,
      languages_count: langs.length,
      languages_display: langs.map(l => String(l).toUpperCase()).join(' · '),
      installed_at: installed?.installed_at || null,
      installed: true,
    };
  });
}

/**
 * builtin:docs_overview_installed — sichtbare, installierte Doc-Sets.
 * Identisch mit list_docs, aber semantisch klarer benannt für das neue
 * docs_overview-Dashboard.
 */
async function builtinDocsOverviewInstalled() {
  return builtinListDocs();
}

/**
 * builtin:docs_overview_available — sichtbare Doc-Sets aus dem Catalog,
 * die noch NICHT vollständig installiert sind. Für den "Verfügbar"-Block der
 * docs_overview-Sub-Dashboard mit Install-Button.
 *
 * Multi-Sprach-Sets bleiben hier solange sichtbar, wie noch nicht alle
 * Catalog-Sprachen installiert sind (siehe docs-manifest.listVisibleAvailable).
 * `installed_languages` listet die schon vorhandenen Sprachen, damit das
 * Frontend sie im Sprach-Picker als ausgegraut darstellen kann.
 */
async function builtinDocsOverviewAvailable() {
  const docsManifest = require('./docs-manifest');
  const rows = docsManifest.listVisibleAvailable();
  return rows.map(({ catalog, installed }) => {
    const langs = Array.isArray(catalog.languages) ? catalog.languages : [];
    const installedLangs = installed && Array.isArray(installed.languages)
      ? installed.languages
      : [];
    // Was unter "Verfügbar" wirklich angezeigt werden soll: nur die Sprachen,
    // die für dieses Set noch nicht lokal vorliegen. Das spiegelt die
    // "Installiert"-Liste (die exakt die installierten zeigt). `languages`
    // bleibt zu Backwards-Kompatibilität die vollständige Catalog-Liste.
    const installedSet = new Set(installedLangs);
    const missingLangs = langs.filter(l => !installedSet.has(l));
    return {
      id: catalog.id,
      name: catalog.name || catalog.id,
      description: catalog.description || null,
      source_url: catalog.source_url || null,
      skill: catalog.skill || null,
      languages: langs,
      languages_count: langs.length,
      languages_display: langs.map(l => String(l).toUpperCase()).join(' · '),
      installed_languages: installedLangs,
      missing_languages: missingLangs,
      missing_languages_count: missingLangs.length,
      missing_languages_display: missingLangs.map(l => String(l).toUpperCase()).join(' · '),
      output_format: catalog.output_format || null,
      download_format: catalog.download_format || null,
      installed: installedLangs.length > 0, // true für Teil-Installs
    };
  });
}

/**
 * builtin:docset_info — single-row header for the docset detail dashboard.
 * Params: id (required), lang (optional).
 */
async function builtinDocsetInfo(params = {}) {
  const docsSource = require('./docs-source');
  const id = params.id;
  if (!id) throw createError('VALIDATION_ERROR', 'builtin:docset_info requires param "id"');
  const lang = params._lang || params.lang || 'en';
  const info = await docsSource.getDocsetInfo(id, lang);
  if (!info) return [];
  const langs = Array.isArray(info.languages) ? info.languages : [];
  return [{
    id: info.id,
    name: info.name || info.id,
    description: info.description || null,
    source_url: info.source_url || null,
    online_link_md: info.online_link_md || '',
    categories: typeof info.categories === 'number' ? info.categories : null,
    entries: typeof info.entries === 'number' ? info.entries : null,
    // Capability + Endpoint der rubrikübergreifenden Eintragssuche. Die List
    // liest beides über ihre `entrySearch.metaDataset`-Prop; Sets ohne
    // Eintragsebene liefern entry_search=false und bekommen kein Kästchen.
    entry_search: !!info.entry_search,
    entry_search_url: info.entry_search_url || null,
    entry_search_min_chars: info.entry_search_min_chars ?? null,
    start_page: info.start_page || null,
    languages: langs,
    languages_count: langs.length,
    languages_display: langs.map(l => String(l).toUpperCase()).join(' · '),
  }];
}

/**
 * builtin:docset_start_entry — die im Manifest deklarierte Startseite eines
 * Doc-Sets als gerenderter Volltext (content_html, sanitized + Link-Rewrite
 * über die getDocsetEntry-Pipeline). Leeres Dataset, wenn das Set keine
 * start_page deklariert oder die Seite fehlt — das Bundle rendert dann leer.
 * Params: id (required), lang (optional).
 */
async function builtinDocsetStartEntry(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const id = params.id;
  if (!id) throw createError('VALIDATION_ERROR', 'builtin:docset_start_entry requires param "id"');
  const lang = params._lang || params.lang || 'en';
  const info = await docsSource.getDocsetInfo(id, lang);
  if (!info || !info.start_page) return [];
  // markdown-fs-Konvention: category == fn == Page-Slug (vgl. docs-content.js).
  const entry = await docsSource.getDocsetEntry(ctx, id, info.start_page, info.start_page, lang);
  if (!entry) return [];
  return [{
    id: entry.id,
    title: entry.title || info.start_page,
    content_html: entry.content_html || '',
    format: entry.format || 'markdown',
  }];
}

/**
 * builtin:docset_categories — list of categories for a docset.
 * Params: id (required), lang (optional, default 'en').
 */
async function builtinDocsetCategories(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const id = params.id;
  if (!id) throw createError('VALIDATION_ERROR', 'builtin:docset_categories requires param "id"');
  return docsSource.listDocsetCategories(ctx, id, params._lang || params.lang || 'en');
}

/**
 * builtin:docset_categories_with_counts — wie docset_categories, aber annotiert
 * jede Kategorie mit `code_ref_count` (Anzahl Code-Referenzen in der FM-Solution).
 * Bei references: false liefert das Set null pro Eintrag (keine Pill).
 */
async function builtinDocsetCategoriesWithCounts(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const docsReferences = require('./docs-references');
  const id = params.id;
  if (!id) throw createError('VALIDATION_ERROR', 'builtin:docset_categories_with_counts requires param "id"');
  const lang = params._lang || params.lang || 'en';
  const cats = await docsSource.listDocsetCategories(ctx, id, lang);
  return docsReferences.annotateCategoriesWithCounts(ctx, id, cats);
}

/**
 * builtin:docset_category_info — single-row header for the category dashboard.
 * Params: docset (required), category (required), lang (optional).
 */
async function builtinDocsetCategoryInfo(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const docset = params.docset;
  const category = params.category;
  if (!docset || !category) {
    throw createError('VALIDATION_ERROR', 'builtin:docset_category_info requires params "docset" and "category"');
  }
  const info = await docsSource.getDocsetCategoryInfo(ctx, docset, category, params._lang || params.lang || 'en');
  if (!info) return [];
  return [{
    docset,
    id: info.id,
    name: info.name,
    slug: info.slug,
    kind: info.kind || null,
    description: info.description || null,
    source_url: info.source_url || null,
    online_url: info.online_url || null,
    online_link_md: info.online_link_md || '',
    entry_count: typeof info.entry_count === 'number' ? info.entry_count : null,
  }];
}

/**
 * builtin:docset_functions — list of functions/script-steps in a category.
 * Params: docset (required), category (required), lang (optional).
 */
async function builtinDocsetFunctions(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const docset = params.docset;
  const category = params.category;
  if (!docset || !category) {
    throw createError('VALIDATION_ERROR', 'builtin:docset_functions requires params "docset" and "category"');
  }
  return docsSource.listDocsetFunctions(ctx, docset, category, params._lang || params.lang || 'en');
}

/**
 * builtin:xml_directory_status — Verzeichnis-Listing + Status-Spalte für das
 * Sub-Dashboard "xml_convert".
 * Liefert pro Datei: filename, size, mtime, status, emoji, imported_at,
 * ddr_info (true|false|null — Header-Probe, Fallback Katalog).
 */
/**
 * Kontext-Lösung der xml_convert-Datasets: das Bundle reicht
 * `solution_id` aus der Import-Seiten-URL durch. Ungültige/unbekannte IDs
 * fallen still auf die aktive Lösung zurück (die Endpoints validieren hart,
 * die Datasets degradieren weich).
 */
function contextSolutionParam(params = {}) {
  const solutions = require('../config/solutions');
  const id = params.solution_id;
  if (typeof id === 'string' && solutions.isValidId(id) && solutions.solutionExists(id)) return id;
  return undefined;
}

async function builtinXmlDirectoryStatus(ctx, params = {}) {
  const xmlConvert = require('./xml-convert');
  const status = await xmlConvert.getStatus(ctx, contextSolutionParam(params));
  return status.files;
}

/**
 * builtin:xml_directory_listing — kompakte Datei-Liste fürs Home-Dashboard
 * im leeren Zustand (Monospace-Block). Nur die Dateinamen + Größe + mtime.
 */
async function builtinXmlDirectoryListing() {
  const xmlConvert = require('./xml-convert');
  return xmlConvert.getDirectoryListing();
}

/**
 * builtin:file_source_size — size (bytes) of one file's XML source export, for
 * the file-detail view KPI. Sourced from the on-disk xml/ listing (filesystem
 * metadata, like the home file sizes) rather than the object catalog. Matches on
 * the file name with the .xml suffix stripped, NFC-normalised, case-insensitive.
 * Returns one row [{ size_bytes }] — null when the param is missing or no XML
 * source is present (KPI then renders "—").
 */
async function builtinFileSourceSize(params = {}) {
  const file = params.file;
  if (!file) return [{ size_bytes: null }];
  const xmlConvert = require('./xml-convert');
  const listing = await xmlConvert.getDirectoryListing();
  const target = String(file).normalize('NFC').toLowerCase();
  const match = listing.find(
    f => String(f.filename).replace(/\.xml$/i, '').normalize('NFC').toLowerCase() === target,
  );
  return [{ size_bytes: match ? match.size : null }];
}

/**
 * builtin:xml_directory_meta — eine Meta-Zeile für die Empty-State-Karte:
 * Datei-Anzahl + Gesamtgröße + Pfade + Laufzeit-/Reveal-Flags. So zieht die
 * Karte Anzahl, „Ordner öffnen" (nativ) und den Host-Pfad-Fallback (Container)
 * aus einer Quelle. Vom 6-s-Soft-Refresh des Home-Dashboards gepollt.
 */
async function builtinXmlDirectoryMeta(ctx, params = {}) {
  const xmlConvert = require('./xml-convert');
  const status = await xmlConvert.getStatus(ctx, contextSolutionParam(params));
  const files = status.files || [];
  const totalBytes = files.reduce((sum, f) => sum + (Number(f.size) || 0), 0);
  return [{
    count: files.length,
    total_bytes: totalBytes,
    xml_dir: status.xml_dir,
    host_xml_dir: status.host_xml_dir ?? null,
    runtime: status.runtime,
    can_reveal: status.can_reveal === true,
  }];
}

/**
 * builtin:xml_last_run — Meta-Zeile zum letzten Konvertierungslauf (ohne
 * events[]). Wird im Sub-Dashboard für die Statuszeile über dem Log genutzt.
 * Liefert eine Liste mit 0 oder 1 Eintrag.
 */
async function builtinXmlLastRun(ctx, params = {}) {
  const xmlConvert = require('./xml-convert');
  const data = await xmlConvert.getStatus(ctx, contextSolutionParam(params));
  return data.last_run ? [data.last_run] : [];
}

/**
 * builtin:xml_semantic_names — die zwei Drift-Kennzahlen (Struktur + Benennung)
 * für die „Graph-Communities"-Card. Eine Zeile (oder leer, wenn
 * keine Partition existiert → available:false). Vom 6-s-Soft-Refresh gepollt.
 */
async function builtinXmlSemanticNames(ctx, params = {}) {
  const xmlConvert = require('./xml-convert');
  const data = await xmlConvert.getStatus(ctx, contextSolutionParam(params));
  return data.semantic_names ? [data.semantic_names] : [];
}

/**
 * builtin:cluster_count — eine Zeile `[{ count }]` für die Home-Hero
 * „Cluster"-Bubble. `count` = Anzahl der
 * Communities der aktiven Engine; `null`, wenn keine Partition existiert
 * (`clusters_available=false`) → das Frontend rendert dann `—`. Nutzt den
 * robusten `communityTablesPresent()`-Guard aus graph.service (kein SQL-Crash
 * auf einer ungeclusterten DB, kein Stub-Risiko).
 */
async function builtinClusterCount(ctx) {
  const graphService = require('./graph.service');
  const stats = await graphService.getCommunityStats(ctx);
  const count = stats.clusters_available ? stats.total_communities : null;
  return [{ count }];
}

/**
 * builtin:xml_import_integrity — der Dup-Absorption-Zensus des letzten Imports
 * für die „Import-Integrität"-Card im xml_convert-Dashboard. Liest die P6-View
 * `v_check_absorbed_dups` und aggregiert sie CONTAINER-ZENTRISCH — Teilobjekt-
 * Verluste werden in die Zeile ihres Container-Katalogs gehoistet:
 *
 *   - Script-Hierarchie: eine `ScriptCatalog`-Zeile je Datei. `Absorbed` =
 *     verlorene GANZE Scripts, `Sub_Absorbed` = verlorene Steps innerhalb
 *     erhaltener Scripts (StepsForScripts). Beispiel: „Artikel Bilder | 1 | 47".
 *   - Layout-Hierarchie (analog): eine `Layouts`-Zeile je Datei. `Absorbed` =
 *     verlorene GANZE Layouts, `Sub_Absorbed` = verlorene Layout-Objekte
 *     innerhalb erhaltener Layouts (LayoutObjects).
 *   - Sonderfall: Kollisionen in Katalogen außerhalb beider Hierarchien →
 *     eigene Zeile mit `is_other=true`, exakter Anzahl und `Sub_Absorbed=NULL`.
 *
 * Alle 219k StepsForScripts-Zeilen tragen ein Script (verifiziert) → der reine
 * Step-Verlust ist immer einem Script-Kontext zuordenbar; dasselbe gilt für
 * LayoutObjects (Rekursion läuft je Layout). Deshalb genügt die hoisted Summe
 * (keine Roh-Detailerfassung nötig).
 *
 * NULL-sicher / Alt-DB-fest: fehlt die View (Alt-DB ohne Zensus), `[]`
 * zurückgeben statt zu crashen. HUGEINT → BIGINT casten (int128-Serialisierung).
 */
async function builtinXmlImportIntegrity(ctx, params = {}) {
  // Kontext ≠ aktive Lösung: Zensus/View leben in der aktiven Copy — für eine
  // nicht-aktive Lösung ehrlich leer liefern statt fremder Zahlen (Pool → M).
  const target = contextSolutionParam(params);
  if (target && target !== require('../config/solutions').getActiveSolutionId()) return [];
  // Seit dem UUID-Healing (Schema 1.19.0) ist v_check_absorbed_dups auf geheilten
  // Beständen konstruktionsbedingt LEER — die Karte speist sich deshalb primär aus
  // dem Zensus (DuplicateAbsorptionDetails: gefundene Dubletten + Heilungs-Status)
  // und liefert EINE kompakte Summary-Zeile; die View bleibt als „echter Restverlust"
  // (Alt-DBs, FM_UUID_HEAL=0) zusätzlich enthalten. Details → Metadata-Dashboards.
  const present = await db.executeQuery(
    ctx,
    `SELECT
       (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_name = 'DuplicateAbsorptionDetails') AS has_census,
       (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_name = 'v_check_absorbed_dups') AS has_view,
       (SELECT COUNT(*) FROM information_schema.columns
         WHERE table_name = 'DuplicateAbsorptionDetails'
           AND column_name = 'Heal_Status') AS has_heal`,
  );
  const flags = present.rows[0] || {};
  const toNum = (v) => (typeof v === 'bigint' ? Number(v) : Number(v) || 0);
  const hasCensus = toNum(flags.has_census) > 0;
  const hasView = toNum(flags.has_view) > 0;
  const hasHeal = toNum(flags.has_heal) > 0;
  if (!hasCensus && !hasView) return [];

  const occExpr = hasCensus
    ? '(SELECT COUNT(*) FROM DuplicateAbsorptionDetails)'
    : '0';
  const healedExpr = hasHeal
    ? `(SELECT COUNT(*) FROM DuplicateAbsorptionDetails WHERE Heal_Status = 'healed')`
    : '0';
  const filesExpr = hasCensus
    ? '(SELECT COUNT(DISTINCT File_Name) FROM DuplicateAbsorptionDetails)'
    : '0';
  const lostExpr = hasView
    ? '(SELECT COALESCE(SUM(Absorbed), 0) FROM v_check_absorbed_dups)'
    : '0';
  const result = await db.executeQuery(
    ctx,
    `SELECT
       ${occExpr}::BIGINT AS Dup_Occurrences,
       ${healedExpr}::BIGINT AS Healed,
       ${filesExpr}::BIGINT AS Affected_Files,
       ${lostExpr}::BIGINT AS Absorbed_Remaining`,
  );
  return result.rows;
}

/**
 * builtin:xml_import_integrity_details — Objekt-Merkmale der KOLLIDIERENDEN Objekte
 * je Dup-UUID für die Detail-Aufklappung der „Import-
 * Integrität"-Card. Liest die P1-Tabelle `DuplicateAbsorptionDetails` (Typ + Name je
 * kollidierendem Vorkommen). Aktuell befüllt für ScriptCatalog (benannte Objekte, die
 * still verschwinden); weitere Kataloge folgen. Leere Liste = keine Detail-Objekte
 * (kein Verlust, oder nur Kataloge ohne Detail-Erfassung wie StepsForScripts).
 *
 * NULL-sicher / Alt-DB-fest: fehlt die Tabelle (Alt-DB ohne die Erweiterung), `[]`
 * zurückgeben statt zu crashen — analog `builtin:xml_import_integrity`.
 */
async function builtinXmlImportIntegrityDetails(ctx, params = {}) {
  const target = contextSolutionParam(params);
  if (target && target !== require('../config/solutions').getActiveSolutionId()) return [];
  const present = await db.executeQuery(
    ctx,
    `SELECT COUNT(*) AS cnt FROM information_schema.tables
      WHERE table_name = 'DuplicateAbsorptionDetails'`,
  );
  const row = present.rows[0];
  const cnt = typeof row.cnt === 'bigint' ? Number(row.cnt) : row.cnt;
  if (cnt < 1) return [];
  const result = await db.executeQuery(
    ctx,
    `SELECT Catalog, File_Name, Object_UUID, Object_Name, Object_Type,
            Occurrence_Seq::BIGINT AS Occurrence_Seq
       FROM DuplicateAbsorptionDetails
      ORDER BY File_Name, Catalog, Object_UUID, Occurrence_Seq`,
  );
  return result.rows;
}

/**
 * builtin:docset_functions_with_counts — wie docset_functions, aber annotiert
 * jede Funktion mit `code_ref_count`. Bei references: false → null.
 */
async function builtinDocsetFunctionsWithCounts(ctx, params = {}) {
  const docsSource = require('./docs-source');
  const docsReferences = require('./docs-references');
  const docset = params.docset;
  const category = params.category;
  if (!docset || !category) {
    throw createError('VALIDATION_ERROR', 'builtin:docset_functions_with_counts requires params "docset" and "category"');
  }
  const lang = params._lang || params.lang || 'en';
  const fns = await docsSource.listDocsetFunctions(ctx, docset, category, lang);
  return docsReferences.annotateFunctionsWithCounts(ctx, docset, fns);
}

/**
 * builtin:list_tests — Analysis Tests für die /tests-Leitseite. Liefert die
 * List-Antwort inkl. folder/tier/testType/keywords + Validierungsstatus.
 * Lazy require: tests.service importiert diesen Service (kein Top-Level-Zyklus).
 */
async function builtinListTests(params = {}) {
  const testsService = require('./tests.service');
  const lang = params._lang || params.lang || 'en';
  // Localise before filtering: `q` must search the displayed texts.
  const all = (await testsService.listTests()).map(t => testsService.localizeTest(t, lang));
  const filtered = testsService.filterTests(all, {
    objectType: params.objectType,
    testType: params.testType,
    scope: params.scope,
    keyword: params.keyword,
    q: params.q,
    folder: params.folder,
  });
  const rows = await Promise.all(filtered.map(async t => ({
    id: t.id,
    title: t.definition.title,
    description: t.definition.description || null,
    test_type: t.definition.testType,
    keywords: (t.definition.keywords || []).join(', '),
    object_types: (t.definition.objectTypes || []).join(', '),
    scopes: (t.definition.scopes || []).join(', '),
    member_count: (t.definition.members || []).length,
    folder: t.folder || null,
    folder_label: await testsService.resolveFolderLabel(t.folder, lang),
    tier: t.tier,
    // Pflege-Metadaten der Kachel — technisch ('_'-Präfix). Die Detailseite
    // (builtin:test_detail) zeigt den Validierungsstatus prominent; in der
    // Übersicht trägt er nur den Kachel-Zustand und würde sonst jede Suche
    // nach "ok"/"false" auf alle Zeilen ausweiten.
    _overrides_system: t.overridesSystem === true,
    _validation_status: t.validation.status,
    _validation_warnings: t.validation.warnings.length,
    _validation_errors: t.validation.errors.length,
  })));
  rows.sort((a, b) => String(a.title).localeCompare(String(b.title), lang));
  return rows;
}

/**
 * builtin:list_test_folders — die Kategorie-Ordner der Tests-Tiers für die
 * Ordner-Navigation der Übersichtsseite. Gleiche Zeilenform wie
 * `list_dashboard_folders` (das ist der Vertrag, den die TileGrid-Ordner-
 * Navigation liest): eine Zeile je Ordner inkl. Zwischenebenen, mit
 * lokalisiertem Label des EIGENEN Segments, Icon, Description, order
 * (folder.json) und den Zählern
 *   direct_count = Tests direkt im Ordner, total_count = inkl. Teilbaum.
 *
 * Gezählt wird über beide Tiers hinweg (`templates/tests` + `tests-custom`) —
 * der Ordnerpfad ist der Schlüssel, ein in beiden Tiers vorhandener Pfad ist
 * EINE Rubrik. Die Anzeigedaten kommen aus `loadFolderMeta`, das seinerseits
 * schon tierübergreifend auflöst.
 */
async function builtinListTestFolders(params = {}) {
  const testsService = require('./tests.service');
  const lang = params._lang || params.lang || 'en';
  const all = await testsService.listTests();

  // Alle Ordner-Pfade (inkl. Zwischenebenen) + Zähler aufsammeln.
  const folders = new Map(); // path → { direct, total }
  const ensure = p => {
    if (!folders.has(p)) folders.set(p, { direct: 0, total: 0 });
    return folders.get(p);
  };
  for (const t of all) {
    if (!t.folder) continue;
    const segs = String(t.folder).split('/');
    let prefix = '';
    for (let i = 0; i < segs.length; i++) {
      prefix = prefix ? `${prefix}/${segs[i]}` : segs[i];
      const node = ensure(prefix);
      node.total += 1;
      if (i === segs.length - 1) node.direct += 1;
    }
  }

  const rows = await Promise.all([...folders.entries()].map(async ([folderPath, counts]) => {
    const meta = await testsService.loadFolderMeta(folderPath);
    const seg = folderPath.split('/').pop();
    const label = (meta?.locales && meta.locales[lang]) || meta?.title || humanizeFolderSegment(seg);
    const parent = folderPath.includes('/') ? folderPath.slice(0, folderPath.lastIndexOf('/')) : null;
    return {
      path: folderPath,
      parent,
      label,
      // Voll lokalisierter Pfad (für die flache Trefferansicht der Suche).
      path_label: await testsService.resolveFolderLabel(folderPath, lang),
      icon: meta?.icon || null,
      description: meta?.description || null,
      order: Number.isFinite(meta?.order) ? meta.order : null,
      direct_count: counts.direct,
      total_count: counts.total,
    };
  }));

  // Sortierung je Ebene: order (fehlend = hinten), dann Label.
  rows.sort((a, b) => {
    const depth = a.path.split('/').length - b.path.split('/').length;
    if (depth !== 0) return depth;
    const ao = a.order ?? Number.MAX_SAFE_INTEGER;
    const bo = b.order ?? Number.MAX_SAFE_INTEGER;
    if (ao !== bo) return ao - bo;
    return String(a.label).localeCompare(String(b.label), lang);
  });
  return rows;
}

// ---------------------------------------------------------------------------
// Test-Detailansicht (`/tests/:id` → Bundle `test_detail`)
//
// Drei Projektionen derselben Quelle wie `GET /api/tests/:id`: Kopfdaten,
// Member-Liste und Profile. Die Member-Auflösung kommt aus
// `tests.service.resolveMemberSummary` — es gibt keinen zweiten Auflösungsweg.
// Bewusst KEINE eigenen SQL-Dateien: der `:param`-Präprozessor der API würde
// jedes `:wort` nullen, Builtin-Resolver bekommen die Params direkt.
// ---------------------------------------------------------------------------

/**
 * Lädt einen Test, ohne zu werfen — eine unbekannte ID darf nicht den ganzen
 * Bundle-Load kippen, sondern muss als Guard-Zeile (`not_found`) ankommen.
 */
async function loadTestForDetail(id) {
  if (!id) return null;
  const testsService = require('./tests.service');
  try {
    return await testsService.getTest(String(id));
  } catch {
    return null;
  }
}

/** Der Original-Eintrag eines Members: Regel-Dashboard bzw. Custom Query. */
function memberTargetPath(member) {
  if (!member.resolved) return '';
  return member.kind === 'dashboard'
    ? `/dashboard/${encodeURIComponent(member.ref)}`
    : `/query/${encodeURIComponent(member.ref)}`;
}

/**
 * builtin:test_detail — genau EINE Zeile mit den Kopfdaten eines Tests; bei
 * unbekannter ID eine Guard-Zeile mit `not_found: true`.
 */
async function builtinTestDetail(params = {}) {
  const testsService = require('./tests.service');
  const lang = params._lang || params.lang || 'en';
  const id = params.id;
  const test = testsService.localizeTest(await loadTestForDetail(id), lang);
  if (!test) {
    return [{ not_found: true, id: id ? String(id) : null, title: null }];
  }
  const def = test.definition;
  const members = await Promise.all(def.members.map(m => testsService.resolveMemberSummary(m, lang)));
  return [{
    not_found: false,
    id: test.id,
    title: def.title,
    description: def.description || null,
    test_type: def.testType,
    keywords: (def.keywords || []).join(', '),
    object_types: (def.objectTypes || []).join(', '),
    scopes: (def.scopes || []).join(' · '),
    outputs: (def.outputs || []).join(' · '),
    member_count: def.members.length,
    profile_count: (def.profiles || []).length,
    unresolved_count: members.filter(m => !m.resolved).length,
    folder: test.folder || null,
    folder_label: await testsService.resolveFolderLabel(test.folder, lang),
    tier: test.tier,
    overrides_system: test.overridesSystem === true,
    version: def.version || null,
    validation_status: test.validation.status,
    validation_errors: test.validation.errors.length,
    validation_warnings: test.validation.warnings.length,
    // Kopiervorlage für den Skill-Aufruf — der häufigste Grund, diese Seite
    // per Deep-Link zu öffnen.
    skill_call: `/fm-test ${test.id}`,
  }];
}

/**
 * builtin:test_members — eine Zeile je Member, in Ausführungsreihenfolge.
 * `target_path` ist der fertige App-Pfad des Original-Eintrags (leer bei nicht
 * auflösbarem Member → Zeilenklick läuft ins Leere statt ins Nichts).
 */
async function builtinTestMembers(params = {}) {
  const testsService = require('./tests.service');
  const lang = params._lang || params.lang || 'en';
  const test = testsService.localizeTest(await loadTestForDetail(params.id), lang);
  if (!test) return [];
  const def = test.definition;
  const members = await Promise.all(def.members.map(m => testsService.resolveMemberSummary(m, lang)));
  // Welche Profile enthalten diesen Member? Profile ohne `members`-Feld sind
  // die Vollprüfung und enthalten damit jeden Member.
  const profilesByRef = new Map();
  for (const p of def.profiles || []) {
    const refs = p.members || def.members.map(m => m.ref);
    for (const ref of refs) {
      if (!profilesByRef.has(ref)) profilesByRef.set(ref, []);
      profilesByRef.get(ref).push(p.id);
    }
  }
  return Promise.all(members.map(async (m, i) => ({
    index: i + 1,
    kind: m.kind,
    ref: m.ref,
    title: m.resolved ? (m.title || m.ref) : m.ref,
    icon: m.icon || null,
    severity: m.severity || null,
    // Rubrik = der Ort, an dem der Eintrag in seiner eigenen Übersicht steht:
    // Ordnerpfad des Dashboards bzw. Kategorie der Custom Query.
    rubric: m.resolved
      ? (m.kind === 'dashboard'
        ? await resolveFolderLabel(m.folder, lang)
        : (m.category || null))
      : null,
    resolved: m.resolved === true,
    default_result_meaning: (m.analysis && m.analysis.defaultResult
      && m.analysis.defaultResult.meaning) || null,
    profiles: (profilesByRef.get(m.ref) || []).join(', '),
    target_path: memberTargetPath(m),
  })));
}

/**
 * builtin:test_profiles — eine Zeile je deklariertem Profil. Ohne
 * `members`-Feld ist das Profil die Vollprüfung (`is_full`).
 */
async function builtinTestProfiles(params = {}) {
  const testsService = require('./tests.service');
  const lang = params._lang || params.lang || 'en';
  const test = testsService.localizeTest(await loadTestForDetail(params.id), lang);
  if (!test) return [];
  const def = test.definition;
  if (!(def.profiles || []).length) return [];
  const members = await Promise.all(def.members.map(m => testsService.resolveMemberSummary(m, lang)));
  const titleByRef = new Map(members.map(m => [m.ref, m.resolved ? (m.title || m.ref) : m.ref]));
  return (def.profiles || []).map(p => {
    const refs = p.members || def.members.map(m => m.ref);
    return {
      profile_id: p.id,
      title: p.title,
      description: p.description || null,
      member_count: refs.length,
      total_member_count: def.members.length,
      scope_label: `${refs.length}/${def.members.length}`,
      is_full: !p.members,
      member_refs: refs.join(', '),
      member_titles: refs.map(r => titleByRef.get(r) || r).join(' · '),
    };
  });
}

/**
 * builtin:test_issues — eine Zeile je Validierungsbefund (M1–M7). Speist die
 * Warn-Karte der Detailansicht; leer = Test ist sauber.
 */
async function builtinTestIssues(params = {}) {
  const test = await loadTestForDetail(params.id);
  if (!test) return [];
  return [
    ...test.validation.errors.map(e => ({ level: 'error', rule: e.rule, message: e.message })),
    ...test.validation.warnings.map(w => ({ level: 'warning', rule: w.rule, message: w.message })),
  ];
}

// ---------------------------------------------------------------------------
// Results-Layer-Builtins (Result Envelope v1) — machen konsolidierte
// Ergebnisse Bundle-fähig (Healthchecks/Root-Dashboards). Alle drei lesen
// AUSSCHLIESSLICH den Server-Ergebnis-Cache — sie führen beim Bundle-Load
// nie SQL-Läufe aus; nicht Gelaufenes erscheint als `pending`, der Lauf wird
// explizit getriggert (POST /api/results/run).
// Lazy require: results.service nutzt diesen Service (kein Top-Level-Zyklus).
// ---------------------------------------------------------------------------

/**
 * builtin:results_registry — eine Zeile je ergebnisfähiger Einheit
 * (ref_kind, ref_id, rubric, title, severity, unit, source). Werkzeug für
 * Coverage-Dashboards und den künftigen Test-Editor.
 */
async function builtinResultsRegistry(ctx, params = {}) {
  const resultsService = require('./results.service');
  const kinds = params.kinds
    ? String(params.kinds).split(',').map(s => s.trim()).filter(Boolean)
    : undefined;
  const rows = await resultsService.listRegistry({ kinds });
  return rows.map(r => ({
    ref_kind: r.ref.kind,
    ref_id: r.ref.id,
    rubric: r.rubric,
    title: r.title,
    icon: r.icon,
    severity: r.severity,
    unit: r.unit,
    name: r.name,
    meaning: r.meaning,
    source: r.source,
    has_declaration: true,
  }));
}

/**
 * builtin:results_aggregate — Konsolidierungs-Knoten über die Ordner-
 * Hierarchie (Param `root`, leer = gesamt; alternativ `roots` als Komma-
 * Liste mehrerer Teilbäume — dann ist der ''-Knoten das kombinierte
 * Seiten-Aggregat). counts je Zustand + worst + unit-reine Summen +
 * covered/declared/total (Teilabdeckung sichtbar).
 */
async function builtinResultsAggregate(ctx, params = {}) {
  const resultsService = require('./results.service');
  const kinds = params.kinds
    ? String(params.kinds).split(',').map(s => s.trim()).filter(Boolean)
    : undefined;
  const { nodes } = await resultsService.aggregate(ctx, {
    root: params.root ? String(params.root) : '',
    roots: params.roots ? String(params.roots) : undefined,
    kinds,
  });
  return nodes.map(n => ({
    path: n.path,
    worst: n.worst,
    ok: n.counts.ok,
    warning: n.counts.warning,
    error: n.counts.error,
    neutral: n.counts.neutral,
    failed: n.counts.failed,
    pending: n.counts.pending,
    findings_sum: n.sums.findings ?? null,
    covered: n.covered,
    declared: n.declared,
    total: n.total,
    // Display convenience for KPI strips ("run: 3/96") — counts stay numeric.
    coverage: `${n.covered}/${n.total}`,
  }));
}

/**
 * builtin:results_list — flache Envelope-Liste eines Teilbaums
 * (Params `root` bzw. `roots` als Komma-Liste, `state`, `kinds`, `limit`).
 * Mit `open_target` für openDashboard/runQuery-Links; `pending`-Einheiten
 * erscheinen sichtbar mit.
 */
async function builtinResultsList(ctx, params = {}) {
  const resultsService = require('./results.service');
  const kinds = params.kinds
    ? String(params.kinds).split(',').map(s => s.trim()).filter(Boolean)
    : undefined;
  const { results } = await resultsService.getSummary(ctx, { kinds });
  const root = params.root ? String(params.root) : '';
  // `roots` (comma-separated) filters over several subtrees; wins over `root`.
  const rootList = params.roots
    ? String(params.roots).split(',').map(s => s.trim()).filter(Boolean)
    : (root ? [root] : []);
  const states = params.state
    ? new Set(String(params.state).split(',').map(s => s.trim()).filter(Boolean))
    : null;
  const out = [];
  for (const envelope of Object.values(results)) {
    const rubric = envelope.rubric || '';
    if (rootList.length && !rootList.some(r => rubric === r || rubric.startsWith(`${r}/`))) continue;
    const state = envelope.runStatus === 'ran' ? envelope.resultState
      : envelope.runStatus === 'failed' ? 'failed' : 'pending';
    if (states && !states.has(state)) continue;
    out.push({
      // Herkunfts-Plumbing: je Karte konstant ('dashboard'/'defaultResult') —
      // ohne '_'-Präfix träfe die Suche nach "dashboard" jede Zeile der Karte.
      // `ref_id` und `rubric` bleiben durchsuchbar: das sind die fachlichen
      // Bezeichner, über die man einen Eintrag tatsächlich sucht.
      _ref_kind: envelope.ref.kind,
      ref_id: envelope.ref.id,
      rubric: envelope.rubric,
      title: envelope.title,
      state,
      run_status: envelope.runStatus,
      result_state: envelope.resultState,
      value: envelope.value,
      unit: envelope.unit,
      meaning: envelope.meaning,
      severity: envelope.severity,
      _source: envelope.source,
      // '_'-Präfix = technisches Feld: Navigationsziel, keine Anzeige und
      // nicht Teil der Zeilensuche (siehe _useRowSearch).
      _open_target: envelope.ref.kind === 'dashboard' ? `/dashboard/${envelope.ref.id}`
        : envelope.ref.kind === 'query' ? `/query/${envelope.ref.id}`
          : `/tests/${envelope.ref.id}`,
    });
  }
  const rank = { error: 0, warning: 1, failed: 2, neutral: 3, ok: 4, pending: 5 };
  out.sort((a, b) => (rank[a.state] ?? 9) - (rank[b.state] ?? 9)
    || (Number(b.value) || 0) - (Number(a.value) || 0)
    || String(a.title).localeCompare(String(b.title)));
  const limit = Number(params.limit);
  return Number.isFinite(limit) && limit > 0 ? out.slice(0, limit) : out;
}

// builtin:api_sets_list — verfügbare API-Filter-Sets (Install-Verzeichnis +
// Bundle `api-sets/`), Labels je Sprache lokalisiert. Speist das Set-Dropdown.
async function builtinApiSetsList(params = {}) {
  const lang = params._lang || params.lang || 'en';
  const bundleDir = await findBundleDir('external_apis');
  const dirs = [API_SETS_INSTALL_DIR];              // Install-Verzeichnis gewinnt
  if (bundleDir) dirs.push(path.join(bundleDir, 'api-sets'));
  const byId = new Map();
  for (const dir of dirs) {
    let entries;
    try { entries = await fs.readdir(dir); } catch { continue; }
    for (const name of entries) {
      if (!name.endsWith('.json')) continue;
      const id = name.slice(0, -5);
      if (byId.has(id)) continue;                   // bereits aus Override-Dir geladen
      try {
        const set = JSON.parse(await fs.readFile(path.join(dir, name), 'utf-8'));
        const label = (set.locales && set.locales[lang]) || set.label || id;
        byId.set(id, { id, label });
      } catch { /* defekte Set-Datei überspringen */ }
    }
  }
  const rows = [...byId.values()];
  rows.sort((a, b) =>
    a.id === 'generic' ? -1 : b.id === 'generic' ? 1 : String(a.label).localeCompare(String(b.label)));
  return rows;
}

const BUILTIN_RESOLVERS = {
  api_sets_list: (_ctx, params) => builtinApiSetsList(params),
  list_custom_queries: (_ctx, params) => builtinListCustomQueries(params),
  list_dashboards: (_ctx, params) => builtinListDashboards(params),
  list_dashboard_folders: (_ctx, params) => builtinListDashboardFolders(params),
  results_registry: builtinResultsRegistry,
  results_aggregate: builtinResultsAggregate,
  results_list: builtinResultsList,
  list_tests: (_ctx, params) => builtinListTests(params),
  list_test_folders: (_ctx, params) => builtinListTestFolders(params),
  test_detail: (_ctx, params) => builtinTestDetail(params),
  test_members: (_ctx, params) => builtinTestMembers(params),
  test_profiles: (_ctx, params) => builtinTestProfiles(params),
  test_issues: (_ctx, params) => builtinTestIssues(params),
  list_docs: (_ctx, params) => builtinListDocs(params),
  docs_overview_installed: (_ctx, params) => builtinDocsOverviewInstalled(params),
  docs_overview_available: (_ctx, params) => builtinDocsOverviewAvailable(params),
  files: builtinFiles,
  query_meta: (_ctx, params) => builtinQueryMeta(params),
  docset_info: (_ctx, params) => builtinDocsetInfo(params),
  docset_start_entry: builtinDocsetStartEntry,
  docset_categories: builtinDocsetCategories,
  docset_categories_with_counts: builtinDocsetCategoriesWithCounts,
  docset_category_info: builtinDocsetCategoryInfo,
  docset_functions: builtinDocsetFunctions,
  docset_functions_with_counts: builtinDocsetFunctionsWithCounts,
  xml_directory_status: builtinXmlDirectoryStatus,
  xml_directory_listing: (_ctx, params) => builtinXmlDirectoryListing(params),
  file_source_size: (_ctx, params) => builtinFileSourceSize(params),
  xml_directory_meta: builtinXmlDirectoryMeta,
  xml_last_run: builtinXmlLastRun,
  xml_semantic_names: builtinXmlSemanticNames,
  xml_import_integrity: builtinXmlImportIntegrity,
  xml_import_integrity_details: builtinXmlImportIntegrityDetails,
  cluster_count: builtinClusterCount,
};

async function runBuiltin(ctx, key, params) {
  const resolver = BUILTIN_RESOLVERS[key];
  if (!resolver) {
    throw createError('VALIDATION_ERROR', `Unknown builtin dataset: ${key}`, { key });
  }
  const data = await resolver(ctx, params);
  return { data: convertBigInts(data), meta: { source: `builtin:${key}` } };
}

// ---------------------------------------------------------------------------
// Dataset-Ausführung mit Parameter-Merging
// ---------------------------------------------------------------------------

/**
 * Führt ein einzelnes Dataset aus.
 * - manifest.datasets[].params definieren Defaults pro Dataset
 * - requestParams (dashboard-weite Params aus der HTTP-Query) überschreiben
 */
async function executeDataset(ctx, bundle, datasetSpec, requestParams = {}) {
  const params = { ...(datasetSpec.params || {}), ...requestParams };
  // Token-Substitution in der Source-URI: erlaubt z.B. "custom:{{query}}" im Manifest,
  // damit das `_generic`-Bundle das eigentliche Template per Param wählt.
  const resolvedSource = String(datasetSpec.source).replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (m, key) => {
    return params[key] != null ? String(params[key]) : '';
  });
  const { scheme, ref } = parseSourceUri(resolvedSource);
  if (!ref || ref === '{{}}' || ref.trim() === '') {
    throw createError('VALIDATION_ERROR', `Dataset source '${datasetSpec.source}' has empty reference after substitution`);
  }

  switch (scheme) {
    case 'bundle':
      return runBundleQuery(ctx, bundle, ref, params);
    case 'custom':
      return runCustomTemplate(ctx, ref, params);
    case 'report':
      return runReportTemplate(ctx, ref, params);
    case 'builtin':
      return runBuiltin(ctx, ref, params);
    default:
      throw createError('VALIDATION_ERROR', `Unknown dataset scheme: ${scheme}`);
  }
}

/**
 * DuckDB meldet dies (englisch, locale-unabhängig), wenn ein Dataset auf eine
 * Katalog-Tabelle/-View zugreift, die erst nach einem XML-Import entsteht. Auf
 * leerem Katalog heißt das „noch nichts importiert" — kein echter Fehler.
 */
function isNoImportError(message) {
  return typeof message === 'string' && /Table with name\s+\S+\s+does not exist/i.test(message);
}

/**
 * True, wenn noch keine FileMaker-Lösung importiert wurde. Die Kern-Kataloge
 * werden auf frischer DB leer gestubbt (config/database `ensureCoreStubs`),
 * daher ist dieses COUNT immer sicher; ein unerwarteter Fehler fällt bewusst
 * auf „nicht leer" zurück, damit wir nie einen echten Fehler hinter dem
 * Leerzustand verstecken.
 */
async function isCatalogEmpty(ctx) {
  try {
    const r = await db.executeQuery(ctx, 'SELECT COUNT(*) AS n FROM FilesCatalog');
    return Number(r.rows?.[0]?.n) === 0;
  } catch {
    return false;
  }
}

/**
 * Führt alle Datasets eines Bundles parallel aus. Einzel-Fehler werden pro
 * Dataset gekapselt. Zusätzlich wird der Leerzustand ausgewiesen: Ist der
 * Katalog leer (kein Import), werden „table does not exist"-Fehler NICHT als
 * roter Fehler durchgereicht, sondern als Leerzustand markiert (`emptyReason:
 * 'no_import'`) — einzelne Karten zeigen dann „Noch keine Daten.", und der
 * DashboardHost schaltet die ganze Seite auf die neutrale NoDataYet-Karte.
 * Echte Template-Bugs auf gefülltem Katalog bleiben laute Fehler.
 */
async function executeAllDatasets(ctx, bundle, requestParams = {}) {
  const specs = bundle.manifest.datasets || [];
  const catalogEmpty = await isCatalogEmpty(ctx);
  const results = await Promise.all(
    specs.map(async spec => {
      try {
        const { data, meta } = await executeDataset(ctx, bundle, spec, requestParams);
        return { id: spec.id, data, meta, error: null };
      } catch (err) {
        if (catalogEmpty && isNoImportError(err.message)) {
          return { id: spec.id, data: [], meta: { source: spec.source }, error: null, emptyReason: 'no_import' };
        }
        console.warn(`[dashboard:${bundle.id}] dataset '${spec.id}' failed: ${err.message}`);
        return { id: spec.id, data: [], meta: { source: spec.source }, error: err.message };
      }
    })
  );

  const datasets = {};
  for (const r of results) {
    datasets[r.id] = {
      data: r.data,
      meta: r.meta,
      ...(r.error ? { error: r.error } : {}),
      ...(r.emptyReason ? { emptyReason: r.emptyReason } : {}),
    };
  }
  return { datasets, catalogEmpty };
}

/**
 * Führt ein einzelnes Dataset aus (für Lazy-Reload).
 */
async function executeSingleDataset(ctx, bundle, datasetId, requestParams = {}) {
  const spec = (bundle.manifest.datasets || []).find(d => d.id === datasetId);
  if (!spec) {
    throw createError('TEMPLATE_NOT_FOUND', `Dataset '${datasetId}' not found in dashboard '${bundle.id}'`, {
      bundleId: bundle.id,
      datasetId,
    });
  }
  return executeDataset(ctx, bundle, spec, requestParams);
}

module.exports = {
  DASHBOARDS_DIRS,
  listBundles,
  getBundle,
  resolveFolderCrumbs,
  resolveFolderLabel,
  executeAllDatasets,
  executeSingleDataset,
  clearCache,
};
