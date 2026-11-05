import type { ReactNode } from 'react';
import './BulkToggle.css';

/**
 * Segmented "expand all / collapse all" control shared by every expandable
 * tree or listing (dashboard list, hierarchy view, script viewer). Icons are
 * double chevrons in the stroke style of DisclosureChevron; the label hides
 * where a host scopes `.bulk-toggle__label` away (narrow toolbars).
 */

const iconProps = {
  width: 14,
  height: 14,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
  focusable: 'false' as const,
};

export const ExpandAllIcon = () => (
  <svg {...iconProps}>
    <polyline points="7 7 12 12 17 7" />
    <polyline points="7 13 12 18 17 13" />
  </svg>
);

export const CollapseAllIcon = () => (
  <svg {...iconProps}>
    <polyline points="7 11 12 6 17 11" />
    <polyline points="7 17 12 12 17 17" />
  </svg>
);

/** Collapse multi-line content into one line: chevron folding between two rules. */
export const CollapseLinesIcon = () => (
  <svg {...iconProps}>
    <line x1="5" y1="5" x2="19" y2="5" />
    <polyline points="8 15 12 11 16 15" />
    <line x1="5" y1="19" x2="19" y2="19" />
  </svg>
);

export function BulkToggleGroup({ label, children }: { label?: string; children: ReactNode }) {
  return (
    <span className="bulk-toggle" role="group" aria-label={label}>
      {children}
    </span>
  );
}

export function BulkToggleButton({
  icon,
  label,
  onClick,
  disabled = false,
  title,
}: {
  icon: ReactNode;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  /** Tooltip; defaults to the label (stays useful when the label is hidden). */
  title?: string;
}) {
  return (
    <button type="button" className="bulk-toggle__btn" disabled={disabled} onClick={onClick} title={title ?? label}>
      {icon}
      <span className="bulk-toggle__label">{label}</span>
    </button>
  );
}
