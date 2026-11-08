import { memo } from 'react';
import type { LayoutObject } from '../hooks/useLayoutData';
import { useLayoutObjectPalette, type LayoutObjectPalette } from './layoutObjectTheme';

/** `outOfScope` = outside the selected layout part (grey, half transparent, takes precedence). */
export type LayoutObjectDisplayMode = 'normal' | 'highlight' | 'dim' | 'outOfScope';
export type LabelMode = 'type' | 'name';

type Props = {
  object: LayoutObject;
  displayMode: LayoutObjectDisplayMode;
  labelMode: LabelMode;
  onMouseEnter: (uuid: string, clientX: number, clientY: number) => void;
  onMouseMove: (clientX: number, clientY: number) => void;
  onMouseLeave: () => void;
  /** `modifier` = Alt-Klick (macOS ⌥) → gehoistetes Cross-Nav-Ziel statt Detail. */
  onClick: (object: LayoutObject, opts?: { modifier?: boolean }) => void;
};

const CONTAINER_TYPES = new Set([
  'Portal', 'Group', 'Tab Control', 'Panel', 'Slide Control', 'PopoverPanel',
]);

const HIGHLIGHT_RING_WIDTH = 4;
const SELECTED_RING_WIDTH = 6;

function escapeText(s: string): string {
  // SVG-text Inhalt darf <,> nicht enthalten — React entkommt automatisch.
  return s.length > 32 ? s.slice(0, 31) + '…' : s;
}

// Hilfsfunktion: nicht-leeres Trim oder null. Verhindert, dass Whitespace-only Texte
// (z.B. ein einzelnes Leerzeichen als Trenner-Element) als sichtbares Label landen.
function nonBlank(s: string | null | undefined): string | null {
  if (!s) return null;
  const t = s.trim();
  return t.length > 0 ? t : null;
}

function buildLabel(o: LayoutObject, mode: LabelMode): string {
  if (mode === 'name') {
    return (
      nonBlank(o.field_name)
      ?? nonBlank(o.text_content)
      ?? nonBlank(o.object_name)
      ?? o.object_type
    );
  }
  return o.object_type;
}

export const LayoutObjectShape = memo(function LayoutObjectShape({
  object,
  displayMode,
  labelMode,
  onMouseEnter,
  onMouseMove,
  onMouseLeave,
  onClick,
}: Props) {
  const palette = useLayoutObjectPalette();
  const x = object.abs_left;
  const y = object.abs_top;
  const width = Math.max(object.abs_right - object.abs_left, 1);
  const height = Math.max(object.abs_bottom - object.abs_top, 1);

  const outOfScope = displayMode === 'outOfScope';
  const dimmed = displayMode === 'dim' || outOfScope;

  const fill = dimmed ? palette.dimmedFill : palette.fillFor(object.object_type);
  const stroke = dimmed ? palette.dimmedStroke : palette.strokeFor(object.object_type);
  const labelColor = dimmed ? palette.dimmedText : palette.normalText;
  const isContainer = CONTAINER_TYPES.has(object.object_type);

  const label = escapeText(buildLabel(object, labelMode));
  const showLabel = height >= 14 && width >= 30;

  return (
    <g
      className={outOfScope ? 'layout-object layout-object--out-of-scope' : 'layout-object'}
      style={{ cursor: 'pointer' }}
      opacity={outOfScope ? 0.5 : undefined}
      onMouseEnter={e => onMouseEnter(object.object_uuid, e.clientX, e.clientY)}
      onMouseMove={e => onMouseMove(e.clientX, e.clientY)}
      onMouseLeave={onMouseLeave}
      onClick={e => onClick(object, { modifier: e.altKey })}
    >
      <rect
        x={x}
        y={y}
        width={width}
        height={height}
        fill={fill}
        fillOpacity={0.6}
        stroke={stroke}
        strokeWidth={1}
        strokeDasharray={isContainer ? '5,3' : undefined}
        rx={2}
        ry={2}
      />
      {showLabel && (
        <text
          x={x + width / 2}
          y={y + height / 2 + 3}
          textAnchor="middle"
          fontSize={9}
          fill={labelColor}
          fontFamily='-apple-system, "Segoe UI", Arial, sans-serif'
          pointerEvents="none"
        >
          {label}
        </text>
      )}
    </g>
  );
});

/**
 * Highlight-Ring (orange) als globales SVG-Overlay — wird wie der SelectionRing *nach*
 * allen Objekten gerendert, damit er auch dann sichtbar bleibt, wenn das Treffer-Objekt
 * von späteren Container-Children visuell überlagert wird.
 */
export const HighlightRing = memo(function HighlightRing({ object }: { object: LayoutObject }) {
  const palette = useLayoutObjectPalette();
  const x = object.abs_left;
  const y = object.abs_top;
  const width = Math.max(object.abs_right - object.abs_left, 1);
  const height = Math.max(object.abs_bottom - object.abs_top, 1);
  const offset = HIGHLIGHT_RING_WIDTH / 2;
  return (
    <rect
      x={x - offset}
      y={y - offset}
      width={width + HIGHLIGHT_RING_WIDTH}
      height={height + HIGHLIGHT_RING_WIDTH}
      fill="none"
      stroke={palette.highlightRing}
      strokeWidth={HIGHLIGHT_RING_WIDTH}
      rx={4}
      ry={4}
      pointerEvents="none"
    />
  );
});

/**
 * Selektions-Ring als globales SVG-Overlay — wird *nach* allen Layout-Objekten gerendert,
 * sodass er auch über tief verschachtelten Tab-Panels sichtbar bleibt.
 */
export const SelectionRing = memo(function SelectionRing({ object }: { object: LayoutObject }) {
  const palette = useLayoutObjectPalette();
  const x = object.abs_left;
  const y = object.abs_top;
  const width = Math.max(object.abs_right - object.abs_left, 1);
  const height = Math.max(object.abs_bottom - object.abs_top, 1);
  const offset = SELECTED_RING_WIDTH / 2;
  return (
    <rect
      x={x - offset}
      y={y - offset}
      width={width + SELECTED_RING_WIDTH}
      height={height + SELECTED_RING_WIDTH}
      fill="none"
      stroke={palette.selectionRing}
      strokeWidth={SELECTED_RING_WIDTH}
      rx={6}
      ry={6}
      pointerEvents="none"
    />
  );
});

// Re-export für Konsumenten, die die Palette außerhalb dieses Files brauchen
export { useLayoutObjectPalette };
export type { LayoutObjectPalette };
