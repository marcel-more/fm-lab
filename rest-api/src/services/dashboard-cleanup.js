const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const environment = require('../config/environment');
const { readInventory, knownNames } = require('./dashboard-inventory');
const templateInventory = require('./template-inventory');
const engine = require('./template-cleanup');

/**
 * Dashboard cleanup — finds leftovers of older template layouts and moves them
 * to their place. Configuration of the template cleanup engine
 * (`template-cleanup.js`, file-system layer, lock, protocol).
 *
 * Older releases kept the system pages directly in `dashboards/`, the shipped
 * content rubrics in `dashboards-custom/` and the queries in `sql-custom/`
 * (next to `sql/` and `sql-custom-details/`). `git pull` moves tracked files
 * but leaves directories with untracked rests behind, and installations updated
 * by copying keep complete old copies. Old copies in `dashboards-custom/` are
 * the serious case: they override the shipped bundles as custom bundles (badge
 * "overrides standard") and stay invisible in `git status`, because the user
 * area is ignored.
 *
 * The reference for "what does this release ship" is `dashboards/inventory.json`
 * (bundles and single-file dashboards) plus `queries/inventory.json` (internal
 * templates). Without a usable dashboard inventory nothing is classified — an
 * unknown tree is never treated as foreign.
 *
 * Bundle cases (a bundle is a directory with `manifest.json`):
 *
 *   a1  dashboards/          bundle not in the inventory, id of a shipped bundle → removed
 *   a2  dashboards-custom/   bundle at the path of a shipped bundle, same id    → removed
 *                            (`modified` when its files differ from the shipped one)
 *   a3  both                 rest folder: an old rubric folder left with only
 *                            folder.json/system files, or a folder named like a
 *                            shipped bundle without any bundle inside           → removed
 *   b1  dashboards/          own bundle (or folder of own bundles), id unknown  → dashboards-custom/<rel>
 *   b2  dashboards/          any other folder not in the inventory              → removed
 *   b3  dashboards/          b1 whose id or target already exists in custom     → removed (`conflict`)
 *
 * File cases (a single-file dashboard is a `.sql` file outside a bundle;
 * "known" = a name of either inventory):
 *
 *   f1  old location         known name                                         → removed
 *                            (`modified` when it differs from the shipped file,
 *                            `-- @category:` lines ignored)
 *   f2  old location         unknown name — the user's own query                → dashboards-custom/<name>.sql
 *                            (from `sql/` with `note: 'report_template'`)
 *   f3  both                 f2/f5 whose id or target already exists in custom  → removed (`conflict`)
 *   f4  old location         anything else: other files, folders without `.sql` → removed
 *   f5  dashboards/          `.sql` not at an inventory path: unknown name      → dashboards-custom/<rel>
 *                                                             known name        → removed
 *
 * Never touched: anything in the inventory, own bundles, files and folders in
 * `dashboards-custom/` outside the old rubric paths (deliberate overrides
 * included), `dashboards-community/`, `queries/`, other files on the top level
 * of `dashboards/` and `dashboards-custom/`. An old location is only part of
 * the cleanup when it lies next to `dashboards/` and is not configured as an
 * active template directory; a run that emptied it removes it.
 *
 * "removed" = `dashboards-removed/<stamp>/<base>/<rel>`, one time-stamped folder
 * per run with `cleanup.json`. Nothing is deleted.
 *
 * Own versions: a `modified` old copy (a2, or f1 of a shipped single-file
 * dashboard) is first copied to `dashboards-custom/<id>-local` (`.sql` for a
 * file; `-local-2`, … when taken) with the new id and a title suffix, then
 * moved aside like any other old copy. The user keeps the edited version under
 * Custom, and nothing stays at the tracked old path — a locally edited tracked
 * file there would block the next `git pull` that deletes it. The copies sit on
 * the top level of `dashboards-custom/`: an old rubric folder may move aside as
 * a whole in the same run (a3).
 *
 * Frozen index: the publish ships `templates/frozen-legacy.json` — the files
 * an earlier release tracked at the old places, path → git blob sha of that
 * release. Old copies are left behind where the update did not go through
 * `git pull` (files copied over an old folder, a pull rescued by
 * tools/update.sh). With the index, `modified` means "edited by the user" —
 * not "differs from the shipped version", which a later release may have
 * changed itself. A unit at an old place
 * whose files are all unedited frozen copies is an old shipped copy, even when
 * its id is no longer shipped (b1/f2/f5 → moved aside). Without the index the
 * comparison with the shipped version stays the fallback.
 *
 * `classify` is pure (snapshot + inventory in, items out) and unit-tested over
 * fixture trees; `compute` is the thin file-system layer around it.
 */

const SHIPPED = 'dashboards';
const CUSTOM = 'dashboards-custom';
const REMOVED = 'dashboards-removed';
const QUERIES = 'queries';
// Old query locations, next to `queries/` (the internal templates).
const OLD_BASES = ['sql-custom', 'sql', 'sql-custom-details'];
const REPORT_TEMPLATE_BASE = 'sql';

// Files that do not keep an old rubric folder in dashboards-custom/ alive.
const RESIDUE_FILES = new Set(['folder.json', '.DS_Store', 'Thumbs.db', 'desktop.ini', '.gitkeep']);

const { PROTOCOL_FILE, formatStamp, summarize, scanTree, sameTree, withOwnVersionSuffix: withSuffix, editJson } = engine;

const isSql = name => name.endsWith('.sql');
const sqlId = name => name.slice(0, -4);
const joinRel = (rel, name) => (rel ? `${rel}/${name}` : name);

// ---------------------------------------------------------------------------
// Pure classification
// ---------------------------------------------------------------------------

/**
 * Snapshot node: { name, rel, bundle, dirs: Node[], files: string[] }.
 *
 * @param {{ shipped: object|null, custom: object|null, old?: Object<string, object|null> }} snapshot
 *   root nodes (rel ''); `old` keyed by old base (`sql-custom`, …)
 * @param {{ bundles: {id,path,unit?}[], folders: string[] }} inventory
 * @param {{ exclude?: string[], stamp?: string, known?: Set<string>, canonical?: Map<string,string> }} [opts]
 *   exclude:   `from` values to leave in place (they also keep their parent folders)
 *   stamp:     time-stamp folder name used in the `to` paths
 *   known:     names shipped by this release (default: the inventory ids)
 *   canonical: name → logical path of the shipped file an old copy is compared
 *              with (default: the inventory's single-file dashboards)
 * @returns {{ case, from, to, target, id, ids, conflict, modified, note, canonical? }[]}
 *   from/to relative to the templates directory, e.g. `dashboards/home` →
 *   `dashboards-removed/<stamp>/dashboards/home`. Items of dashboards-custom/
 *   come first: moving its old rubric folders away before own bundles move in
 *   keeps the two from colliding; items of the old locations come last.
 */
function classify(snapshot, inventory, { exclude = [], stamp = '<timestamp>', known, canonical } = {}) {
  const excluded = new Set(exclude);
  const shippedBundles = inventory.bundles.filter(b => b.unit !== 'file');
  const shippedFiles = inventory.bundles.filter(b => b.unit === 'file');
  const bundleIdByPath = new Map(shippedBundles.map(b => [b.path, b.id]));
  const inventoryIds = new Set(shippedBundles.map(b => b.id));
  const filePaths = new Set(shippedFiles.map(b => b.path));
  const knownNamesSet = known || new Set(inventory.bundles.map(b => b.id));
  const canonicalOf = canonical || new Map(shippedFiles.map(b => [b.id, `${SHIPPED}/${b.path}`]));
  const folderPaths = new Set(inventory.folders);
  for (const b of inventory.bundles) {
    const parts = b.path.split('/');
    for (let i = 1; i < parts.length; i++) folderPaths.add(parts.slice(0, i).join('/'));
  }

  const customDirs = new Map(); // rel → node
  const customIds = new Set();  // bundles and single-file dashboards
  const indexCustom = node => {
    for (const f of node.files) if (isSql(f)) customIds.add(sqlId(f));
    for (const d of node.dirs) {
      customDirs.set(d.rel, d);
      if (d.bundle) customIds.add(d.name);
      else indexCustom(d);
    }
  };
  if (snapshot.custom) indexCustom(snapshot.custom);
  // Ids that move into dashboards-custom/ during this run.
  const claimed = new Set();

  const removedTo = (base, rel) => `${REMOVED}/${stamp}/${base}/${rel}`;
  const customItems = [];
  const shippedItems = [];
  const oldItems = [];

  const push = (list, item) => {
    if (excluded.has(item.from)) return false;
    list.push({ ids: item.id ? [item.id] : [], ...item, modified: false, conflict: item.conflict === true, note: item.note ?? null });
    return true;
  };

  // --- dashboards-custom/: old copies at shipped paths, emptied old rubrics ---
  // Returns true when nothing of `node` would stay behind.
  const walkCustom = node => {
    let allGone = true;
    for (const d of node.dirs) {
      if (d.bundle) {
        const shippedId = bundleIdByPath.get(d.rel);
        const moved = shippedId === d.name && push(customItems, {
          case: 'a2', from: `${CUSTOM}/${d.rel}`, to: removedTo(CUSTOM, d.rel), target: 'removed', id: d.name,
        });
        if (!moved) allGone = false;
      } else if (folderPaths.has(d.rel)) {
        const mark = customItems.length;
        const gone = walkCustom(d) && d.files.every(f => RESIDUE_FILES.has(f));
        const moved = gone && pushResidue(customItems, mark, {
          case: 'a3', from: `${CUSTOM}/${d.rel}`, to: removedTo(CUSTOM, d.rel), target: 'removed', id: null,
        });
        if (!moved) allGone = false;
      } else {
        allGone = false; // own folder of the user
      }
    }
    return allGone;
  };

  // A rest folder moves as a whole: nested rest items become redundant
  // (bundle items stay — they carry `modified` and can be excluded).
  const pushResidue = (list, mark, item) => {
    if (excluded.has(item.from)) return false;
    const nested = list.splice(mark);
    list.push(...nested.filter(i => !(i.case === 'a3' || i.case === 'b2') || !i.from.startsWith(`${item.from}/`)));
    return push(list, item);
  };

  // --- dashboards/: everything that is not in the inventory ---
  const bundlesBelow = node => node.dirs.flatMap(d => (d.bundle ? [d] : bundlesBelow(d)));
  const sqlBelow = node => [
    ...node.files.filter(isSql).map(sqlId),
    ...node.dirs.flatMap(d => (d.bundle ? [] : sqlBelow(d))),
  ];

  const customBlocked = rel => {
    if (customDirs.has(rel)) return true;
    const parts = rel.split('/');
    for (let i = 1; i < parts.length; i++) {
      if (customDirs.get(parts.slice(0, i).join('/'))?.bundle) return true;
    }
    return false;
  };

  const pushOwn = (node, ids, ownCase) => {
    const conflict = ids.some(id => customIds.has(id) || claimed.has(id)) || customBlocked(node.rel);
    const id = node.bundle ? node.name : null;
    if (conflict) {
      return push(shippedItems, { case: 'b3', from: `${SHIPPED}/${node.rel}`, to: removedTo(SHIPPED, node.rel), target: 'removed', id, ids, conflict: true });
    }
    const moved = push(shippedItems, { case: ownCase, from: `${SHIPPED}/${node.rel}`, to: `${CUSTOM}/${node.rel}`, target: 'custom', id, ids });
    if (moved) ids.forEach(i => claimed.add(i));
    return moved;
  };

  // A `.sql` file outside a bundle and outside the inventory paths.
  const foreignFile = rel => {
    const id = sqlId(path.posix.basename(rel));
    if (knownNamesSet.has(id)) {
      return push(shippedItems, { case: 'f5', from: `${SHIPPED}/${rel}`, to: removedTo(SHIPPED, rel), target: 'removed', id });
    }
    if (customIds.has(id) || claimed.has(id) || customBlocked(rel)) {
      return push(shippedItems, { case: 'f3', from: `${SHIPPED}/${rel}`, to: removedTo(SHIPPED, rel), target: 'removed', id, conflict: true });
    }
    const moved = push(shippedItems, { case: 'f5', from: `${SHIPPED}/${rel}`, to: `${CUSTOM}/${rel}`, target: 'custom', id });
    if (moved) claimed.add(id);
    return moved;
  };

  // Returns true when `node` (not in the inventory) moves away completely.
  const foreign = node => {
    if (node.bundle) {
      if (inventoryIds.has(node.name)) {
        return push(shippedItems, {
          case: 'a1', from: `${SHIPPED}/${node.rel}`, to: removedTo(SHIPPED, node.rel), target: 'removed', id: node.name,
        });
      }
      return pushOwn(node, [node.name], 'b1');
    }
    const below = bundlesBelow(node);
    const files = sqlBelow(node);
    const rest = {
      case: inventoryIds.has(node.name) ? 'a3' : 'b2',
      from: `${SHIPPED}/${node.rel}`, to: removedTo(SHIPPED, node.rel), target: 'removed', id: null,
    };
    if (below.length === 0 && files.length === 0) return push(shippedItems, rest);
    const ids = [...below.map(b => b.name), ...files];
    const ownOnly = !below.some(b => inventoryIds.has(b.name)) && !files.some(id => knownNamesSet.has(id))
      && !ids.some(id => customIds.has(id) || claimed.has(id)) && !customBlocked(node.rel);
    if (ownOnly) return pushOwn(node, ids, below.length ? 'b1' : 'f5'); // a folder of own content moves as one
    let allGone = true;
    for (const f of node.files) if (isSql(f) && !foreignFile(joinRel(node.rel, f))) allGone = false;
    for (const d of node.dirs) if (!foreign(d)) allGone = false;
    return allGone && push(shippedItems, { ...rest, case: 'b2' });
  };

  const walkShipped = node => {
    for (const f of node.files) {
      const rel = joinRel(node.rel, f);
      if (isSql(f) && !filePaths.has(rel)) foreignFile(rel);
    }
    for (const d of node.dirs) {
      if (bundleIdByPath.has(d.rel)) continue;
      if (folderPaths.has(d.rel)) walkShipped(d);
      else foreign(d);
    }
  };

  // --- old query locations: every entry moves out ---
  const walkOld = (base, node) => {
    for (const f of node.files) {
      const rel = joinRel(node.rel, f);
      const from = `${base}/${rel}`;
      if (!isSql(f)) {
        push(oldItems, { case: 'f4', from, to: removedTo(base, rel), target: 'removed', id: null });
        continue;
      }
      const id = sqlId(f);
      if (knownNamesSet.has(id)) {
        push(oldItems, { case: 'f1', from, to: removedTo(base, rel), target: 'removed', id, canonical: canonicalOf.get(id) ?? null });
      } else if (customIds.has(id) || claimed.has(id)) {
        push(oldItems, { case: 'f3', from, to: removedTo(base, rel), target: 'removed', id, conflict: true });
      } else if (push(oldItems, {
        case: 'f2', from, to: `${CUSTOM}/${f}`, target: 'custom', id,
        note: base === REPORT_TEMPLATE_BASE ? 'report_template' : null,
      })) {
        claimed.add(id);
      }
    }
    for (const d of node.dirs) {
      if (sqlBelow(d).length) walkOld(base, d);
      else push(oldItems, { case: 'f4', from: `${base}/${d.rel}`, to: removedTo(base, d.rel), target: 'removed', id: null });
    }
  };

  if (snapshot.custom) walkCustom(snapshot.custom);
  if (snapshot.shipped) walkShipped(snapshot.shipped);
  for (const base of OLD_BASES) {
    const root = snapshot.old?.[base];
    if (!root) continue;
    if (sqlBelow(root).length) walkOld(base, root);
    else push(oldItems, { case: 'f4', from: base, to: `${REMOVED}/${stamp}/${base}`, target: 'removed', id: null });
  }
  return [...customItems, ...shippedItems, ...oldItems];
}

// ---------------------------------------------------------------------------
// File-system layer
// ---------------------------------------------------------------------------

/**
 * Logical bases → absolute directories. The old query locations take part
 * only when they lie next to `dashboards/` (one templates directory) and are
 * not configured as an active template directory.
 */
function baseDirs() {
  const t = environment.templates;
  const dirs = {
    [SHIPPED]: t.dashboardsDir,
    [CUSTOM]: t.dashboardsCustomDir,
    [REMOVED]: t.dashboardsRemovedDir,
    [QUERIES]: t.queriesDir,
  };
  const templatesRoot = path.dirname(path.resolve(t.dashboardsDir));
  const active = new Set([t.queriesSystemOverrideDir, t.queriesModulesOverrideDir].filter(Boolean).map(p => path.resolve(p)));
  const candidates = {
    'sql-custom': t.queriesLegacyDir,
    sql: path.join(path.dirname(t.queriesDir), 'sql'),
    'sql-custom-details': path.join(path.dirname(t.queriesDir), 'sql-custom-details'),
  };
  for (const [base, dir] of Object.entries(candidates)) {
    const abs = dir && path.resolve(dir);
    if (abs && path.dirname(abs) === templatesRoot && !active.has(abs)) dirs[base] = abs;
  }
  return dirs;
}

/** SQL text without `-- @category:` lines (old copies still carry them). */
function comparableSql(abs) {
  return fs.readFileSync(abs, 'utf-8')
    .replace(/\r\n/g, '\n')
    .split('\n')
    .filter(line => !/^\s*--\s*@category\s*:/.test(line))
    .join('\n');
}

function sameSql(a, b) {
  try {
    return comparableSql(a) === comparableSql(b);
  } catch {
    return false;
  }
}

const FROZEN_INDEX = 'frozen-legacy.json';

/** `files` of templates/frozen-legacy.json as a Map, or null without a usable index. */
function readFrozenIndex(templatesRoot) {
  try {
    const index = JSON.parse(fs.readFileSync(path.join(templatesRoot, FROZEN_INDEX), 'utf-8'));
    if (index?.version !== 1 || !index.files || typeof index.files !== 'object') return null;
    return new Map(Object.entries(index.files));
  } catch {
    return null;
  }
}

/** git blob sha of a file — the id the frozen index records. */
function blobSha(abs) {
  const buf = fs.readFileSync(abs);
  return crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex');
}

/**
 * Compares a unit (directory or file, logical path) with the frozen index.
 * → null when the index knows nothing below it; else { edited } — true when a
 * file differs, was added or is missing.
 */
function frozenState(logical, dirs, frozen) {
  const prefix = `${logical}/`;
  const expected = [...frozen.keys()].filter(k => k === logical || k.startsWith(prefix));
  if (expected.length === 0) return null;
  const abs = engine.resolveLogical(logical, dirs);
  let present;
  try {
    present = fs.statSync(abs).isDirectory() ? engine.listFiles(abs).map(f => `${prefix}${f}`) : [logical];
  } catch {
    return null;
  }
  if (present.length !== expected.length) return { edited: true };
  return { edited: present.some(k => frozen.get(k) !== blobSha(engine.resolveLogical(k, dirs))) };
}

/**
 * Marks old copies (a2, f1) whose content differs: from the frozen index when
 * it knows the copy (edited by the user), else from the shipped version.
 */
function annotateModified(items, dirs = baseDirs(), frozen = null) {
  for (const item of items) {
    if (frozen && (item.case === 'a2' || item.case === 'f1')) {
      const state = frozenState(item.from, dirs, frozen);
      if (state) {
        item.modified = state.edited;
        continue;
      }
    }
    if (item.case === 'a2') {
      const rel = item.from.slice(CUSTOM.length + 1);
      item.modified = !sameTree(engine.resolveLogical(item.from, dirs), path.join(dirs[SHIPPED], rel));
    } else if (item.case === 'f1') {
      item.modified = !item.canonical
        || !sameSql(engine.resolveLogical(item.from, dirs), engine.resolveLogical(item.canonical, dirs));
    }
  }
  return items;
}

/** Ids in use below `dashboards-custom/` (bundle directories and `.sql` names). */
function customIdsOf(node, out = new Set()) {
  if (!node) return out;
  for (const f of node.files) if (isSql(f)) out.add(sqlId(f));
  for (const d of node.dirs) {
    if (d.bundle) out.add(d.name);
    else customIdsOf(d, out);
  }
  return out;
}

/**
 * Gives every `modified` old copy that can live on as an own dashboard a
 * `fork` target: a2 bundles and f1 copies of a shipped single-file dashboard
 * (copies of internal templates in queries/ are no dashboards — they only move
 * aside). Ids already in use (shipped, custom, own content moving in, earlier
 * forks of this run) are skipped.
 */
function annotateForks(items, dirs, { customIds, known }) {
  const taken = new Set([...customIds, ...known]);
  for (const item of items) if (item.target === 'custom') item.ids.forEach(id => taken.add(id));
  for (const item of items) {
    if (!item.modified || !item.id) continue;
    const isBundle = item.case === 'a2';
    const isFile = item.case === 'f1' && item.canonical?.startsWith(`${SHIPPED}/`);
    if (!isBundle && !isFile) continue;
    let forkId = `${item.id}-local`;
    for (let n = 2; ; n++) {
      const rel = isBundle ? forkId : `${forkId}.sql`;
      if (!taken.has(forkId) && !fs.existsSync(path.join(dirs[CUSTOM], rel))) break;
      forkId = `${item.id}-local-${n}`;
    }
    taken.add(forkId);
    item.fork_id = forkId;
    item.fork = `${CUSTOM}/${isBundle ? forkId : `${forkId}.sql`}`;
  }
  return items;
}

/** Engine hook: copies an old copy to its fork target under the new id. */
function fork(srcAbs, dstAbs, item) {
  try {
    if (item.case === 'a2') {
      fs.cpSync(srcAbs, dstAbs, { recursive: true, errorOnExist: true, force: false });
      editJson(path.join(dstAbs, 'manifest.json'), m => {
        m.id = item.fork_id;
        m.title = withSuffix(m.title, 'en');
      });
      let locales = [];
      try {
        locales = fs.readdirSync(path.join(dstAbs, 'locales')).filter(f => f.endsWith('.json'));
      } catch {
        // no locales
      }
      for (const f of locales) {
        editJson(path.join(dstAbs, 'locales', f), l => {
          if (l.manifest && typeof l.manifest.title === 'string') l.manifest.title = withSuffix(l.manifest.title, f.slice(0, -5));
        });
      }
    } else {
      fs.mkdirSync(path.dirname(dstAbs), { recursive: true });
      const text = fs.readFileSync(srcAbs, 'utf-8')
        .replace(/^(\s*--\s*@title\s*:\s*)(.*?)\s*$/m, (_, head, title) => `${head}${withSuffix(title, 'en')}`);
      fs.writeFileSync(dstAbs, text, { encoding: 'utf-8', flag: 'wx' });
    }
  } catch (err) {
    fs.rmSync(dstAbs, { recursive: true, force: true });
    throw err;
  }
}

/** Next free own-version id `<id>-local`, `<id>-local-2`, … below dashboards-custom/. */
function freeForkId(id, customDir, taken = new Set()) {
  const ids = customIdsOf(scanTree(customDir));
  for (let n = 1; ; n++) {
    const forkId = n === 1 ? `${id}-local` : `${id}-local-${n}`;
    if (!taken.has(forkId) && !ids.has(forkId)
      && !fs.existsSync(path.join(customDir, forkId)) && !fs.existsSync(path.join(customDir, `${forkId}.sql`))) return forkId;
  }
}

function compute(dirs, { exclude, stamp }) {
  const inventory = readInventory(dirs[SHIPPED]);
  if (!inventory) return { inventory: false, items: [] };
  const known = knownNames({ dashboardsDir: dirs[SHIPPED], queriesDir: dirs[QUERIES] });
  const canonical = new Map();
  const internal = templateInventory.readInventory('queries', dirs[QUERIES])
    || templateInventory.buildInventory('queries', dirs[QUERIES]);
  for (const q of internal.queries) canonical.set(q.name, `${QUERIES}/${q.path}`);
  for (const b of inventory.bundles) if (b.unit === 'file') canonical.set(b.id, `${SHIPPED}/${b.path}`);
  const snapshot = {
    shipped: scanTree(dirs[SHIPPED]),
    custom: scanTree(dirs[CUSTOM]),
    old: Object.fromEntries(OLD_BASES.filter(b => dirs[b]).map(b => [b, scanTree(dirs[b], null)])),
  };
  const items = classify(snapshot, inventory, { exclude, stamp, known, canonical });
  const frozen = readFrozenIndex(path.dirname(path.resolve(dirs[SHIPPED])));
  annotateModified(items, dirs, frozen);
  if (frozen) reclassifyFrozen(items, dirs, frozen, stamp);
  return { inventory: true, items: annotateForks(items, dirs, { customIds: customIdsOf(snapshot.custom), known }) };
}

/**
 * Own content by name (b1/f2/f5 → custom) that consists only of unedited
 * frozen copies is an old shipped copy whose id this release no longer ships:
 * it moves aside instead (a1 bundle, a3 folder, f1 file).
 */
function reclassifyFrozen(items, dirs, frozen, stamp) {
  for (const item of items) {
    if (item.target !== 'custom' || !['b1', 'f2', 'f5'].includes(item.case)) continue;
    const state = frozenState(item.from, dirs, frozen);
    if (!state || state.edited) continue;
    item.case = item.case === 'b1' ? (item.id ? 'a1' : 'a3') : 'f1';
    item.target = 'removed';
    item.to = `${REMOVED}/${stamp}/${item.from}`;
    item.note = null;
  }
}

const routine = engine.createCleanup({
  kind: 'dashboard',
  removedBase: REMOVED,
  baseDirs,
  compute,
  fork,
  pruneBases: OLD_BASES,
});

module.exports = {
  SHIPPED,
  CUSTOM,
  REMOVED,
  OLD_BASES,
  PROTOCOL_FILE,
  formatStamp,
  classify,
  summarize,
  scanTree,
  sameTree,
  baseDirs,
  preview: routine.preview,
  run: routine.run,
  lastRun: routine.lastRun,
  isRunning: routine.isRunning,
  forkUnit: fork,
  freeForkId,
  readFrozenIndex,
  blobSha,
};
