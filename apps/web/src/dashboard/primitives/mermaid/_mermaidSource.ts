/**
 * Pure helpers of the `Mermaid` primitive (no DOM, no renderer) — unit-tested
 * in tests/mermaidSource.test.ts.
 */

type Row = Record<string, unknown>;

export interface MermaidNodeRef {
  /** Mermaid node id as written in the diagram text (`n1_2`). */
  id: string;
  [key: string]: unknown;
}

/**
 * Diagram text of the node:
 * - `source` (layout text, `{{token}}`s already substituted by the caller) wins;
 * - a node with its OWN dataset binding joins the `field` of every row with
 *   a line break (one diagram from several rows);
 * - otherwise the `field` of the row it is bound to (the container's row, or the
 *   first row of the inherited dataset).
 */
export function mermaidText(opts: {
  source?: string;
  field: string;
  ownBinding: boolean;
  row?: Row;
  rows?: Row[];
}): string {
  if (typeof opts.source === 'string' && opts.source.trim()) return opts.source;
  const text = (r: Row | undefined) => {
    const v = r?.[opts.field];
    return v == null ? '' : String(v);
  };
  if (opts.ownBinding && opts.rows && opts.rows.length > 0) {
    return opts.rows.map(text).filter(Boolean).join('\n');
  }
  if (opts.row) return text(opts.row);
  return text(opts.rows?.[0]);
}

/**
 * Node lookup from the `nodesField` column: a JSON array (string or already
 * parsed list) of objects with at least `id`. Several rows are merged; the first
 * entry of an id wins. Malformed values are ignored.
 */
export function mermaidNodeMap(values: unknown[]): Map<string, MermaidNodeRef> {
  const map = new Map<string, MermaidNodeRef>();
  for (const value of values) {
    let list: unknown = value;
    if (typeof value === 'string') {
      try {
        list = JSON.parse(value);
      } catch {
        continue;
      }
    }
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      if (!item || typeof item !== 'object') continue;
      const id = (item as Row).id;
      if (typeof id !== 'string' && typeof id !== 'number') continue;
      const key = String(id);
      if (!map.has(key)) map.set(key, { ...(item as Row), id: key });
    }
  }
  return map;
}
