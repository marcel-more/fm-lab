import { useState, useEffect, useRef, useCallback, useMemo, lazy, Suspense } from 'react';
import { Routes, Route, useNavigate, useSearchParams, useParams, Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { api } from './api/client';
import { OBJECT_TYPES } from '@packages/shared/constants';

// Four pseudo types displayed
// in the "Used tokens" optgroup of the type dropdown.
const PSEUDO_TYPE_GROUP = ['ScriptStepType', 'BuiltinFunction', 'PluginComponent', 'PluginFunction'] as const;
const PSEUDO_TYPE_SET = new Set<string>(PSEUDO_TYPE_GROUP);
import { useInfiniteSearch, useDebounce, useScrollRestore, CONNECTION_ERROR } from './hooks';
import { VirtualList, DetailView, SearchOptions, FolderTree, PseudoTokenView, StartHeader, SubNav, StatusBar, Filterbar, AppFooter, type FolderTreeSubtype } from './components';
import { buildObjectPath, buildBreadcrumb } from './lib/navigation';
import { SettingsView } from './views/SettingsView';
import { RelationshipGraphView } from './views/RelationshipGraphView';
import { LayoutView } from './views/LayoutView';
import { DashboardHost } from './dashboard/DashboardHost';
import { DashboardView } from './dashboard/DashboardView';
import { QueryView } from './dashboard/QueryView';
import {
  DashboardsPage,
  CustomQueriesPage,
  TestsOverviewPage,
  TestDetailPage,
  DocsOverviewPage,
  XmlImportPage,
  DocsSetPage,
  DocsCategoryPage,
  FileDetailPage,
} from './dashboard/LeitPages';
import { DocsEntryView } from './docs/DocsEntryView';

// Code-split the Graph Explorer (cytoscape + fcose layout) out of the main
// bundle — it is only reached via the /graph route.
const GraphExplorerView = lazy(() =>
  import('./views/GraphExplorerView').then((m) => ({ default: m.GraphExplorerView })),
);

// Graph-Atlas (Top-Down-Einstieg) — eigener Chunk, zieht die visx-Treemap nur
// auf der /atlas-Route herein (wie Cytoscape auf /graph).
const GraphAtlasView = lazy(() =>
  import('./views/GraphAtlasView').then((m) => ({ default: m.GraphAtlasView })),
);

// Cluster-Übersicht (/cluster) — eigener Chunk (lazy, wie Atlas).
const ClusterView = lazy(() =>
  import('./views/ClusterView').then((m) => ({ default: m.ClusterView })),
);

// fm-spec Schema-Viewer (/fm-spec) — eigener Chunk (lazy).
const FmSpecView = lazy(() =>
  import('./views/FmSpecView').then((m) => ({ default: m.FmSpecView })),
);
const FmSpecStepView = lazy(() =>
  import('./views/FmSpecStepView').then((m) => ({ default: m.FmSpecStepView })),
);
const FmSpecFunctionView = lazy(() =>
  import('./views/FmSpecFunctionView').then((m) => ({ default: m.FmSpecFunctionView })),
);
const FmSpecTriggerView = lazy(() =>
  import('./views/FmSpecTriggerView').then((m) => ({ default: m.FmSpecTriggerView })),
);

/**
 * Wrapper, der DocsEntryView per `key` an die Route-Params bindet. Damit
 * unmountet React den Inhalt beim Wechsel zwischen zwei Doc-Pages und der
 * komplette State (entry, loading, scroll) wird von vorne aufgebaut —
 * verhindert "alter Titel sichtbar, neuer Content lädt"-Race-Conditions.
 */
function DocsEntryRoute() {
  const { set, category, fn } = useParams();
  return <DocsEntryView key={`${set}/${category}/${fn}`} />;
}
import type { SortOption, GroupOption, VirtualListRow, FMObject } from './types';
import './App.css';

type FileInfo = {
  File_Name?: string;
  File_FullName?: string;
  FileMaker_Version?: string;
  Has_DDR_INFO?: boolean;
  Import_Timestamp?: string;
};

type ViewMode = 'search' | 'tree';

const TREE_SUBTYPE_URL: Record<FolderTreeSubtype, string> = {
  ScriptCatalog: 'script',
  Layouts: 'layout',
  CustomFunctionsCatalog: 'customfunction',
};

function urlToSubtype(value: string | null): FolderTreeSubtype {
  switch (value) {
    case 'layout':         return 'Layouts';
    case 'customfunction': return 'CustomFunctionsCatalog';
    default:               return 'ScriptCatalog';
  }
}

function SearchView() {
  const navigate = useNavigate();
  const { t, i18n } = useTranslation(['common', 'nav', 'errors', 'types']);
  const [searchParams, setSearchParams] = useSearchParams();
  const { saveScrollPosition, restoreScrollPosition } = useScrollRestore();
  const scrollContainerRef = useRef<HTMLDivElement>(null);

  // Initialize filter states from URL params (for deep linking & back-navigation)
  const [mode, setMode] = useState<ViewMode>(searchParams.get('mode') === 'tree' ? 'tree' : 'search');
  const [searchName, setSearchName] = useState(searchParams.get('q') || '');
  const [selectedFile, setSelectedFile] = useState<string>(searchParams.get('file') || '');
  const [objectType, setObjectType] = useState<string>(searchParams.get('type') || '');
  const [treeSubtype, setTreeSubtype] = useState<FolderTreeSubtype>(urlToSubtype(searchParams.get('subtype')));
  const [files, setFiles] = useState<FileInfo[]>([]);
  const [sortBy, setSortBy] = useState<SortOption>((searchParams.get('sort') as SortOption) || 'standard');
  const [groupBy, setGroupBy] = useState<GroupOption>((searchParams.get('group') as GroupOption) || 'none');
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());

  // Ref to track if search input should maintain focus
  const searchInputRef = useRef<HTMLInputElement>(null);
  const wasFocusedRef = useRef(false);

  // Debounce search/filter input (300ms delay)
  const debouncedSearchName = useDebounce(searchName, 300);

  // Use infinite search hook (only relevant in 'search' mode, but called unconditionally
  // to keep hook order stable; the result is simply ignored when mode === 'tree').
  const { items, loading, loadingMore, hasMore, totalCount, error, loadMore } = useInfiniteSearch({
    searchName: debouncedSearchName || '*',
    selectedFile,
    objectType,
  });

  // Zwei-Wege-Sync zwischen URL und Filter-State. Die Implementierung muss zwei
  // Falle vermeiden:
  //   1) Beim Mount oder externen navigate() sollen URL→State greifen, nicht
  //      State→URL die URL mit altem State überschreiben.
  //   2) Wenn der User in den Inputs tippt, soll State→URL die URL aktualisieren,
  //      ohne dass URL→State daraufhin den gerade gesetzten State zurücksetzt.
  // Lösung: ein Ref, das markiert, dass der letzte State-Change *aus der URL*
  // stammt — in diesem Fall überspringt State→URL einen Tick.
  const internalSyncRef = useRef(false);
  // Tracks the last label URL→State has seen. Allows detecting when a
  // ?label=... param arrives externally (dashboard click) so State→URL
  // doesn't immediately strip it on mount.
  const prevLabelRef = useRef('');
  const searchParamsString = searchParams.toString();

  // URL → State
  useEffect(() => {
    const qName = searchParams.get('q') || '';
    const qFile = searchParams.get('file') || '';
    const qType = searchParams.get('type') || '';
    const qMode: ViewMode = searchParams.get('mode') === 'tree' ? 'tree' : 'search';
    const qLabel = searchParams.get('label') || '';
    const changed =
      qName !== searchName ||
      qFile !== selectedFile ||
      qType !== objectType ||
      qMode !== mode ||
      qLabel !== prevLabelRef.current;
    if (changed) {
      prevLabelRef.current = qLabel;
      internalSyncRef.current = true;
      if (qName !== searchName) setSearchName(qName);
      if (qFile !== selectedFile) setSelectedFile(qFile);
      if (qType !== objectType) setObjectType(qType);
      if (qMode !== mode) setMode(qMode);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParamsString]);

  // State → URL
  useEffect(() => {
    if (internalSyncRef.current) {
      // Dieser State-Change kommt gerade aus der URL — nicht zurückschreiben.
      internalSyncRef.current = false;
      return;
    }
    const params = new URLSearchParams();
    if (mode === 'tree') {
      params.set('mode', 'tree');
      params.set('subtype', TREE_SUBTYPE_URL[treeSubtype]);
      if (selectedFile) params.set('file', selectedFile);
      if (debouncedSearchName) params.set('q', debouncedSearchName);
    } else {
      if (debouncedSearchName) params.set('q', debouncedSearchName);
      if (selectedFile) params.set('file', selectedFile);
      if (objectType) params.set('type', objectType);
      if (sortBy !== 'standard') params.set('sort', sortBy);
      if (groupBy !== 'none') params.set('group', groupBy);
      // Externe Deep-Link-Params (kommen aus Dashboard-Action-URLs, z.B. von
      // den Counter-Pills im docset_home) durchreichen, damit der State→URL-
      // Effekt sie nicht beim ersten Tick wieder strippt. PseudoTokenView /
      // andere Konsumenten lesen sie direkt aus der URL.
      const pseudoCategory = searchParams.get('category');
      if (pseudoCategory) params.set('category', pseudoCategory);
    }
    const nextString = params.toString();
    // ?label=... ist ein externer Dekorations-Param (kommt aus Dashboard-Navigation),
    // der nicht von diesem Effekt verwaltet wird. Beim Vergleich ignorieren, damit
    // State→URL den Label-Param nicht beim nächsten Mount-Tick strippt.
    const currentWithoutLabel = new URLSearchParams(searchParamsString);
    currentWithoutLabel.delete('label');
    if (nextString !== currentWithoutLabel.toString()) {
      setSearchParams(params, { replace: true });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, treeSubtype, debouncedSearchName, selectedFile, objectType, sortBy, groupBy]);

  // Load available files on mount
  useEffect(() => {
    async function loadFiles() {
      try {
        const response = await api.info();
        if (response.success && response.data?.solution?.files) {
          setFiles(response.data.solution.files);
        }
      } catch (err) {
        console.error(t('errors:loadFiles'), err);
      }
    }
    loadFiles();
  }, [t]);

  // Restore focus to search input after loading states change
  useEffect(() => {
    if (wasFocusedRef.current && searchInputRef.current && !loading) {
      searchInputRef.current.focus();
    }
  }, [loading]);

  // Restore scroll position when items are loaded (after back-navigation)
  const hasRestoredRef = useRef(false);
  useEffect(() => {
    if (mode === 'search' && items.length > 0 && !hasRestoredRef.current) {
      hasRestoredRef.current = true;
      restoreScrollPosition('search-list', scrollContainerRef.current);
    }
  }, [mode, items.length, restoreScrollPosition]);

  // Reset restore flag when search params change
  useEffect(() => {
    hasRestoredRef.current = false;
  }, [debouncedSearchName, selectedFile, objectType, mode, treeSubtype]);

  // Reset expanded groups when grouping changes (all collapsed by default)
  useEffect(() => {
    setExpandedGroups(new Set());
  }, [groupBy]);

  // Sort and group items for the virtual list
  const lang = i18n.language;
  const unknownLabel = t('common:unknown');
  const processedRows: VirtualListRow[] = useMemo(() => {
    let sorted: FMObject[];
    if (sortBy === 'standard') {
      sorted = items;
    } else {
      sorted = [...items].sort((a, b) => {
        switch (sortBy) {
          case 'name':
            return (a.Object_Name || '').localeCompare(b.Object_Name || '', lang);
          case 'type':
            return (a.Object_Type || '').localeCompare(b.Object_Type || '', lang)
              || (a.Object_Name || '').localeCompare(b.Object_Name || '', lang);
          case 'file':
            return (a.File_Name || '').localeCompare(b.File_Name || '', lang)
              || (a.Object_Name || '').localeCompare(b.Object_Name || '', lang);
          default:
            return 0;
        }
      });
    }

    if (groupBy === 'none') {
      return sorted.map(obj => ({ _type: 'item' as const, object: obj }));
    }

    const groups = new Map<string, FMObject[]>();
    for (const obj of sorted) {
      const key = groupBy === 'type'
        ? (obj.Object_Type || unknownLabel)
        : (obj.File_Name || unknownLabel);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key)!.push(obj);
    }

    const sortedKeys = [...groups.keys()].sort((a, b) => a.localeCompare(b, lang));

    const rows: VirtualListRow[] = [];
    for (const key of sortedKeys) {
      const groupItems = groups.get(key)!;
      const isExpanded = expandedGroups.has(key);
      rows.push({ _type: 'header', groupKey: key, groupLabel: key, itemCount: groupItems.length, isExpanded });
      if (isExpanded) {
        for (const obj of groupItems) {
          rows.push({ _type: 'item', object: obj });
        }
      }
    }
    return rows;
  }, [items, sortBy, groupBy, expandedGroups, lang, unknownLabel]);

  // Scroll-Reset bei Filter-/Sort-/Group-Wechsel. Sonst bleibt nach einem weit
  // gescrollten Ergebnis die alte Scroll-Position stehen, während die neue
  // (oft viel kleinere) Trefferliste oben rendert — das Fenster wirkt leer.
  // Guard: wenn bereits oben, nichts tun (kein erzwungenes Scroll-Event,
  // kein Konflikt mit useScrollRestore beim Back-Navigieren).
  useEffect(() => {
    const el = scrollContainerRef.current;
    if (el && el.scrollTop > 0) {
      el.scrollTop = 0;
    }
  }, [sortBy, groupBy, debouncedSearchName, selectedFile, objectType]);

  const handleToggleGroup = useCallback((groupKey: string) => {
    setExpandedGroups(prev => {
      const next = new Set(prev);
      if (next.has(groupKey)) {
        next.delete(groupKey);
      } else {
        next.add(groupKey);
      }
      return next;
    });
  }, []);

  const handleItemClick = useCallback((uuid: string, file?: string | null) => {
    saveScrollPosition('search-list', scrollContainerRef.current);
    // Klon-Disambiguierung: die Zieldatei des angeklickten Objekts wandert als
    // `?file=` mit (Graceful Downgrade, wenn nicht gesetzt).
    navigate(buildObjectPath(uuid, null, file ?? null));
  }, [navigate, saveScrollPosition]);

  // Pseudo-Token-Drilldown: PluginComponent → PluginFunction (Hierarchie
  // aus PSEUDO_TYPE_DRILLDOWN in shared/constants). Statt zur DetailView
  // navigieren wir auf die Filteransicht des Kind-Typs mit dem Container-
  // Namen als Category-Filter — File-/Sort-Kontext bleibt erhalten.
  const handlePseudoDrilldown = useCallback((d: { type: string; via: 'category'; value: string }) => {
    const params = new URLSearchParams();
    params.set('type', d.type);
    params.set(d.via, d.value);
    if (selectedFile) params.set('file', selectedFile);
    const currentSort = searchParams.get('sort');
    if (currentSort) params.set('sort', currentSort);
    setSearchParams(params, { replace: false });
  }, [selectedFile, searchParams, setSearchParams]);

  const isTreeMode = mode === 'tree';
  const filterLabel = isTreeMode ? t('nav:form.filterLabel') : t('nav:form.searchLabel');
  const filterPlaceholder = isTreeMode
    ? t('nav:form.filterPlaceholder')
    : t('nav:form.searchPlaceholder');
  const filterTitle = isTreeMode
    ? t('nav:form.filterTitle')
    : t('nav:form.searchTitle');

  // Klasse S (Start) ⇄ Klasse L (Listing).
  // S = Such-Modus ohne jeden aktiven Filter (Home-Dashboard sichtbar); jeder
  // Filter oder der Tree-Modus schaltet auf L (Sub-Navi + kompakte Filterbar).
  const isStart = !isTreeMode && !debouncedSearchName && !selectedFile && !objectType;

  // Filter-Controls — einmal definiert, in beiden Zuständen verwendet (Start:
  // unter dem StartHeader; Listing: in der Filterbar der StatusBar).
  const filterControls = (
    <>
      <div className="form-group">
        <label htmlFor="search-name">{filterLabel}</label>
        <input
          ref={searchInputRef}
          id="search-name"
          type="text"
          value={searchName}
          onChange={(e) => setSearchName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              setSearchName('');
              e.currentTarget.blur();
            }
          }}
          onFocus={() => { wasFocusedRef.current = true; }}
          onBlur={() => { wasFocusedRef.current = false; }}
          placeholder={filterPlaceholder}
          title={filterTitle}
        />
      </div>

      <div className="form-group">
        <label htmlFor="file-name">{t('nav:form.fileLabel')}</label>
        <select
          id="file-name"
          value={selectedFile}
          onChange={(e) => setSelectedFile(e.target.value)}
        >
          <option value="">{t('nav:form.allFiles')}</option>
          {files.map((file) => (
            <option key={file.File_Name || ''} value={file.File_Name || ''}>
              {file.File_Name}
            </option>
          ))}
        </select>
      </div>

      {isTreeMode ? (
        <div className="form-group">
          <label htmlFor="tree-subtype">{t('nav:form.typeLabel')}</label>
          <select
            id="tree-subtype"
            value={treeSubtype}
            onChange={(e) => setTreeSubtype(e.target.value as FolderTreeSubtype)}
          >
            {(['ScriptCatalog', 'Layouts', 'CustomFunctionsCatalog'] as FolderTreeSubtype[]).map(st => (
              <option key={st} value={st}>{t(`nav:treeSubtypes.${st}`)}</option>
            ))}
          </select>
        </div>
      ) : (
        <div className="form-group">
          <label htmlFor="object-type">{t('nav:form.objectTypeLabel')}</label>
          <select
            id="object-type"
            value={objectType}
            onChange={(e) => setObjectType(e.target.value)}
          >
            <option value="">{t('nav:form.allTypes')}</option>
            {OBJECT_TYPES.filter(type => !PSEUDO_TYPE_SET.has(type)).map((type) => (
              <option key={type} value={type}>
                {t(`types:objectTypes.${type}`, { defaultValue: type })}
              </option>
            ))}
            <optgroup label={t('nav:form.usedTokensGroup') as string}>
              {PSEUDO_TYPE_GROUP.map((type) => (
                <option key={type} value={type}>
                  {t(`types:objectTypes.${type}`, { defaultValue: type })}
                </option>
              ))}
            </optgroup>
          </select>
        </div>
      )}

      {!isTreeMode && (
        <button
          className="search-options-toggle"
          onClick={() => setOptionsOpen(prev => !prev)}
          aria-expanded={optionsOpen}
          type="button"
        >
          {optionsOpen ? t('nav:form.optionsOpen') : t('nav:form.optionsClosed')}
        </button>
      )}
    </>
  );

  const optionsPanel = !isTreeMode && optionsOpen ? (
    <SearchOptions
      sortBy={sortBy}
      groupBy={groupBy}
      onSortChange={setSortBy}
      onGroupChange={setGroupBy}
    />
  ) : null;

  return (
    <div className="app">
      {isStart ? (
        <>
          <StartHeader mode={mode} onSelectMode={setMode} />
          <div className="search-form">
            <div className="form-row">{filterControls}</div>
            {optionsPanel}
          </div>
        </>
      ) : (
        <>
          <SubNav breadcrumbs={buildBreadcrumb(isTreeMode ? { kind: 'hierarchy' } : { kind: 'search' }, t)} />
          <StatusBar>
            <Filterbar>
              {filterControls}
              {optionsPanel && <div className="filterbar__options">{optionsPanel}</div>}
            </Filterbar>
          </StatusBar>
        </>
      )}

      {/* Context-Label — gesetzt wenn via Dashboard-Action mit ?label=... navigiert */}
      {!isTreeMode && (debouncedSearchName || selectedFile || objectType) && searchParams.get('label') && (
        <div className="search-context-label">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <polyline points="9 18 15 12 9 6"/>
          </svg>
          {searchParams.get('label')}
        </div>
      )}

      {/* Error message (search mode only) */}
      {!isTreeMode && error && objectType !== 'RelationshipGraph' && (
        <div className={error === CONNECTION_ERROR ? 'error-message error-message--connection' : 'error-message'}>
          {error === CONNECTION_ERROR ? t('errors:noConnection') : error}
        </div>
      )}

      {/* RelationshipGraph: direct-entry card — no list, just a deep link */}
      {!isTreeMode && objectType === 'RelationshipGraph' && (
        <div className="relationship-graph-entry">
          {selectedFile ? (
            <Link
              to={`/relationship-graph/${encodeURIComponent(selectedFile)}`}
              className="relationship-graph-entry-card"
            >
              <span className="relationship-graph-entry-title">
                {t('nav:relationshipGraph.openCardTitle')}
              </span>
              <span className="relationship-graph-entry-file">{selectedFile}</span>
              <span className="relationship-graph-entry-hint">→</span>
            </Link>
          ) : (
            <div className="relationship-graph-entry-empty">
              {t('nav:relationshipGraph.selectFilePrompt')}
            </div>
          )}
        </div>
      )}

      {/* Search mode: Pseudo-Token-Typen — eigene aggregierte Ansicht */}
      {!isTreeMode && PSEUDO_TYPE_SET.has(objectType) && (
        <PseudoTokenView
          objectType={objectType}
          file={selectedFile || undefined}
          onItemClick={handleItemClick}
          onDrilldown={handlePseudoDrilldown}
          initialCategory={searchParams.get('category') || undefined}
          initialSort={(searchParams.get('sort') as 'usage' | 'name' | 'category') || undefined}
        />
      )}

      {/* Search mode: Default-Dashboard — sichtbar wenn KEINE Filter aktiv */}
      {!isTreeMode && !debouncedSearchName && !selectedFile && !objectType && (
        <DashboardHost id="home" />
      )}

      {/* Search mode: Virtual list — nur wenn Filter aktiv und kein Spezial-Typ */}
      {/*
        key bindet das Komponenten-Lifecycle an die aktiven Filter. Beim Wechsel
        eines Filter-Werts (File, Type, Suchbegriff) unmountet React die alte
        VirtualList vollständig und mountet eine frische — inklusive Virtualizer-
        Range/Measurement-State. Verhindert Restbilder ("Fragmente") wenn die
        neue Trefferliste deutlich kürzer ist als die alte.
      */}
      {!isTreeMode && (debouncedSearchName || selectedFile || objectType) && !error && objectType !== 'RelationshipGraph' && !PSEUDO_TYPE_SET.has(objectType) && (
        <VirtualList
          key={`${selectedFile}::${objectType}::${debouncedSearchName}`}
          rows={processedRows}
          itemCount={items.length}
          isLoading={loading || loadingMore}
          hasMore={hasMore}
          onLoadMore={loadMore}
          totalCount={totalCount}
          onItemClick={handleItemClick}
          onToggleGroup={handleToggleGroup}
          scrollContainerRef={scrollContainerRef}
          searchTerm={debouncedSearchName}
        />
      )}

      {/* Search mode: initial loading state (pseudo types have their own loader) */}
      {!isTreeMode && (debouncedSearchName || selectedFile || objectType) && objectType !== 'RelationshipGraph' && !PSEUDO_TYPE_SET.has(objectType) && loading && items.length === 0 && (
        <div className="virtual-list-empty">
          {t('nav:list.loading')}
        </div>
      )}

      {/* Tree mode: Folder tree */}
      {isTreeMode && (
        <FolderTree
          subtype={treeSubtype}
          file={selectedFile || undefined}
          filter={debouncedSearchName}
        />
      )}

      {/* Discreet brand/license footer — start page only (Klasse S). */}
      {isStart && <AppFooter />}
    </div>
  );
}

function App() {
  return (
    <Routes>
      <Route path="/" element={<SearchView />} />
      <Route path="/object/:uuid" element={<DetailView />} />
      <Route path="/settings" element={<SettingsView />} />
      <Route path="/relationship-graph/:fileName" element={<RelationshipGraphView />} />
      <Route path="/relationship-graph" element={<RelationshipGraphView />} />
      <Route
        path="/graph"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <GraphExplorerView />
          </Suspense>
        }
      />
      <Route
        path="/atlas"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <GraphAtlasView />
          </Suspense>
        }
      />
      <Route
        path="/cluster"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <ClusterView />
          </Suspense>
        }
      />
      <Route
        path="/fm-spec"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <FmSpecView />
          </Suspense>
        }
      />
      <Route
        path="/fm-spec/step/:stepId"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <FmSpecStepView />
          </Suspense>
        }
      />
      <Route
        path="/fm-spec/function/:functionId"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <FmSpecFunctionView />
          </Suspense>
        }
      />
      <Route
        path="/fm-spec/trigger/:triggerId"
        element={
          <Suspense fallback={<div className="graph-explorer-placeholder">…</div>}>
            <FmSpecTriggerView />
          </Suspense>
        }
      />
      <Route path="/layout/:uuid" element={<LayoutView />} />
      <Route path="/file/:filename" element={<FileDetailPage />} />
      {/* Leitseiten (bare routes) — vor den :param-Routen */}
      <Route path="/dashboard" element={<DashboardsPage />} />
      <Route path="/dashboard/:id" element={<DashboardView />} />
      <Route path="/query" element={<CustomQueriesPage />} />
      <Route path="/tests" element={<TestsOverviewPage />} />
      <Route path="/tests/:id" element={<TestDetailPage />} />
      <Route path="/query/:queryName" element={<QueryView />} />
      <Route path="/xml-import" element={<XmlImportPage />} />
      <Route path="/docs" element={<DocsOverviewPage />} />
      <Route path="/docs/:set" element={<DocsSetPage />} />
      <Route path="/docs/:set/:category" element={<DocsCategoryPage />} />
      <Route path="/docs/:set/:category/:fn" element={<DocsEntryRoute />} />
    </Routes>
  );
}

export default App;
