import { Fragment, useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { useTranslation } from 'react-i18next';
import type { ResultDisplayState, ResultEnvelope } from '../../api/resultsApi';
import { BulkToggleButton, BulkToggleGroup, CollapseAllIcon, ExpandAllIcon } from '../../components/BulkToggle';
import { DisclosureChevron } from '../../components/DisclosureChevron';
import type { DashboardSummary } from '../../hooks/useDashboardSummary';
import { formatKpiValue } from './_format';
import {
  AUTO_RUN_MAX_PENDING, AggregateTokens, STATE_TOKEN, aggregateBadgeRoots, aggregateFolder, resultFacts,
  type FolderAggregate,
} from './_folderAggregate';
import {
  applyBulkExpansion, buildFolderTree, bulkExpansionAvailability, flattenVisible, isCustomAreaRoot,
  isFolderExpanded, isForcedOpen, nextSort, sortSiblings,
  type DashboardNode, type FolderNode, type FolderRow, type TreeDashboard, type TreeNode, type TreeSortKey,
  type TreeSortMode,
} from './_folderTree';
import { browserStores, loadExpanded, pruneExpanded, saveExpanded } from './_expansionStore';
import { isSortable, listPreset, rowValues, type ListColumn, type ListColumnKey, type ListPreset } from './_listColumns';
import { FavoriteButton } from './FavoriteButton';
import { FolderIcon } from './FolderIcon';
import { PulseIcon } from './PulseIcon';
import { StarIcon } from './StarIcon';

type Row = Record<string, unknown>;

/** Default key of the folders' expansion state (tab + browser level); pages pass their own key. */
const EXPANDED_STORAGE_KEY = 'fmlab.dashboards.list.expanded';

/** The four state columns; `failed` shares the error column, `pending` the findings column. */
type StateColumn = 'error' | 'warning' | 'ok' | 'neutral';
const isStateColumn = (key: ListColumnKey): key is StateColumn =>
  key === 'error' || key === 'warning' || key === 'ok' || key === 'neutral';

const RAW_LABEL = (_column: ListColumnKey, raw: string): string => raw;

/** CSS modifier of a column cell. */
const columnClass = (key: ListColumnKey): string =>
  isStateColumn(key) ? 'dash-tree__c--state' : `dash-tree__c--${key.toLowerCase()}`;

const nodeKey = (node: FolderNode<Row> | DashboardNode<Row>): string =>
  node.kind === 'folder' ? `f:${node.path}` : `d:${node.id}`;


/** Badge of a custom dashboard that replaces a shipped one with the same id. */
export function OverrideBadge({ className = '' }: { className?: string }) {
  const { t } = useTranslation(['dashboard']);
  return (
    <span
      className={`dash-badge-override${className ? ` ${className}` : ''}`}
      title={t('dashboard:folderNav.overridesHint') as string}
    >
      {t('dashboard:folderNav.overridesBadge')}
    </span>
  );
}

/** Badge of a dashboard read from the old query folder (`sql-custom/`). */
export function LegacyBadge({ className = '' }: { className?: string }) {
  const { t } = useTranslation(['dashboard']);
  return (
    <span
      className={`dash-badge-legacy${className ? ` ${className}` : ''}`}
      title={t('dashboard:folderNav.legacyHint') as string}
    >
      {t('dashboard:folderNav.legacyBadge')}
    </span>
  );
}

export interface FolderTreeListProps {
  folders: FolderRow[];
  /** Dashboard rows to show: all rows, or the match set of a search / state filter. */
  rows: Row[];
  /** true when `rows` is a match set — folders without matches drop out, the rest opens. */
  filtered: boolean;
  /** '' = top level; otherwise the drill-down folder shown as the first row. */
  root: string;
  sort: TreeSortMode;
  /** Makes the column headers sort buttons; the caller keeps the mode (`?sort=`). */
  onSortChange?: (mode: TreeSortMode) => void;
  summary: DashboardSummary;
  /** Whether result chips are on: envelopes feed the state columns and auto-runs may fire. */
  resultChips: boolean;
  /**
   * Column preset (`dashboard` default, `test`): the columns after the name,
   * the sortable keys and the envelope kind the rows read.
   */
  preset?: ListPreset;
  /**
   * Whether result envelopes feed the columns read-only — without auto-runs
   * (the test status). Default: `resultChips`.
   */
  readResults?: boolean;
  /** Display label of a raw preset value (e.g. a test type). Default: the raw value. */
  columnLabel?: (column: ListColumnKey, raw: string) => string;
  /** Key of the folders' expansion state in sessionStorage (tab) and localStorage (browser seed). */
  expandedStorageKey?: string;
  /** Display title + description (tooltip) of a dashboard row. */
  describe: (row: Row) => { title: string; subtitle: string };
  onOpen: (row: Row) => void;
  onDrillDown: (path: string) => void;
  unitLabel: (envelope: ResultEnvelope) => string;
  /** Shown instead of an empty tree; null renders nothing (the caller reports it). */
  emptyMessage: string | null;
  /** Shown below the expanded, still empty "Custom" area folder. */
  customEmptyHint: ReactNode;
  /**
   * Flat mode (favorites view): `rows` become one level without folder rows,
   * each with its rubric path under the title and a remove star at the end;
   * Delete/Backspace on a row removes it too. No featured pinning.
   */
  flat?: boolean;
  /** Flat mode: removes a row (remove star, Delete/Backspace). */
  onRemove?: (row: Row) => void;
  /**
   * Tree mode: a favorite star per dashboard row in a last column that
   * toggles; folder rows leave the cell empty. (The flat mode always has the
   * column, its star removes via `onRemove`.)
   */
  favorites?: {
    /** Whether the row's dashboard can be favorited at all. */
    available: (row: Row) => boolean;
    isFavorite: (row: Row) => boolean;
    toggle: (row: Row) => void;
  };
  /**
   * Tree mode: element (in the caller's search bar) that receives the
   * "expand all | collapse all" buttons; null renders none.
   */
  bulkSlot?: HTMLElement | null;
}

/**
 * Hierarchical list of the dashboard overview (Finder-style treegrid): folder
 * rows fold open in place, a double click (or Enter) drills down via
 * `?folder=`, dashboard rows open on a single click. State columns and the
 * findings column read the same result envelopes as the folder tiles. The
 * flat mode renders the favorites with the same columns and keyboard model.
 */
export function FolderTreeList({
  folders, rows, filtered, root, sort, summary, resultChips,
  describe, onOpen, onDrillDown, unitLabel, emptyMessage, customEmptyHint,
  flat = false, onRemove, favorites, onSortChange, bulkSlot = null,
  preset = listPreset('dashboard'), readResults = resultChips, columnLabel = RAW_LABEL,
  expandedStorageKey = EXPANDED_STORAGE_KEY,
}: FolderTreeListProps) {
  const starColumn = flat || !!favorites;
  const resultKind = preset.resultKind;
  const { t, i18n } = useTranslation(['dashboard']);
  // Tab state, seeded from the list the user operated last (any tab); open
  // tabs are never synchronised.
  const [remembered, setRemembered] = useState<Record<string, boolean>>(() => {
    const { tab, browser } = browserStores();
    return loadExpanded(tab, browser, expandedStorageKey);
  });
  const saveRemembered = (state: Record<string, boolean>) => {
    const { tab, browser } = browserStores();
    saveExpanded(tab, browser, expandedStorageKey, state);
  };
  const [overrides, setOverrides] = useState<Set<string>>(() => new Set());
  const [focusKey, setFocusKey] = useState<string | null>(null);
  const rowRefs = useRef(new Map<string, HTMLDivElement>());
  // Set when a removed row hands the focus on to its neighbour.
  const refocusRef = useRef(false);

  // Momentary folds of forced-open rows belong to the view they were made in.
  useEffect(() => {
    setOverrides(new Set());
  }, [root, filtered]);

  // Entries of vanished folders go, so a folder re-created under the same path
  // starts closed. Only against the complete folder dataset — the favorites
  // view passes none, a failed load an empty one.
  useEffect(() => {
    if (flat || folders.length === 0) return;
    const known = new Set(folders.map(f => f.path));
    setRemembered(prev => {
      const next = pruneExpanded(prev, known);
      if (!next) return prev;
      saveRemembered(next);
      return next;
    });
    // saveRemembered only closes over expandedStorageKey (stable per page).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flat, folders]);

  const tree = useMemo(() => {
    const dashboards: TreeDashboard<Row>[] = rows.map(row => {
      const id = String(row.id ?? '');
      const envelope = readResults ? summary.envelopeFor(resultKind, id) : undefined;
      return {
        id,
        folder: row.folder == null ? null : String(row.folder),
        featured: row.featured === true,
        module: row.folder_label == null ? null : String(row.folder_label),
        result: envelope ? resultFacts(envelope) : null,
        values: rowValues(preset, row, columnLabel),
        row,
      };
    });
    if (flat) {
      // One level, input order = Name ↑; featured bundles sort like any other.
      return sortSiblings<Row>(
        dashboards.map((d): TreeNode<Row> => ({ kind: 'dashboard', id: d.id, dashboard: { ...d, featured: false } })),
        sort,
      );
    }
    return buildFolderTree(folders, dashboards, { root, filtered, sort });
    // summary.results is the store snapshot behind envelopeFor (a new map per merge).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flat, folders, rows, filtered, root, sort, readResults, resultKind, preset, columnLabel, summary.results]);

  const expansionCtx = useMemo(() => ({ root, filtered, remembered, overrides }), [root, filtered, remembered, overrides]);
  const visible = useMemo(
    () => flattenVisible(tree, path => isFolderExpanded(path, expansionCtx)),
    [tree, expansionCtx],
  );
  const bulk = useMemo(
    () => (flat ? { canExpand: false, canCollapse: false } : bulkExpansionAvailability(tree, expansionCtx)),
    [flat, tree, expansionCtx],
  );

  const focusIndex = Math.max(0, visible.findIndex(r => nodeKey(r.node) === focusKey));

  useEffect(() => {
    if (!refocusRef.current) return;
    refocusRef.current = false;
    if (focusKey) rowRefs.current.get(focusKey)?.focus();
  }, [visible, focusKey]);

  const moveFocus = (index: number) => {
    const target = visible[Math.min(Math.max(index, 0), visible.length - 1)];
    if (!target) return;
    const key = nodeKey(target.node);
    setFocusKey(key);
    rowRefs.current.get(key)?.focus();
  };

  const isRunningUnder = (folder: string | null): boolean => {
    if (!folder) return false;
    const segments = folder.split('/');
    for (let i = segments.length; i > 0; i -= 1) {
      if (summary.isFolderRunning(segments.slice(0, i).join('/'))) return true;
    }
    return false;
  };

  // Auto-run on expanding (O7): same bounded `missing` run as entering a folder.
  const autoRun = (path: string) => {
    if (!resultChips) return;
    const agg = aggregateFolder(summary.results, path);
    const pending = agg ? agg.total - agg.covered : 0;
    if (pending === 0 || pending > AUTO_RUN_MAX_PENDING || summary.isFolderRunning(path)) return;
    void summary.runFolder(path, 'missing');
  };

  const toggle = (path: string, expanded: boolean) => {
    if (isForcedOpen(path, { root, filtered })) {
      setOverrides(prev => {
        const next = new Set(prev);
        if (expanded) next.add(path);
        else next.delete(path);
        return next;
      });
    } else {
      setRemembered(prev => {
        const next = { ...prev };
        if (expanded) delete next[path];
        else next[path] = true;
        saveRemembered(next);
        return next;
      });
    }
    if (!expanded) autoRun(path);
  };

  // Expand all / collapse all: no auto-run — that stays with expanding one folder by hand.
  const applyBulk = (action: 'expand' | 'collapse') => {
    const next = applyBulkExpansion(tree, expansionCtx, action);
    setOverrides(next.overrides);
    if (!filtered) {
      setRemembered(next.remembered);
      saveRemembered(next.remembered);
    }
  };

  const onRowKeyDown = (e: KeyboardEvent<HTMLDivElement>, index: number) => {
    const { node, expanded, parentIndex } = visible[index];
    switch (e.key) {
      case 'ArrowDown': moveFocus(index + 1); break;
      case 'ArrowUp': moveFocus(index - 1); break;
      case 'Home': moveFocus(0); break;
      case 'End': moveFocus(visible.length - 1); break;
      case 'ArrowRight':
        if (node.kind !== 'folder') return;
        if (!expanded) toggle(node.path, false);
        else if (node.children.length > 0) moveFocus(index + 1);
        break;
      case 'ArrowLeft':
        if (node.kind === 'folder' && expanded) toggle(node.path, true);
        else if (parentIndex >= 0) moveFocus(parentIndex);
        break;
      case ' ':
        if (node.kind !== 'folder') return;
        toggle(node.path, expanded);
        break;
      case 'Enter':
        if (node.kind === 'dashboard') onOpen(node.dashboard.row);
        else if (node.path !== root) onDrillDown(node.path);
        break;
      case 'Delete':
      case 'Backspace': {
        if (!flat || !onRemove || node.kind !== 'dashboard') return;
        // The row disappears — the focus moves on to the next one (or the previous at the end).
        const neighbour = visible[index + 1] ?? visible[index - 1];
        if (neighbour) {
          setFocusKey(nodeKey(neighbour.node));
          refocusRef.current = true;
        }
        onRemove(node.dashboard.row);
        break;
      }
      default:
        return;
    }
    e.preventDefault();
  };

  const stateLabel = (s: ResultDisplayState) => t(`dashboard:folderNav.state.${s}`, { defaultValue: s }) as string;
  const formatNumber = (n: number) => formatKpiValue(n, 'number', i18n.language);
  const indent = (level: number) => ({ '--dash-tree-level': level - 1 }) as CSSProperties;
  const twisty = (expanded: boolean | null) => <DisclosureChevron open={expanded} />;
  const skeleton = <span className="dash-chip dash-chip--skeleton dash-tree__skeleton" />;

  const folderStateCell = (agg: FolderAggregate, s: ResultDisplayState): ReactNode => (
    <>
      {agg.counts[s] > 0 && <span className={`dash-chip dash-state-${s}`}>{agg.counts[s]}{STATE_TOKEN[s]}</span>}
      {s === 'error' && agg.counts.failed > 0 && (
        <span className="dash-chip dash-state-failed">{agg.counts.failed}{STATE_TOKEN.failed}</span>
      )}
    </>
  );

  /** Single token of a (worst) state; empty for none or pending (never computed). */
  const stateToken = (state: ResultDisplayState | null, error?: string | null): ReactNode =>
    state && state !== 'pending' && (
      <span className={`dash-state-${state}`} title={error ?? stateLabel(state)}>{STATE_TOKEN[state]}</span>
    );

  /** Folder cell of one preset column: subtree aggregate / sums. */
  const folderCell = (col: ListColumn, node: FolderNode<Row>, running: boolean): ReactNode => {
    const agg = node.aggregate;
    if (isStateColumn(col.key)) return folderStateCell(agg, col.key);
    switch (col.key) {
      case 'status':
        return agg.total > 0 && <AggregateTokens agg={agg} />;
      case 'findings':
        return running ? skeleton : agg.findings > 0 && (
          <span className="dash-tree__sum" title={t('dashboard:folderTree.findingsSum') as string}>
            {formatNumber(agg.findings)}
          </span>
        );
      case 'members':
        return node.sums.members !== undefined && (
          <span className="dash-tree__sum" title={t('dashboard:folderTree.membersSum') as string}>
            {formatNumber(node.sums.members)}
          </span>
        );
      case 'testStatus':
        return stateToken(agg.worst);
      default:
        return null;
    }
  };

  const renderFolder = (node: FolderNode<Row>, level: number, expanded: boolean, index: number) => {
    const { folder, aggregate: agg } = node;
    const key = nodeKey(node);
    const tooltip = [
      `${t('dashboard:folderTree.entries', { count: node.directCount })} · ${t(`dashboard:${preset.texts.total}`, { count: node.dashboardCount })}`,
      folder.description,
      node.path !== root ? t('dashboard:folderTree.doubleClickHint') : null,
    ].filter(Boolean).join('\n');
    const running = resultChips && isRunningUnder(node.path);
    const showHint = !filtered && expanded && node.children.length === 0 && isCustomAreaRoot(folder);
    return (
      <Fragment key={key}>
        <div
          ref={el => { if (el) rowRefs.current.set(key, el); else rowRefs.current.delete(key); }}
          role="row"
          aria-level={level}
          aria-expanded={expanded}
          tabIndex={index === focusIndex ? 0 : -1}
          className={`dash-tree__row dash-tree__row--folder${level === 1 ? ' dash-tree__row--top' : ''}`}
          onClick={() => toggle(node.path, expanded)}
          onDoubleClick={() => { if (node.path !== root) onDrillDown(node.path); }}
          onKeyDown={e => onRowKeyDown(e, index)}
          onFocus={() => setFocusKey(key)}
        >
          <span role="gridcell" className="dash-tree__name" style={indent(level)} title={tooltip}>
            {twisty(expanded)}
            <span className="dash-tree__icon"><FolderIcon size={14} /></span>
            <span className="dash-tree__label">{folder.label}</span>
            <span className="dash-tree__count">({filtered ? node.dashboardCount : node.directCount})</span>
            {agg.covered < agg.total && (
              <span className="dash-chip dash-chip--coverage" title={t('dashboard:folderNav.coverageHint') as string}>
                {agg.covered}/{agg.total}
              </span>
            )}
          </span>
          {preset.columns.map(col => (
            <span key={col.key} role="gridcell" className={`dash-tree__c ${columnClass(col.key)}`}>
              {folderCell(col, node, running)}
            </span>
          ))}
          {starColumn && <span role="gridcell" className="dash-tree__c dash-tree__c--star" />}
        </div>
        {showHint && (
          <div role="row" aria-level={level + 1} className="dash-tree__row dash-tree__row--hint">
            <span role="gridcell" className="dash-tree__name dash-tree__hint" style={indent(level + 1)}>
              {customEmptyHint}
            </span>
          </div>
        )}
      </Fragment>
    );
  };

  const renderDashboard = (node: DashboardNode<Row>, level: number, index: number) => {
    const { row } = node.dashboard;
    const key = nodeKey(node);
    const cell = describe(row);
    // Featured entry point (Healthchecks): a sum row over its badge roots.
    if (row.featured === true) {
      const agg = resultChips ? aggregateBadgeRoots(summary.results, row._badge_roots) : null;
      if (agg) return renderFeatured(node, level, index, agg);
    }
    const envelope = readResults ? summary.envelopeFor(resultKind, node.id) : undefined;
    const facts = node.dashboard.result;
    const values = node.dashboard.values;
    const running = !!envelope && resultChips && (summary.isRefRunning(resultKind, node.id)
      || (envelope.runStatus === 'pending' && isRunningUnder(node.dashboard.folder)));
    const tokenFor = (s: ResultDisplayState): ReactNode => {
      if (!facts) return null;
      if (s === 'error' && facts.state === 'failed') {
        return <span className="dash-state-failed" title={envelope?.error ?? stateLabel('failed')}>{STATE_TOKEN.failed}</span>;
      }
      return facts.state === s ? <span className={`dash-state-${s}`} title={stateLabel(s)}>{STATE_TOKEN[s]}</span> : null;
    };
    let findings: ReactNode = null;
    if (running) findings = skeleton;
    else if (envelope && facts?.state === 'pending') {
      findings = <span className="dash-tree__pending" title={stateLabel('pending')}>{STATE_TOKEN.pending}</span>;
    } else if (envelope && envelope.runStatus === 'ran' && envelope.value != null) {
      const meaning = envelope.meaning ? ` — ${envelope.meaning}` : '';
      findings = (
        <span className="dash-chip dash-chip--kpi dash-tree__value" title={`${unitLabel(envelope)}${meaning}`}>
          {typeof envelope.value === 'number' ? formatNumber(envelope.value) : String(envelope.value)}
        </span>
      );
    }
    const leafCell = (col: ListColumn): ReactNode => {
      if (isStateColumn(col.key)) return tokenFor(col.key);
      switch (col.key) {
        case 'status':
        case 'testStatus':
          return facts && stateToken(facts.state, envelope?.error);
        case 'findings':
          return findings;
        case 'testType':
          return values?.testType != null && <span className="dash-tree__text">{String(values.testType)}</span>;
        case 'members':
          return typeof values?.members === 'number' && formatNumber(values.members);
        default:
          return null;
      }
    };
    const rubric = flat && row.folder_label != null ? String(row.folder_label) : null;
    return (
      <div
        key={key}
        ref={el => { if (el) rowRefs.current.set(key, el); else rowRefs.current.delete(key); }}
        role="row"
        aria-level={level}
        tabIndex={index === focusIndex ? 0 : -1}
        className="dash-tree__row dash-tree__row--dashboard"
        onClick={() => onOpen(row)}
        onKeyDown={e => onRowKeyDown(e, index)}
        onFocus={() => setFocusKey(key)}
      >
        <span role="gridcell" className="dash-tree__name" style={indent(level)} title={cell.subtitle || undefined}>
          {!flat && twisty(null)}
          {flat ? (
            // No folder context in the flat list — the rubric path stands in.
            <span className="dash-tree__titlestack">
              <span className="dash-tree__label">{cell.title}</span>
              {rubric && <span className="dash-tree__rubric">{rubric}</span>}
            </span>
          ) : (
            <span className="dash-tree__label">{cell.title}</span>
          )}
          {row.overrides === true && <OverrideBadge />}
          {row.legacy === true && <LegacyBadge />}
        </span>
        {preset.columns.map(col => (
          <span key={col.key} role="gridcell" className={`dash-tree__c ${columnClass(col.key)}`}>{leafCell(col)}</span>
        ))}
        {starColumn && (
          <span role="gridcell" className="dash-tree__c dash-tree__c--star">
            {flat ? onRemove && (
              <FavoriteButton active onToggle={() => onRemove(row)} name={cell.title} tabIndex={-1} className="dash-favstar--row" />
            ) : favorites?.available(row) && (
              // The roving tabindex sits on the row — the star is reached by pointer.
              <FavoriteButton
                active={favorites.isFavorite(row)}
                onToggle={() => favorites.toggle(row)}
                name={cell.title}
                tabIndex={-1}
                className="dash-favstar--row"
              />
            )}
          </span>
        )}
      </div>
    );
  };

  /**
   * Featured row: pulse icon, accent surface and the aggregate of every rubric
   * it spans in the state and findings columns — the overall health above the
   * rubrics it sums up. Stays a treegrid row (keyboard, star, pinning).
   */
  const renderFeatured = (node: DashboardNode<Row>, level: number, index: number, agg: FolderAggregate) => {
    const { row } = node.dashboard;
    const key = nodeKey(node);
    const cell = describe(row);
    const running = String(row._badge_roots ?? '').split(',').some(r => isRunningUnder(r.trim() || null));
    const tooltip = [cell.subtitle, t('dashboard:folderTree.featuredHint')].filter(Boolean).join('\n');
    return (
      <div
        key={key}
        ref={el => { if (el) rowRefs.current.set(key, el); else rowRefs.current.delete(key); }}
        role="row"
        aria-level={level}
        tabIndex={index === focusIndex ? 0 : -1}
        className="dash-tree__row dash-tree__row--dashboard dash-tree__row--featured"
        onClick={() => onOpen(row)}
        onKeyDown={e => onRowKeyDown(e, index)}
        onFocus={() => setFocusKey(key)}
      >
        <span role="gridcell" className="dash-tree__name" style={indent(level)} title={tooltip}>
          <span className="dash-tree__icon dash-tree__icon--featured"><PulseIcon animated={agg.covered < agg.total} /></span>
          <span className="dash-tree__label">{cell.title}</span>
          <span className="dash-chip dash-tree__rulechip">{t('dashboard:featured.ruleCount', { count: agg.total })}</span>
          {agg.covered < agg.total && (
            <span className="dash-chip dash-chip--coverage" title={t('dashboard:folderNav.coverageHint') as string}>
              {agg.covered}/{agg.total}
            </span>
          )}
        </span>
        {preset.columns.map(col => (
          <span key={col.key} role="gridcell" className={`dash-tree__c ${columnClass(col.key)}`}>
            {isStateColumn(col.key)
              ? folderStateCell(agg, col.key)
              : col.key === 'status'
                ? stateToken(agg.worst)
                : col.key === 'findings'
                  ? running ? skeleton : agg.findings > 0 && (
                    <span className="dash-tree__sum" title={t('dashboard:folderTree.findingsSum') as string}>
                      {formatNumber(agg.findings)}
                    </span>
                  )
                  : null}
          </span>
        ))}
        {starColumn && (
          <span role="gridcell" className="dash-tree__c dash-tree__c--star">
            {flat ? onRemove && (
              <FavoriteButton active onToggle={() => onRemove(row)} name={cell.title} tabIndex={-1} className="dash-favstar--row" />
            ) : favorites?.available(row) && (
              <FavoriteButton
                active={favorites.isFavorite(row)}
                onToggle={() => favorites.toggle(row)}
                name={cell.title}
                tabIndex={-1}
                className="dash-favstar--row"
              />
            )}
          </span>
        )}
      </div>
    );
  };

  // Sortable column headers: buttons with an arrow on the active one.
  // Without result chips only the text columns sort.
  const sortableKey = (key: TreeSortKey) => !!onSortChange && isSortable(preset, key, readResults);
  const ariaSort = (keys: TreeSortKey[]): 'ascending' | 'descending' | 'none' =>
    keys.includes(sort.key) ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none';
  const sortButton = (key: TreeSortKey, label: string, content: ReactNode) => {
    if (!sortableKey(key)) return content;
    const active = sort.key === key;
    return (
      <button
        type="button"
        className={`dash-tree__sort${active ? ' dash-tree__sort--active' : ''}`}
        onClick={() => onSortChange?.(nextSort(sort, key))}
        title={t('dashboard:folderTree.sortBy', { column: label }) as string}
        aria-label={label}
      >
        {content}
        <span className="dash-tree__sortarrow" aria-hidden="true">{active ? (sort.dir === 'asc' ? '↑' : '↓') : ''}</span>
      </button>
    );
  };
  const colName = t('dashboard:folderTree.colName') as string;
  const colModule = t(`dashboard:${preset.texts.moduleHeader}`) as string;

  const headerCell = (col: ListColumn): ReactNode => {
    const className = `dash-tree__c ${columnClass(col.key)}`;
    const label = t(`dashboard:${col.headerKey}`, { defaultValue: col.key }) as string;
    if (isStateColumn(col.key)) {
      const s = col.key;
      return (
        <span
          key={s}
          role="columnheader"
          className={className}
          title={sortableKey(s) ? undefined : label}
          aria-label={sortableKey(s) ? undefined : label}
          aria-sort={ariaSort([s])}
        >
          {sortButton(s, label, <span className={`dash-state-${s}`} aria-hidden="true">{STATE_TOKEN[s]}</span>)}
        </span>
      );
    }
    if (col.key === 'findings') {
      return (
        <span
          key={col.key}
          role="columnheader"
          className={className}
          title={sortableKey('findings') ? undefined : t('dashboard:folderTree.colFindingsHint') as string}
          aria-label={sortableKey('findings') ? undefined : label}
          aria-sort={ariaSort(['findings'])}
        >
          {sortButton('findings', label, '#')}
        </span>
      );
    }
    return (
      <span key={col.key} role="columnheader" className={className} aria-sort={col.sortKey ? ariaSort([col.sortKey]) : undefined}>
        {col.sortKey ? sortButton(col.sortKey, label, label) : label}
      </span>
    );
  };

  const bulkButtons = bulkSlot && !flat ? createPortal(
    <BulkToggleGroup label={t('dashboard:folderTree.bulkLabel') as string}>
      <BulkToggleButton
        icon={<ExpandAllIcon />}
        label={t('dashboard:folderTree.expandAll') as string}
        disabled={!bulk.canExpand}
        onClick={() => applyBulk('expand')}
      />
      <BulkToggleButton
        icon={<CollapseAllIcon />}
        label={t('dashboard:folderTree.collapseAll') as string}
        disabled={!bulk.canCollapse}
        onClick={() => applyBulk('collapse')}
      />
    </BulkToggleGroup>,
    bulkSlot,
  ) : null;

  if (visible.length === 0) {
    return (
      <>
        {bulkButtons}
        {emptyMessage ? <div className="dash-tilegrid__empty">{emptyMessage}</div> : null}
      </>
    );
  }

  return (
    <>
    {bulkButtons}
    <div
      className={`dash-tree${starColumn ? ' dash-tree--starred' : ''}${preset.id !== 'dashboard' ? ` dash-tree--${preset.id}` : ''}`}
      role="treegrid"
      aria-label={t(flat ? 'dashboard:view.favorites' : `dashboard:${preset.texts.treeLabel}`) as string}
    >
      <div role="row" className="dash-tree__row dash-tree__row--head">
        <span role="columnheader" className="dash-tree__name" aria-sort={ariaSort(flat ? ['name', 'module'] : ['name'])}>
          {sortButton('name', colName, colName)}
          {flat && (
            <>
              <span className="dash-tree__sortsep" aria-hidden="true">|</span>
              {sortButton('module', colModule, colModule)}
            </>
          )}
        </span>
        {preset.columns.map(headerCell)}
        {starColumn && (
          <span
            role="columnheader"
            className="dash-tree__c dash-tree__c--star"
            title={t('dashboard:favorites.column') as string}
            aria-label={t('dashboard:favorites.column') as string}
          >
            <StarIcon size={12} />
          </span>
        )}
      </div>
      {visible.map((vr, index) =>
        vr.node.kind === 'folder'
          ? renderFolder(vr.node, vr.level, vr.expanded, index)
          : renderDashboard(vr.node, vr.level, index),
      )}
    </div>
    </>
  );
}
