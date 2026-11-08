/**
 * Per-column value labels of the Table primitive.
 *
 * SQL emits a stable code (`dead_branch`, `unused`, `true`); the layout maps it
 * to a caption:
 *
 *   { "field": "reason", "label": "Reason",
 *     "valueLabels": { "unused": "Not used anywhere", "dead_branch": "Dead branch" } }
 *
 * Every entry is a plain string in `layout.json`, so a locale file overrides it
 * like any other prop (`<table-id>.props.columns[3].valueLabels.dead_branch`).
 * The code stays the cell's value: server search, sort and click tokens keep
 * working on it, and the badge tone is still derived from the code.
 *
 * Lookup: exact key first, then the lower-cased key (booleans arrive as
 * `true`/`false`, SQL tokens in their own casing). A value without an entry
 * returns `undefined` — the caller shows the raw value then.
 */

export type ValueLabels = Record<string, string>;

export function valueLabelFor(rawValue: unknown, labels: ValueLabels | undefined): string | undefined {
  if (!labels || rawValue == null || typeof rawValue === 'object') return undefined;
  const raw = String(rawValue);
  if (Object.prototype.hasOwnProperty.call(labels, raw)) return labels[raw];
  const lower = raw.toLowerCase();
  if (Object.prototype.hasOwnProperty.call(labels, lower)) return labels[lower];
  return undefined;
}

/**
 * The captions a row shows through `valueLabels`, joined for the client-side
 * search — so a term matches what the user reads, not only the code behind it.
 * Empty when no column declares labels.
 */
export function rowLabelText(
  row: Record<string, unknown>,
  columns: ReadonlyArray<{ field: string; valueLabels?: ValueLabels }>,
): string {
  const parts: string[] = [];
  for (const c of columns) {
    if (!c.valueLabels) continue;
    const label = valueLabelFor(row[c.field], c.valueLabels);
    if (label) parts.push(label);
  }
  return parts.join('\u001f');
}
