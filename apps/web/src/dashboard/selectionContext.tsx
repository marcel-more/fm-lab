import { createContext, useCallback, useContext, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

/**
 * Cross-primitive selection channel for one rendered dashboard.
 *
 * Motivation: a lens table (e.g. the profiles of an Analysis Test) and the
 * list it narrows (the test's members) are two sibling `Table` nodes. A column
 * per lens value would widen the already wide list; instead the lens row is
 * clicked and every matching row of the other table is tinted.
 *
 * Deliberately view-only and ephemeral: no URL param, no dataset refetch, and
 * the state dies with the renderer (page change resets it). Channels are named
 * (`selectionKey`) so several independent lenses can coexist on one page.
 *
 * Master-detail builds on the same channels: a node bound with
 * `data.selection` shows the row whose key equals the channel value, a
 * `FilterChips` with `channel` writes into it, and `visibleWhen.selection`
 * shows or hides nodes by it — all without reloading data. Channel defaults
 * declared in the layout (`FilterChips.default`) are the initial values, so a
 * guarded node renders right on the first paint.
 */
interface SelectionState {
  /** channel → currently selected value (null = nothing selected). */
  selection: Record<string, string | null>;
  /** Selecting the already-selected value clears it (click again = off). */
  toggle: (key: string, value: string) => void;
  /** Sets the channel to `value` (null clears it), never toggles. */
  select: (key: string, value: string | null) => void;
}

const SelectionContext = createContext<SelectionState>({
  selection: {},
  toggle: () => { /* no provider (e.g. isolated primitive test) — selection is a no-op */ },
  select: () => { /* no provider — no-op */ },
});

export function SelectionProvider({
  children,
  initial,
}: {
  children: ReactNode;
  /** Initial channel values (layout defaults); read on mount only. */
  initial?: Record<string, string | null>;
}) {
  const [selection, setSelection] = useState<Record<string, string | null>>(() => ({ ...(initial ?? {}) }));
  const toggle = useCallback((key: string, value: string) => {
    setSelection(cur => ({ ...cur, [key]: cur[key] === value ? null : value }));
  }, []);
  const select = useCallback((key: string, value: string | null) => {
    setSelection(cur => (cur[key] === value ? cur : { ...cur, [key]: value }));
  }, []);
  const value = useMemo(() => ({ selection, toggle, select }), [selection, toggle, select]);
  return <SelectionContext.Provider value={value}>{children}</SelectionContext.Provider>;
}

export function useSelection(): SelectionState {
  return useContext(SelectionContext);
}
