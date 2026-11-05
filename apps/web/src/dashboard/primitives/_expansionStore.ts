/**
 * Persistence of the hierarchical list's folder expansion on two levels:
 *
 * - **tab** (`sessionStorage`): the working state of this tab — survives
 *   reload, "back" and every remount of the list;
 * - **browser** (`localStorage`): the seed for a tab without own state — a new
 *   tab starts with the list the user operated last.
 *
 * Every own action writes the tab's complete state as a snapshot to both
 * levels. Open tabs are never synchronised (no `storage` listener, no merge):
 * a list must not change without an action in its own tab.
 *
 * Format: `{ "<folder path>": true }` — open folders only; a folder without an
 * entry is closed, so folders the browser has never seen open start closed.
 *
 * Runtime-import-free on purpose (see `_folderTree.ts`): the stores are passed
 * in, the unit tests use in-memory fakes.
 */

/** The part of the Web Storage API the expansion state needs. */
export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export type ExpandedState = Record<string, true>;

/**
 * Parses a stored state. `null` = no (usable) entry — distinct from `{}`, the
 * state of a tab whose folders are all closed, which must not fall back to the
 * browser level.
 */
export function parseExpanded(raw: string | null): ExpandedState | null {
  if (raw == null) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  const out: ExpandedState = {};
  for (const [path, open] of Object.entries(parsed)) {
    if (open === true) out[path] = true;
  }
  return out;
}

function read(store: KeyValueStore | null, key: string): ExpandedState | null {
  if (!store) return null;
  try {
    return parseExpanded(store.getItem(key));
  } catch {
    return null;
  }
}

/** Initial state of a mount: tab level → browser level → all closed. */
export function loadExpanded(tab: KeyValueStore | null, browser: KeyValueStore | null, key: string): ExpandedState {
  return read(tab, key) ?? read(browser, key) ?? {};
}

/** Writes the tab's state as a snapshot to both levels; a failing store never blocks the other. */
export function saveExpanded(
  tab: KeyValueStore | null,
  browser: KeyValueStore | null,
  key: string,
  state: Readonly<Record<string, boolean>>,
): void {
  const snapshot: ExpandedState = {};
  for (const [path, open] of Object.entries(state)) {
    if (open === true) snapshot[path] = true;
  }
  const raw = JSON.stringify(snapshot);
  for (const store of [tab, browser]) {
    if (!store) continue;
    try {
      store.setItem(key, raw);
    } catch {
      /* storage unavailable — the state lives in the other level or the mount */
    }
  }
}

/**
 * Drops the entries of folders that no longer exist, so a folder re-created
 * later under the same path starts closed. `null` = nothing to drop. The
 * caller passes the complete folder dataset only — never an empty or partial
 * one (favorites view, failed load).
 */
export function pruneExpanded(
  state: Readonly<Record<string, boolean>>,
  knownPaths: ReadonlySet<string>,
): Record<string, boolean> | null {
  let changed = false;
  const out: Record<string, boolean> = {};
  for (const [path, open] of Object.entries(state)) {
    if (knownPaths.has(path)) out[path] = open;
    else changed = true;
  }
  return changed ? out : null;
}

/** The browser's stores, `null` where even accessing them throws (blocked storage). */
export function browserStores(): { tab: KeyValueStore | null; browser: KeyValueStore | null } {
  const get = (pick: () => Storage): KeyValueStore | null => {
    try {
      return pick();
    } catch {
      return null;
    }
  };
  return { tab: get(() => window.sessionStorage), browser: get(() => window.localStorage) };
}
