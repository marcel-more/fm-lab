/**
 * Persistence of a `Table`'s view state (layout prop `stateKey`) on the two
 * levels of `_expansionStore.ts`:
 *
 * - **tab** (`sessionStorage`): sort, explicitly chosen page size, page, focus
 *   row and the one-shot "restore the focus" flag — "back" from the row's
 *   target lands on the same page with the keyboard focus on the opened row;
 * - **browser** (`localStorage`): sort and page size only — the seed for a tab
 *   without own state. A new tab starts on page 1 without focus.
 *
 * The page size is stored only when the user chose it; a derived default
 * (`defaultPageSize: 'auto'`) keeps following the row count. No tab sync, as
 * for the folder expansion.
 *
 * Runtime-import-free on purpose (see `_folderTree.ts`): the stores are passed
 * in, the unit tests use in-memory fakes.
 */
import type { KeyValueStore } from './_expansionStore';
import type { PageSize } from './_tablePaging';

export interface TableViewState {
  sort?: { field: string; dir: 'asc' | 'desc' };
  pageSize?: PageSize;
  page?: number;
  /** Identity of the focused row (`rowKey` value). */
  focus?: string;
  /** Set when a row was opened by keyboard: the next mount focuses it again. */
  restoreFocus?: boolean;
}

/** Parses a stored state; `null` = no (usable) entry. Unknown or invalid fields are dropped. */
export function parseTableState(raw: string | null): TableViewState | null {
  if (raw == null) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  const p = parsed as Record<string, unknown>;
  const out: TableViewState = {};
  const sort = p.sort as Record<string, unknown> | undefined;
  if (sort && typeof sort.field === 'string' && sort.field !== ''
      && (sort.dir === 'asc' || sort.dir === 'desc')) {
    out.sort = { field: sort.field, dir: sort.dir };
  }
  if (p.pageSize === 'all' || (typeof p.pageSize === 'number' && Number.isInteger(p.pageSize) && p.pageSize > 0)) {
    out.pageSize = p.pageSize;
  }
  if (typeof p.page === 'number' && Number.isInteger(p.page) && p.page >= 1) out.page = p.page;
  if (typeof p.focus === 'string') out.focus = p.focus;
  if (p.restoreFocus === true) out.restoreFocus = true;
  return out;
}

function read(store: KeyValueStore | null, key: string): TableViewState | null {
  if (!store) return null;
  try {
    return parseTableState(store.getItem(key));
  } catch {
    return null;
  }
}

/** The browser-level part of a state: what a new tab inherits. */
function seedOf(state: TableViewState): TableViewState {
  const out: TableViewState = {};
  if (state.sort) out.sort = state.sort;
  if (state.pageSize != null) out.pageSize = state.pageSize;
  return out;
}

/** Initial state of a mount: tab level → browser seed (sort + page size) → empty. */
export function loadTableState(tab: KeyValueStore | null, browser: KeyValueStore | null, key: string): TableViewState {
  const own = read(tab, key);
  if (own) return own;
  const seed = read(browser, key);
  return seed ? seedOf(seed) : {};
}

/** Writes the full state to the tab level and its seed part to the browser level. */
export function saveTableState(
  tab: KeyValueStore | null,
  browser: KeyValueStore | null,
  key: string,
  state: TableViewState,
): void {
  const writes: Array<[KeyValueStore | null, TableViewState]> = [[tab, state], [browser, seedOf(state)]];
  for (const [store, value] of writes) {
    if (!store) continue;
    try {
      store.setItem(key, JSON.stringify(value));
    } catch {
      /* storage unavailable — the state lives in the other level or the mount */
    }
  }
}
