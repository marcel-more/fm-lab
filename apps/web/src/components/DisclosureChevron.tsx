import './DisclosureChevron.css';

/**
 * Disclosure chevron of every expandable row, section and card: points right
 * when closed and rotates 90° down when open. `open = null` renders the empty
 * slot only, so leaf rows stay aligned with their expandable siblings.
 * Decorative — the owning control carries `aria-expanded` and the name.
 */
export function DisclosureChevron({ open, className }: { open: boolean | null; className?: string }) {
  return (
    <span
      className={`disclosure-chevron${open ? ' disclosure-chevron--open' : ''}${className ? ` ${className}` : ''}`}
      aria-hidden="true"
    >
      {open !== null && (
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          focusable="false"
        >
          <polyline points="9 6 15 12 9 18" />
        </svg>
      )}
    </span>
  );
}
