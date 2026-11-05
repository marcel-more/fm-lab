import { API_BASE } from '../config/apiBase';

/**
 * Favorites-API-Client — workspace-wide favorites (`.fmlab/favorites.json`),
 * independent of the selected solution, one list per kind (dashboards incl.
 * single-file units, Analysis Tests). Single-id operations only, so two tabs
 * never overwrite each other's changes. Plain fetch like the rest of the
 * frontend.
 */

const API = `${API_BASE}/api`;

export interface FavoriteEntry {
  id: string;
  /** ISO-8601 UTC; null for entries written without a timestamp. */
  added_at: string | null;
}

/** Kinds the favorites API knows. */
export type FavoriteKind = 'dashboard' | 'test';

export interface FavoritesList {
  /** Available favorites in the order they were added. */
  items: FavoriteEntry[];
  /** Stored ids that no longer resolve (gone, or no longer favoritable). */
  missing: string[];
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API}${path}`, init);
  if (!res.ok) {
    let detail = '';
    try {
      const body = await res.json();
      detail = body?.error?.message ?? '';
    } catch {
      /* ignore */
    }
    throw new Error(`HTTP ${res.status} ${detail || res.statusText}`);
  }
  const body = await res.json();
  if (body?.success === false) {
    throw new Error(body?.error?.message || 'Unknown API error');
  }
  return body.data as T;
}

const listPath = (kind: FavoriteKind) => `/favorites/${kind}`;
const itemPath = (kind: FavoriteKind, id: string) => `${listPath(kind)}/${encodeURIComponent(id)}`;

export function getFavorites(kind: FavoriteKind): Promise<FavoritesList> {
  return request<FavoritesList>(listPath(kind));
}

export function addFavorite(kind: FavoriteKind, id: string): Promise<FavoritesList> {
  return request<FavoritesList>(itemPath(kind, id), { method: 'PUT' });
}

export function removeFavorite(kind: FavoriteKind, id: string): Promise<FavoritesList> {
  return request<FavoritesList>(itemPath(kind, id), { method: 'DELETE' });
}
