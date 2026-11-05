import i18n from '../i18n';
import {
  addFavorite as apiAdd, getFavorites, removeFavorite as apiRemove,
  type FavoriteKind, type FavoritesList,
} from '../api/favoritesApi';
import { showToast } from './toastStore';

/**
 * Client-side state of the favorites, one store per kind (dashboards, tests)
 * — shared by the star in a detail title and the favorites view of an
 * overview (useSyncExternalStore in useFavorites, no prop drilling, no
 * dataset in the gallery bundle).
 *
 * Loads once (deduped) and again on demand (overview mount, tab becoming
 * visible) — there is no push between tabs; single-id PUT/DELETE calls keep
 * concurrent tabs from losing changes. Toggles are optimistic: the id flips
 * at once, a failed call rolls back that id only and shows a toast. While
 * calls are pending, server answers are held back so they cannot undo a
 * newer optimistic change; the last answer applies once all have settled.
 *
 * Every change yields a NEW state object (new arrays, new Set) — consumers
 * memoizing on these identities recompute after each toggle.
 */

export interface FavoritesState {
  /** false until the first successful load. */
  loaded: boolean;
  /** Available favorite ids in the order they were added. */
  order: readonly string[];
  ids: ReadonlySet<string>;
  /** Stored ids that no longer resolve (gone, or no longer favoritable). */
  missing: readonly string[];
}

export interface FavoritesStore {
  readonly kind: FavoriteKind;
  subscribe: (listener: () => void) => () => void;
  getState: () => FavoritesState;
  /** Loads the favorites (deduped); `force` re-fetches an already loaded state. */
  ensureLoaded: (force?: boolean) => Promise<void>;
  toggle: (id: string) => Promise<boolean>;
  add: (id: string) => Promise<boolean>;
  /**
   * Removes a favorite. With a `title` the removal is announced in a toast
   * whose "Undo" adds the favorite again (a fresh PUT).
   */
  remove: (id: string, title?: string) => Promise<boolean>;
  /** Removes several favorites at once, without undo (e.g. the unavailable ones). */
  removeMany: (ids: readonly string[]) => Promise<boolean[]>;
}

function insertAt(list: readonly string[], index: number, id: string): string[] {
  const next = [...list];
  next.splice(Math.min(Math.max(index, 0), next.length), 0, id);
  return next;
}

function createFavoritesStore(kind: FavoriteKind): FavoritesStore {
  let state: FavoritesState = { loaded: false, order: [], ids: new Set(), missing: [] };
  const listeners = new Set<() => void>();
  let inflightLoad: Promise<void> | null = null;
  /** Bumped by every change call — a load that started earlier must not apply. */
  let changeGeneration = 0;
  let pendingChanges = 0;
  let heldAnswer: FavoritesList | null = null;

  function setState(order: readonly string[], missing: readonly string[], loaded = state.loaded): void {
    state = { loaded, order: [...order], ids: new Set(order), missing: [...missing] };
    for (const l of listeners) l();
  }

  function applyServer(server: FavoritesList): void {
    setState(server.items.map(e => e.id), server.missing, true);
  }

  function ensureLoaded(force = false): Promise<void> {
    if (!force && state.loaded) return Promise.resolve();
    if (inflightLoad) return inflightLoad;
    const generation = changeGeneration;
    inflightLoad = getFavorites(kind)
      .then(server => {
        if (pendingChanges === 0 && generation === changeGeneration) applyServer(server);
      })
      .catch(() => { /* transient — the next mount or visibility change retries */ })
      .finally(() => { inflightLoad = null; });
    return inflightLoad;
  }

  /** One optimistic single-id change; resolves to whether the server accepted it. */
  function change(id: string, add: boolean): Promise<boolean> {
    const orderIndex = state.order.indexOf(id);
    const missingIndex = state.missing.indexOf(id);
    changeGeneration += 1;
    pendingChanges += 1;
    if (add) {
      if (orderIndex < 0) setState([...state.order, id], state.missing.filter(x => x !== id));
    } else {
      setState(state.order.filter(x => x !== id), state.missing.filter(x => x !== id));
    }
    const call = add ? apiAdd(kind, id) : apiRemove(kind, id);
    return call
      .then(server => {
        heldAnswer = server;
        return true;
      })
      .catch(() => {
        // Roll back this id only — concurrent changes of other ids stay.
        let order = state.order.filter(x => x !== id);
        let missing = state.missing.filter(x => x !== id);
        if (orderIndex >= 0) order = insertAt(order, orderIndex, id);
        if (missingIndex >= 0) missing = insertAt(missing, missingIndex, id);
        setState(order, missing);
        showToast({ message: i18n.t('dashboard:favorites.saveFailed'), tone: 'error' });
        return false;
      })
      .finally(() => {
        pendingChanges -= 1;
        if (pendingChanges === 0 && heldAnswer) {
          const answer = heldAnswer;
          heldAnswer = null;
          applyServer(answer);
        }
      });
  }

  const add = (id: string) => change(id, true);

  return {
    kind,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getState: () => state,
    ensureLoaded,
    toggle: id => change(id, !state.ids.has(id)),
    add,
    remove(id, title) {
      if (title !== undefined) {
        showToast({
          message: i18n.t('dashboard:favorites.removed', { title }),
          action: { label: i18n.t('dashboard:favorites.undo'), onAction: () => { void add(id); } },
        });
      }
      return change(id, false);
    },
    removeMany: ids => Promise.all(ids.map(id => change(id, false))),
  };
}

const stores = new Map<FavoriteKind, FavoritesStore>();

/** The store of one kind — created on first use, shared by every consumer. */
export function getFavoritesStore(kind: FavoriteKind): FavoritesStore {
  let store = stores.get(kind);
  if (!store) {
    store = createFavoritesStore(kind);
    stores.set(kind, store);
  }
  return store;
}
