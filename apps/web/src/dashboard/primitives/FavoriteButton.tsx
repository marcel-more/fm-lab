import { useTranslation } from 'react-i18next';
import { StarIcon } from './StarIcon';

/**
 * Favorite star as a button — the one control behind the star in the
 * dashboard title, on dashboard tiles and in the list rows. Outline = not a
 * favorite, filled = favorite. The click never reaches the surrounding row or
 * tile (which would open the dashboard or fold a folder).
 */
export function FavoriteButton({
  active, onToggle, name, size = 16, className = '', tabIndex, disabled,
}: {
  active: boolean;
  onToggle: () => void;
  /** Dashboard title, appended to the accessible name where rows repeat the button. */
  name?: string;
  size?: number;
  className?: string;
  tabIndex?: number;
  disabled?: boolean;
}) {
  const { t } = useTranslation(['dashboard']);
  const label = t(active ? 'dashboard:favorites.remove' : 'dashboard:favorites.add') as string;
  return (
    <button
      type="button"
      className={`dash-favstar${active ? ' dash-favstar--on' : ''}${className ? ` ${className}` : ''}`}
      aria-pressed={active}
      aria-label={name ? `${label}: ${name}` : label}
      title={label}
      tabIndex={tabIndex}
      disabled={disabled}
      onClick={e => {
        e.stopPropagation();
        onToggle();
      }}
      onDoubleClick={e => e.stopPropagation()}
    >
      <StarIcon filled={active} size={size} />
    </button>
  );
}
