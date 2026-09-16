import React, { useMemo, useRef, useCallback, useState, useEffect, useSyncExternalStore } from 'react';
import { useParams, useNavigate, useLocation, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetail } from '../hooks/useObjectDetail';
import { useRefOrigin } from '../hooks/useRefOrigin';
import { useRefContext } from '../hooks/useRefContext';
import { ObjectHeader } from './ObjectHeader';
import { PluginPlatformBadge } from './PluginPlatformBadge';
import { ScriptOsBadge } from './ScriptOsBadge';
import { HierarchyTree, type HierarchyTreeHandle } from './HierarchyTree';
import { TypeDetail } from './TypeDetail';
import { ObjectGraphPanel, type ObjectGraphPanelHandle } from './ObjectGraphPanel';
import type { LayoutCanvasHandle } from './LayoutCanvas';
import { SubNav } from './SubNav';
import { TestsPanel } from './TestsPanel';
import { StatusBar } from './StatusBar';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import { RefOriginPill } from './RefOriginPill';
import { VarSelectionPill } from './VarSelectionPill';
import { AmbiguousFilePicker } from './AmbiguousFilePicker';
import { VarSelectionContext, parseVarParam, type VarSelection } from '../script/varSelectionContext';
import { Slot } from '../plugins';
import { useEscapeStack } from '../hooks/useEscapeStack';
import { useUrlState } from '../hooks/useUrlState';
import { buildBreadcrumb, buildObjectPath } from '../lib/navigation';
import { CurrentFileContext } from '../lib/currentFileContext';
import { getObjectBadge, subscribeTestsStore } from '../lib/testsStore';
import type { DetailViewTab } from '../types';
import { DETAIL_TABS } from '../types';
import '../DetailView.css';

function displayObjectType(objectType: string, sourceTable?: string | null): string {
  if (objectType !== 'Folder') return objectType;
  switch (sourceTable) {
    case 'ScriptCatalog':          return 'ScriptFolder';
    case 'Layouts':                return 'LayoutFolder';
    case 'CustomFunctionsCatalog': return 'CustomFunctionFolder';
    default:                       return 'Folder';
  }
}

/**
 * Detail View Component
 * Displays full object details with sub-navigation tabs:
 * Details | Referenzen | Graph | Versions | Notes
 */
export const DetailView: React.FC = () => {
  const { t } = useTranslation(['nav', 'errors']);
  const { uuid } = useParams<{ uuid: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  // Klon-Disambiguierung: `?file=` ist der zweite Identitäts-Begleiter neben der
  // UUID (siehe lib/navigation.ts). Fehlt er, gilt Graceful Downgrade.
  const [fileParam] = useUrlState<string>('file', '');
  // `ref` (Cross-Reference-Origin) muss vor useObjectDetail gelesen werden, weil
  // er als `origin` die operationalen Referenzen eines Pseudo-Aggregats
  // (ScriptStepType) anreichert (Origin_Hit-Markierung der Zielfelder).
  const [refParam] = useUrlState<string>('ref', '');
  const { object, references, loading, error, ambiguousFiles, retry } = useObjectDetail(uuid, fileParam || null, refParam || null);
  const hierarchyRef = useRef<HierarchyTreeHandle>(null);
  const graphPanelRef = useRef<ObjectGraphPanelHandle>(null);
  // Detail-Tab eines Layouts: eingebetteter LayoutCanvas. Der Handle wird in den
  // ESC-Stack unten verdrahtet, sodass ESC im Layout-Suchfeld zuerst Suche/Filter
  // räumt (analog zur Vollbild-LayoutView), statt direkt zurückzunavigieren.
  const layoutCanvasRef = useRef<LayoutCanvasHandle>(null);

  // URL ist Single Source of Truth für Tab — beim Wechsel wird die URL
  // aktualisiert (replace), sodass beim Zurück-Navigieren der Tab erhalten
  // bleibt. Default 'detail' wird NICHT in die URL geschrieben (saubere URL).
  const validTabIds = useMemo(
    () => new Set(DETAIL_TABS.filter(t => t.enabled).map(t => t.id)),
    [],
  );
  const [tabParam, setTabParam] = useUrlState<string>('tab', 'detail');
  const activeTab: DetailViewTab = (validTabIds.has(tabParam as DetailViewTab) ? tabParam : 'detail') as DetailViewTab;
  const setActiveTab = useCallback((tab: DetailViewTab) => {
    setTabParam(tab);
  }, [setTabParam]);

  // Cross-Reference Highlight.
  // `ref` lebt nur in der URL (oben gelesen); useRefOrigin holt das Origin + alle
  // Back-Reference-UUIDs im Destination-Container vom Backend und cached pro
  // (dst, ref)-Paar.
  // destFile skopiert die Destination-Seite (das aktuell geöffnete, klon-
  // aufgelöste Objekt) im Back-Refs-Lookup; der Origin (ref) bleibt downgrade.
  const refOrigin = useRefOrigin(uuid, refParam || null, fileParam || null);

  // `?marks=` — literale Objekt-UUIDs im Destination-Container, OHNE
  // Back-References-Auflösung direkt ins Highlight-Set (Mehrfach-Hervorhebung,
  // z. B. alle Findings einer Regel aus dem Tests-Tab). Kombinierbar mit `ref`:
  // beide Mengen werden vereinigt.
  const [marksParam] = useUrlState<string>('marks', '');
  const highlightUuids = useMemo(() => {
    if (!marksParam) return refOrigin.matchUuids;
    const merged = new Set(refOrigin.matchUuids);
    for (const part of marksParam.split(',')) {
      const v = part.trim();
      if (v) merged.add(v);
    }
    return merged;
  }, [refOrigin.matchUuids, marksParam]);

  // Findings-Kontext des auslösenden Klicks: `?ref_src=` (Dashboard-ID) +
  // `?ref_msgid=` (Message-Token) + `?ref_arg_<name>=` (Interpolation). Die
  // lokalisierte Message kommt server-seitig aus dem Dashboard-Manifest
  // (useRefContext); die Pill rendert sie als abgesetzte Quelle-Zeile.
  const [refSrcParam] = useUrlState<string>('ref_src', '');
  const [refMsgIdParam] = useUrlState<string>('ref_msgid', '');
  const [searchParams, setSearchParams] = useSearchParams();
  const refArgs = useMemo(() => {
    const args: Record<string, string> = {};
    for (const [k, v] of searchParams.entries()) {
      if (k.startsWith('ref_arg_')) args[k.slice('ref_arg_'.length)] = v;
    }
    return args;
  }, [searchParams]);
  const refContext = useRefContext(refSrcParam || null, refMsgIdParam || null, refArgs);

  // Dismiss räumt Ref UND Kontext-Params atomar in EINEM setSearchParams-Call
  // — separate useUrlState-Setter würden sich gegenseitig überschreiben
  // (gleiche Race wie in useLayoutSearch.runUserUpdate dokumentiert).
  const dismissRefOrigin = useCallback(() => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      next.delete('ref');
      next.delete('ref_src');
      next.delete('ref_msgid');
      next.delete('marks');
      for (const k of Array.from(next.keys())) {
        if (k.startsWith('ref_arg_')) next.delete(k);
      }
      return next;
    }, { replace: true });
  }, [setSearchParams]);

  // Live-Match-Count aus Token-Container-Viewern (Script / CustomFunction /
  // Field). back_references zählt für diese Container nur 1 Self-Link, daher
  // korrigiert der Viewer die Anzeige der RefOriginPill mit der echten Anzahl
  // hervorgehobener Token-Vorkommen. Reset beim Wechsel von uuid oder ref-Param.
  const [liveMatchCount, setLiveMatchCount] = useState<number | undefined>(undefined);
  useEffect(() => { setLiveMatchCount(undefined); }, [uuid, refParam]);

  // Variablen-Auswahl: `?var=<scope>:<name>` ist die
  // Single Source of Truth; Klicks auf Variable-Tokens toggeln den Param rein
  // client-seitig (replace, kein Server-Roundtrip). Der Kontext versorgt die
  // Token-Blatt-Komponenten (CalcTokenSpan/RefSpan) in allen Tab-Viewern.
  const [varParam, setVarParam] = useUrlState<string>('var', '');
  const selectedVarKey = useMemo(() => parseVarParam(varParam), [varParam]);
  const toggleVar = useCallback((key: string) => {
    setVarParam(prev => (parseVarParam(prev) === key ? '' : key));
  }, [setVarParam]);
  const clearVarSelection = useCallback(() => { setVarParam(''); }, [setVarParam]);
  // Trefferzahl + Original-Schreibweise, datenbasiert vom aktiven Viewer
  // gemeldet. Kein Reset bei var-Wechsel: der Viewer meldet im selben Commit
  // synchron nach (Child-Effekte laufen vor Parent-Effekten — ein Parent-Reset
  // würde die frische Meldung überschreiben). Reset nur beim Objektwechsel.
  const [varMatches, setVarMatches] = useState<{ count: number; name: string | null }>({ count: 0, name: null });
  const reportVarMatches = useCallback((count: number, name: string | null) => {
    setVarMatches(prev => (prev.count === count && prev.name === name ? prev : { count, name }));
  }, []);
  useEffect(() => { setVarMatches({ count: 0, name: null }); }, [uuid]);
  const varSelection = useMemo<VarSelection>(() => ({
    selectedKey: selectedVarKey,
    toggle: toggleVar,
    reportMatches: reportVarMatches,
  }), [selectedVarKey, toggleVar, reportVarMatches]);
  // Pill nur, wenn der aktive Detail-Tab tatsächlich Treffer rendert — in den
  // anderen Tabs ist die Auswahl wirkungslos (Param bleibt harmlos in der URL).
  const showVarPill = !!selectedVarKey && activeTab === 'detail' && varMatches.count > 0;

  // Tests-Tab badge: worst cached test result for this object — shows
  // a dot on the tab before it is even opened. Fed by the tests result store.
  const testsBadge = useSyncExternalStore(
    subscribeTestsStore,
    () => (uuid ? getObjectBadge(uuid) : null),
  );

  const handleBack = () => {
    // Falls die DetailView per Direkt-Link/Bookmark geöffnet wurde, gibt es
    // keinen Vorgänger im History-Stack — dann auf die Startseite gehen.
    if (location.key !== 'default') navigate(-1);
    else navigate('/');
  };

  // Mehrstufige ESC-Logik: Suchfeld leeren → Filter leeren → Zurück.
  // Stages werden in Reihenfolge geprüft, die erste aktive konsumiert ESC.
  useEscapeStack([
    // Detail-Tab (Layout): Tooltip → Suche/Selektion → Typ-Filter. Außerhalb des
    // Layout-Detail-Tabs ist layoutCanvasRef null, daher fallen diese Stages durch.
    () => {
      if (layoutCanvasRef.current?.hasTooltip()) {
        layoutCanvasRef.current.closeTooltip();
        return true;
      }
      return false;
    },
    () => {
      if (layoutCanvasRef.current?.hasSearchState()) {
        layoutCanvasRef.current.clearSearch();
        return true;
      }
      return false;
    },
    () => {
      if (layoutCanvasRef.current?.hasFilters()) {
        layoutCanvasRef.current.clearFilters();
        return true;
      }
      return false;
    },
    () => {
      if (hierarchyRef.current?.hasQuery()) {
        hierarchyRef.current.clearQuery();
        return true;
      }
      return false;
    },
    () => {
      if (hierarchyRef.current?.hasFilters()) {
        hierarchyRef.current.clearFilters();
        return true;
      }
      return false;
    },
    // Graph-Tab: ein aktiver Namensfilter wird zuerst geleert (nur gemountet,
    // wenn der Graph-Tab aktiv ist — sonst ist der Ref null und die Stage fällt
    // durch zur Zurück-Navigation).
    () => graphPanelRef.current?.clearTransientFilters() ?? false,
    // Aktive Variablen-Auswahl räumen, bevor ESC zurücknavigiert.
    () => {
      if (selectedVarKey) {
        clearVarSelection();
        return true;
      }
      return false;
    },
    () => {
      handleBack();
      return true;
    },
  ]);

  if (loading) {
    return (
      <div className="app">
        <LoadingSpinner message={t('nav:detailView.loadingDetails') as string} />
      </div>
    );
  }

  // Sicherheitsnetz: bare-UUID-Navigation auf ein in mehreren Dateien existierendes
  // Objekt (409 AMBIGUOUS_UUID) → Datei-Picker statt hartem Fehler.
  if (ambiguousFiles && ambiguousFiles.length > 0 && uuid) {
    return (
      <div className="app">
        <button onClick={handleBack} className="back-button" aria-label={t('nav:detailView.backAria') as string}>
          &larr; {t('nav:detailView.backLabel')}
        </button>
        <div style={{ marginTop: '1rem' }}>
          <AmbiguousFilePicker uuid={uuid} files={ambiguousFiles} />
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="app">
        <button onClick={handleBack} className="back-button" aria-label={t('nav:detailView.backAria') as string}>
          &larr; {t('nav:detailView.backLabel')}
        </button>
        <div style={{ marginTop: '1rem' }}>
          <ErrorMessage message={error} onRetry={retry} />
        </div>
      </div>
    );
  }

  if (!object) {
    return (
      <div className="app">
        <ErrorMessage message={t('nav:detailView.objectNotFound') as string} />
      </div>
    );
  }

  const breadcrumbType = displayObjectType(object.Object_Type, object.Source_Table);
  // Built-ins stehen im Katalog unter ihrem KANONISCHEN englischen Namen — das
  // ist ihre Identität, sprachunabhängig. Für eine Lösung, deren Formeln
  // lokalisiert geschrieben sind, ist dieser Name allein aber nicht der Name,
  // den der Entwickler kennt: deshalb kanonisch + lokalisierte Fassung
  // daneben, nicht statt. Localized_Name liefert die API nur mit ?lang= und nur
  // bei echter Abweichung.
  const localizedName = object.Object_Type === 'BuiltinFunction'
    ? (object as Record<string, unknown>).Localized_Name
    : null;
  const titleName = object.Object_Name
    ? (typeof localizedName === 'string' && localizedName
        ? `${object.Object_Name} · ${localizedName}`
        : object.Object_Name)
    : (t('nav:detailView.noName') as string);
  const breadcrumbItems = buildBreadcrumb({
    kind: 'object',
    objectType: breadcrumbType,
    objectName: titleName,
    objectPath: buildObjectPath(uuid!, null, fileParam || null),
    tab: activeTab,
  }, t);

  const renderTabContent = () => {
    switch (activeTab) {
      case 'detail':
        return (
          <TypeDetail
            objectType={object.Object_Type}
            uuid={object.Object_UUID}
            highlightUuids={highlightUuids}
            highlightText={refOrigin.origin?.name ?? null}
            onClearRef={dismissRefOrigin}
            onLiveMatchCount={setLiveMatchCount}
            layoutCanvasRef={layoutCanvasRef}
          />
        );
      case 'references':
        return <HierarchyTree ref={hierarchyRef} references={references} />;
      case 'graph':
        return <ObjectGraphPanel ref={graphPanelRef} object={object} />;
      case 'tests':
        return (
          <TestsPanel
            objectUuid={object.Object_UUID}
            objectType={object.Object_Type}
            fileName={object.File_Name ?? null}
          />
        );
      default:
        return null;
    }
  };

  return (
    <CurrentFileContext.Provider value={object.File_Name ?? null}>
    <VarSelectionContext.Provider value={varSelection}>
    <div className="app" role="main" aria-labelledby="object-title">
      {/* Navigation (Ebene 3+4): Home-Icon + Breadcrumb + Meta-Navi, darunter Back.
          Die Origin-Indikator-Pill (Cross-Reference Highlight) erscheint direkt
          rechts neben dem Zurück-Button — nur wenn ein `ref`-Parameter in der URL
          gesetzt ist. liveMatchCount überschreibt den server-seitigen Container-
          Self-Link-Count für Token-Container-Detail-Tabs (Script / CF / Field). */}
      <SubNav breadcrumbs={breadcrumbItems} />
      <StatusBar
        onBack={handleBack}
        message={(refParam || refSrcParam || showVarPill) ? (
          <div className="status-pill-stack">
            {(refParam || refSrcParam) && (
              <RefOriginPill
                state={refOrigin}
                rawRef={refParam}
                onDismiss={dismissRefOrigin}
                liveMatchCount={activeTab === 'detail' ? liveMatchCount : undefined}
                contextState={refContext}
                contextSrc={refSrcParam || null}
              />
            )}
            {showVarPill && (
              <VarSelectionPill
                varKey={selectedVarKey!}
                displayName={varMatches.name}
                count={varMatches.count}
                onDismiss={clearVarSelection}
              />
            )}
          </div>
        ) : undefined}
      />

      {/* Object header */}
      <ObjectHeader object={object} />

      {/* Plug-in platform map badge (plugref) — PluginFunction only */}
      {object.Object_Type === 'PluginFunction' && object.Object_Name && (
        <PluginPlatformBadge objectName={object.Object_Name} />
      )}

      {/* OS-binding badge (v7) — Script only, fed by cached
          platform-os-binding test runs (neutral inventory, no defect). */}
      {object.Object_Type === 'Script' && object.Object_UUID && (
        <ScriptOsBadge objectUuid={object.Object_UUID} />
      )}

      {/* Sub-navigation tabs (left) + object actions like "Open in FileMaker" (right) */}
      <div className="detail-tab-bar">
        <nav className="detail-tab-nav" role="tablist" aria-label={t('nav:detailView.tabsAria') as string}>
          {DETAIL_TABS.map((tab) => (
            <button
              key={tab.id}
              className={`tab-button${activeTab === tab.id ? ' active' : ''}${!tab.enabled ? ' disabled' : ''}`}
              onClick={() => tab.enabled && setActiveTab(tab.id)}
              role="tab"
              aria-selected={activeTab === tab.id}
              aria-disabled={!tab.enabled}
              tabIndex={tab.enabled ? 0 : -1}
            >
              {t(`nav:${tab.label}`)}
              {tab.id === 'tests' && testsBadge && (
                <span className={`tab-badge tab-badge-${testsBadge}`} aria-hidden="true" />
              )}
            </button>
          ))}
        </nav>
        <div className="detail-tab-actions">
          <Slot
            name="objectHeaderActions"
            objectUuid={object.Object_UUID}
            objectType={object.Object_Type}
            objectName={object.Object_Name || ''}
            fileName={object.File_Name || ''}
          />
        </div>
      </div>

      {/* Tab content */}
      <div className="detail-tab-content">
        {renderTabContent()}
      </div>
    </div>
    </VarSelectionContext.Provider>
    </CurrentFileContext.Provider>
  );
};
