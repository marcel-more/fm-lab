import { useFavorites, type Favorites, type FavoritesOptions } from './useFavorites';

/** Dashboard favorites — `useFavorites('dashboard')`, kept for existing consumers. */
export type DashboardFavorites = Favorites;

export function useDashboardFavorites(options: FavoritesOptions = {}): DashboardFavorites {
  return useFavorites('dashboard', options);
}
