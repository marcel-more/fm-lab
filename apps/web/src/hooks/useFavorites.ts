import { useEffect, useSyncExternalStore } from 'react';
import type { FavoriteKind } from '../api/favoritesApi';
import { getFavoritesStore } from '../lib/favoritesStore';

/**
 * Favorites of one kind (dashboards, tests) for the star in a detail title
 * and the favorites view of an overview (useSyncExternalStore over the
 * kind's favoritesStore).
 *
 * Loads once on first use; `refreshOnMount` re-fetches on every mount (the
 * overview), and a tab becoming visible re-fetches too — the sync between
 * tabs and browsers, there is no push. `enabled: false` keeps the hook inert
 * for TileGrid consumers without a favorites view.
 */
export interface Favorites {
  /** false until the first successful load. */
  loaded: boolean;
  ids: ReadonlySet<string>;
  /** Stored ids that no longer resolve (gone, or no longer favoritable). */
  missing: readonly string[];
  isFavorite: (id: string) => boolean;
  toggle: (id: string) => void;
  /** Removes a favorite; with a title the toast offers "Undo". */
  remove: (id: string, title?: string) => void;
  /** Removes several favorites without undo (unavailable ones). */
  removeMany: (ids: readonly string[]) => void;
}

export interface FavoritesOptions {
  enabled?: boolean;
  refreshOnMount?: boolean;
}

export function useFavorites(
  kind: FavoriteKind,
  { enabled = true, refreshOnMount = false }: FavoritesOptions = {},
): Favorites {
  const store = getFavoritesStore(kind);
  const snapshot = useSyncExternalStore(store.subscribe, store.getState);

  useEffect(() => {
    if (enabled) void store.ensureLoaded(refreshOnMount);
  }, [store, enabled, refreshOnMount]);

  useEffect(() => {
    if (!enabled) return undefined;
    const onVisible = () => {
      if (document.visibilityState === 'visible') void store.ensureLoaded(true);
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [store, enabled]);

  return {
    loaded: snapshot.loaded,
    ids: snapshot.ids,
    missing: snapshot.missing,
    isFavorite: id => snapshot.ids.has(id),
    toggle: id => { void store.toggle(id); },
    remove: (id, title) => { void store.remove(id, title); },
    removeMany: ids => { void store.removeMany(ids); },
  };
}
