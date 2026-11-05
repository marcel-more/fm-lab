const fs = require('fs');
const path = require('path');
const { fmlabDir } = require('../plugins/settings-store');

/**
 * Favorites store — workspace-wide favorites of the web client.
 *
 *   .fmlab/favorites.json  →
 *   {
 *     "version": 1,
 *     "scopes": {
 *       "workspace": {
 *         "dashboard": [ { "id": "unused_layout", "added_at": "2026-11-01T10:12:00Z" } ]
 *       }
 *     }
 *   }
 *
 * Grouped by scope and object kind: today only the `workspace` scope and the
 * `dashboard` kind are written, per-user scopes and further kinds slot in
 * beside them without a format change. Entries the store does not touch
 * (other scopes, other kinds) survive every write.
 *
 * Deliberately a file of its own instead of a key in `.fmlab/settings.json`:
 * that file is saved as a whole via `PUT /api/system/config`, which would race
 * with favorite toggles.
 *
 * Reads normalize to the format above (missing or empty file → empty
 * structure). An unreadable file is never overwritten silently: the read
 * yields an empty structure and logs a warning, the next write first moves the
 * file aside to `favorites.json.corrupt-<timestamp>`. Writes are atomic
 * (tmp + rename); all file access is synchronous, so one API process is the
 * single writer without interleaving.
 */

const FORMAT_VERSION = 1;
const WORKSPACE_SCOPE = 'workspace';

function favoritesPath() {
  return path.join(fmlabDir(), 'favorites.json');
}

/** ISO-8601 UTC without milliseconds: 2026-11-01T10:12:00Z. */
function isoSeconds(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function normalizeEntries(list) {
  if (!Array.isArray(list)) return [];
  const seen = new Set();
  const out = [];
  for (const raw of list) {
    const id = isPlainObject(raw) ? raw.id : raw;
    if (typeof id !== 'string' || id === '' || seen.has(id)) continue;
    seen.add(id);
    const addedAt = isPlainObject(raw) && typeof raw.added_at === 'string' ? raw.added_at : null;
    out.push({ id, added_at: addedAt });
  }
  return out;
}

/** Brings any parsed content into the canonical shape (never throws). */
function normalize(data) {
  const scopes = {};
  if (isPlainObject(data) && isPlainObject(data.scopes)) {
    for (const [scope, kinds] of Object.entries(data.scopes)) {
      if (!isPlainObject(kinds)) continue;
      scopes[scope] = {};
      for (const [kind, list] of Object.entries(kinds)) {
        if (Array.isArray(list)) scopes[scope][kind] = normalizeEntries(list);
      }
    }
  }
  return { version: FORMAT_VERSION, scopes };
}

/**
 * Store bound to one file. `now` is injectable for tests.
 */
function createFavoritesStore(file, { now = () => new Date() } = {}) {
  let warnedFor = null;

  /** → { data, corrupt } — corrupt = the file exists but cannot be used. */
  function read() {
    let text;
    try {
      text = fs.readFileSync(file, 'utf-8');
    } catch (err) {
      if (err.code === 'ENOENT') return { data: normalize(null), corrupt: false };
      return unreadable(err.message);
    }
    if (text.trim() === '') return { data: normalize(null), corrupt: false };
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      return unreadable(err.message);
    }
    if (!isPlainObject(parsed)) return unreadable('top-level value is not an object');
    return { data: normalize(parsed), corrupt: false };
  }

  function unreadable(reason) {
    // One warning per file state — the overview reads on every mount.
    let stamp = null;
    try { stamp = fs.statSync(file).mtimeMs; } catch { /* gone meanwhile */ }
    if (stamp !== warnedFor) {
      warnedFor = stamp;
      console.warn(`favorites: cannot read ${file} (${reason}) — treating it as empty; it is moved aside on the next change`);
    }
    return { data: normalize(null), corrupt: true };
  }

  function write(data, corrupt) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (corrupt && fs.existsSync(file)) {
      const backup = `${file}.corrupt-${now().toISOString().replace(/[:.]/g, '-')}`;
      fs.renameSync(file, backup);
      console.warn(`favorites: moved unreadable ${file} aside to ${backup}`);
    }
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', 'utf-8');
    fs.renameSync(tmp, file);
    warnedFor = null;
  }

  function entriesOf(data, kind, scope) {
    return data.scopes[scope]?.[kind] ?? [];
  }

  /** Entries of one kind in insertion order (copies). */
  function list(kind, scope = WORKSPACE_SCOPE) {
    return entriesOf(read().data, kind, scope).map(e => ({ ...e }));
  }

  /** Idempotent: an existing entry keeps its `added_at`. Returns the new list. */
  function add(kind, id, scope = WORKSPACE_SCOPE) {
    const { data, corrupt } = read();
    const current = entriesOf(data, kind, scope);
    if (!current.some(e => e.id === id)) {
      data.scopes[scope] = { ...data.scopes[scope], [kind]: [...current, { id, added_at: isoSeconds(now()) }] };
      write(data, corrupt);
    }
    return list(kind, scope);
  }

  /** Idempotent: removing an absent id is a no-op. Returns the new list. */
  function remove(kind, id, scope = WORKSPACE_SCOPE) {
    const { data, corrupt } = read();
    const current = entriesOf(data, kind, scope);
    if (current.some(e => e.id === id)) {
      data.scopes[scope] = { ...data.scopes[scope], [kind]: current.filter(e => e.id !== id) };
      write(data, corrupt);
    }
    return list(kind, scope);
  }

  return { file, list, add, remove };
}

let defaultStore = null;

/** The workspace store on `.fmlab/favorites.json` (created on first use). */
function getDefaultFavoritesStore() {
  if (!defaultStore) defaultStore = createFavoritesStore(favoritesPath());
  return defaultStore;
}

module.exports = {
  FORMAT_VERSION,
  WORKSPACE_SCOPE,
  favoritesPath,
  createFavoritesStore,
  getDefaultFavoritesStore,
};
