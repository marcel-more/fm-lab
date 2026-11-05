import type { ResultDisplayState } from '../../api/resultsApi';
import type { DashboardArea } from '../../api/dashboardApi';

/**
 * Pure model of the dashboard overview's folder hierarchy: result folding per
 * subtree, the tree of the hierarchical list (built from the `folders` and
 * `dashboards` datasets), sibling sorting, expansion rules and the flattened
 * visible rows.
 *
 * Runtime-import-free on purpose (type imports only): the unit tests under
 * `apps/web/tests/` run this file directly with Node's test runner and type
 * stripping — no bundler, no React, no path aliases.
 */

/** Row shape of builtin:list_dashboard_folders. */
export interface FolderRow {
  path: string;
  parent: string | null;
  area: DashboardArea;
  label: string;
  path_label: string | null;
  icon: string | null;
  description: string | null;
  order: number | null;
  direct_count: number;
  total_count: number;
}

/**
 * Top-level folder of the user area ("Custom"). Recognised by its area, never
 * by its path; it stays visible while empty and then carries the hint how to
 * create a first own dashboard.
 */
export function isCustomAreaRoot(folder: FolderRow): boolean {
  return folder.area === 'custom' && folder.parent === null;
}

// ---------------------------------------------------------------------------
// Result folding
// ---------------------------------------------------------------------------

/** Display-state ranking for the status sort and worst-state aggregation. */
export const STATE_RANK: Record<ResultDisplayState, number> = {
  error: 0, warning: 1, failed: 2, neutral: 3, ok: 4, pending: 5,
};

/** Result facts of one dashboard, reduced from its envelope by the caller. */
export interface ResultFacts {
  state: ResultDisplayState;
  /** false while the unit has never been computed (runStatus `pending`). */
  covered: boolean;
  /** Findings count (unit `findings`, ran) — summed per folder; null otherwise. */
  findings: number | null;
  /** Numeric headline value (ran) — key of the "result count" sort; null otherwise. */
  value: number | null;
}

export interface FolderAggregate {
  counts: Record<ResultDisplayState, number>;
  worst: ResultDisplayState | null;
  findings: number;
  covered: number;
  total: number;
}

export function emptyAggregate(): FolderAggregate {
  return {
    counts: { error: 0, warning: 0, failed: 0, neutral: 0, ok: 0, pending: 0 },
    worst: null,
    findings: 0,
    covered: 0,
    total: 0,
  };
}

/** Folds one dashboard's facts into an aggregate (in place). */
export function addToAggregate(agg: FolderAggregate, facts: ResultFacts): void {
  agg.counts[facts.state] += 1;
  agg.total += 1;
  if (facts.covered) agg.covered += 1;
  if (facts.findings !== null) agg.findings += facts.findings;
  if (agg.worst === null || STATE_RANK[facts.state] < STATE_RANK[agg.worst]) agg.worst = facts.state;
}

/** Folds a child aggregate into its parent (in place). */
export function mergeAggregate(into: FolderAggregate, from: FolderAggregate): void {
  for (const state of Object.keys(from.counts) as ResultDisplayState[]) {
    into.counts[state] += from.counts[state];
  }
  into.findings += from.findings;
  into.covered += from.covered;
  into.total += from.total;
  if (from.worst !== null && (into.worst === null || STATE_RANK[from.worst] < STATE_RANK[into.worst])) {
    into.worst = from.worst;
  }
}

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

export interface TreeDashboard<R> {
  id: string;
  folder: string | null;
  featured: boolean;
  /** Rubric label — key of the "module" sort in the flat list; null without rubric. */
  module?: string | null;
  /**
   * Values of list-preset columns beyond the result facts (e.g. a test's type
   * label or member count), keyed by sort key; null = missing. Numbers are
   * summed per folder.
   */
  values?: Readonly<Record<string, string | number | null>>;
  /** null while no envelope is known for the dashboard. */
  result: ResultFacts | null;
  /** The caller's dataset row, handed back untouched. */
  row: R;
}

export interface FolderNode<R> {
  kind: 'folder';
  path: string;
  folder: FolderRow;
  children: TreeNode<R>[];
  /** Direct entries in the shown tree: child folders + dashboards. */
  directCount: number;
  /** Dashboards in the shown subtree (= matches of a filtered tree). */
  dashboardCount: number;
  aggregate: FolderAggregate;
  /** Sums of the numeric `values` over the shown subtree (only keys with a number). */
  sums: Record<string, number>;
}

export interface DashboardNode<R> {
  kind: 'dashboard';
  id: string;
  dashboard: TreeDashboard<R>;
}

export type TreeNode<R> = FolderNode<R> | DashboardNode<R>;

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

/**
 * Sort keys = the sortable columns: name (standard order), module (flat list
 * only: rubric, then title), the four state columns, the findings column, the
 * status column (worst state) and the value columns of other list presets
 * (`testType` text, `members` count — read from `TreeDashboard.values`).
 */
export type TreeSortKey =
  | 'name' | 'module' | 'error' | 'warning' | 'ok' | 'neutral' | 'findings' | 'status'
  | 'testType' | 'members';
export type TreeSortDir = 'asc' | 'desc';

export interface TreeSortMode {
  key: TreeSortKey;
  dir: TreeSortDir;
}

export const TREE_SORT_KEYS: readonly TreeSortKey[] = [
  'name', 'module', 'error', 'warning', 'ok', 'neutral', 'findings', 'status', 'testType', 'members',
];

/** Name ↑ — the standard order of the datasets. */
export const DEFAULT_SORT: TreeSortMode = { key: 'name', dir: 'asc' };

/** Direction of the first click: text columns ascending, count columns descending, status worst first. */
export function firstSortDir(key: TreeSortKey): TreeSortDir {
  return key === 'name' || key === 'module' || key === 'status' || key === 'testType' ? 'asc' : 'desc';
}

/**
 * Click cycle of a column header: another column starts with its first
 * direction, the second click reverses it, the third returns to Name ↑.
 */
export function nextSort(current: TreeSortMode, key: TreeSortKey): TreeSortMode {
  if (current.key !== key) return { key, dir: firstSortDir(key) };
  if (current.dir === firstSortDir(key)) return { key, dir: current.dir === 'asc' ? 'desc' : 'asc' };
  return DEFAULT_SORT;
}

/** `?sort=findings-desc` → mode; unknown or missing values fall back to Name ↑. */
export function parseSort(raw: string | null, allowed: readonly TreeSortKey[] = TREE_SORT_KEYS): TreeSortMode {
  const m = /^([a-zA-Z]+)-(asc|desc)$/.exec(raw ?? '');
  if (!m || !(allowed as readonly string[]).includes(m[1])) return DEFAULT_SORT;
  return { key: m[1] as TreeSortKey, dir: m[2] as TreeSortDir };
}

/** URL value of a mode; null for the default (no `?sort=`). */
export function formatSort(mode: TreeSortMode): string | null {
  return mode.key === DEFAULT_SORT.key && mode.dir === DEFAULT_SORT.dir ? null : `${mode.key}-${mode.dir}`;
}

export function isDefaultSort(mode: TreeSortMode): boolean {
  return formatSort(mode) === null;
}

export interface FolderTreeOptions {
  /** '' = top level; otherwise the drill-down folder, which becomes the single root row. */
  root: string;
  /**
   * true when `dashboards` is a match set (search or state filter): folders
   * without a match in their subtree are dropped. Unfiltered trees keep empty
   * folders (the "Custom" area must stay reachable).
   */
  filtered: boolean;
  sort: TreeSortMode;
}

/**
 * Builds the shown tree. Both inputs keep their dataset order, which the
 * server already sorts (folders by `order` then label with the area folders
 * last, dashboards by localized title) — that order IS the Name ↑ sort.
 */
export function buildFolderTree<R>(
  folders: readonly FolderRow[],
  dashboards: readonly TreeDashboard<R>[],
  options: FolderTreeOptions,
): TreeNode<R>[] {
  const folderByPath = new Map<string, FolderRow>();
  const childFolders = new Map<string, FolderRow[]>();
  for (const f of folders) {
    folderByPath.set(f.path, f);
    const key = f.parent ?? '';
    const list = childFolders.get(key);
    if (list) list.push(f);
    else childFolders.set(key, [f]);
  }
  const dashboardsIn = new Map<string, TreeDashboard<R>[]>();
  for (const d of dashboards) {
    const key = d.folder ?? '';
    const list = dashboardsIn.get(key);
    if (list) list.push(d);
    else dashboardsIn.set(key, [d]);
  }

  const dashboardNode = (d: TreeDashboard<R>): DashboardNode<R> => ({ kind: 'dashboard', id: d.id, dashboard: d });

  const buildFolder = (folder: FolderRow): FolderNode<R> => {
    const subfolders = (childFolders.get(folder.path) ?? [])
      .map(buildFolder)
      .filter(n => !options.filtered || n.dashboardCount > 0);
    const own = (dashboardsIn.get(folder.path) ?? []).map(dashboardNode);
    const aggregate = emptyAggregate();
    const sums: Record<string, number> = {};
    const addSum = (key: string, n: number) => { sums[key] = (sums[key] ?? 0) + n; };
    let dashboardCount = own.length;
    for (const sub of subfolders) {
      mergeAggregate(aggregate, sub.aggregate);
      dashboardCount += sub.dashboardCount;
      for (const [key, n] of Object.entries(sub.sums)) addSum(key, n);
    }
    for (const node of own) {
      if (node.dashboard.result) addToAggregate(aggregate, node.dashboard.result);
      for (const [key, value] of Object.entries(node.dashboard.values ?? {})) {
        if (typeof value === 'number') addSum(key, value);
      }
    }
    const children = sortSiblings<R>([...subfolders, ...own], options.sort);
    return {
      kind: 'folder',
      path: folder.path,
      folder,
      children,
      directCount: children.length,
      dashboardCount,
      aggregate,
      sums,
    };
  };

  if (options.root) {
    const rootFolder = folderByPath.get(options.root);
    if (!rootFolder) return [];
    const node = buildFolder(rootFolder);
    return options.filtered && node.dashboardCount === 0 ? [] : [node];
  }
  const topFolders = (childFolders.get('') ?? [])
    .map(buildFolder)
    .filter(n => !options.filtered || n.dashboardCount > 0);
  const topDashboards = (dashboardsIn.get('') ?? []).map(dashboardNode);
  return sortSiblings<R>([...topFolders, ...topDashboards], options.sort);
}

/** State counts a sort column reads; `failed` belongs to the error column. */
function stateCount<R>(node: TreeNode<R>, state: 'error' | 'warning' | 'ok' | 'neutral'): number | null {
  if (node.kind === 'folder') {
    const { counts, covered } = node.aggregate;
    if (covered === 0) return null;
    return state === 'error' ? counts.error + counts.failed : counts[state];
  }
  const facts = node.dashboard.result;
  if (!facts || facts.state === 'pending') return null;
  if (state === 'error') return facts.state === 'error' || facts.state === 'failed' ? 1 : 0;
  return facts.state === state ? 1 : 0;
}

/** Key value of one node for a sort key; null = missing (always sorted last). */
function sortKeyValue<R>(node: TreeNode<R>, key: TreeSortKey): number | string | null {
  switch (key) {
    case 'error':
    case 'warning':
    case 'ok':
    case 'neutral':
      return stateCount(node, key);
    case 'findings':
      if (node.kind === 'folder') return node.aggregate.covered > 0 ? node.aggregate.findings : null;
      return node.dashboard.result?.value ?? null;
    case 'status': {
      const state = node.kind === 'folder' ? node.aggregate.worst : node.dashboard.result?.state ?? null;
      return state === null || state === 'pending' ? null : STATE_RANK[state];
    }
    case 'module':
      return node.kind === 'dashboard' ? (node.dashboard.module ?? '') : '';
    case 'name':
      return null; // the input order itself
    default:
      // Preset value columns: the leaf's value, a folder's subtree sum.
      if (node.kind === 'folder') return node.sums[key] ?? null;
      return node.dashboard.values?.[key] ?? null;
  }
}

/**
 * Sorts one sibling level: featured dashboards first (the overview's entry
 * points, pinned in every mode), then folders, then dashboards — sort keys
 * never mix the groups. Within a group Name ↑ keeps the input order (the
 * datasets' standard order), Name ↓ reverses it; every other key compares its
 * column value in the chosen direction, with missing values last in both
 * directions and ties in standard order (stable).
 */
export function sortSiblings<R>(nodes: readonly TreeNode<R>[], mode: TreeSortMode): TreeNode<R>[] {
  const group = (n: TreeNode<R>) => (n.kind === 'folder' ? 1 : n.dashboard.featured ? 0 : 2);
  const sign = mode.dir === 'asc' ? 1 : -1;
  return nodes
    .map((node, index) => ({ node, index, value: sortKeyValue(node, mode.key) }))
    .sort((a, b) => {
      const g = group(a.node) - group(b.node);
      if (g !== 0) return g;
      if (mode.key === 'name') return sign * (a.index - b.index);
      if (a.value === null || b.value === null) {
        if (a.value === b.value) return a.index - b.index;
        return a.value === null ? 1 : -1;
      }
      const cmp = typeof a.value === 'string' && typeof b.value === 'string'
        ? a.value.localeCompare(b.value)
        : Number(a.value) - Number(b.value);
      return cmp !== 0 ? sign * cmp : a.index - b.index;
    })
    .map(e => e.node);
}

// ---------------------------------------------------------------------------
// Expansion + visible rows
// ---------------------------------------------------------------------------

export interface ExpansionContext {
  root: string;
  filtered: boolean;
  /** Remembered per-folder state of the tab, seeded from the browser level (path → expanded). */
  remembered: Readonly<Record<string, boolean>>;
  /** Folders the user folded in a forced-open context, for the moment only. */
  overrides: ReadonlySet<string>;
}

/**
 * Whether a folder row is expanded. Forced open: the drill-down root row and
 * every folder of a filtered tree (each is an ancestor of a match) — folding
 * one there is a momentary override that never touches the remembered state.
 * Otherwise the remembered state applies; without one, a folder is closed
 * (the root level itself is always shown).
 */
export function isFolderExpanded(path: string, ctx: ExpansionContext): boolean {
  if (ctx.filtered || path === ctx.root) return !ctx.overrides.has(path);
  return ctx.remembered[path] ?? false;
}

/** Whether toggling a folder changes the remembered state or only a momentary override. */
export function isForcedOpen(path: string, ctx: Pick<ExpansionContext, 'root' | 'filtered'>): boolean {
  return ctx.filtered || path === ctx.root;
}

export interface VisibleRow<R> {
  node: TreeNode<R>;
  /** 1-based tree depth (aria-level). */
  level: number;
  /** Index of the parent folder row in the flat list; -1 on the top level. */
  parentIndex: number;
  /** Folder rows only: whether the children follow. */
  expanded: boolean;
}

/** Depth-first flattening of the rows currently visible (children of collapsed folders skipped). */
export function flattenVisible<R>(
  nodes: readonly TreeNode<R>[],
  isExpanded: (path: string) => boolean,
): VisibleRow<R>[] {
  const out: VisibleRow<R>[] = [];
  const walk = (list: readonly TreeNode<R>[], level: number, parentIndex: number) => {
    for (const node of list) {
      const expanded = node.kind === 'folder' && isExpanded(node.path);
      const index = out.length;
      out.push({ node, level, parentIndex, expanded });
      if (node.kind === 'folder' && expanded) walk(node.children, level + 1, index);
    }
  };
  walk(nodes, 1, -1);
  return out;
}

// ---------------------------------------------------------------------------
// Expand all / collapse all
// ---------------------------------------------------------------------------

/** Every folder path of the shown tree, depth-first. */
export function collectFolderPaths<R>(nodes: readonly TreeNode<R>[]): string[] {
  const out: string[] = [];
  const walk = (list: readonly TreeNode<R>[]) => {
    for (const node of list) {
      if (node.kind !== 'folder') continue;
      out.push(node.path);
      walk(node.children);
    }
  };
  walk(nodes);
  return out;
}

export interface ExpansionState {
  remembered: Record<string, boolean>;
  overrides: Set<string>;
}

/**
 * Whether "expand all" / "collapse all" would change anything. Collapsing
 * never touches the drill-down root row (it would leave a single row).
 */
export function bulkExpansionAvailability<R>(
  nodes: readonly TreeNode<R>[],
  ctx: ExpansionContext,
): { canExpand: boolean; canCollapse: boolean } {
  let canExpand = false;
  let canCollapse = false;
  for (const path of collectFolderPaths(nodes)) {
    const open = isFolderExpanded(path, ctx);
    if (!open) canExpand = true;
    else if (path !== ctx.root) canCollapse = true;
  }
  return { canExpand, canCollapse };
}

/**
 * Opens (`expand`) or folds (`collapse`) every folder of the shown tree. The
 * remembered state changes like a manual toggle; forced-open folders (filtered
 * tree, drill-down root) only change their momentary overrides — the
 * remembered state of a filtered tree stays untouched. Never runs anything:
 * the bounded auto-run belongs to expanding one folder by hand.
 */
export function applyBulkExpansion<R>(
  nodes: readonly TreeNode<R>[],
  ctx: ExpansionContext,
  action: 'expand' | 'collapse',
): ExpansionState {
  const remembered = { ...ctx.remembered };
  const overrides = new Set(ctx.overrides);
  for (const path of collectFolderPaths(nodes)) {
    if (action === 'collapse' && path === ctx.root) continue;
    if (isForcedOpen(path, ctx)) {
      if (action === 'expand') overrides.delete(path);
      else overrides.add(path);
    } else if (action === 'expand') {
      remembered[path] = true;
    } else {
      delete remembered[path];
    }
  }
  return { remembered, overrides };
}
