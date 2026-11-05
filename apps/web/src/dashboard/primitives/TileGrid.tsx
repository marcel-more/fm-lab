import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import { substituteString } from '../tokens';
import { useRowSearch } from './_useRowSearch';
import { dispatchAction } from '../actions';
import { translateCellValue } from './_cellTranslate';
import type { ActionSpec } from '../actions';
import { DisclosureChevron } from '../../components/DisclosureChevron';
import { useDashboardSummary } from '../../hooks/useDashboardSummary';
import { useFavorites } from '../../hooks/useFavorites';
import { displayState, type ResultDisplayState, type ResultEnvelope } from '../../api/resultsApi';
import {
  AUTO_RUN_MAX_PENDING, AggregateTokens, FILTERABLE_STATES, STATE_TOKEN,
  aggregateBadgeRoots, aggregateEnvelopes, aggregateFolder, formatEntryCount, type FolderAggregate,
} from './_folderAggregate';
import {
  DEFAULT_SORT, formatSort, isCustomAreaRoot, parseSort,
  type FolderRow, type TreeSortMode,
} from './_folderTree';
import { isFavoritableArea, listPreset, presetSortKeys, type ListColumnKey } from './_listColumns';
import { FolderIcon } from './FolderIcon';
import { FavoriteButton } from './FavoriteButton';
import { FolderTreeList, LegacyBadge, OverrideBadge } from './FolderTreeList';
import { PulseIcon } from './PulseIcon';
import { StarIcon } from './StarIcon';

interface TileSpec {
  title: string;
  subtitle?: string;
  icon?: string;
  badge?: string;
  /** i18n prefix that labels the substituted badge value (`types:testTypes` → `types:testTypes.<value>`). */
  badgeLabels?: string;
  onClick?: ActionSpec;
}

type ViewMode = 'tiles' | 'list';

/** Segments of the view selector, declared per layout via `viewModes`. */
type OverviewView = 'folders' | 'list' | 'favorites';
const OVERVIEW_VIEWS: OverviewView[] = ['folders', 'list', 'favorites'];

/** `?type=` value of the dashboards that declare no object type. */
const TYPE_NONE = '_none';

/** Default key of the last chosen view — the fallback when the URL has no `?view=`. */
const VIEW_STORAGE_KEY = 'fmlab.dashboards.view';

/**
 * The view is kept on two levels under the same key: the tab
 * (`sessionStorage`) keeps its own view across reload and return from a
 * dashboard, the browser (`localStorage`) seeds new tabs. Open tabs are never
 * synchronised.
 */
type ViewLevel = 'tab' | 'browser';

const viewStore = (level: ViewLevel): Storage =>
  level === 'tab' ? window.sessionStorage : window.localStorage;

function readStoredView(level: ViewLevel, key: string): string | null {
  try {
    return viewStore(level).getItem(key);
  } catch {
    return null;
  }
}

function storeView(key: string, view: OverviewView, levels: readonly ViewLevel[] = ['tab', 'browser']): void {
  for (const level of levels) {
    try {
      viewStore(level).setItem(key, view);
    } catch {
      /* storage unavailable — the URL still carries the view */
    }
  }
}

const TilesIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <rect x="3" y="3" width="7" height="7" rx="1.5" />
    <rect x="14" y="3" width="7" height="7" rx="1.5" />
    <rect x="3" y="14" width="7" height="7" rx="1.5" />
    <rect x="14" y="14" width="7" height="7" rx="1.5" />
  </svg>
);

const ListIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
    <line x1="8" y1="6" x2="20" y2="6" />
    <line x1="8" y1="12" x2="20" y2="12" />
    <line x1="8" y1="18" x2="20" y2="18" />
    <circle cx="4" cy="6" r="1.1" fill="currentColor" stroke="none" />
    <circle cx="4" cy="12" r="1.1" fill="currentColor" stroke="none" />
    <circle cx="4" cy="18" r="1.1" fill="currentColor" stroke="none" />
  </svg>
);

/** KPI + state chip row of one dashboard tile. */
const ResultChips = ({ envelope, running, unitLabel }: {
  envelope: ResultEnvelope | undefined;
  running: boolean;
  unitLabel: (envelope: ResultEnvelope) => string;
}) => {
  if (!envelope) return null;
  if (running) {
    return <span className="dash-tile__chips"><span className="dash-chip dash-chip--skeleton" /></span>;
  }
  const state = displayState(envelope);
  return (
    <span className="dash-tile__chips">
      {envelope.runStatus === 'ran' && envelope.value != null && (
        <span className="dash-chip dash-chip--kpi" title={envelope.meaning ?? undefined}>
          {String(envelope.value)}{' '}{unitLabel(envelope)}
        </span>
      )}
      <span
        className={`dash-chip dash-chip--state dash-state-${state}${state === 'pending' ? ' dash-chip--pending' : ''}`}
        title={envelope.error ?? undefined}
      >
        {STATE_TOKEN[state]}
      </span>
    </span>
  );
};

export function TileGrid({ node, dataset, datasets, navigate }: PrimitiveProps) {
  const { t, i18n } = useTranslation(['common', 'detail', 'dashboard', 'types']);
  // Pipe substituted tile strings through the dashboard cell-value translator
  // so canonical English titles / descriptions / categories emitted from SQL
  // templates render in the active UI language. Unknown values pass through.
  const tx = (s: string) => String(translateCellValue(s, t));
  const tile = (node.props?.tile as TileSpec) ?? { title: '{{title}}' };
  const minTileWidth = (node.props?.minTileWidth as number) ?? 220;
  const empty = node.props?.empty as { message?: string } | undefined;
  // Opt-in toolbar with a tiles⇄list toggle + entry-count meta.
  const viewToggle = node.props?.viewToggle as boolean | undefined;
  // Opt-in view selector (supersedes viewToggle): its segments, the view kept
  // in `?view=`, and — together with folderNav — the hierarchical list.
  const rawViewModes = node.props?.viewModes;
  // Opt-in folder navigation (?folder= deep-links) + result chips. Default
  // off → every other TileGrid consumer behaves exactly as before.
  const folderNav = node.props?.folderNav === true;
  const viewModes = useMemo<OverviewView[] | null>(() => {
    if (!Array.isArray(rawViewModes)) return null;
    // The favorites view is a list of the folder navigation's dashboards.
    const modes = OVERVIEW_VIEWS.filter(v => rawViewModes.includes(v) && (v !== 'favorites' || folderNav));
    return modes.length ? modes : null;
  }, [rawViewModes, folderNav]);
  const folderParam = (node.props?.folderParam as string) || 'folder';
  const foldersDatasetId = (node.props?.foldersDataset as string) || 'folders';
  const resultChips = folderNav && node.props?.resultChips === true;
  // Columns of the hierarchical list and favorites view (`dashboard` | `test`).
  const preset = listPreset(node.props?.listColumns);
  // Result kinds read-only from the summary (status column, no runs) — the
  // result chips imply `dashboard`.
  const resultKinds = Array.isArray(node.props?.resultKinds)
    ? (node.props.resultKinds as unknown[]).map(String)
    : resultChips ? ['dashboard'] : [];
  const readResults = folderNav && (resultChips || resultKinds.includes(preset.resultKind));
  // Per-page storage keys, so two overviews never share view or expansion state.
  const viewStorageKey = (node.props?.viewStorageKey as string) || VIEW_STORAGE_KEY;
  const expandedStorageKey = node.props?.expandedStorageKey as string | undefined;
  const favoriteKind = node.props?.favoriteKind === 'test' ? 'test' : 'dashboard';
  const rows = dataset?.data ?? [];

  const [viewMode, setViewMode] = useState<ViewMode>('tiles');
  // Receives the list's "expand all | collapse all" buttons (portal target).
  const [bulkSlot, setBulkSlot] = useState<HTMLSpanElement | null>(null);
  // Collapsed subfolder sections of the filtered hierarchy view (default: expanded).
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(new Set());
  const [searchParams, setSearchParams] = useSearchParams();
  const summary = useDashboardSummary(resultChips || readResults);
  // Favorites (workspace-wide, server-side): re-fetched on every overview mount.
  const favoritesEnabled = !!viewModes?.includes('favorites');
  const favorites = useFavorites(favoriteKind, { enabled: favoritesEnabled, refreshOnMount: true });
  // Display label of a preset value column (test type) — stable per language,
  // the list memoizes its tree on it.
  const columnLabel = useMemo(
    () => (column: ListColumnKey, raw: string): string =>
      column === 'testType' ? t(`types:testTypes.${raw}`, { defaultValue: raw }) as string : raw,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [i18n.language],
  );

  // Effective view: `?view=` (deep link, survives reload) → this tab's view →
  // the view chosen last in any tab → the layout's `defaultView` → first segment.
  const viewParam = searchParams.get('view');
  const pickView = (v: unknown): OverviewView | null =>
    viewModes && typeof v === 'string' && (viewModes as string[]).includes(v) ? (v as OverviewView) : null;
  const overviewView = viewModes
    ? (pickView(viewParam)
      ?? pickView(readStoredView('tab', viewStorageKey))
      ?? pickView(readStoredView('browser', viewStorageKey))
      ?? pickView(node.props?.defaultView)
      ?? viewModes[0])
    : null;
  // A deep-linked view counts as the last chosen one — links without `?view=`
  // (breadcrumbs, dashboard crumbs) then land in the same view. Entered without
  // `?view=`, the resolved view is pinned to the tab only: a later choice in
  // another tab must not switch this one on the next re-render.
  useEffect(() => {
    if (!overviewView) return;
    if (viewParam === overviewView) storeView(viewStorageKey, overviewView);
    else if (!viewParam) storeView(viewStorageKey, overviewView, ['tab']);
  }, [overviewView, viewParam, viewStorageKey]);
  // View switches REPLACE the history entry: "back" steps through folder
  // levels (pushed by setFolder), never toggles between views. The favorites
  // view has no folder level and drops `?folder=`.
  const selectView = (view: OverviewView) => {
    storeView(viewStorageKey, view);
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      next.set('view', view);
      if (view === 'favorites') next.delete(folderParam);
      return next;
    }, { replace: true });
  };

  const favoritesView = folderNav && overviewView === 'favorites';
  // A deep link into the favorites view may still carry a folder — drop it,
  // so the breadcrumb shows the root.
  const strayFolder = favoritesView && searchParams.has(folderParam);
  useEffect(() => {
    if (!strayFolder) return;
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      next.delete(folderParam);
      return next;
    }, { replace: true });
  }, [strayFolder, folderParam, setSearchParams]);

  const currentFolder = folderNav && !favoritesView ? (searchParams.get(folderParam) ?? '') : '';

  // Sorting (`?sort=<key>-<dir>`) by the column headers of the list and the
  // favorites view; switches REPLACE the history entry like `?view=`. Without
  // result envelopes only the preset's text columns sort. The folder view has
  // no headers and keeps Name ↑.
  const treeListView = folderNav && overviewView === 'list';
  const sortKeys = presetSortKeys(preset, favoritesView);
  const sortMode: TreeSortMode = favoritesView || treeListView
    ? parseSort(searchParams.get('sort'), readResults ? sortKeys : preset.textSortKeys)
    : DEFAULT_SORT;
  const setSortMode = (mode: TreeSortMode) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      const value = formatSort(mode);
      if (value) next.set('sort', value);
      else next.delete('sort');
      return next;
    }, { replace: true });
  };
  const stateFilter = useMemo(() => {
    if (!folderNav) return new Set<ResultDisplayState>();
    const raw = searchParams.get('state') ?? '';
    return new Set(
      raw.split(',').map(s => s.trim()).filter((s): s is ResultDisplayState =>
        (FILTERABLE_STATES as string[]).includes(s)),
    );
  }, [folderNav, searchParams]);

  // Object-type filter (`?type=`): declared `object_types` of the overview
  // rows — global like the search. Options carry their dashboard counts;
  // an unknown value is ignored.
  const typeOptions = useMemo(() => {
    if (!folderNav) return { types: [] as { type: string; label: string; count: number }[], none: 0 };
    const counts = new Map<string, number>();
    let none = 0;
    for (const row of rows) {
      const types = Array.isArray(row.object_types) ? (row.object_types as unknown[]).map(String) : [];
      if (types.length === 0) none += 1;
      for (const type of new Set(types)) counts.set(type, (counts.get(type) ?? 0) + 1);
    }
    const types = [...counts.entries()]
      .map(([type, count]) => ({ type, count, label: t(`types:objectTypes.${type}`, { defaultValue: type }) as string }))
      .sort((a, b) => a.label.localeCompare(b.label, i18n.language));
    return { types, none };
  }, [folderNav, rows, t, i18n.language]);
  const typeParam = searchParams.get('type');
  const typeFilter = typeParam && (typeParam === TYPE_NONE
    ? typeOptions.none > 0
    : typeOptions.types.some(o => o.type === typeParam)) ? typeParam : null;
  const matchesType = (row: Record<string, unknown>): boolean => {
    if (!typeFilter) return true;
    const types = Array.isArray(row.object_types) ? (row.object_types as unknown[]).map(String) : [];
    return typeFilter === TYPE_NONE ? types.length === 0 : types.includes(typeFilter);
  };
  const setTypeFilter = (value: string) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      if (value) next.set('type', value);
      else next.delete('type');
      return next;
    }, { replace: true });
  };

  const folderRows = useMemo<FolderRow[]>(() => {
    if (!folderNav) return [];
    return ((datasets?.[foldersDatasetId]?.data ?? []) as unknown[]) as FolderRow[];
  }, [folderNav, datasets, foldersDatasetId]);
  const folderByPath = useMemo(() => new Map(folderRows.map(f => [f.path, f])), [folderRows]);
  const folderExists = currentFolder === '' || folderByPath.has(currentFolder);

  const search = useRowSearch(rows, {
    searchable: node.props?.searchable as boolean | 'auto' | undefined,
    autoThreshold: node.props?.searchAutoThreshold as number | undefined,
    placeholder: node.props?.searchPlaceholder as string | undefined,
  });
  const hasQuery = search.query.trim() !== '';

  // Auto-run on rubric levels (O7): entering a folder triggers a `missing`
  // run for its subtree — bounded, idempotent against the server cache.
  // The root stays explicit ("run all"), pending chips make the state visible.
  const pendingInFolder = useMemo(() => {
    if (!resultChips || !summary.results || !currentFolder) return 0;
    const prefix = `${currentFolder}/`;
    let n = 0;
    for (const envelope of Object.values(summary.results)) {
      if (envelope.ref.kind !== 'dashboard' || envelope.runStatus !== 'pending') continue;
      const rubric = envelope.rubric || '';
      if (rubric === currentFolder || rubric.startsWith(prefix)) n += 1;
    }
    return n;
  }, [resultChips, summary.results, currentFolder]);

  useEffect(() => {
    if (!resultChips || !currentFolder || !folderExists) return;
    if (pendingInFolder === 0 || pendingInFolder > AUTO_RUN_MAX_PENDING) return;
    if (summary.isFolderRunning(currentFolder)) return;
    void summary.runFolder(currentFolder, 'missing');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resultChips, currentFolder, folderExists, pendingInFolder]);

  // Favorites view: dataset rows of the favorite ids, in dataset order (the
  // server sorts by localized title — the "standard" order).
  const favoriteRows = useMemo(
    () => (favoritesView ? rows.filter(r => favorites.ids.has(String(r.id ?? ''))) : []),
    [favoritesView, rows, favorites.ids],
  );
  // Auto-run like entering a folder: up to AUTO_RUN_MAX_PENDING pending
  // favorites run once with `missing`; a larger set stays explicit ("run all").
  const pendingFavoriteIds = useMemo(() => {
    if (!resultChips || !summary.results) return [];
    const results = summary.results;
    return favoriteRows
      .map(r => String(r.id ?? ''))
      .filter(id => results[`dashboard:${id}`]?.runStatus === 'pending');
  }, [resultChips, summary.results, favoriteRows]);
  const autoRunKey = useRef<string | null>(null);
  useEffect(() => {
    if (pendingFavoriteIds.length === 0 || pendingFavoriteIds.length > AUTO_RUN_MAX_PENDING) return;
    const key = [...pendingFavoriteIds].sort().join(',');
    if (autoRunKey.current === key) return;
    autoRunKey.current = key;
    void summary.runDashboards(pendingFavoriteIds, 'missing');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pendingFavoriteIds]);

  const setFolder = (path: string) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      if (path) next.set(folderParam, path);
      else next.delete(folderParam);
      return next;
    });
  };
  const toggleStateFilter = (state: ResultDisplayState) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      const active = new Set(stateFilter);
      if (active.has(state)) active.delete(state);
      else active.add(state);
      if (active.size) next.set('state', [...active].join(','));
      else next.delete('state');
      return next;
    });
  };

  const envelopeForRow = (row: Record<string, unknown>): ResultEnvelope | undefined =>
    resultChips ? summary.envelopeFor('dashboard', String(row.id ?? '')) : undefined;

  const unitLabel = (envelope: ResultEnvelope): string => {
    if (envelope.unit === 'findings') {
      return t('dashboard:folderNav.findings', { defaultValue: 'Findings' }) as string;
    }
    return envelope.unit ?? '';
  };

  // Favorite stars on dashboard tiles and list rows of the overview (toggle;
  // the favorites view removes instead). Only with the favorites segment.
  const rowId = (row: Record<string, unknown>) => String(row.id ?? '');
  const canFavorite = (row: Record<string, unknown>) =>
    favoritesEnabled && isFavoritableArea(preset, row.area);
  /** Wraps a dashboard tile with its star — a sibling of the tile button, never nested in it. */
  const withStar = (row: Record<string, unknown>, title: string, tileEl: ReactNode, key: number) =>
    canFavorite(row) ? (
      <div key={key} className="dash-tile-cell">
        {tileEl}
        <FavoriteButton
          active={favorites.isFavorite(rowId(row))}
          onToggle={() => favorites.toggle(rowId(row))}
          name={title}
          className="dash-favstar--tile"
        />
      </div>
    ) : tileEl;

  if (rows.length === 0) {
    return <div className="dash-tilegrid__empty">{empty?.message ?? t('common:noEntries')}</div>;
  }

  const mode: ViewMode = overviewView
    ? (overviewView === 'list' ? 'list' : 'tiles')
    : viewToggle ? viewMode : 'tiles';
  // The hierarchical list replaces the flat one only behind the view selector.
  const treeList = treeListView;

  const gridStyle: React.CSSProperties = {
    display: 'grid',
    gridTemplateColumns: `repeat(auto-fill, minmax(${minTileWidth}px, 1fr))`,
    gap: '12px',
  };

  const badgeLabel = (raw: string): string =>
    tile.badgeLabels && raw ? t(`${tile.badgeLabels}.${raw}`, { defaultValue: raw }) as string : tx(raw);

  // Shared per-row cell projection (used by both the tile grid and the list).
  const buildCell = (row: Record<string, unknown>) => ({
    title: tx(substituteString(tile.title, row)),
    subtitle: tile.subtitle ? tx(substituteString(tile.subtitle, row)) : '',
    badge: tile.badge ? badgeLabel(substituteString(tile.badge, row)) : '',
    clickable: !!tile.onClick,
  });

  // Renders one block of dashboard rows as either tiles or a list. In tile
  // mode with active folderNav the description leaves the tile (it stays a
  // search hit) and the chip row takes its place; the list mode keeps the
  // description as the dense view (O3). `showRubric` adds the folder path as
  // a meta line (flat search/filter views).
  const renderRows = (subset: Record<string, unknown>[], showRubric = false) =>
    mode === 'list' ? (
      <ul className="dash-navlist">
        {subset.map((row, i) => {
          const c = buildCell(row);
          const envelope = envelopeForRow(row);
          return (
            <li key={i}>
              <button
                type="button"
                className={`dash-navlist__item${c.clickable ? ' dash-navlist__item--clickable' : ''}`}
                onClick={c.clickable ? () => dispatchAction(tile.onClick, row, { navigate }) : undefined}
                disabled={!c.clickable}
              >
                <span className="dash-navlist__title">{c.title}</span>
                {folderNav && row.overrides === true && <OverrideBadge />}
                {folderNav && row.legacy === true && <LegacyBadge />}
                {c.subtitle && <span className="dash-navlist__subtitle">{c.subtitle}</span>}
                {showRubric && row.folder_label != null && (
                  <span className="dash-navlist__rubric">{String(row.folder_label)}</span>
                )}
                {resultChips && (
                  <ResultChips
                    envelope={envelope}
                    running={envelope ? summary.isRefRunning('dashboard', envelope.ref.id) : false}
                    unitLabel={unitLabel}
                  />
                )}
                {c.badge && <span className="dash-navlist__badge">{c.badge}</span>}
              </button>
            </li>
          );
        })}
      </ul>
    ) : (
      <div className="dash-tilegrid" style={gridStyle}>
        {subset.map((row, i) => {
          const c = buildCell(row);
          const envelope = envelopeForRow(row);
          const state = envelope ? displayState(envelope) : null;
          return withStar(row, c.title, (
            <button
              key={i}
              type="button"
              className={`dash-tile${c.clickable ? ' dash-tile--clickable' : ''}${resultChips && state ? ` dash-tile--state-${state}` : ''}`}
              onClick={c.clickable ? () => dispatchAction(tile.onClick, row, { navigate }) : undefined}
              disabled={!c.clickable}
              title={folderNav ? (c.subtitle || undefined) : undefined}
            >
              <span className="dash-tile__title">{c.title}</span>
              {folderNav && row.overrides === true && <OverrideBadge />}
              {folderNav && row.legacy === true && <LegacyBadge />}
              {!folderNav && c.subtitle && <span className="dash-tile__subtitle">{c.subtitle}</span>}
              {showRubric && row.folder_label != null && (
                <span className="dash-tile__rubric">{String(row.folder_label)}</span>
              )}
              {resultChips && (
                <ResultChips
                  envelope={envelope}
                  running={envelope ? summary.isRefRunning('dashboard', envelope.ref.id) : false}
                  unitLabel={unitLabel}
                />
              )}
              {c.badge && <span className="dash-tile__badge">{c.badge}</span>}
            </button>
          ), i);
        })}
      </div>
    );

  // Folder tiles for the current level (folderNav mode).
  const renderFolderTiles = (folders: FolderRow[]) => (
    <div className="dash-tilegrid" style={gridStyle}>
      {folders.map(f => {
        const agg = resultChips ? aggregateFolder(summary.results, f.path) : null;
        const running = resultChips && summary.isFolderRunning(f.path);
        // Direct entries = sub-folders + dashboards directly inside, the same
        // count the list shows; `direct_count` of the dataset holds dashboards only.
        const subfolders = folderRows.filter(x => x.parent === f.path).length;
        const entries = subfolders + f.direct_count;
        const tooltip = [
          `${t('dashboard:folderTree.entries', { count: entries })} · ${t(`dashboard:${preset.texts.total}`, { count: f.total_count })}`,
          f.description,
        ].filter(Boolean).join('\n');
        return (
          <button
            key={f.path}
            type="button"
            className={`dash-tile dash-tile--clickable dash-tile--folder${agg?.worst ? ` dash-tile--state-${agg.worst}` : ''}`}
            onClick={() => setFolder(f.path)}
            title={tooltip}
          >
            <span className="dash-tile__title">
              <span className="dash-tile__foldericon"><FolderIcon /></span>
              {f.label}
              <span className="dash-tilegroup__count">{formatEntryCount(entries, f.total_count, subfolders > 0)}</span>
            </span>
            {agg && (
              <span className="dash-tile__chips-row">
                <AggregateTokens agg={agg} />
                {agg.covered < agg.total && (
                  <span className="dash-chip dash-chip--coverage" title={t('dashboard:folderNav.coverageHint', { defaultValue: 'Teilabdeckung — noch nicht alle Ergebnisse berechnet' }) as string}>
                    {agg.covered}/{agg.total}
                  </span>
                )}
              </span>
            )}
            {resultChips && (
              <span
                role="button"
                tabIndex={0}
                className={`dash-tile__run${running ? ' dash-tile__run--busy' : ''}`}
                title={t('dashboard:folderNav.run', { defaultValue: 'Ausführen' }) as string}
                onClick={e => {
                  e.stopPropagation();
                  void summary.runFolder(f.path, 'refresh');
                }}
                onKeyDown={e => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.stopPropagation();
                    void summary.runFolder(f.path, 'refresh');
                  }
                }}
              >
                {running ? '⏳' : '▶'}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );

  /**
   * Entry count of a featured bundle: the number of result-capable dashboards
   * in the subtrees it declares (`badgeRoots`). Counted, never evaluated — the
   * summary map holds one entry per registry unit including pending stubs, so
   * this is the same number the bundle's own "Checks" KPI shows, without a run
   * and without an extra request. Absent while the summary is still loading.
   */
  const featuredCount = (row: Record<string, unknown>): number | null => {
    if (!resultChips || !summary.results) return null;
    const roots = String(row._badge_roots ?? '').split(',').map(s => s.trim()).filter(Boolean);
    if (!roots.length) return null;
    const total = roots.reduce((sum, r) => sum + (aggregateFolder(summary.results, r)?.total ?? 0), 0);
    return total > 0 ? total : null;
  };

  /**
   * Featured entries (manifest `featured: true`) — the overview's entry points.
   * Rendered as a full-width band ABOVE the folder tiles instead of competing
   * as an equal tile below them, and deliberately without result chips or a
   * state edge: those stay the visual language of the folders, so the band
   * reads as a different species rather than a fifth rubric.
   */
  const renderFeatured = (subset: Record<string, unknown>[]) => (
    <div className="dash-featured">
      {subset.map((row, i) => {
        const c = buildCell(row);
        const count = featuredCount(row);
        // The pulse moves while rules of the band still wait for a result.
        const agg = resultChips ? aggregateBadgeRoots(summary.results, row._badge_roots) : null;
        return withStar(row, c.title, (
          <button
            key={i}
            type="button"
            className={`dash-tile dash-tile--featured${c.clickable ? ' dash-tile--clickable' : ''}`}
            onClick={c.clickable ? () => dispatchAction(tile.onClick, row, { navigate }) : undefined}
            disabled={!c.clickable}
          >
            <span className="dash-featured__icon">
              <PulseIcon size={20} animated={!!agg && agg.covered < agg.total} />
            </span>
            <span className="dash-featured__body">
              <span className="dash-featured__head">
                <span className="dash-tile__title">{c.title}</span>
                {count !== null && (
                  <span className="dash-featured__count">
                    {t('dashboard:featured.ruleCount', { count, defaultValue: '{{count}} checks' })}
                  </span>
                )}
              </span>
              {c.subtitle && <span className="dash-featured__desc">{c.subtitle}</span>}
            </span>
          </button>
        ), i);
      })}
    </div>
  );

  // ---------------------------------------------------------------------------
  // Legacy grouped mode (`groupBy`) — unchanged for existing consumers.
  // ---------------------------------------------------------------------------
  const groupByField = !folderNav ? (node.props?.groupBy as string | undefined) : undefined;
  const groups: { key: string; label: string; rows: Record<string, unknown>[] }[] = [];
  if (groupByField) {
    const byKey = new Map<string, Record<string, unknown>[]>();
    for (const row of search.filtered) {
      const raw = row[groupByField];
      const key = raw == null ? '' : String(raw);
      if (!byKey.has(key)) byKey.set(key, []);
      byKey.get(key)!.push(row);
    }
    // Humanized fallback when no server-provided localized label is available.
    const folderLabelFallback = (key: string) =>
      key
        .split('/')
        .map((seg) => tx(seg.replace(/[-_]/g, ' ').replace(/\b\w/g, (ch) => ch.toUpperCase())))
        .join(' / ');
    const keys = [...byKey.keys()].sort((a, b) => {
      if (a === '') return -1;
      if (b === '') return 1;
      return a.localeCompare(b);
    });
    for (const key of keys) {
      const groupRows = byKey.get(key)!;
      const serverLabel = key !== '' ? (groupRows[0]?.folder_label as string | undefined) : undefined;
      groups.push({
        key,
        label:
          key === ''
            ? (t('common:general', { defaultValue: 'General' }) as string)
            : serverLabel || folderLabelFallback(key),
        rows: groupRows,
      });
    }
  }
  const rootCount = groupByField
    ? (groups.find((g) => g.key === '')?.rows.length ?? 0)
    : search.filtered.length;
  const nestedCount = groupByField ? groups.some((g) => g.key !== '') : false;

  // ---------------------------------------------------------------------------
  // folderNav derivations — local/global resolution:
  //   search  ⇒ GLOBAL flat view (rubric path per hit, counts global)
  //   filter  ⇒ LOCAL to the current folder: direct hits + one collapsible
  //             section per subfolder (collapsed = consolidated count+tokens)
  //   neither ⇒ plain folder level; counts always map to the shown level.
  // ---------------------------------------------------------------------------
  const filterActive = folderNav && stateFilter.size > 0;
  // The favorites view resolves search, type and state filter itself (flat
  // list). The object-type filter resolves globally like the search.
  const searchMode = folderNav && !favoritesView && (hasQuery || typeFilter !== null);
  const filterMode = folderNav && !favoritesView && !searchMode && filterActive;

  const inSubtree = (row: Record<string, unknown>, folderPath: string): boolean => {
    if (!folderPath) return true;
    const f = row.folder == null ? '' : String(row.folder);
    return f === folderPath || f.startsWith(`${folderPath}/`);
  };
  const matchesStateFilter = (row: Record<string, unknown>): boolean => {
    if (!filterActive) return true;
    const envelope = envelopeForRow(row);
    if (!envelope) return false;
    return stateFilter.has(displayState(envelope));
  };

  const childFolders = folderNav
    ? folderRows.filter(f => (currentFolder ? f.parent === currentFolder : f.parent === null))
    : [];
  const childRows = folderNav
    ? search.filtered.filter(r => (currentFolder ? String(r.folder ?? '') === currentFolder : r.folder == null))
    : [];
  // Featured entries leave the normal grid (they render as their own band) —
  // otherwise the same bundle would appear twice on the level.
  const featuredRows = childRows.filter(r => r.featured === true);
  const plainRows = childRows.filter(r => r.featured !== true);
  // Search resolves globally (special case by design); an additionally active
  // state filter narrows the global hits further.
  const globalMatches = searchMode ? search.filtered.filter(matchesType).filter(matchesStateFilter) : [];
  // State filter resolves within the current subtree — the hierarchy context
  // stays visible instead of collapsing into a global list.
  const subtreeMatches = filterMode
    ? rows.filter(r => inSubtree(r, currentFolder)).filter(matchesStateFilter)
    : [];
  // Favorites view: search and state filter narrow the favorites directly —
  // there is no hierarchy to keep.
  const favoriteMatches = favoritesView
    ? search.filtered.filter(r => favorites.ids.has(String(r.id ?? ''))).filter(matchesType).filter(matchesStateFilter)
    : [];
  // Favorites without a row: ids the server reports missing plus ids without
  // a row in the overview dataset (e.g. a bundle tagged `internal`).
  const missingFavoriteIds = favoritesView
    ? (() => {
      const rowIds = new Set(rows.map(r => String(r.id ?? '')));
      return [...favorites.missing, ...[...favorites.ids].filter(id => !rowIds.has(id))];
    })()
    : [];

  /** Total number of dashboards in the currently shown subtree. */
  const subtreeTotal = currentFolder
    ? (folderByPath.get(currentFolder)?.total_count ?? childRows.length)
    : rows.length;

  /** Consolidated aggregate over a concrete row set (collapsed section header). */
  const aggregateRowSet = (set: Record<string, unknown>[]): FolderAggregate =>
    aggregateEnvelopes(set.map(envelopeForRow).filter((e): e is ResultEnvelope => !!e));

  const toggleSection = (path: string) => {
    setCollapsedSections(prev => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  };

  /**
   * Filtered hierarchy view (state filter without search): direct matches of
   * the current folder first, then one collapsible section per subfolder that
   * has matches. Collapsed sections keep a consolidated view (match count +
   * state tokens); expanded sections show the filtered tiles incl. rubric
   * path for hits nested deeper than the section folder.
   */
  const renderFilteredHierarchy = () => {
    const direct = subtreeMatches.filter(r =>
      (currentFolder ? String(r.folder ?? '') === currentFolder : r.folder == null));
    const sections = childFolders
      .map(f => ({ folder: f, matches: subtreeMatches.filter(r => inSubtree(r, f.path)) }))
      .filter(s => s.matches.length > 0);
    if (direct.length === 0 && sections.length === 0) {
      return (
        <div className="dash-tilegrid__empty">
          {t('dashboard:folderNav.noFilterMatches', { defaultValue: 'Keine Einträge mit diesem Status in dieser Rubrik.' })}
        </div>
      );
    }
    return (
      <div className="dash-tilegroups">
        {direct.length > 0 && renderRows(direct)}
        {sections.map(({ folder: f, matches }) => {
          const collapsed = collapsedSections.has(f.path);
          return (
            <section key={f.path} className="dash-tilegroup dash-tilegroup--collapsible">
              <h3 className="dash-tilegroup__title">
                <button
                  type="button"
                  className="dash-tilegroup__toggle"
                  onClick={() => toggleSection(f.path)}
                  aria-expanded={!collapsed}
                >
                  <DisclosureChevron open={!collapsed} />
                  {f.label}
                  <span className="dash-tilegroup__count">{formatEntryCount(matches.length, matches.length, false)}</span>
                </button>
                {collapsed && <AggregateTokens agg={aggregateRowSet(matches)} />}
                <button
                  type="button"
                  className="dash-folderbar__link dash-tilegroup__open"
                  onClick={() => setFolder(f.path)}
                >
                  {t('dashboard:folderNav.openFolder', { defaultValue: 'Ordner öffnen' })} →
                </button>
              </h3>
              {!collapsed && renderRows(matches, true)}
            </section>
          );
        })}
      </div>
    );
  };

  // "Run all" on the current level: root chunks per top-level folder
  // (frontend chunking instead of a queue system, O8); inside a folder it
  // runs the subtree; in the favorites view it runs the shown favorites.
  const runAllBusy = folderNav && (favoritesView
    ? favoriteMatches.some(r => summary.isRefRunning('dashboard', String(r.id ?? '')))
    : currentFolder
      ? summary.isFolderRunning(currentFolder)
      : childFolders.some(f => summary.isFolderRunning(f.path)));
  const runAll = () => {
    if (favoritesView) {
      void summary.runDashboards(favoriteMatches.map(r => String(r.id ?? '')), 'missing');
    } else if (currentFolder) {
      void summary.runFolder(currentFolder, 'missing');
    } else {
      for (const f of folderRows.filter(f => f.parent === null)) {
        void summary.runFolder(f.path, 'missing');
      }
    }
  };

  const stateFilterLabel = (s: ResultDisplayState): string =>
    t(`dashboard:folderNav.state.${s}`, { defaultValue: s }) as string;

  // Shown instead of an empty level when the user area holds no bundle yet.
  const customEmptyHint = t(`dashboard:${preset.texts.customEmpty}`, { command: preset.texts.customCommand }) as string;
  const currentFolderRow = currentFolder ? folderByPath.get(currentFolder) : undefined;

  const viewButton =(key: string, active: boolean, label: string, icon: ReactNode, onSelect: () => void) => (
    <button
      key={key}
      type="button"
      className={`dash-viewbar__btn${active ? ' active' : ''}`}
      aria-pressed={active}
      title={label}
      aria-label={label}
      onClick={onSelect}
    >
      {icon}
    </button>
  );
  const viewIcons: Record<OverviewView, ReactNode> = {
    folders: <TilesIcon />, list: <ListIcon />, favorites: <StarIcon />,
  };

  /**
   * Favorites view: the favorite dashboards as a flat list with the columns of
   * the hierarchical list, a hint for favorites that are no longer available
   * and the empty state.
   */
  const renderFavorites = () => {
    if (!favorites.loaded) return null;
    return (
      <>
        {missingFavoriteIds.length > 0 && (
          <div className="dash-favmissing" role="note">
            <span>{t('dashboard:favorites.missing', { count: missingFavoriteIds.length })}</span>
            {' — '}
            <button
              type="button"
              className="dash-folderbar__link"
              onClick={() => favorites.removeMany(missingFavoriteIds)}
            >
              {t('dashboard:favorites.removeMissing')}
            </button>
          </div>
        )}
        <FolderTreeList
          flat
          folders={[]}
          rows={favoriteMatches}
          filtered={false}
          root=""
          sort={sortMode}
          onSortChange={setSortMode}
          summary={summary}
          resultChips={resultChips}
          preset={preset}
          readResults={readResults}
          columnLabel={columnLabel}
          describe={row => {
            const c = buildCell(row);
            return { title: c.title, subtitle: c.subtitle };
          }}
          onOpen={row => dispatchAction(tile.onClick, row, { navigate })}
          onDrillDown={() => { /* no folders in the flat list */ }}
          onRemove={row => favorites.remove(String(row.id ?? ''), buildCell(row).title)}
          unitLabel={unitLabel}
          emptyMessage={favoriteRows.length === 0
            ? t(`dashboard:${preset.texts.favoritesEmpty}`) as string
            : hasQuery
              ? null
              : t('dashboard:folderNav.noFilterMatches') as string}
          customEmptyHint={null}
        />
      </>
    );
  };

  return (
    <div className="dash-tilegrid-wrap">
      {(viewToggle || viewModes) && (
        <div className="dash-viewbar">
          <div className="dash-viewbar__toggle" role="group" aria-label={t('dashboard:view.label') as string}>
            {viewModes
              ? viewModes.map(v => viewButton(
                v, overviewView === v, t(`dashboard:view.${v}`) as string, viewIcons[v], () => selectView(v),
              ))
              : (
                <>
                  {viewButton('tiles', mode === 'tiles', t('dashboard:view.tiles') as string, <TilesIcon />, () => setViewMode('tiles'))}
                  {viewButton('list', mode === 'list', t('dashboard:view.list') as string, <ListIcon />, () => setViewMode('list'))}
                </>
              )}
          </div>

          {resultChips && summary.results && (
            <>
              <div className="dash-viewbar__filters" role="group" aria-label={t('dashboard:folderNav.filterLabel', { defaultValue: 'Status' }) as string}>
                {FILTERABLE_STATES.map(s => (
                  <button
                    key={s}
                    type="button"
                    className={`dash-chip dash-chip--filter dash-state-${s}${stateFilter.has(s) ? ' dash-chip--active' : ''}`}
                    aria-pressed={stateFilter.has(s)}
                    onClick={() => toggleStateFilter(s)}
                    title={stateFilterLabel(s)}
                  >
                    {STATE_TOKEN[s]} {stateFilterLabel(s)}
                  </button>
                ))}
              </div>
              <button
                type="button"
                className="dash-folderbar__runall"
                onClick={runAll}
                disabled={runAllBusy}
              >
                {runAllBusy
                  ? (t('dashboard:folderNav.running', { defaultValue: 'läuft…' }) as string)
                  : (t('dashboard:folderNav.runAll', { defaultValue: 'Alle ausführen' }) as string)}
              </button>
            </>
          )}

          {/* Entry-count meta — always mapped to the SHOWN level: search =
              global matches, filter = matches in the current subtree, plain
              folder view = level items (subtree total), hierarchical list =
              dashboards in the shown tree. */}
          <span className="dash-viewbar__count">
            {!folderNav
              ? formatEntryCount(rootCount, rows.length, nestedCount)
              : favoritesView
                ? formatEntryCount(favoriteMatches.length, favoriteMatches.length, false)
                : searchMode
                ? formatEntryCount(globalMatches.length, globalMatches.length, false)
                : filterMode
                  ? formatEntryCount(subtreeMatches.length, subtreeMatches.length, false)
                  : treeList
                    ? formatEntryCount(subtreeTotal, subtreeTotal, false)
                    : formatEntryCount(
                      childRows.length + childFolders.length,
                      subtreeTotal,
                      childFolders.length > 0,
                    )}
          </span>
        </div>
      )}

      {search.visible && (
        <div className="dash-search-bar">
          <span className="dash-search-bar__count">
            {t('detail:autoTable.rowCount', {
              count: !folderNav
                ? search.filtered.length
                : favoritesView
                  ? favoriteMatches.length
                  : searchMode
                  ? globalMatches.length
                  : filterMode
                    ? subtreeMatches.length
                    : subtreeTotal,
            })}
            {searchMode && globalMatches.length !== search.totalCount && (
              <> · {t('detail:autoTable.filteredFrom', { count: search.totalCount })}</>
            )}
            {filterMode && subtreeMatches.length !== subtreeTotal && (
              <> · {t('detail:autoTable.filteredFrom', { count: subtreeTotal })}</>
            )}
            {favoritesView && favoriteMatches.length !== favoriteRows.length && (
              <> · {t('detail:autoTable.filteredFrom', { count: favoriteRows.length })}</>
            )}
            {!folderNav && hasQuery && search.filtered.length !== search.totalCount && (
              <> · {t('detail:autoTable.filteredFrom', { count: search.totalCount })}</>
            )}
            {/* The list hides its drill-down root while searching — say so. */}
            {treeList && searchMode && currentFolder && (
              <> · <span className="dash-search-bar__scope">{t(`dashboard:${preset.texts.searchAll}`)}</span></>
            )}
          </span>
          {treeList && <span ref={setBulkSlot} className="dash-search-bar__bulk" />}
          {folderNav && typeOptions.types.length > 0 && (
            <select
              className="dash-search-bar__type"
              value={typeFilter ?? ''}
              onChange={e => setTypeFilter(e.target.value)}
              aria-label={t('dashboard:typeFilter.label') as string}
              title={t('dashboard:typeFilter.label') as string}
            >
              <option value="">{t('dashboard:typeFilter.all')}</option>
              {typeOptions.types.map(o => (
                <option key={o.type} value={o.type}>{`${o.label} (${o.count})`}</option>
              ))}
              {typeOptions.none > 0 && (
                <option value={TYPE_NONE}>{`${t('dashboard:typeFilter.none')} (${typeOptions.none})`}</option>
              )}
            </select>
          )}
          <input
            type="search"
            className="dash-search-bar__input"
            placeholder={search.placeholder}
            value={search.query}
            onChange={e => search.setQuery(e.target.value)}
          />
        </div>
      )}

      {folderNav ? (
        !folderExists ? (
          // Guard: unknown ?folder= value — no error, a hint + root link.
          <div className="dash-tilegrid__empty">
            <p>{t('dashboard:folderNav.notFound', { defaultValue: 'Ordner nicht gefunden.' })}</p>
            <button type="button" className="dash-folderbar__link" onClick={() => setFolder('')}>
              {t('dashboard:folderNav.backToRoot', { defaultValue: 'Zur Übersicht' })}
            </button>
          </div>
        ) : favoritesView ? (
          renderFavorites()
        ) : treeList ? (
          // Hierarchical list: search (global) and state filter (local)
          // narrow it to a filtered tree instead of a flat result list.
          <FolderTreeList
            folders={folderRows}
            rows={searchMode ? globalMatches : filterMode ? subtreeMatches : rows}
            filtered={searchMode || filterMode}
            root={searchMode ? '' : currentFolder}
            sort={sortMode}
            onSortChange={setSortMode}
            bulkSlot={bulkSlot}
            summary={summary}
            resultChips={resultChips}
            preset={preset}
            readResults={readResults}
            columnLabel={columnLabel}
            expandedStorageKey={expandedStorageKey}
            describe={row => {
              const c = buildCell(row);
              return { title: c.title, subtitle: c.subtitle };
            }}
            onOpen={row => dispatchAction(tile.onClick, row, { navigate })}
            onDrillDown={setFolder}
            favorites={favoritesEnabled ? {
              available: canFavorite,
              isFavorite: row => favorites.isFavorite(rowId(row)),
              toggle: row => favorites.toggle(rowId(row)),
            } : undefined}
            unitLabel={unitLabel}
            emptyMessage={searchMode
              ? null
              : filterMode
                ? t('dashboard:folderNav.noFilterMatches') as string
                : empty?.message ?? (t('common:noEntries') as string)}
            customEmptyHint={customEmptyHint}
          />
        ) : searchMode ? (
          // Search resolves GLOBALLY — flat hit list across the whole
          // hierarchy with the rubric path per tile.
          renderRows(globalMatches, true)
        ) : filterMode ? (
          // State filter resolves LOCALLY — filtered hierarchy of the
          // current folder with collapsible subfolder sections.
          renderFilteredHierarchy()
        ) : (
          <>
            {featuredRows.length > 0 && renderFeatured(featuredRows)}
            {childFolders.length > 0 && renderFolderTiles(childFolders)}
            {plainRows.length > 0 && renderRows(plainRows)}
            {childFolders.length === 0 && childRows.length === 0 && (
              <div className="dash-tilegrid__empty">
                {currentFolderRow && isCustomAreaRoot(currentFolderRow)
                  ? customEmptyHint
                  : empty?.message ?? t('common:noEntries')}
              </div>
            )}
          </>
        )
      ) : groupByField ? (
        <div className="dash-tilegroups">
          {groups.map((g) => (
            <section key={g.key || '__root__'} className="dash-tilegroup">
              <h3 className="dash-tilegroup__title">
                {g.label}
                <span className="dash-tilegroup__count">{formatEntryCount(g.rows.length, g.rows.length, false)}</span>
              </h3>
              {renderRows(g.rows)}
            </section>
          ))}
        </div>
      ) : (
        renderRows(search.filtered)
      )}

      {(hasQuery || typeFilter !== null) && (favoritesView ? favoriteRows.length > 0 && favoriteMatches.length === 0
        : (searchMode ? globalMatches : search.filtered).length === 0) && (
        <div className="dash-search-bar__empty">
          {hasQuery
            ? t('detail:autoTable.noMatches', { query: search.query })
            : t('dashboard:typeFilter.noMatches')}
        </div>
      )}
    </div>
  );
}
