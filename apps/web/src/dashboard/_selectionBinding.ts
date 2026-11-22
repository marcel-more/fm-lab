/**
 * Master-detail over selection channels — the pure part (no React), unit-tested
 * in tests/selectionBinding.test.ts. The renderer (DashboardRenderer.tsx) and the
 * channel state (selectionContext.tsx) use it.
 */
import type { DashboardLayout, DatasetResult, LayoutNode, VisibleWhen } from '../api/dashboardApi';

type Row = Record<string, unknown>;

function holds(cond: VisibleWhen, value: unknown): boolean {
  if ('equals' in cond) return value === cond.equals;
  if ('notEquals' in cond) return value !== cond.notEquals;
  if ('truthy' in cond) return cond.truthy ? !!value : !value;
  return true;
}

/** True when the node's guard reads a selection channel. */
export function usesSelection(node: LayoutNode): boolean {
  return !!node.data?.selection || !!(node.visibleWhen && 'selection' in node.visibleWhen);
}

/**
 * Evaluates `visibleWhen`. Dataset guard: first row of the dataset; on any
 * uncertainty (missing dataset/row/field) VISIBLE, so a node never disappears
 * because its guard dataset failed to load. Selection guard: the channel value
 * (null when nothing is selected).
 */
export function isVisible(
  cond: VisibleWhen | undefined,
  datasets: Record<string, DatasetResult> | undefined,
  selection: Record<string, string | null>,
): boolean {
  if (!cond) return true;
  if ('selection' in cond) return holds(cond, selection[cond.selection] ?? null);
  const row = datasets?.[cond.dataset]?.data?.[0] as Row | undefined;
  return holds(cond, row?.[cond.field]);
}

/**
 * The row a `data.selection` binding shows: the row whose `key` equals the
 * channel value; else the first row (`fallback: "first"`, default) or none.
 */
export function selectedRow(
  rows: Row[],
  key: string,
  value: string | null | undefined,
  fallback: 'first' | 'none' = 'first',
): Row | undefined {
  if (value != null) {
    const hit = rows.find((r) => String(r[key] ?? '') === value);
    if (hit) return hit;
  }
  return fallback === 'first' ? rows[0] : undefined;
}

/** The dataset narrowed to the selected row (no row → empty data). */
export function narrowDataset(dataset: DatasetResult | undefined, row: Row | undefined): DatasetResult | undefined {
  if (!dataset) return dataset;
  return { ...dataset, data: row ? [row] : [] };
}

/**
 * Initial channel values declared in the layout: every `FilterChips` with a
 * `channel` and a `default`.
 */
export function initialChannels(layout: DashboardLayout | undefined): Record<string, string | null> {
  const out: Record<string, string | null> = {};
  const walk = (node: LayoutNode | undefined) => {
    if (!node) return;
    const p = node.props ?? {};
    if (node.type === 'FilterChips' && typeof p.channel === 'string' && typeof p.default === 'string') {
      if (!(p.channel in out)) out[p.channel] = p.default;
    }
    for (const child of node.children ?? []) walk(child);
  };
  walk(layout?.root);
  return out;
}

/**
 * Value a `selectionDefault: "first"` table puts into its channel: the key of
 * the first row when the channel is empty or its value is not in the rows;
 * null when nothing needs to change.
 */
export function defaultSelection(rows: Row[], field: string, current: string | null | undefined): string | null {
  if (rows.length === 0) return null;
  if (current != null && rows.some((r) => String(r[field] ?? '') === current)) return null;
  const first = rows[0][field];
  return first == null ? null : String(first);
}
