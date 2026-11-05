const fs = require('fs').promises;
const path = require('path');
const environment = require('../config/environment');

/**
 * Query discovery: the index of the internal SQL templates — addressed by name
 * from server and frontend code, never listed, never overridable.
 *
 *   area       source                       /api/query  /api/report
 *   system     queries/system/**            no          yes
 *   module     queries/modules/**           yes         no
 *   (bundle)   <dashboard tree>/…/<bundle>/queries/   last resort  no
 *
 * A template is one `*.sql` file; its name (file name without `.sql`) is
 * unique across both areas and their sub-folders. Content queries are not
 * templates of this index: they are file units of the dashboard discovery
 * (`<dashboard tree>/…/<name>.sql`), which `/api/query` and `custom:<name>` ask
 * first (see template.service). A file unit named like an internal template is
 * discarded there — it would take over a template the UI depends on.
 *
 * Name collisions: a duplicate keeps the first one found (files before
 * sub-folders, each by name — the shallower file wins) and is logged as a
 * warning. Any other top-level entry of queries/ than system/ and modules/ is
 * ignored.
 *
 * The index is rebuilt after INDEX_TTL_MS at the latest, so a template file
 * dropped into an area shows up without a reload.
 */

const MAX_FOLDER_DEPTH = 4;
const INDEX_TTL_MS = 2000;
const NAME_PATTERN = /^[a-zA-Z0-9_-]+$/;

// Storage folders of queries/ → area of their templates.
const SHIPPED_GROUP_AREAS = { system: 'system', modules: 'module' };

// Sources of the index. The former TEMPLATE_DIR / TEMPLATE_DETAILS_DIR
// variables may relocate the base of the system / module area.
const T = environment.templates;
const SOURCES = [
  { key: 'system', base: T.queriesSystemOverrideDir || path.join(T.queriesDir, 'system'), area: 'system' },
  { key: 'modules', base: T.queriesModulesOverrideDir || path.join(T.queriesDir, 'modules'), area: 'module' },
];

function isValidQueryName(name) {
  return typeof name === 'string' && NAME_PATTERN.test(name);
}

let indexPromise = null;
let indexBuiltAt = 0;

function clearCache() {
  indexPromise = null;
  indexBuiltAt = 0;
}

// Directory entries in a stable order: files before sub-folders, each by name
// — so of two equal names the shallower file is found first.
async function readDirSorted(absDir) {
  try {
    const entries = await fs.readdir(absDir, { withFileTypes: true });
    return entries.sort((a, b) => (a.isDirectory() - b.isDirectory())
      || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  } catch (err) {
    if (err.code === 'ENOENT' || err.code === 'ENOTDIR') return [];
    throw err;
  }
}

/**
 * Recursive walk below `source.base` up to MAX_FOLDER_DEPTH: collects every
 * `*.sql` file. Dot entries are skipped.
 */
async function walk(source, relDir, depth, out) {
  const absDir = path.join(source.base, relDir);
  for (const e of await readDirSorted(absDir)) {
    if (e.name.startsWith('.')) continue;
    if (e.isDirectory()) {
      if (depth >= MAX_FOLDER_DEPTH) continue;
      await walk(source, relDir ? `${relDir}/${e.name}` : e.name, depth + 1, out);
      continue;
    }
    if (!e.isFile() || !e.name.endsWith('.sql')) continue;
    const name = e.name.slice(0, -4);
    if (!isValidQueryName(name)) {
      console.warn(`[query] "${path.join(absDir, e.name)}" — invalid query name (allowed: letters, digits, _ and -), skipped`);
      continue;
    }
    out.push({
      name,
      path: path.join(absDir, e.name),
      dir: absDir,
      area: source.area,
      folder: null,
      overrides: false,
      legacy: false,
    });
  }
}

/** Builds the index name → entry from all SOURCES (first one found wins). */
async function buildIndex() {
  const map = new Map();
  for (const source of SOURCES) {
    const scanned = [];
    await walk(source, '', 0, scanned);
    for (const entry of scanned) {
      const existing = map.get(entry.name);
      if (existing) {
        console.warn(`[query:${entry.name}] "${entry.path}" collides with "${existing.path}" — duplicate query name, discarding`);
        continue;
      }
      map.set(entry.name, entry);
    }
  }
  return map;
}

function getIndex() {
  if (indexPromise && Date.now() - indexBuiltAt > INDEX_TTL_MS) indexPromise = null;
  if (!indexPromise) {
    indexBuiltAt = Date.now();
    indexPromise = buildIndex().catch(err => {
      // Do not cache a failed scan — the next call tries again.
      indexPromise = null;
      throw err;
    });
  }
  return indexPromise;
}

/**
 * Last resort of `/api/query`: a query shipped inside a dashboard bundle
 * (`<bundle>/queries/<name>.sql`, any depth of the dashboard tree). Lazy
 * require — dashboard.service loads the template service. File units have no
 * `queries/` folder of their own.
 */
async function resolveBundleQuery(name) {
  if (!isValidQueryName(name)) return null;
  const dashboardService = require('./dashboard.service');
  for (const bundle of await dashboardService.listBundles()) {
    if (bundle.unit === 'file') continue;
    const dir = path.join(bundle.dir, 'queries');
    const file = path.join(dir, `${name}.sql`);
    try {
      if ((await fs.stat(file)).isFile()) {
        return { name, path: file, dir, area: 'bundle', folder: null, overrides: false, legacy: false };
      }
    } catch {
      // not in this bundle
    }
  }
  return null;
}

/**
 * Resolves an internal template name:
 *   'report' → system only;
 *   'query'  → module only (the content and bundle steps of `/api/query`
 *              live in template.service).
 * Returns the entry { name, path, dir, area, folder, overrides, legacy } or null.
 */
async function resolve(name, source = 'query') {
  if (!isValidQueryName(name)) return null;
  const entry = (await getIndex()).get(name);
  if (!entry) return null;
  const wanted = source === 'report' ? 'system' : 'module';
  return entry.area === wanted ? entry : null;
}

/** All entries of the given areas (default: both), sorted by name. */
async function list({ areas } = {}) {
  const wanted = areas && areas.length ? areas : ['system', 'module'];
  return [...(await getIndex()).values()]
    .filter(e => wanted.includes(e.area))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/** Area of an internal template name ('system' | 'module'), null when unknown. */
async function internalArea(name) {
  const entry = (await getIndex()).get(name);
  return entry ? entry.area : null;
}

async function isModuleName(name) {
  return (await internalArea(name)) === 'module';
}

async function isSystemName(name) {
  return (await internalArea(name)) === 'system';
}

module.exports = {
  SOURCES,
  MAX_FOLDER_DEPTH,
  INDEX_TTL_MS,
  resolve,
  resolveBundleQuery,
  list,
  internalArea,
  isModuleName,
  isSystemName,
  isValidQueryName,
  clearCache,
};
