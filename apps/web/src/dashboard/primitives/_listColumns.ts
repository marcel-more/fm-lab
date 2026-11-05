import type { TreeSortKey } from './_folderTree';

/**
 * Column presets of the overview's hierarchical list and favorites view
 * (layout prop `listColumns` of TileGrid): which columns follow the name
 * column, which of them sort, which rows can carry a favorite star and which
 * result envelopes feed the state columns.
 *
 *   dashboard  four state columns ● ▲ ✓ ◦, status (narrow screens), findings
 *   test       test type · members · status of the last solution-scope run
 *
 * Runtime-import-free on purpose (type imports only), like `_folderTree`: the
 * unit tests under `apps/web/tests/` run it with Node's type stripping.
 */

export type ListPresetId = 'dashboard' | 'test';

export type ListColumnKey =
  | 'error' | 'warning' | 'ok' | 'neutral' | 'status' | 'findings'
  | 'testType' | 'members' | 'testStatus';

export interface ListColumn {
  key: ListColumnKey;
  /** i18n key of the header label (namespace `dashboard`). */
  headerKey: string;
  /** Key the column header sorts by; null = not sortable. */
  sortKey: TreeSortKey | null;
  /** Sortable only when result envelopes feed the list (dashboard state columns). */
  needsResults: boolean;
}

export interface ListPreset {
  id: ListPresetId;
  /** Columns after the name column, in display order (the star column is separate). */
  columns: readonly ListColumn[];
  /** Sort keys of the list view (`?sort=`); the favorites view adds `module`. */
  sortKeys: readonly TreeSortKey[];
  /** Sort keys that work without result envelopes. */
  textSortKeys: readonly TreeSortKey[];
  /** Areas whose rows carry a favorite star; null = every area. */
  favoritableAreas: ReadonlySet<string> | null;
  /** Kind of the result envelopes the rows read (`<kind>:<id>` in the summary map). */
  resultKind: 'dashboard' | 'test';
  /** Kind-specific texts — i18n keys of the namespace `dashboard`. */
  texts: ListPresetTexts;
}

export interface ListPresetTexts {
  /** Second header of the favorites view (`Name | <module>`). */
  moduleHeader: string;
  /** Folder tooltip total (plural): "n dashboards / tests in total". */
  total: string;
  /** Accessible name of the treegrid. */
  treeLabel: string;
  /** Hint while a search hides the drill-down root. */
  searchAll: string;
  /** Empty favorites view. */
  favoritesEmpty: string;
  /** Empty "Custom" area folder (takes `{{command}}`). */
  customEmpty: string;
  /** Command that creates a first own entry. */
  customCommand: string;
}

const stateColumn = (key: 'error' | 'warning' | 'ok' | 'neutral'): ListColumn => ({
  key, headerKey: `folderNav.state.${key}`, sortKey: key, needsResults: true,
});

const DASHBOARD_PRESET: ListPreset = {
  id: 'dashboard',
  columns: [
    stateColumn('error'),
    stateColumn('warning'),
    stateColumn('ok'),
    stateColumn('neutral'),
    { key: 'status', headerKey: 'folderTree.colStatus', sortKey: 'status', needsResults: true },
    { key: 'findings', headerKey: 'folderTree.colFindings', sortKey: 'findings', needsResults: true },
  ],
  sortKeys: ['name', 'error', 'warning', 'ok', 'neutral', 'findings', 'status'],
  textSortKeys: ['name', 'module'],
  favoritableAreas: new Set(['builtin', 'custom', 'community']),
  resultKind: 'dashboard',
  texts: {
    moduleHeader: 'folderTree.colModule',
    total: 'folderTree.dashboardsTotal',
    treeLabel: 'folderTree.label',
    searchAll: 'folderTree.searchAll',
    favoritesEmpty: 'favorites.empty',
    customEmpty: 'folderNav.customEmpty',
    customCommand: '/create-custom-dashboard',
  },
};

const TEST_PRESET: ListPreset = {
  id: 'test',
  columns: [
    { key: 'testType', headerKey: 'folderTree.colTestType', sortKey: 'testType', needsResults: false },
    { key: 'members', headerKey: 'folderTree.colMembers', sortKey: 'members', needsResults: false },
    { key: 'testStatus', headerKey: 'folderTree.colStatus', sortKey: 'status', needsResults: false },
  ],
  sortKeys: ['name', 'testType', 'members', 'status'],
  textSortKeys: ['name', 'module', 'testType', 'members', 'status'],
  favoritableAreas: null,
  resultKind: 'test',
  texts: {
    moduleHeader: 'folderTree.colFolder',
    total: 'folderTree.testsTotal',
    treeLabel: 'folderTree.labelTests',
    searchAll: 'folderTree.searchAllTests',
    favoritesEmpty: 'favorites.emptyTests',
    customEmpty: 'folderNav.customEmptyTests',
    customCommand: '/create-custom-test',
  },
};

const PRESETS: Record<ListPresetId, ListPreset> = { dashboard: DASHBOARD_PRESET, test: TEST_PRESET };

/** The preset of a layout value; anything unknown is the dashboard preset. */
export function listPreset(id: unknown): ListPreset {
  return id === 'test' ? TEST_PRESET : PRESETS.dashboard;
}

/** Sort keys of a view: the list's own, the favorites view additionally by module. */
export function presetSortKeys(preset: ListPreset, favoritesView: boolean): TreeSortKey[] {
  return favoritesView ? [...preset.sortKeys, 'module'] : [...preset.sortKeys];
}

/** Whether a column header sorts — result columns only while envelopes feed the list. */
export function isSortable(preset: ListPreset, key: TreeSortKey, withResults: boolean): boolean {
  return withResults || preset.textSortKeys.includes(key);
}

/** Whether a row of the given area carries a favorite star. */
export function isFavoritableArea(preset: ListPreset, area: unknown): boolean {
  return preset.favoritableAreas === null || preset.favoritableAreas.has(String(area ?? ''));
}

/**
 * Values of the preset's value columns for one dataset row (`TreeDashboard.values`):
 * the test preset reads `test_type` (as its display label) and `member_count`.
 * Empty or non-numeric values become null — sorted last.
 */
export function rowValues(
  preset: ListPreset,
  row: Record<string, unknown>,
  label: (column: ListColumnKey, raw: string) => string,
): Record<string, string | number | null> | undefined {
  if (preset.id !== 'test') return undefined;
  const rawType = row.test_type == null ? '' : String(row.test_type);
  const members = typeof row.member_count === 'number' && Number.isFinite(row.member_count) ? row.member_count : null;
  return {
    testType: rawType ? label('testType', rawType) : null,
    members,
  };
}
