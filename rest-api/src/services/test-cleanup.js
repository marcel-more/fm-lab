const fs = require('fs');
const path = require('path');
const environment = require('../config/environment');
const templateInventory = require('./template-inventory');
const engine = require('./template-cleanup');

/**
 * Analysis Test cleanup — finds tests and folders in the shipped tree
 * `tests/` that this release does not ship, and moves them to their place.
 * Configuration of the template cleanup engine (`template-cleanup.js`).
 *
 * `git pull` leaves untracked rests behind, installations updated by copying
 * keep old copies of tests that were moved or renamed, and own tests written
 * into `tests/` would be overwritten by the next update. The reference for
 * "what does this release ship" is `tests/inventory.json`; without a usable
 * inventory nothing is classified.
 *
 * Cases (a test is a directory with `test.json`):
 *
 *   t1  tests/   test not at its inventory path, id of a shipped test     → removed
 *   t2  tests/   own test (or folder of own tests), id unknown            → tests-custom/<rel>
 *   t3  tests/   t2 whose id or target already exists in tests-custom/    → removed (`conflict`)
 *   t4  tests/   any other folder not in the inventory                    → removed
 *
 * Never touched: anything in the inventory, `tests-custom/`, `tests-community/`,
 * files on the top level of `tests/`.
 *
 * "removed" = `tests-removed/<stamp>/tests/<rel>`, one time-stamped folder per
 * run with `cleanup.json`. Nothing is deleted.
 */

const SHIPPED = 'tests';
const CUSTOM = 'tests-custom';
const REMOVED = 'tests-removed';
const MARKER = 'test.json';

/**
 * @param {{ shipped: object|null, custom: object|null }} snapshot  root nodes (rel '')
 * @param {{ tests: {id,path}[], folders: string[] }} inventory
 * @param {{ exclude?: string[], stamp?: string }} [opts]
 * @returns {{ case, from, to, target, id, ids, conflict, modified, note }[]}
 */
function classify(snapshot, inventory, { exclude = [], stamp = '<timestamp>' } = {}) {
  const excluded = new Set(exclude);
  const testPaths = new Set(inventory.tests.map(t => t.path));
  const inventoryIds = new Set(inventory.tests.map(t => t.id));
  const folderPaths = new Set(inventory.folders);
  for (const t of inventory.tests) {
    const parts = t.path.split('/');
    for (let i = 1; i < parts.length; i++) folderPaths.add(parts.slice(0, i).join('/'));
  }

  const customDirs = new Map(); // rel → node
  const customIds = new Set();
  const indexCustom = node => {
    for (const d of node.dirs) {
      customDirs.set(d.rel, d);
      if (d.bundle) customIds.add(d.name);
      else indexCustom(d);
    }
  };
  if (snapshot.custom) indexCustom(snapshot.custom);
  const claimed = new Set();

  const items = [];
  const removedTo = rel => `${REMOVED}/${stamp}/${SHIPPED}/${rel}`;
  const push = item => {
    if (excluded.has(item.from)) return false;
    items.push({ ids: item.id ? [item.id] : [], ...item, modified: false, conflict: item.conflict === true, note: null });
    return true;
  };

  const testsBelow = node => node.dirs.flatMap(d => (d.bundle ? [d] : testsBelow(d)));
  const customBlocked = rel => {
    if (customDirs.has(rel)) return true;
    const parts = rel.split('/');
    for (let i = 1; i < parts.length; i++) {
      if (customDirs.get(parts.slice(0, i).join('/'))?.bundle) return true;
    }
    return false;
  };

  const pushOwn = (node, ids) => {
    const id = node.bundle ? node.name : null;
    if (ids.some(i => customIds.has(i) || claimed.has(i)) || customBlocked(node.rel)) {
      return push({ case: 't3', from: `${SHIPPED}/${node.rel}`, to: removedTo(node.rel), target: 'removed', id, ids, conflict: true });
    }
    const moved = push({ case: 't2', from: `${SHIPPED}/${node.rel}`, to: `${CUSTOM}/${node.rel}`, target: 'custom', id, ids });
    if (moved) ids.forEach(i => claimed.add(i));
    return moved;
  };

  // Returns true when `node` (not in the inventory) moves away completely.
  const foreign = node => {
    if (node.bundle) {
      if (inventoryIds.has(node.name)) {
        return push({ case: 't1', from: `${SHIPPED}/${node.rel}`, to: removedTo(node.rel), target: 'removed', id: node.name });
      }
      return pushOwn(node, [node.name]);
    }
    const rest = { case: 't4', from: `${SHIPPED}/${node.rel}`, to: removedTo(node.rel), target: 'removed', id: null };
    const below = testsBelow(node);
    if (below.length === 0) return push(rest);
    const ids = below.map(t => t.name);
    if (!ids.some(i => inventoryIds.has(i) || customIds.has(i) || claimed.has(i)) && !customBlocked(node.rel)) {
      return pushOwn(node, ids); // a folder of own tests moves as one
    }
    let allGone = true;
    for (const d of node.dirs) if (!foreign(d)) allGone = false;
    return allGone && push(rest);
  };

  const walkShipped = node => {
    for (const d of node.dirs) {
      if (testPaths.has(d.rel)) continue;
      if (folderPaths.has(d.rel)) walkShipped(d);
      else foreign(d);
    }
  };

  if (snapshot.shipped) walkShipped(snapshot.shipped);
  return items;
}

function baseDirs() {
  const t = environment.templates;
  return {
    [SHIPPED]: t.testsDir,
    [CUSTOM]: t.testsCustomDir,
    [REMOVED]: t.testsRemovedDir,
  };
}

function compute(dirs, { exclude, stamp }) {
  const inventory = templateInventory.readInventory('tests', dirs[SHIPPED]);
  if (!inventory) return { inventory: false, items: [] };
  const snapshot = { shipped: engine.scanTree(dirs[SHIPPED], MARKER), custom: engine.scanTree(dirs[CUSTOM], MARKER) };
  return { inventory: true, items: classify(snapshot, inventory, { exclude, stamp }) };
}

/** Copies a test folder to `dstAbs` as an own version: new id, title suffix (also per locale). */
function forkTest(srcAbs, dstAbs, forkId) {
  try {
    fs.cpSync(srcAbs, dstAbs, { recursive: true, errorOnExist: true, force: false });
    engine.editJson(path.join(dstAbs, MARKER), test => {
      test.id = forkId;
      test.title = engine.withOwnVersionSuffix(test.title, 'en');
      for (const [lang, overrides] of Object.entries(test.locales || {})) {
        if (overrides && typeof overrides.title === 'string') overrides.title = engine.withOwnVersionSuffix(overrides.title, lang);
      }
    });
  } catch (err) {
    fs.rmSync(dstAbs, { recursive: true, force: true });
    throw err;
  }
}

/** Next free own-version id `<id>-local`, `<id>-local-2`, … below tests-custom/. */
function freeForkId(id, customDir, taken = new Set()) {
  for (let n = 1; ; n++) {
    const forkId = n === 1 ? `${id}-local` : `${id}-local-${n}`;
    if (!taken.has(forkId) && !fs.existsSync(path.join(customDir, forkId))) return forkId;
  }
}

const routine = engine.createCleanup({ kind: 'test', removedBase: REMOVED, baseDirs, compute });

module.exports = {
  SHIPPED,
  CUSTOM,
  REMOVED,
  PROTOCOL_FILE: engine.PROTOCOL_FILE,
  classify,
  preview: routine.preview,
  run: routine.run,
  lastRun: routine.lastRun,
  isRunning: routine.isRunning,
  forkTest,
  freeForkId,
};
