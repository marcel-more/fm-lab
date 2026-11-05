const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const Joi = require('joi');
const environment = require('../config/environment');
const { createError } = require('../middleware/error-handler');
const db = require('../config/database');
const templateService = require('./template.service');
const queryDiscovery = require('./query-discovery');
const dashboardInventory = require('./dashboard-inventory');
const paging = require('./paging.service');
const dashboardI18nService = require('./dashboard-i18n.service');
const { schemas: dashboardSchemas } = require('./dashboard-schemas');
const { SCOPES, OUTPUT_TYPES, schemas: testsSchemas } = require('./tests-schemas');
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
 * Lädt Dashboards aus drei Bereichsverzeichnissen (DASHBOARD_SOURCES) in zwei
 * Bauformen (`unit`):
 *   bundle  Ordner mit manifest.json + layout.json + data/*.sql + style.css + assets/*
 *   file    eine `.sql`-Datei mit `-- @`-Kopf direkt in einem Gruppierungsordner
 *           (oder auf Bereichsebene von dashboards-custom/ bzw. -community/);
 *           Manifest abgeleitet aus dem Kopf (deriveFileManifest), Darstellung
 *           über das Layout von `_generic`. Nie auf oberster Ebene von
 *           dashboards/, nie innerhalb eines Bundles.
 * Bundle-IDs und Datei-Einheiten teilen einen Namensraum. Jedes Dashboard trägt
 * einen Bereich (`area`) und einen Ordner-Pfad (`folder` — zugleich die Rubrik
 * im Results-Layer):
 *
 *   area       Ablage                        folder
 *   system     dashboards/system/**          null
 *   module     dashboards/modules/**         null
 *   builtin    dashboards/<rest>             Eltern-Pfad relativ zu dashboards/
 *   custom     dashboards-custom/**          custom[/<Eltern-Pfad>]
 *   community  dashboards-community/**       community[/<Eltern-Pfad>]
 *
 * system/ und modules/ sind reine Ablage-Gruppierung und tauchen nie als
 * Ordner-Pfad auf. Custom und Community bekommen ein virtuelles Präfix — es
 * erscheint in Übersicht und Breadcrumb als Zwischenebene „Custom“/„Community“
 * und hält die Bereiche aus dem Ordner-Namensraum der mitgelieferten Inhalte heraus.
 *
 * ID-Kollisionen: Custom überschreibt nur builtin-Dashboards (`overrides: true`);
 * eine Kollision mit system/module sowie jede Community-Kollision wird verworfen.
 * Eine Datei-Einheit, die wie ein internes Template (queries/system,
 * queries/modules) heißt, wird verworfen — `custom:<name>` löst Datei-Einheiten
 * vor den Modul-Templates auf, sie würde ein UI-Template kapern.
 *
 * Alter Ablageort eigener Queries: `sql-custom/` (LEGACY_SOURCE) wird read-only
 * als Datei-Einheiten des Bereichs custom mit `legacy: true` gelesen — nur
 * Namen, die weder das Dashboard- noch das Query-Inventar kennt; Altkopien
 * mitgelieferter Queries werden so nie zu Overrides.
 *
 * Dataset-Quellen (manifest.datasets[].source):
 *   bundle:<rel-path>       → SQL im selben Bundle (data/*.sql)
 *   custom:<template-name>  → Datei-Einheit, sonst Modul-Template, sonst Bundle-Query
 *   report:<template-name>  → internes Template aus queries/system/
 *   builtin:<key>           → server-bereitgestellte Quelle (list_dashboards, query_meta, files, …)
 */

// Bundle-Quellen in Rang-Reihenfolge der Override-Regel (s. buildDiscovery).
// `prefix` = virtuelles erstes Ordner-Segment des Bereichs; die ausgelieferte
// Quelle (prefix null) leitet den Bereich aus dem ersten Pfadsegment ab.
const DASHBOARD_SOURCES = [
  { key: 'custom', base: environment.templates.dashboardsCustomDir, area: 'custom', prefix: 'custom' },
  { key: 'shipped', base: environment.templates.dashboardsDir, area: null, prefix: null },
  { key: 'community', base: environment.templates.dashboardsCommunityDir, area: 'community', prefix: 'community' },
];
const SHIPPED_SOURCE = DASHBOARD_SOURCES.find(s => s.key === 'shipped');

// Alter Ablageort eigener Queries (nur Dateien der obersten Ebene). Rang nach
// custom, vor shipped — aber nur für Namen außerhalb beider Inventare.
const LEGACY_SOURCE = {
  key: 'legacy',
  base: environment.templates.queriesLegacyDir,
  area: 'custom',
  prefix: 'custom',
  legacy: true,
  flat: true,
};

// Das Bundle, dessen Layout jede Datei-Einheit rendert.
const GENERIC_BUNDLE_ID = '_generic';

// Bereiche, deren Dashboards als mitgeliefert gesperrt sind (manifest.locked).
const LOCKED_AREAS = new Set(['builtin', 'system', 'module']);

// Ablage-Gruppierungsordner in dashboards/ → Bereich ihrer Bundles.
const SHIPPED_GROUP_AREAS = { system: 'system', modules: 'module' };

// Reservierte Namen auf oberster Ebene von dashboards/: die Gruppierungsordner
// und die virtuellen Bereichs-Präfixe (ein Ordner `custom/` würde sonst die
// Zwischenebene des Nutzer-Bereichs verdecken).
const RESERVED_TOP_LEVEL = new Set([
  ...Object.keys(SHIPPED_GROUP_AREAS),
  ...DASHBOARD_SOURCES.map(s => s.prefix).filter(Boolean),
]);

// Inhaltsbereiche: in der Übersicht gelistet (Default des `areas`-Parameters)
// und favorisierbar. system/module erreicht man über die Hauptnavigation.
const CONTENT_AREAS = ['builtin', 'custom', 'community'];

function isFavoritableArea(area) {
  return CONTENT_AREAS.includes(area);
}

// Discovery-Cache: ID → { manifest, layout, dir, area, folder, overrides, mtime }
const bundleCache = new LRUCache({
  max: 50,
  ttl: 1000 * 60 * 60, // 1h
  updateAgeOnGet: true,
});

// Max. Ordner-Tiefe für die rekursive Bundle-Discovery (Baum ≤4).
const MAX_FOLDER_DEPTH = 4;

// Discovery-Map: id → { id, dir, file?, base, area, folder, overrides, legacy, unit }. Einmalig pro Cache-Generation
// aufgebaut (gemeinsame Promise → kein paralleler Doppel-Scan) und in clearCache
// invalidiert. So bleibt findBundleDir O(1) statt pro Lookup den Baum zu scannen.
// Spätestens nach DISCOVERY_TTL_MS wird neu gescannt: ein abgelegtes Dashboard
// (v. a. eine einzelne .sql-Datei) erscheint ohne Reload.
const DISCOVERY_TTL_MS = 2000;
let discoveryPromise = null;
let discoveryBuiltAt = 0;

// Folder-Metadaten-Cache (folder.json je Ordner): folderPath → { mtime, title, locales }.
// Trägt die lokalisierten Ordner-Anzeigenamen für die Übersicht (Datenschicht mit
// Fallback: locales[lang] → title → humanisiertes Segment). mtime-invalidiert.
const folderMetaCache = new Map();

// Warnungen des Discovery-Scans einmal je Text — der Scan läuft nach der TTL
// erneut und soll dieselbe Kollision nicht wiederholt melden.
const discoveryWarned = new Set();
function warnDiscovery(message) {
  if (discoveryWarned.has(message)) return;
  discoveryWarned.add(message);
  console.warn(message);
}

function clearCache() {
  bundleCache.clear();
  discoveryPromise = null;
  discoveryBuiltAt = 0;
  folderMetaCache.clear();
  discoveryWarned.clear();
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
 * Bereich und Ordner-Pfad eines Bundles aus seiner Quelle und dem relativen
 * Eltern-Pfad (`relDir`, '' an der Wurzel). Siehe Tabelle im Kopf der Datei.
 */
function classifyBundle(source, relDir) {
  if (source.prefix) {
    return { area: source.area, folder: relDir ? `${source.prefix}/${relDir}` : source.prefix };
  }
  const groupArea = relDir ? SHIPPED_GROUP_AREAS[relDir.split('/')[0]] : null;
  if (groupArea) return { area: groupArea, folder: null };
  return { area: 'builtin', folder: relDir || null };
}

/**
 * Rekursiver Verzeichnis-Walk: sammelt alle Bundle-Verzeichnisse (= Ordner mit
 * `manifest.json`) und Datei-Einheiten (`*.sql`) unter `source.base` bis Tiefe
 * MAX_FOLDER_DEPTH. Ein Bundle-Ordner wird NICHT weiter durchsucht (Bundles
 * verschachteln nicht, ihre data/- und queries/-Dateien sind keine Einheiten).
 * Die reservierten Namen auf oberster Ebene von dashboards/ sind nie Bundles:
 * Gruppierungsordner werden durchsucht, virtuelle Präfix-Namen übersprungen;
 * `.sql`-Dateien auf dieser Ebene sind nicht erlaubt. Eine flache Quelle
 * (LEGACY_SOURCE) liefert nur die Dateien ihrer obersten Ebene.
 */
async function walkBundleDir(source, relDir, depth, out) {
  const absDir = path.join(source.base, relDir);
  let entries;
  try {
    entries = await fs.readdir(absDir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT' || err.code === 'ENOTDIR') return;
    throw err;
  }
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    if (e.isFile() && e.name.endsWith('.sql')) {
      const fileAbs = path.join(absDir, e.name);
      if (source === SHIPPED_SOURCE && !relDir) {
        warnDiscovery(`[dashboard] "${fileAbs}" — single-file dashboards are not allowed on the top level of dashboards/, skipped`);
        continue;
      }
      const id = e.name.slice(0, -4);
      if (!isValidBundleId(id)) {
        warnDiscovery(`[dashboard] "${fileAbs}" — invalid dashboard id (allowed: letters, digits, _ and -), skipped`);
        continue;
      }
      out.push({
        id, dir: absDir, file: fileAbs, base: source.base, ...classifyBundle(source, relDir),
        overrides: false, legacy: source.legacy === true, unit: 'file', depth,
      });
      continue;
    }
    if (!e.isDirectory() || source.flat) continue;
    const childRel = relDir ? `${relDir}/${e.name}` : e.name;
    const childAbs = path.join(source.base, childRel);
    if (source === SHIPPED_SOURCE && !relDir && RESERVED_TOP_LEVEL.has(e.name)) {
      if (SHIPPED_GROUP_AREAS[e.name]) {
        await walkBundleDir(source, childRel, depth + 1, out);
      } else {
        warnDiscovery(`[dashboard] "${childAbs}" uses the reserved folder name "${e.name}" — skipped`);
      }
      continue;
    }
    let isBundle = false;
    try {
      isBundle = (await fs.stat(path.join(childAbs, 'manifest.json'))).isFile();
    } catch {
      // kein manifest.json → entweder Kategorie-Ordner oder Bundle-Unterordner
    }
    if (isBundle) {
      out.push({
        id: e.name, dir: childAbs, base: source.base, ...classifyBundle(source, relDir),
        overrides: false, legacy: false, unit: 'bundle', depth,
      });
    } else if (depth < MAX_FOLDER_DEPTH) {
      await walkBundleDir(source, childRel, depth + 1, out);
    }
  }
}

// Reihenfolge innerhalb einer Quelle für die Dubletten-Regel: die flachere
// Einheit zuerst, bei gleicher Tiefe das Bundle vor der Datei (stabil).
function byPrecedence(a, b) {
  return (a.depth - b.depth) || ((a.unit === 'file') - (b.unit === 'file'));
}

// Öffentlicher Discovery-Eintrag (ohne die Hilfsfelder des Walks).
function publicEntry({ depth, ...entry }) {
  return entry;
}

/**
 * Baut die Discovery-Map (id → Eintrag) aus allen DASHBOARD_SOURCES und der
 * LEGACY_SOURCE. Override-Regel bei gleicher ID (Bundle ↔ Bundle, Bundle ↔
 * Datei, Datei ↔ Datei gleichermaßen):
 *   - custom gewinnt gegen builtin (`overrides: true`, behält seinen custom/…-Pfad);
 *     gegen system/module wird es verworfen — ein Nutzer-Dashboard darf `home`
 *     oder `_generic` nicht kapern;
 *   - legacy (sql-custom/) nur für Namen außerhalb beider Inventare, die keine
 *     andere Quelle führt;
 *   - community überschreibt nie (verworfen);
 *   - doppelte ID innerhalb einer Quelle → die flachere Einheit bleibt, bei
 *     gleicher Tiefe das Bundle (byPrecedence).
 * Datei-Einheiten mit dem Namen eines internen Templates werden verworfen.
 * Jede verworfene Kollision wird als Warnung geloggt.
 */
async function buildDiscovery() {
  const scanned = {};
  for (const source of [...DASHBOARD_SOURCES, LEGACY_SOURCE]) {
    scanned[source.key] = [];
    await walkBundleDir(source, '', 0, scanned[source.key]);
    scanned[source.key].sort(byPrecedence);
  }
  const map = new Map();
  const discard = (entry, existing, reason) => warnDiscovery(
    `[dashboard:${entry.id}] ${entry.unit} at "${entry.file || entry.dir}" collides with "${existing.file || existing.dir}" — ${reason}, discarding`,
  );
  // Datei-Einheit ↔ internes Template (queries/system, queries/modules).
  const internalClash = async entry => {
    if (entry.unit !== 'file') return false;
    const area = await queryDiscovery.internalArea(entry.id);
    if (!area) return false;
    warnDiscovery(`[dashboard:${entry.id}] file at "${entry.file}" is named like an internal ${area} template — discarding`);
    return true;
  };

  for (const entry of scanned.shipped) {
    const existing = map.get(entry.id);
    if (existing) { discard(entry, existing, 'duplicate dashboard id'); continue; }
    if (await internalClash(entry)) continue;
    map.set(entry.id, publicEntry(entry));
  }

  const customSeen = new Map();
  for (const entry of scanned.custom) {
    const sibling = customSeen.get(entry.id);
    if (sibling) { discard(entry, sibling, 'duplicate dashboard id'); continue; }
    const shipped = map.get(entry.id);
    if (shipped && shipped.area !== 'builtin') {
      discard(entry, shipped, `custom dashboards may only override builtin dashboards, not ${shipped.area}`);
      continue;
    }
    if (await internalClash(entry)) continue;
    customSeen.set(entry.id, entry);
    map.set(entry.id, publicEntry(shipped ? { ...entry, overrides: true } : entry));
  }

  if (scanned.legacy.length) {
    const known = dashboardInventory.knownNames();
    for (const entry of scanned.legacy) {
      // Altkopie eines mitgelieferten Namens oder eigener Name, den der Nutzer
      // schon nach dashboards-custom/ übernommen hat → still übergehen.
      if (!dashboardInventory.isUnknownName(entry.id, known) || customSeen.has(entry.id)) continue;
      const existing = map.get(entry.id);
      if (existing) { discard(entry, existing, 'the old query location never overrides'); continue; }
      if (await internalClash(entry)) continue;
      map.set(entry.id, publicEntry(entry));
    }
  }

  for (const entry of scanned.community) {
    const existing = map.get(entry.id);
    if (existing) { discard(entry, existing, 'community dashboards never override'); continue; }
    if (await internalClash(entry)) continue;
    map.set(entry.id, publicEntry(entry));
  }
  return map;
}

function getDiscovery() {
  if (discoveryPromise && Date.now() - discoveryBuiltAt > DISCOVERY_TTL_MS) discoveryPromise = null;
  if (!discoveryPromise) {
    discoveryBuiltAt = Date.now();
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

// Template-Eintrag einer Datei-Einheit für die Auflösung per Name
// (template.service): dieselbe Form wie ein Eintrag der Query-Discovery.
function fileUnitEntry(entry) {
  return {
    name: entry.id,
    path: entry.file,
    dir: entry.dir,
    area: entry.area,
    folder: entry.folder,
    overrides: entry.overrides === true,
    legacy: entry.legacy === true,
    unit: 'file',
  };
}

/**
 * Datei-Einheit eines Namens (inkl. Override und alter Ablage), sonst null —
 * erster Schritt der Auflösung von `custom:<name>` und `/api/query`.
 */
async function findFileUnit(name) {
  if (!isValidBundleId(name)) return null;
  const entry = (await getDiscovery()).get(name);
  return entry && entry.unit === 'file' ? fileUnitEntry(entry) : null;
}

/** Alle Datei-Einheiten der Inhaltsbereiche als Template-Einträge, nach Name sortiert. */
async function listFileUnits() {
  return [...(await getDiscovery()).values()]
    .filter(e => e.unit === 'file' && CONTENT_AREAS.includes(e.area))
    .map(fileUnitEntry)
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/**
 * Lädt ein einzelnes Dashboard. Bundles: manifest + layout, beides per Joi
 * validiert. Datei-Einheiten: abgeleitetes Manifest (loadFileUnit).
 * Bei Fehler: gibt null zurück und loggt — App soll nicht crashen.
 */
async function loadBundle(id) {
  const map = await getDiscovery();
  const entry = map.get(id);
  if (!entry) return null;
  return entry.unit === 'file' ? loadFileUnit(entry) : loadDirBundle(entry);
}

async function loadDirBundle(entry) {
  const { id, dir, area, folder } = entry; // folder: Ordner-Pfad (ohne <id>), null = ohne Ordner
  const cacheKey = id;
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
    // dir-Vergleich: ein neues/entferntes Custom-Override verlegt die ID in ein
    // anderes Verzeichnis, ohne dass sich dort eine mtime ändern muss.
    if (cached && cached.unit === 'bundle' && cached.mtime === combinedMtime && cached.dir === dir) {
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
      unit: 'bundle',
      area,
      folder,
      overrides: entry.overrides === true,
      legacy: false,
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

// Warnungen einer Datei-Einheit einmal je Dateistand loggen — ohne Cache
// (Entwicklung) lädt jede Übersicht alle Einheiten neu.
const fileUnitWarned = new Set();
function warnFileUnitOnce(entry, mtime, message) {
  const key = `${entry.file}:${mtime}:${message}`;
  if (fileUnitWarned.has(key)) return;
  fileUnitWarned.add(key);
  console.warn(`[dashboard:${entry.id}] ${message}`);
}

/**
 * Parameter-Liste aus der `-- @params:`-Zeile des Kopfs (letzte gewinnt, wie
 * in parseTemplateMetadata): Kommas trennen nur außerhalb von Klammern;
 * `name (optional|required, default <wert>, <beschreibung>)`; `none` = keine.
 */
function parseHeaderParams(content) {
  let raw = null;
  for (const line of String(content).split('\n')) {
    const m = line.match(/^\s*--\s*@params\s*:\s*(.*)$/i);
    if (m) raw = m[1].trim();
  }
  if (!raw || /^none$/i.test(raw)) return [];
  const splitTopLevel = text => {
    const parts = [];
    let depth = 0;
    let cur = '';
    for (const ch of text) {
      if (ch === '(') depth += 1;
      if (ch === ')') depth = Math.max(0, depth - 1);
      if (ch === ',' && depth === 0) { parts.push(cur); cur = ''; } else { cur += ch; }
    }
    parts.push(cur);
    return parts.map(p => p.trim()).filter(Boolean);
  };
  const out = [];
  for (const part of splitTopLevel(raw)) {
    const m = /^([A-Za-z_][\w-]*)\s*(?:\((.*)\))?\s*$/.exec(part);
    if (!m) continue;
    const param = { name: m[1], type: 'string', required: false };
    const description = [];
    for (const item of splitTopLevel(m[2] || '')) {
      let d;
      if (/^required$/i.test(item)) param.required = true;
      else if (/^optional$/i.test(item)) param.required = false;
      else if ((d = /^optional\s*:\s*(.+)$/i.exec(item))) description.push(d[1]);
      else if ((d = /^default\s+(.+)$/i.exec(item))) param.default = d[1];
      else description.push(item);
    }
    if (description.length) param.description = description.join(', ');
    out.push(param);
  }
  return out;
}

/**
 * Abgeleitetes Manifest einer Datei-Einheit aus ihrem `-- @`-Kopf: Titel
 * (Fallback humanisierte ID), Beschreibung, Icon (Default `query`), Version,
 * Autor, Tags, `locked` für mitgelieferte Bereiche, die Datasets des
 * `_generic`-Layouts (`query_meta` mit fester ID, `results` = `custom:<id>`),
 * die Parameter aus `@params` (+ `query`, `file`) und der `analysis`-Block aus
 * `@object_types`/`@output_types`/`@scope`/`@default_result`. Unbrauchbare
 * Analyse-Angaben werden mit Warnung verworfen, die Einheit bleibt sichtbar.
 */
function deriveFileManifest(entry, meta, content, warn) {
  const id = entry.id;
  if (!meta.title) warn('no @title in the SQL header — using the humanized file name');
  const params = [
    { name: 'query', type: 'string', required: false, default: id,
      description: 'Name of the query (fixed: this single-file dashboard).' },
  ];
  for (const p of parseHeaderParams(content)) {
    if (!params.some(q => q.name === p.name)) params.push(p);
  }
  if (!params.some(p => p.name === 'file')) {
    params.push({ name: 'file', type: 'string', required: false,
      description: 'Optional file filter — forwarded to the query.' });
  }
  const manifest = {
    id,
    version: meta.version || '1.0.0',
    title: meta.title || humanizeFolderSegment(id),
    ...(meta.description ? { description: meta.description } : {}),
    ...(meta.author ? { author: meta.author } : {}),
    icon: meta.icon || 'query',
    tags: meta.tags || [],
    ...(LOCKED_AREAS.has(entry.area) ? { locked: true } : {}),
    entry: 'layout.json',
    datasets: [
      { id: 'query_meta', source: 'builtin:query_meta', params: { query: id } },
      { id: 'results', source: `custom:${id}` },
    ],
    params,
    permissions: { read_only: true, allow_navigation: true },
  };

  const pickValid = (values, allowed, key) => {
    const bad = values.filter(v => !allowed.includes(v));
    if (bad.length) warn(`ignoring unknown @${key} value(s): ${bad.join(', ')}`);
    return values.filter(v => allowed.includes(v));
  };
  const objectTypes = meta.object_types || [];
  const outputTypes = pickValid(meta.output_types || [], OUTPUT_TYPES, 'output_types');
  const scope = pickValid(meta.scope || [], SCOPES, 'scope');
  let defaultResult = null;
  if (meta.default_result) {
    const dr = meta.default_result;
    const aggregate = typeof dr.aggregate === 'string' && dr.aggregate ? dr.aggregate : 'row_count';
    const candidate = {
      dataset: 'results',
      aggregate,
      ...(aggregate.startsWith('first_row:') ? { column: aggregate.slice('first_row:'.length) } : {}),
      type: dr.type || 'number',
      name: dr.name,
      ...(dr.meaning != null ? { meaning: dr.meaning } : {}),
      ...(dr.unit != null ? { unit: dr.unit } : {}),
    };
    const { error } = testsSchemas.defaultResult.validate(candidate);
    if (error) warn(`ignoring invalid @default_result (${error.message})`);
    else defaultResult = candidate;
  }
  if (objectTypes.length || outputTypes.length || scope.length || defaultResult) {
    manifest.analysis = {
      objectTypes,
      outputTypes,
      ...(scope.length ? { scope: { supported: scope } } : {}),
      ...(defaultResult ? { defaultResult } : {}),
    };
  }
  return manifest;
}

/**
 * Lädt eine Datei-Einheit: Kopf lesen, Manifest ableiten und wie ein Bundle
 * validieren, Layout von `_generic` referenzieren (nicht kopieren). Das
 * Bundle-Objekt trägt zusätzlich `file` und `queryMeta` (die vollständigen
 * Kopf-Metadaten für query_meta). `dir` ist das Verzeichnis der Datei.
 * Cache-Invalidierung über die mtime der Datei und des `_generic`-Bundles.
 */
async function loadFileUnit(entry) {
  const { id, dir, file, area, folder } = entry;
  const generic = await loadBundle(GENERIC_BUNDLE_ID);
  if (!generic) {
    console.warn(`[dashboard:${id}] cannot render single-file dashboard — bundle "${GENERIC_BUNDLE_ID}" is missing or invalid`);
    return null;
  }
  const fileMtime = await tryStatMtime(file);
  const combinedMtime = Math.max(fileMtime, generic.mtime);
  if (environment.templates.cacheEnabled) {
    const cached = bundleCache.get(id);
    if (cached && cached.unit === 'file' && cached.mtime === combinedMtime && cached.file === file) return cached;
  }
  try {
    const content = await fs.readFile(file, 'utf-8');
    const queryMeta = templateService.parseTemplateMetadata(content);
    const warn = message => warnFileUnitOnce(entry, fileMtime, message);
    const raw = deriveFileManifest(entry, queryMeta, content, warn);
    const { error, value: manifest } = dashboardSchemas.manifest.validate(raw, {
      abortEarly: false,
      stripUnknown: false,
      convert: true,
    });
    if (error) {
      warn(`derived manifest invalid: ${error.message}`);
      return null;
    }
    const bundle = {
      id,
      dir,
      file,
      unit: 'file',
      area,
      folder,
      overrides: entry.overrides === true,
      legacy: entry.legacy === true,
      manifest,
      layout: generic.layout,
      queryMeta,
      mtime: combinedMtime,
    };
    if (environment.templates.cacheEnabled) bundleCache.set(id, bundle);
    return bundle;
  } catch (err) {
    console.warn(`[dashboard:${id}] failed to load: ${err.message}`);
    return null;
  }
}

/**
 * Listet alle gefundenen Dashboard-Bundles aus allen DASHBOARD_SOURCES (nach
 * Anwendung der Override-Regel). Fehlerhafte Bundles werden übersprungen.
 */
async function listBundles() {
  const map = await getDiscovery();
  const bundles = await Promise.all([...map.keys()].map(loadBundle));
  return bundles.filter(b => b !== null);
}

// Dashboard id = directory name (bundle) or file name without `.sql` (file
// unit); the pattern also rules out path traversal.
function isValidBundleId(id) {
  return typeof id === 'string' && /^[a-zA-Z0-9_-]+$/.test(id);
}

/**
 * Holt ein Bundle anhand der ID. Wirft TEMPLATE_NOT_FOUND, wenn nicht vorhanden.
 */
async function getBundle(id) {
  if (!isValidBundleId(id)) {
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

async function runBundleQuery(ctx, bundle, relPath, params, datasetSpec = {}) {
  const sqlTemplate = await loadBundleSql(bundle, relPath);
  // Server paging (see paging.service): the page window comes from the request,
  // then the manifest (`pageSize`, `pageParam`, `searchParam`), then the generic
  // default. Datasets without the paging tail run unchanged.
  let effectiveParams = params;
  if (paging.isPagedTemplate(sqlTemplate)) {
    effectiveParams = paging.resolvePaging(params, {
      pageSize: datasetSpec.pageSize,
      pageParam: datasetSpec.pageParam,
      searchParam: datasetSpec.searchParam,
    }).params;
  }
  let sql = templateService.interpolateTemplate(sqlTemplate, effectiveParams);
  // API-Filter-Set injizieren (nur Datasets mit Platzhalter; alle anderen Bundles
  // unberührt). NACH interpolateTemplate → generierte SQL ist präprozessor-sicher.
  // VOR der Sortierung: deren DESCRIBE braucht das vollständige SQL.
  if (sql.includes(API_SET_PLACEHOLDER)) {
    const setId = (params && params.api_set && String(params.api_set)) || 'generic';
    const set = (await resolveApiSet(bundle, setId)) || (await resolveApiSet(bundle, 'generic'));
    sql = sql.split(API_SET_PLACEHOLDER).join(buildClassificationCase(set || {}));
  }
  sql = await paging.applySort(ctx, sqlTemplate, sql, params, {
    sortParam: datasetSpec.sortParam,
    sortColumns: datasetSpec.sortColumns,
  });
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

// Category label of a single-file dashboard: the title of its folder (joined
// for nested paths, "Custom / Team"), else its own `@category`, else
// "Allgemein". The folder titles of the shipped rubrics equal the former
// category labels, so grouping and `?category=` deep links keep working.
async function queryCategory(folder, meta) {
  return (await resolveFolderLabel(folder)) || (meta && meta.category) || 'Allgemein';
}

/**
 * builtin:list_custom_queries — alias for dashboards of the former query
 * catalog: one row per single-file dashboard of the content areas, in the
 * fields of the former catalog rows.
 */
async function builtinListCustomQueries(params = {}) {
  const units = (await listBundles()).filter(b => b.unit === 'file' && CONTENT_AREAS.includes(b.area));
  const rows = await Promise.all(units.map(async b => {
    const t = b.queryMeta;
    return {
      name: b.id,
      title: t.title || b.id,
      description: t.description || null,
      template_type: t.template_type,
      category: await queryCategory(b.folder, t),
      icon: t.icon || 'query',
      display: t.display || 'auto',
      // Klick-Konfiguration der Query — technisch ('_'-Präfix): sie beschreibt,
      // was das Ergebnis-Dashboard beim Zeilenklick tut, und gehört nicht in die
      // Suche über den Query-Katalog.
      _click_action: t.click_action || null,
      _click_args: t.click_args || null,
      tags: t.tags || [],
      params: Array.isArray(t.params) ? t.params.join(', ') : (t.params || ''),
    };
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

// Kopf-Metadaten einer Query über die Auflösungskette von `custom:<name>`:
// eine Datei-Einheit liefert ihr Bundle-Objekt (queryMeta), Modul-Templates und
// Bundle-Queries kommen über den Template-Service.
async function resolveQueryMeta(name) {
  const unit = await findFileUnit(name);
  if (unit) {
    const bundle = await loadBundle(name);
    if (bundle) {
      return { ...bundle.queryMeta, folder: bundle.folder, area: bundle.area, overrides: bundle.overrides, legacy: bundle.legacy };
    }
  }
  return templateService.getTemplateMeta(name, 'query');
}

/**
 * builtin:query_meta — gibt eine einzelne Zeile mit Metadaten einer Query zurück. Benötigt Param `query`. Wird vom `_generic`-Bundle genutzt, um Titel,
 * Beschreibung und Klick-Action-Konfiguration an das Layout zu übergeben.
 */
async function builtinQueryMeta(params = {}) {
  const queryName = params.query;
  if (!queryName) {
    throw createError('VALIDATION_ERROR', 'builtin:query_meta requires param "query"');
  }
  // Wichtig: auch Modul- und Bundle-eigene Queries (dashboards*/…/<bundle>/queries/)
  // auflösen — die Dashboard-Übersicht listet nur die Datei-Einheiten.
  const t = await resolveQueryMeta(queryName);
  if (!t) {
    // Leere Zeile statt Fehler — Dashboard soll trotzdem rendern können
    return [{
      query: queryName,
      title: queryName,
      description: null,
      template_type: null,
      icon: null,
      category: null,
      folder: null,
      area: null,
      overrides: false,
      legacy: false,
      display: 'auto',
      click_action: null,
      click_args: null,
      row_action: null,
      row_action_args: null,
      row_action_label: null,
      chip_filter: null,
      chip_param: null,
      page_param: null,
      search_param: null,
      sort_param: null,
      sort_columns: [],
      page_size: null,
      paging_off: false,
    }];
  }
  return [{
    query: queryName,
    title: t.title || queryName,
    description: t.description || null,
    template_type: t.template_type || null,
    icon: t.icon || null,
    category: (await resolveFolderLabel(t.folder)) || t.category || null,
    folder: t.folder || null,
    area: t.area || null,
    overrides: t.overrides === true,
    legacy: t.legacy === true,
    display: t.display || 'auto',
    click_action: t.click_action || null,
    click_args: t.click_args || null,
    row_action: t.row_action || null,
    row_action_args: t.row_action_args || null,
    row_action_label: t.row_action_label || null,
    chip_filter: t.chip_filter || null,
    chip_param: t.chip_param || null,
    page_param: t.page_param || null,
    search_param: t.search_param || null,
    sort_param: t.sort_param || null,
    sort_columns: t.sort_columns || [],
    page_size: t.page_size ?? null,
    paging_off: t.page_size === 'all',
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

// Quelle eines Ordner-Pfads: ein Bereichs-Präfix (custom/…, community/…) zeigt
// in dessen Verzeichnis, jeder andere Pfad nur nach dashboards/.
function folderSource(folderPath) {
  const head = String(folderPath).split('/')[0];
  return DASHBOARD_SOURCES.find(s => s.prefix && s.prefix === head) || SHIPPED_SOURCE;
}

// Bereich eines Ordner-Pfads der Übersicht (custom, community oder builtin).
function folderArea(folderPath) {
  return folderSource(folderPath).area || 'builtin';
}

// Lädt folder.json eines Ordners (Ordner-Pfad ohne Bundle-ID), mtime-gecacht.
// Das Präfix löst in sein Bereichsverzeichnis auf (`custom` →
// dashboards-custom/folder.json, `custom/x` → dashboards-custom/x/folder.json);
// die Bereiche teilen sich keinen Ordner-Namensraum. Liefert { title, icon,
// description, order, locales } oder null. Joi-validiert (folderManifest) —
// defekte Dateien degradieren zu leeren Metadaten statt die Discovery zu kippen.
async function loadFolderMeta(folderPath) {
  const source = folderSource(folderPath);
  const rel = source.prefix ? String(folderPath).split('/').slice(1).join('/') : String(folderPath);
  const fp = path.join(source.base, rel, 'folder.json');
  const mtime = await tryStatMtime(fp);
  if (!mtime) return null;
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

// Komma-Liste oder Array → getrimmte, nicht-leere Strings.
function parseListParam(value) {
  if (!value) return [];
  return (Array.isArray(value) ? value : String(value).split(','))
    .map(s => String(s).trim())
    .filter(Boolean);
}

// Gemeinsamer Sichtbarkeitsfilter beider Übersichts-Builtins, damit Zähler und
// Liste exakt dasselbe sehen: Bereich ∈ `areas` (Default: die Inhaltsbereiche)
// und kein Tag aus `excludeTags` (z. B. `internal` innerhalb eines Bereichs).
function visibleBundles(bundles, params) {
  const areas = parseListParam(params.areas);
  const wanted = areas.length ? areas : CONTENT_AREAS;
  const excludeTags = parseListParam(params.excludeTags);
  return {
    areas: wanted,
    bundles: bundles.filter(b => wanted.includes(b.area)
      && !(b.manifest.tags || []).some(t => excludeTags.includes(t))),
  };
}

async function builtinListDashboards(params = {}) {
  const lang = params._lang || params.lang || 'en';
  const { bundles: filtered } = visibleBundles(await listBundles(), params);

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
      area: b.area,
      // Custom dashboard replacing a builtin dashboard of the same id.
      overrides: b.overrides === true,
      // Storage form: a bundle directory or a single `.sql` file.
      unit: b.unit || 'bundle',
      // Single-file dashboard read from the old query location (sql-custom/).
      legacy: b.legacy === true,
      folder: b.folder || null,
      folder_label: await resolveFolderLabel(b.folder, lang),
      author: manifest.author || null,
      version: manifest.version || null,
      // Entry-point marker (`featured`) + the folder subtrees its entry count
      // spans — the overview renders such a bundle as a band above the folder
      // grid instead of as an equal tile below it.
      featured: manifest.featured === true,
      _badge_roots: manifest.badgeRoots || null,
      // Declared object types of the result rows (`analysis.objectTypes`) —
      // the source of the overview's object-type filter; [] = none declared.
      object_types: [...((b.manifest.analysis && b.manifest.analysis.objectTypes) || [])],
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
 * Respektiert denselben areas-/excludeTags-Filter wie list_dashboards, damit
 * die Zähler exakt das spiegeln, was die Übersicht anzeigt.
 * Bereichs-Ordner: `custom` erscheint immer, sobald der Bereich angefragt ist
 * (auch leer — dort legt der Nutzer eigene Dashboards an), `community` nur mit
 * Inhalt. Label, order & Co. kommen aus der folder.json des Bereichsverzeichnisses.
 */
async function builtinListDashboardFolders(params = {}) {
  const lang = params._lang || params.lang || 'en';
  const { areas, bundles: visible } = visibleBundles(await listBundles(), params);

  // Alle Ordner-Pfade (inkl. Zwischenebenen) + Zähler aufsammeln.
  const folders = new Map(); // path → { direct, total }
  const ensure = p => {
    if (!folders.has(p)) folders.set(p, { direct: 0, total: 0 });
    return folders.get(p);
  };
  if (areas.includes('custom')) ensure('custom');
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
      area: folderArea(folderPath),
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

  // Sortierung je Ebene: Bereich (Inhalte vor Custom vor Community — auch ohne
  // order in einer folder.json), dann order (fehlend = hinten), dann Label.
  rows.sort((a, b) => {
    const depth = a.path.split('/').length - b.path.split('/').length;
    if (depth !== 0) return depth;
    const area = CONTENT_AREAS.indexOf(a.area) - CONTENT_AREAS.indexOf(b.area);
    if (area !== 0) return area;
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
    // Format-Probe der Inbox (FileMaker-18-Exporte sind nicht importierbar):
    // die Home-Karte startet den Import nur, wenn mindestens eine Datei
    // importierbar ist, sonst wechselt sie nur zur Import-Seite.
    unsupported_count: status.unsupported_count ?? 0,
    importable_count: status.importable_count ?? files.length,
    // A conversion already runs (e.g. the terminal run of tools/init.sh) → the card
    // shows that instead of offering a second start.
    running: status.running === true,
    running_source: status.running_source ?? null,
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
    // Declared object types as an array — the source of the overview's
    // object-type filter (same contract as list_dashboards); [] = none declared.
    object_types: [...(t.definition.objectTypes || [])],
    scopes: (t.definition.scopes || []).join(', '),
    member_count: (t.definition.members || []).length,
    folder: t.folder || null,
    folder_label: await testsService.resolveFolderLabel(t.folder, lang),
    area: t.area,
    // Custom test replacing a builtin test of the same id.
    overrides: t.overrides === true,
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
 * Die Bereiche teilen sich keinen Ordner-Namensraum: eigene Tests hängen unter
 * dem virtuellen Ordner `custom`, Community-Tests unter `community`.
 * Bereichs-Ordner: `custom` erscheint immer (dort legt der Nutzer eigene Tests
 * an), `community` nur mit Inhalt. Label, order & Co. kommen aus der
 * folder.json des Bereichsverzeichnisses (`loadFolderMeta` löst das Präfix auf).
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
  ensure('custom');
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
      area: testsService.folderArea(folderPath),
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

  // Sortierung je Ebene: Bereich (mitgelieferte vor Custom vor Community —
  // auch ohne order in einer folder.json), dann order (fehlend = hinten),
  // dann Label.
  rows.sort((a, b) => {
    const depth = a.path.split('/').length - b.path.split('/').length;
    if (depth !== 0) return depth;
    const area = CONTENT_AREAS.indexOf(a.area) - CONTENT_AREAS.indexOf(b.area);
    if (area !== 0) return area;
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

/** Der Original-Eintrag eines Members: das Dashboard (Bundle oder Datei-Einheit). */
function memberTargetPath(member) {
  if (!member.resolved) return '';
  return `/dashboard/${encodeURIComponent(member.ref)}`;
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
 * Mit `open_target` für openDashboard-Links; `pending`-Einheiten
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
      _open_target: envelope.ref.kind === 'test' ? `/tests/${envelope.ref.id}` : `/dashboard/${envelope.ref.id}`,
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
      return runBundleQuery(ctx, bundle, ref, params, datasetSpec);
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
  DASHBOARD_SOURCES,
  LEGACY_SOURCE,
  RESERVED_TOP_LEVEL,
  CONTENT_AREAS,
  isFavoritableArea,
  isValidBundleId,
  listBundles,
  getBundle,
  findFileUnit,
  listFileUnits,
  parseHeaderParams,
  resolveFolderCrumbs,
  resolveFolderLabel,
  executeAllDatasets,
  executeSingleDataset,
  clearCache,
};
