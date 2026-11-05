const fs = require('fs');
const path = require('path');

/**
 * Template cleanup engine — the shared file-system layer of the cleanup
 * routines that move leftovers of older template layouts to their place
 * (`dashboard-cleanup.js`, `test-cleanup.js`).
 *
 * A routine is a configuration:
 *
 *   {
 *     kind,          'dashboards' | 'tests' — used in messages
 *     removedBase,   logical base of the removal folder (`dashboards-removed`)
 *     baseDirs(),    logical base → absolute directory; includes removedBase.
 *                    A logical path is `<base>/<rel>`, e.g. `dashboards/home`.
 *     compute(dirs, { exclude, stamp })
 *                    → { inventory: boolean, items }   pure classification +
 *                    annotations; `inventory: false` = no usable inventory,
 *                    nothing classified
 *     pruneBases?    logical bases whose directories are removed when a run
 *                    left them empty (old locations that are given up)
 *     fork?(srcAbs, dstAbs, item)
 *                    copies an item's source to `dstAbs` as an own copy of
 *                    the user (new id) before the source is moved; used for
 *                    items that carry a logical `fork` target
 *   }
 *
 * An item is `{ case, from, to, target: 'custom'|'removed', id, ids, modified,
 * conflict, note?, fork?, fork_id? }` with logical `from`/`to`/`fork`.
 * Principles shared by every routine: only move, never delete; the server
 * classifies anew on every run and takes the client's `exclude` list only as a
 * subset; one run per routine at a time; every run that moved something leaves
 * `cleanup.json` in its time-stamped folder `<removedBase>/<stamp>/`, with the
 * `trigger` of the run (`manual` from the overview, `startup` from the
 * automatic run at server start).
 */

const PROTOCOL_FILE = 'cleanup.json';
// Files ignored when comparing an old copy with the shipped one.
const COMPARE_IGNORED = new Set(['.DS_Store', 'Thumbs.db', 'desktop.ini']);
const MAX_DEPTH = 8;

/** UTC, file-system safe: 2026-11-02T14-30-05Z. */
function formatStamp(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z').replace(/:/g, '-');
}

function summarize(items) {
  return {
    total: items.length,
    to_custom: items.filter(i => i.target === 'custom').length,
    to_removed: items.filter(i => i.target === 'removed').length,
    modified: items.filter(i => i.modified).length,
    conflicts: items.filter(i => i.conflict).length,
    forked: items.filter(i => i.fork).length,
  };
}

/** `dashboards-custom/a/b` → absolute path (null for an unknown base). */
function resolveLogical(logical, dirs) {
  const [base, ...rest] = logical.split('/');
  const root = dirs[base];
  return root ? path.join(root, ...rest) : null;
}

/**
 * Snapshot of a base directory; null when it does not exist.
 * Node: { name, rel, bundle, dirs: Node[], files: string[] }. `bundle` marks a
 * unit directory — one that holds `marker` (`manifest.json`, `test.json`);
 * units are not descended into. `marker: null` = plain tree without units.
 */
function scanTree(absBase, marker = 'manifest.json') {
  const read = (abs, rel, name, depth) => {
    let entries;
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch (err) {
      if (err.code === 'ENOENT' || err.code === 'ENOTDIR') return null;
      throw err;
    }
    const bundle = marker !== null && rel !== '' && entries.some(e => e.isFile() && e.name === marker);
    const node = { name, rel, bundle, dirs: [], files: [] };
    for (const e of entries) {
      if (e.isDirectory()) {
        if (e.name.startsWith('.') || bundle || depth >= MAX_DEPTH) continue;
        const childRel = rel ? `${rel}/${e.name}` : e.name;
        const child = read(path.join(abs, e.name), childRel, e.name, depth + 1);
        if (child) node.dirs.push(child);
      } else {
        node.files.push(e.name);
      }
    }
    node.dirs.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    node.files.sort();
    return node;
  };
  return read(absBase, '', '', 0);
}

/** Relative file list of a directory tree (system files ignored), sorted. */
function listFiles(absDir) {
  const out = [];
  const walk = (abs, rel) => {
    for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(path.join(abs, e.name), childRel);
      else if (!COMPARE_IGNORED.has(e.name)) out.push(childRel);
    }
  };
  walk(absDir, '');
  return out.sort();
}

/** True when both directory trees hold the same files with the same bytes. */
function sameTree(a, b) {
  let filesA;
  let filesB;
  try {
    filesA = listFiles(a);
    filesB = listFiles(b);
  } catch {
    return false;
  }
  if (filesA.length !== filesB.length || filesA.some((f, i) => f !== filesB[i])) return false;
  return filesA.every(f => fs.readFileSync(path.join(a, f)).equals(fs.readFileSync(path.join(b, f))));
}

/** Nearest existing ancestor (for the device check of a not yet created target). */
function existingAncestor(abs) {
  let current = abs;
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return current;
}

/**
 * Moves `src` to `dst`. An existing directory at `dst` (created by an earlier
 * item of the same run, e.g. an old copy moved before its rubric folder) is
 * merged into entry by entry.
 */
function moveInto(src, dst) {
  if (!fs.existsSync(dst)) {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.renameSync(src, dst);
    return;
  }
  if (!fs.statSync(src).isDirectory() || !fs.statSync(dst).isDirectory()) {
    throw Object.assign(new Error(`target exists: ${dst}`), { code: 'EEXIST' });
  }
  for (const name of fs.readdirSync(src)) moveInto(path.join(src, name), path.join(dst, name));
  fs.rmdirSync(src);
}

/** Removes empty directories below `abs` (bottom-up), then `abs` itself when empty. */
function pruneEmptyDirs(abs) {
  let entries;
  try {
    entries = fs.readdirSync(abs, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) if (e.isDirectory()) pruneEmptyDirs(path.join(abs, e.name));
  try {
    fs.rmdirSync(abs);
  } catch {
    // not empty (or gone) — stays
  }
}

// Title suffix of an own version, by locale file name (`en` = manifest.json).
const OWN_VERSION_SUFFIX = {
  en: '(own version)',
  de: '(eigene Fassung)',
  es: '(versión propia)',
  fr: '(version personnelle)',
  it: '(versione propria)',
  ja: '（独自版）',
  ko: '(사용자 버전)',
  nl: '(eigen versie)',
  pt: '(versão própria)',
  sv: '(egen version)',
  'zh-Hans': '（自定义版本）',
};
/** `title` with the own-version suffix of `lang` (idempotent). */
const withOwnVersionSuffix = (title, lang) => {
  const suffix = OWN_VERSION_SUFFIX[lang] || OWN_VERSION_SUFFIX.en;
  return typeof title === 'string' && !title.endsWith(suffix) ? `${title} ${suffix}` : title;
};

/** Rewrites a JSON file in place; unreadable files stay as they are. */
function editJson(abs, edit) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(abs, 'utf-8'));
  } catch {
    return;
  }
  edit(data);
  fs.writeFileSync(abs, JSON.stringify(data, null, 2) + '\n', 'utf-8');
}

const yieldToLoop = () => new Promise(resolve => setImmediate(resolve));

/** Builds the routine `{ preview, run, isRunning }` for one configuration. */
function createCleanup(config) {
  const { kind, removedBase } = config;
  let running = false;

  /**
   * Read-only check. → { inventory: boolean, stamp, items, summary }.
   * The `stamp` in the `to` paths is the one a run started now would use.
   */
  function preview({ exclude = [], now = new Date() } = {}) {
    const stamp = formatStamp(now);
    const { inventory, items } = config.compute(config.baseDirs(), { exclude, stamp });
    return { inventory, stamp, items, summary: summarize(items) };
  }

  /**
   * Runs the cleanup. Classifies anew (never trusts a client list), leaves the
   * `exclude` entries in place, checks every source and target before moving
   * anything, moves item by item and writes `cleanup.json` into the run folder.
   * An item with a `fork` target is first copied there as an own copy; when
   * the copy fails, its source stays in place.
   *
   * → { inventory, stamp, moved: item[], skipped: item[], errors: [{from, message}],
   *     summary, removed_dir, trigger }   (summary counts the moved items)
   * Rejects with `{ code: 'CLEANUP_RUNNING' }` while another run of this routine is active.
   */
  async function run({ exclude = [], now = new Date(), trigger = 'manual' } = {}) {
    if (running) throw Object.assign(new Error(`A ${kind} cleanup is already running`), { code: 'CLEANUP_RUNNING' });
    running = true;
    try {
      const dirs = config.baseDirs();
      let stamp = formatStamp(now);
      for (let n = 2; fs.existsSync(path.join(dirs[removedBase], stamp)); n++) stamp = `${formatStamp(now)}-${n}`;
      const { inventory, items } = config.compute(dirs, { exclude, stamp });
      const result = (moved, skipped, errors, removedDir) =>
        ({ inventory, stamp, moved, skipped, errors, summary: summarize(moved), removed_dir: removedDir, trigger });
      if (!inventory || items.length === 0) return result([], [], [], null);

      // Preflight: sources present, own-content targets free, one file system.
      const errors = [];
      for (const item of items) {
        const src = resolveLogical(item.from, dirs);
        const dst = resolveLogical(item.to, dirs);
        if (!fs.existsSync(src)) { errors.push({ from: item.from, message: 'source no longer exists' }); continue; }
        if (item.target === 'custom' && fs.existsSync(dst)) { errors.push({ from: item.from, message: `target exists: ${item.to}` }); continue; }
        if (item.fork && (!config.fork || fs.existsSync(resolveLogical(item.fork, dirs)))) {
          errors.push({ from: item.from, message: `own copy target exists: ${item.fork}` });
          continue;
        }
        if (fs.statSync(src).dev !== fs.statSync(existingAncestor(dst)).dev) {
          errors.push({ from: item.from, message: `source and target are on different file systems (${item.to})` });
        }
      }
      if (errors.length) return result([], items, errors, null);

      const moved = [];
      const skipped = [];
      for (const item of items) {
        if (errors.length) { skipped.push(item); continue; }
        try {
          if (item.fork) config.fork(resolveLogical(item.from, dirs), resolveLogical(item.fork, dirs), item);
          moveInto(resolveLogical(item.from, dirs), resolveLogical(item.to, dirs));
          moved.push(item);
        } catch (err) {
          errors.push({ from: item.from, message: err.code === 'EXDEV' ? 'source and target are on different file systems' : err.message });
          skipped.push(item);
        }
        await yieldToLoop();
      }
      if (!moved.length) return result(moved, skipped, errors, null);

      // An old location that is given up disappears once this run left nothing in it.
      for (const base of config.pruneBases || []) {
        if (dirs[base] && moved.some(i => i.from === base || i.from.startsWith(`${base}/`))) pruneEmptyDirs(dirs[base]);
      }

      // The protocol lives in the run folder — also when only own content
      // moved, so every run leaves a trace.
      const runDir = path.join(dirs[removedBase], stamp);
      fs.mkdirSync(runDir, { recursive: true });
      const protocol = {
        version: 1,
        created_at: now.toISOString().replace(/\.\d{3}Z$/, 'Z'),
        trigger,
        moved: moved.map(({ case: c, from, to, target, id, ids, modified, conflict, note, fork, fork_id: forkId }) =>
          ({ case: c, from, to, target, id, ids, modified, conflict, ...(note ? { note } : {}), ...(fork ? { fork, fork_id: forkId } : {}) })),
        skipped: skipped.map(i => i.from),
        excluded: exclude,
        errors,
      };
      const tmp = path.join(runDir, `${PROTOCOL_FILE}.${process.pid}.tmp`);
      fs.writeFileSync(tmp, JSON.stringify(protocol, null, 2) + '\n', 'utf-8');
      fs.renameSync(tmp, path.join(runDir, PROTOCOL_FILE));
      return result(moved, skipped, errors, `${removedBase}/${stamp}`);
    } finally {
      running = false;
    }
  }

  /**
   * The newest run of this routine with the given trigger, read from the
   * protocols in `<removedBase>/` (survives restarts). null when there is none.
   * → { stamp, created_at, trigger, removed_dir, summary, forks: [{ from, fork, fork_id }] }
   */
  function lastRun({ trigger } = {}) {
    const base = config.baseDirs()[removedBase];
    let stamps;
    try {
      stamps = fs.readdirSync(base, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name);
    } catch {
      return null;
    }
    // Stamps sort chronologically; `-2` suffixes of the same second sort after.
    stamps.sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
    for (const stamp of stamps) {
      let protocol;
      try {
        protocol = JSON.parse(fs.readFileSync(path.join(base, stamp, PROTOCOL_FILE), 'utf-8'));
      } catch {
        continue;
      }
      const runTrigger = protocol.trigger || 'manual';
      if (trigger && runTrigger !== trigger) continue;
      const moved = Array.isArray(protocol.moved) ? protocol.moved : [];
      return {
        stamp,
        created_at: protocol.created_at ?? null,
        trigger: runTrigger,
        removed_dir: `${removedBase}/${stamp}`,
        summary: summarize(moved),
        forks: moved.filter(m => m.fork).map(({ from, fork, fork_id: forkId }) => ({ from, fork, fork_id: forkId })),
      };
    }
    return null;
  }

  return { preview, run, lastRun, isRunning: () => running };
}

module.exports = {
  PROTOCOL_FILE,
  COMPARE_IGNORED,
  formatStamp,
  summarize,
  resolveLogical,
  scanTree,
  listFiles,
  sameTree,
  withOwnVersionSuffix,
  editJson,
  createCleanup,
};
