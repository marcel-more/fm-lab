/**
 * Pure helpers of the TableOccurrence detail view (no React, no i18n) — row
 * types of the projections object_details_tableoccurrence(.sql/_usage.sql),
 * grouping of the predicate rows into relationships, and the usage-category
 * model with its deep link into the references tab.
 */
import { referenceRoleKey, TABLE_OCCURRENCE_USAGE_ROLE } from './referenceRoleKey.ts';
import { mirrorOperator } from './relationshipOperator.ts';

/** One row of the detail projection; `section` discriminates. */
export interface TableOccurrenceRow {
  section: 'meta' | 'predicate' | 'sibling' | 'usage_class' | 'usage' | 'group' | 'anchor' | 'path_step';
  // meta
  to_id?: number | null;
  to_name?: string | null;
  to_type?: string | null;
  file_name?: string | null;
  bt_name?: string | null;
  bt_uuid?: string | null;
  bt_file?: string | null;
  bt_cross_file?: boolean | null;
  ds_name?: string | null;
  ds_type?: string | null;
  ds_path?: string | null;
  ds_resolved_file?: string | null;
  ds_resolved_imported?: boolean | null;
  /** The data source points back at the occurrence's own file. */
  ds_resolved_self?: boolean | null;
  view_state?: string | null;
  color_r?: number | null;
  color_g?: number | null;
  color_b?: number | null;
  relationship_count?: number | null;
  sibling_local_count?: number | null;
  sibling_solution_count?: number | null;
  sibling_solution_files?: number | null;
  // predicate
  rel_id?: number | null;
  rel_uuid?: string | null;
  predicate_index?: number | null;
  operator?: string | null;
  self_is_left?: boolean | null;
  partner_to_uuid?: string | null;
  partner_to_name?: string | null;
  partner_to_type?: string | null;
  partner_bt_name?: string | null;
  partner_ds_name?: string | null;
  self_field_name?: string | null;
  self_field_uuid?: string | null;
  self_field_file?: string | null;
  partner_field_name?: string | null;
  partner_field_uuid?: string | null;
  partner_field_file?: string | null;
  self_create?: boolean | null;
  self_delete?: boolean | null;
  self_sort_enabled?: boolean | null;
  self_sort_fields?: string | null;
  partner_create?: boolean | null;
  partner_delete?: boolean | null;
  partner_sort_enabled?: boolean | null;
  partner_sort_fields?: string | null;
  // sibling
  sibling_uuid?: string | null;
  sibling_name?: string | null;
  sibling_type?: string | null;
  /** Data source of the sibling; null = current file (no data source). */
  sibling_ds_name?: string | null;
  sibling_ds_self?: boolean | null;
  // usage_class
  usage_class?: string | null;
  usage_reason?: string | null;
  usage_ref_count?: number | null;
  user_count?: number | null;
  dead_group_size?: number | null;
  anchor_to_uuid?: string | null;
  anchor_to_name?: string | null;
  low_confidence?: boolean | null;
  // usage
  category?: string | null;
  users?: number | null;
  refs?: number | null;
  edge_roles?: string[] | null;
  has_non_edge?: boolean | null;
  // group (relationship-graph context)
  group_size?: number | null;
  group_layouts?: number | null;
  anchor_count?: number | null;
  self_layouts?: number | null;
  nearest_distance?: number | null;
  // anchor / path_step
  to_uuid?: string | null;
  n_layouts?: number | null;
  distance?: number | null;
  path_no?: number | null;
  step_index?: number | null;
  hop_rel_id?: number | null;
  hop_rel_uuid?: string | null;
  hop_label?: string | null;
}

export interface SideOptions {
  create: boolean;
  cascadeDelete: boolean;
  sorted: boolean;
  sortFields: string[];
}

export interface PredicateView {
  index: number;
  selfField: string | null;
  selfFieldUuid: string | null;
  selfFieldFile: string | null;
  /** Operator as read from this occurrence's side (mirrored when it is the right table). */
  operator: string | null;
  partnerField: string | null;
  partnerFieldUuid: string | null;
  partnerFieldFile: string | null;
}

export interface RelationshipView {
  relId: number;
  relUuid: string | null;
  file: string | null;
  partnerUuid: string | null;
  partnerName: string | null;
  partnerType: string | null;
  partnerBaseTable: string | null;
  partnerDataSource: string | null;
  self: SideOptions;
  partner: SideOptions;
  predicates: PredicateView[];
}

function splitSortFields(raw: string | null | undefined): string[] {
  return (raw ?? '').split(', ').filter((f) => f.length > 0);
}

/**
 * Predicate rows → one entry per relationship (keyed by Rel_ID), predicates in
 * Predicate_Index order, operator read from this occurrence's side. Order of
 * the result: partner name, then Rel_ID.
 */
export function groupRelationships(rows: TableOccurrenceRow[]): RelationshipView[] {
  const byId = new Map<number, RelationshipView>();
  for (const r of rows) {
    if (r.section !== 'predicate' || r.rel_id == null) continue;
    let rel = byId.get(r.rel_id);
    if (!rel) {
      rel = {
        relId: r.rel_id,
        relUuid: r.rel_uuid ?? null,
        file: r.file_name ?? null,
        partnerUuid: r.partner_to_uuid ?? null,
        partnerName: r.partner_to_name ?? null,
        partnerType: r.partner_to_type ?? null,
        partnerBaseTable: r.partner_bt_name ?? null,
        partnerDataSource: r.partner_ds_name ?? null,
        self: {
          create: !!r.self_create,
          cascadeDelete: !!r.self_delete,
          sorted: !!r.self_sort_enabled,
          sortFields: splitSortFields(r.self_sort_fields),
        },
        partner: {
          create: !!r.partner_create,
          cascadeDelete: !!r.partner_delete,
          sorted: !!r.partner_sort_enabled,
          sortFields: splitSortFields(r.partner_sort_fields),
        },
        predicates: [],
      };
      byId.set(r.rel_id, rel);
    }
    rel.predicates.push({
      index: r.predicate_index ?? rel.predicates.length + 1,
      selfField: r.self_field_name ?? null,
      selfFieldUuid: r.self_field_uuid ?? null,
      selfFieldFile: r.self_field_file ?? null,
      operator: r.self_is_left === false ? mirrorOperator(r.operator) : (r.operator ?? null),
      partnerField: r.partner_field_name ?? null,
      partnerFieldUuid: r.partner_field_uuid ?? null,
      partnerFieldFile: r.partner_field_file ?? null,
    });
  }
  const list = Array.from(byId.values());
  for (const rel of list) rel.predicates.sort((a, b) => a.index - b.index);
  return list.sort((a, b) =>
    (a.partnerName ?? '').localeCompare(b.partnerName ?? '') || a.relId - b.relId);
}

/** Display groups of the usage categories, in the order a developer asks "what is it for?". */
export const USAGE_GROUPS: ReadonlyArray<{ id: string; categories: readonly string[] }> = [
  { id: 'context', categories: ['layout_context', 'calc_context', 'security'] },
  { id: 'display', categories: ['layout_field', 'portal', 'layout_part', 'table_view'] },
  { id: 'logic', categories: ['script_step', 'calculation', 'calculation_text', 'navigation'] },
  { id: 'data', categories: ['lookup', 'lookup_context', 'value_list', 'value_list_related'] },
  { id: 'graph', categories: ['relationship', 'relationship_cascade'] },
];

export interface UsageCategory {
  category: string;
  users: number;
  refs: number;
  /** `roles=` filter keys of the references tab that show exactly this category. */
  roleKeys: string[];
}

export interface UsageGroup {
  id: string;
  items: UsageCategory[];
}

/**
 * Filter keys of the references tab for one usage category: every edge role
 * as is (`context_table`, `left_table`, …) plus — for usages without an edge —
 * the appended `uses_table_occurrence` row, combined with the category when
 * the tab forms a chip of its own for it.
 */
export function usageRoleKeys(row: Pick<TableOccurrenceRow, 'category' | 'edge_roles' | 'has_non_edge'>): string[] {
  const keys = new Set<string>(row.edge_roles ?? []);
  if (row.has_non_edge && row.category) {
    keys.add(referenceRoleKey(TABLE_OCCURRENCE_USAGE_ROLE, row.category));
  }
  return Array.from(keys).sort();
}

/**
 * Usage rows → display groups (known groups first in USAGE_GROUPS order,
 * categories within a group in their listed order; unknown categories land in
 * a trailing `other` group). Empty groups are dropped.
 */
export function groupUsage(rows: TableOccurrenceRow[]): UsageGroup[] {
  const byCat = new Map<string, UsageCategory>();
  for (const r of rows) {
    if (r.section !== 'usage' || !r.category) continue;
    byCat.set(r.category, {
      category: r.category,
      users: Number(r.users ?? 0),
      refs: Number(r.refs ?? 0),
      roleKeys: usageRoleKeys(r),
    });
  }
  const groups: UsageGroup[] = [];
  const placed = new Set<string>();
  for (const g of USAGE_GROUPS) {
    const items = g.categories.filter((c) => byCat.has(c)).map((c) => byCat.get(c)!);
    items.forEach((i) => placed.add(i.category));
    if (items.length > 0) groups.push({ id: g.id, items });
  }
  const rest = Array.from(byCat.values()).filter((i) => !placed.has(i.category))
    .sort((a, b) => a.category.localeCompare(b.category));
  if (rest.length > 0) groups.push({ id: 'other', items: rest });
  return groups;
}

/** `#rrggbb` of the diagram colour, null without one. */
export function toHexColor(r: number | null | undefined, g: number | null | undefined, b: number | null | undefined): string | null {
  if (r == null || g == null || b == null) return null;
  const hex = (n: number) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, '0');
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

// ── Relationship option filter ──

/** Options a relationship can be filtered by (either side counts). */
export type RelationshipOption = 'cascade' | 'create' | 'sorted';

export const RELATIONSHIP_OPTIONS: readonly RelationshipOption[] = ['cascade', 'create', 'sorted'];

export function relationshipHasOption(rel: RelationshipView, opt: RelationshipOption): boolean {
  switch (opt) {
    case 'cascade': return rel.self.cascadeDelete || rel.partner.cascadeDelete;
    case 'create': return rel.self.create || rel.partner.create;
    case 'sorted': return rel.self.sorted || rel.partner.sorted;
    default: return false;
  }
}

/**
 * Usage categories that the references tab does not list on their own (the
 * relationship already appears there as its left/right_table edge) — their
 * chip filters the relationship list of the detail view instead.
 */
export const IN_PAGE_USAGE_FILTER: Readonly<Record<string, RelationshipOption>> = {
  relationship_cascade: 'cascade',
};

// ── Other occurrences of the same base table ──

/** all = every file · file = this file · other = the other files of the solution */
export type SiblingScope = 'all' | 'file' | 'other';
export type SiblingSortKey = 'name' | 'file' | 'source';

export interface SiblingView {
  uuid: string | null;
  name: string;
  file: string;
  /** Data source through which it reaches the base table; null = current file. */
  dataSource: string | null;
  /** That data source points back at the sibling's own file. */
  dataSourceSelf: boolean;
  /** Defined in the same file as the viewed occurrence. */
  local: boolean;
}

export function siblingViews(rows: TableOccurrenceRow[], ownFile: string | null): SiblingView[] {
  return rows
    .filter((r) => r.section === 'sibling')
    .map((r) => ({
      uuid: r.sibling_uuid ?? null,
      name: r.sibling_name ?? '',
      file: r.file_name ?? '',
      dataSource: r.sibling_ds_name ?? null,
      dataSourceSelf: !!r.sibling_ds_self,
      local: (r.file_name ?? null) === ownFile,
    }));
}

/**
 * Scope filter, search (name, foreign file, data source) and sort. Sorting by file puts this
 * file first (its cell stays empty in the table), then the other files by
 * name; ties fall back to the occurrence name.
 */
export function filterSortSiblings(
  list: SiblingView[],
  scope: SiblingScope,
  search: string,
  sortKey: SiblingSortKey,
  sortDir: 'asc' | 'desc',
): SiblingView[] {
  const q = search.trim().toLowerCase();
  const scoped = list.filter((s) =>
    (scope === 'all' || (scope === 'file' ? s.local : !s.local))
    && (!q || s.name.toLowerCase().includes(q) || (!s.local && s.file.toLowerCase().includes(q))
      || (s.dataSource ?? '').toLowerCase().includes(q)));
  const byName = (a: SiblingView, b: SiblingView) => a.name.localeCompare(b.name);
  const byFile = (a: SiblingView, b: SiblingView) =>
    (a.local === b.local ? 0 : a.local ? -1 : 1) || a.file.localeCompare(b.file);
  // Current file (no data source) first, then by data source name.
  const bySource = (a: SiblingView, b: SiblingView) =>
    (a.dataSource == null ? 0 : 1) - (b.dataSource == null ? 0 : 1)
    || (a.dataSource ?? '').localeCompare(b.dataSource ?? '');
  const primary = sortKey === 'file' ? byFile : sortKey === 'source' ? bySource : byName;
  const sorted = [...scoped].sort((a, b) => {
    const cmp = primary(a, b);
    return (sortDir === 'asc' ? cmp : -cmp) || byName(a, b) || a.file.localeCompare(b.file);
  });
  return sorted;
}

// ── Relationship-graph context: TO group, layout anchors, context path ──

export interface ContextAnchor {
  uuid: string;
  name: string;
  layouts: number;
  /** Relationship steps between the anchor and the viewed occurrence. */
  distance: number;
}

export interface ContextStep {
  uuid: string;
  name: string;
  /** Relationship arriving at this step (null for the anchor, step 0). */
  relId: number | null;
  relUuid: string | null;
  /** Join fields of that relationship, read from the previous step's side. */
  label: string | null;
}

export interface ContextModel {
  /** TOs in the connected component of the relationship graph (incl. this one). */
  groupSize: number;
  /** Layouts based on any TO of the group. */
  groupLayouts: number;
  anchorCount: number;
  /** Layouts based on the viewed occurrence itself. */
  selfLayouts: number;
  /** Every anchor: most layouts first, then nearest first, then by name. */
  anchors: ContextAnchor[];
  /** Paths from the nearest anchors to the viewed occurrence (anchor first, at most three). */
  paths: ContextStep[][];
}

export function contextModel(rows: TableOccurrenceRow[]): ContextModel | null {
  const g = rows.find((r) => r.section === 'group');
  if (!g) return null;
  const anchors: ContextAnchor[] = rows
    .filter((r) => r.section === 'anchor' && r.to_uuid)
    .map((r) => ({
      uuid: r.to_uuid as string,
      name: r.to_name ?? '',
      layouts: Number(r.n_layouts ?? 0),
      distance: Number(r.distance ?? 0),
    }))
    .sort((a, b) => b.layouts - a.layouts || a.distance - b.distance || a.name.localeCompare(b.name));
  const byPath = new Map<number, ContextStep[]>();
  const stepRows = rows
    .filter((r) => r.section === 'path_step' && r.to_uuid && r.path_no != null)
    .sort((a, b) => (a.path_no! - b.path_no!) || ((a.step_index ?? 0) - (b.step_index ?? 0)));
  for (const r of stepRows) {
    const list = byPath.get(r.path_no!) ?? [];
    list.push({
      uuid: r.to_uuid as string,
      name: r.to_name ?? '',
      relId: r.hop_rel_id ?? null,
      relUuid: r.hop_rel_uuid ?? null,
      label: r.hop_label ?? null,
    });
    byPath.set(r.path_no!, list);
  }
  return {
    groupSize: Number(g.group_size ?? 1),
    groupLayouts: Number(g.group_layouts ?? 0),
    anchorCount: Number(g.anchor_count ?? 0),
    selfLayouts: Number(g.self_layouts ?? 0),
    anchors,
    paths: Array.from(byPath.keys()).sort((a, b) => a - b).map((k) => byPath.get(k)!),
  };
}

export interface AnchorSummary {
  /** Anchors shown one by one (at least the first one). */
  visible: ContextAnchor[];
  /** Anchors behind "+n more". */
  hidden: ContextAnchor[];
  /** Layout count shared by every hidden anchor, or null when they differ. */
  hiddenEachLayouts: number | null;
  /** Layouts of all hidden anchors together. */
  hiddenLayouts: number;
}

/**
 * Splits the (sorted) anchors into the ones shown individually and the rest.
 * At most `maxVisible` are shown; a run of anchors with the same layout count
 * that crosses that limit is hidden as a whole, so the view never picks two
 * arbitrary members of a tie ("Artikel 296 · +10 more with 1 layout each"
 * instead of "Artikel 296 · A 1 · B 1 · +8 more").
 */
export function summarizeAnchors(anchors: ContextAnchor[], maxVisible = 3): AnchorSummary {
  let cut = Math.min(maxVisible, anchors.length);
  if (cut < anchors.length) {
    const tie = anchors[cut].layouts;
    while (cut > 1 && anchors[cut - 1].layouts === tie) cut -= 1;
  }
  const visible = anchors.slice(0, cut);
  const hidden = anchors.slice(cut);
  const each = hidden.length > 0 && hidden.every((a) => a.layouts === hidden[0].layouts) ? hidden[0].layouts : null;
  return {
    visible,
    hidden,
    hiddenEachLayouts: each,
    hiddenLayouts: hidden.reduce((sum, a) => sum + a.layouts, 0),
  };
}
