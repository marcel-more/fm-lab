import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useTranslation } from 'react-i18next';
import { orderSelection, selectionSummary, toggleSelection } from '../lib/multiSelect';
import './MultiSelectPopover.css';

export interface MultiSelectOption {
  value: string;
  label: string;
  /** Number shown at the end of the entry (facet count). */
  count?: number;
  /** Tooltip of the entry. */
  title?: string;
  /** Small muted marker after the label (e.g. "custom style"). */
  badge?: string;
  /** Warning marker; the text is its tooltip. */
  warning?: string;
  /** Sets the entry off from the following ones (special entries on top). */
  dividerAfter?: boolean;
}

export interface MultiSelectPopoverProps {
  options: MultiSelectOption[];
  /** Chosen values; values the options do not list are kept. */
  selected: string[];
  /** New selection, in option order (unlisted values last); [] = nothing chosen. */
  onChange: (values: string[]) => void;
  /** Caption before the control. */
  caption?: string;
  /** Trigger caption when nothing is chosen (default: "All"). */
  emptyLabel?: string;
  /** Extra class on the root element. */
  className?: string;
}

/**
 * Multi-select as a dropdown of checkboxes: a trigger with the current choice
 * ("All", one or two labels, "3 selected"), an × to clear it, and a popover with
 * a "clear" entry and one checkbox per option.
 *
 * The popover lives in a portal on document.body with fixed coordinates, so no
 * overflow:hidden of a card or toolbar can clip it. Left-aligned under the
 * trigger, flipped above when it would leave the viewport, clamped horizontally;
 * a second pass after mount uses the real height.
 *
 * Closes on a click outside trigger and popover and on Escape. Escape is caught
 * in the capture phase and stopped there: views with a page-wide Escape stack
 * (useEscapeStack — clear search, then filters, then navigate back) must not see
 * the same key press, so the first Escape only closes the popover. Focus then
 * returns to the trigger.
 *
 * Used by the dashboard primitive Select (multiple) and the font and style
 * filter of the layout canvas. Classes `dash-select*` (MultiSelectPopover.css).
 */
export function MultiSelectPopover({
  options,
  selected,
  onChange,
  caption,
  emptyLabel,
  className,
}: MultiSelectPopoverProps) {
  const { t } = useTranslation(['common', 'dashboard']);
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  const updatePos = useCallback(() => {
    const el = triggerRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const popHeight = popoverRef.current?.getBoundingClientRect().height ?? 320;
    const popWidth = popoverRef.current?.getBoundingClientRect().width ?? 240;
    const margin = 8;
    let top = rect.bottom + 4;
    if (top + popHeight + margin > window.innerHeight) {
      const above = rect.top - popHeight - 4;
      top = above >= margin ? above : Math.max(margin, window.innerHeight - popHeight - margin);
    }
    const left = Math.max(margin, Math.min(rect.left, window.innerWidth - popWidth - margin));
    setPos(prev => (prev && Math.abs(prev.top - top) < 1 && Math.abs(prev.left - left) < 1 ? prev : { top, left }));
  }, []);

  useLayoutEffect(() => {
    if (!open) return;
    updatePos();
    const raf = requestAnimationFrame(() => updatePos());
    return () => cancelAnimationFrame(raf);
  }, [open, updatePos]);

  useEffect(() => {
    if (!open) return;
    const onPointer = (e: MouseEvent) => {
      const target = e.target as Node;
      if (triggerRef.current?.contains(target) || popoverRef.current?.contains(target)) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      e.preventDefault();
      e.stopPropagation();
      setOpen(false);
      triggerRef.current?.focus();
    };
    const onReposition = () => updatePos();
    document.addEventListener('mousedown', onPointer);
    // capture on window: runs before every document listener (Escape stack)
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('scroll', onReposition, true);
    window.addEventListener('resize', onReposition);
    return () => {
      document.removeEventListener('mousedown', onPointer);
      window.removeEventListener('keydown', onKey, true);
      window.removeEventListener('scroll', onReposition, true);
      window.removeEventListener('resize', onReposition);
    };
  }, [open, updatePos]);

  const optionValues = options.map(o => o.value);
  const selectedSet = new Set(selected);
  const write = (values: string[]) => onChange(orderSelection(optionValues, values));
  const labelOf = (value: string) => options.find(o => o.value === value)?.label ?? value;
  const summary = selectionSummary(
    selected,
    labelOf,
    emptyLabel ?? (t('common:all') as string),
    count => t('dashboard:select.selectedCount', { count }) as string,
  );
  const clearLabel = t('dashboard:select.clear') as string;

  return (
    <div className={`dash-select dash-select--multi${className ? ` ${className}` : ''}`}>
      {caption && <span className="dash-select__label">{caption}</span>}
      <span className="dash-select__group">
        <button
          ref={triggerRef}
          type="button"
          className={`dash-select__control dash-select__trigger${selected.length > 0 ? ' dash-select__trigger--active' : ''}`}
          aria-haspopup="true"
          aria-expanded={open}
          title={summary.title}
          onClick={() => setOpen(o => !o)}
        >
          {summary.text}
        </button>
        {selected.length > 0 && (
          <button
            type="button"
            className="dash-select__reset"
            aria-label={clearLabel}
            title={clearLabel}
            onClick={() => write([])}
          >
            ×
          </button>
        )}
      </span>
      {open && createPortal(
        <div
          ref={popoverRef}
          className="dash-select__popover"
          role="group"
          aria-label={caption ?? emptyLabel}
          style={{ position: 'fixed', top: pos?.top ?? -9999, left: pos?.left ?? -9999 }}
        >
          <button
            type="button"
            className="dash-select__clear"
            disabled={selected.length === 0}
            onClick={() => write([])}
          >
            {clearLabel}
          </button>
          <div className="dash-select__options">
            {options.map(o => (
              <label
                key={o.value}
                className={`dash-select__option${o.dividerAfter ? ' dash-select__option--divider' : ''}`}
                title={o.title}
              >
                <input
                  type="checkbox"
                  checked={selectedSet.has(o.value)}
                  onChange={() => write(toggleSelection(selected, o.value))}
                />
                <span className="dash-select__option-label">{o.label}</span>
                {o.badge && <span className="dash-select__option-badge">{o.badge}</span>}
                {o.warning && (
                  <span className="dash-select__option-warning" title={o.warning} aria-label={o.warning}>
                    ⚠
                  </span>
                )}
                {o.count != null && <span className="dash-select__option-count">{o.count}</span>}
              </label>
            ))}
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
