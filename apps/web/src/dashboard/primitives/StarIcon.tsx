/**
 * Five-point star of the favorites: outline = not a favorite, filled = a
 * favorite. Shared by the star in the dashboard title, the favorites segment
 * of the view selector and the remove star of the favorites list. Inherits
 * the text colour (`currentColor`); stroke weight matches the view-toolbar
 * icons.
 */
export function StarIcon({ filled = false, size = 16 }: { filled?: boolean; size?: number }) {
  return (
    <svg
      className="dash-staricon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? 'currentColor' : 'none'}
      stroke="currentColor"
      strokeWidth="2"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M12 3.2l2.7 5.5 6.1.9-4.4 4.3 1 6.1-5.4-2.9-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z" />
    </svg>
  );
}
