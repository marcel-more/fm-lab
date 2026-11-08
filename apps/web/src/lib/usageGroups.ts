/**
 * Counting helpers of the references tab — pure, no React, no i18n instance.
 *
 * Two numbers, the same as the search column (v_object_usage):
 * - references: every occurrence; the API folds identical occurrences into one
 *   row with Call_Count = N (rendered ×N), so the tab sums Call_Count, not rows,
 * - usage (internal): the distinct using objects — a layout object or layout
 *   part counts as its layout. The "by object" view groups the incoming rows
 *   that count as usage (Counts_As_Usage, set by the API) per using object.
 */
import type { ReferenceItem } from '../types';

/**
 * Number of references a row stands for. The API folds identical occurrences
 * (source × role × subrole class × container) into one row with Call_Count = N
 * (rendered ×N); every counter of the tab — heading, direction buttons, type and
 * role chips, match count — sums references, not rows, so the numbers agree with
 * the "references" figure of the usage summary (meta.usage.refs).
 */
export function refWeight(ref: ReferenceItem): number {
  return typeof ref.Call_Count === 'number' && ref.Call_Count > 0 ? ref.Call_Count : 1;
}

/** Sum of references over rows (see refWeight). */
export function sumRefs(items: ReferenceItem[]): number {
  let n = 0;
  for (const r of items) n += refWeight(r);
  return n;
}

/** Using object of an incoming row (same container rule as v_object_usage). */
export interface UsageOwner { key: string; uuid: string; type: string; name: string; file: string }

export function usageOwnerOf(ref: ReferenceItem): UsageOwner {
  if ((ref.Object_Type === 'LayoutObject' || ref.Object_Type === 'LayoutPart') && ref.Container_UUID) {
    const file = ref.Container_File ?? ref.File_Name;
    return {
      key: `${ref.Container_UUID}\u0000${file}`, uuid: ref.Container_UUID,
      type: ref.Container_Type ?? 'Layout', name: ref.Container_Name ?? '', file,
    };
  }
  return {
    key: `${ref.uuid}\u0000${ref.File_Name}`, uuid: ref.uuid,
    type: ref.Object_Type, name: ref.Object_Name, file: ref.File_Name,
  };
}

export interface UsageGroup { owner: UsageOwner; rows: ReferenceItem[]; refs: number; roles: string[] }

/**
 * Incoming rows → one group per using object. Only rows that count as usage
 * (Counts_As_Usage, set by the API) form groups, so their number equals
 * meta.usage.owners; the remaining incoming rows (restrictions, an unmirrored
 * trigger node) are returned separately for the "no usage" group.
 */
export function buildUsageGroups(rows: ReferenceItem[]): { groups: UsageGroup[]; noUsage: ReferenceItem[] } {
  const byOwner = new Map<string, UsageGroup>();
  const noUsage: ReferenceItem[] = [];
  for (const r of rows) {
    if (r.Counts_As_Usage === false) { noUsage.push(r); continue; }
    const owner = usageOwnerOf(r);
    let g = byOwner.get(owner.key);
    if (!g) { g = { owner, rows: [], refs: 0, roles: [] }; byOwner.set(owner.key, g); }
    g.rows.push(r);
    g.refs += refWeight(r);
    if (!g.roles.includes(r.Link_Role)) g.roles.push(r.Link_Role);
  }
  const groups = Array.from(byOwner.values());
  for (const g of groups) g.roles.sort();
  return { groups, noUsage };
}

/**
 * Does expanding the group show anything the head row does not? Yes when it
 * holds more than one row, or when its single row is a sub-node of the owner
 * (a layout object or layout part: which object, its detail page, its slot).
 * A single row of any other source is the owner itself in the same role —
 * expanding would only repeat the head, so the group gets no toggle.
 */
export function isGroupExpandable(group: UsageGroup): boolean {
  if (group.rows.length !== 1) return true;
  const t = group.rows[0].Object_Type;
  return t === 'LayoutObject' || t === 'LayoutPart';
}
