import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from 'react';
import { nextBreakFit } from './_breakAt';

/**
 * Switches the `breakAt` opportunities of a Table on only while the table
 * would overflow its wrapper without them (see `nextBreakFit`). Re-measures on
 * every size change of the wrapper and whenever `contentKey` changes (other
 * rows, columns or language — the width the table needs changes with them).
 *
 * The React state is a plain boolean; the width measured when the breaks went
 * on lives in a ref. An object state would be re-created whenever React
 * re-applies queued updates (a ResizeObserver update of lower priority stays
 * queued while synchronous renders run past it) — a new object with the same
 * values counts as a change, re-runs the layout effect and loops until React
 * aborts. Booleans compare by value, so a repeated decision is a no-op.
 */
export function useBreakFit(
  tableRef: RefObject<HTMLTableElement | null>,
  enabled: boolean,
  contentKey: unknown,
): boolean {
  const [active, setActive] = useState(false);
  // Mirrors of the decision, readable from the ResizeObserver callback.
  const activeRef = useRef(active);
  activeRef.current = active;
  const neededRef = useRef<number | null>(null);
  const lastKey = useRef(contentKey);

  const measure = () => {
    const table = tableRef.current;
    const wrap = table?.parentElement;
    if (!table || !wrap) return null;
    return { tableWidth: table.getBoundingClientRect().width, available: wrap.clientWidth };
  };

  const decide = () => {
    const m = measure();
    if (!m) return;
    const next = nextBreakFit({ active: activeRef.current, needed: neededRef.current }, m);
    neededRef.current = next.needed;
    if (next.active !== activeRef.current) {
      activeRef.current = next.active;
      setActive(next.active);
    }
  };

  // Before paint: new content is first measured without breaks. Runs again
  // after a switch (`active` in the deps), so the table without breaks is
  // measured once more; it settles because a repeated decision sets nothing.
  useLayoutEffect(() => {
    if (!enabled) return;
    if (lastKey.current !== contentKey) {
      lastKey.current = contentKey;
      if (activeRef.current) {
        neededRef.current = null;
        activeRef.current = false;
        setActive(false);
        return;
      }
    }
    decide();
    // `decide` reads refs only; the deps are the triggers of a re-measurement.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, contentKey, active]);

  useEffect(() => {
    const wrap = tableRef.current?.parentElement;
    if (!enabled || !wrap || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => decide());
    ro.observe(wrap);
    return () => ro.disconnect();
    // The wrapper element lives as long as the table.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled]);

  return enabled && active;
}
