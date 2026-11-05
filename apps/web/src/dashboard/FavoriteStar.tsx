import type { FavoriteKind } from '../api/favoritesApi';
import { useFavorites } from '../hooks/useFavorites';
import { FavoriteButton } from './primitives/FavoriteButton';

/**
 * Favorite toggle of a dashboard or test page, right-aligned on its title
 * row. Optimistic — a failed save rolls back and shows a toast
 * (favoritesStore). Inert until the favorites are loaded, so a click never
 * acts on an unknown state.
 */
export function FavoriteStar({ id, kind = 'dashboard' }: { id: string; kind?: FavoriteKind }) {
  const favorites = useFavorites(kind);
  return (
    <FavoriteButton
      active={favorites.isFavorite(id)}
      onToggle={() => favorites.toggle(id)}
      size={20}
      className="dash-favstar--head"
      disabled={!favorites.loaded}
    />
  );
}
