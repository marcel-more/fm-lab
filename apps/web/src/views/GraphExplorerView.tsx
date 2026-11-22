import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useSearchParams, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { Filterbar } from '../components/Filterbar';
import {
  GraphExplorer,
  type GraphExplorerHandle,
  type GraphExplorerStats,
  type TraceParamsProp,
  type DataTraceParamsProp,
} from '../components/GraphExplorer';
import type { DataTraceControlValues } from '../components/ExplorerDataTracePanel';
import { DATA_TRACE_DEFAULTS, DATA_TRACE_FIELD_LEVELS_MAX } from '../hooks/useDataTrace';
import type { TraceControlValues } from '../components/ExplorerTracePanel';
import type { SubgraphDirection } from '../hooks/useSubgraph';
import { TRACE_DEFAULTS, type TraceEntryKey } from '../hooks/useTrace';
import { useEscapeStack } from '../hooks/useEscapeStack';
import { buildObjectPath, buildBreadcrumb } from '../lib/navigation';
import './GraphExplorerView.css';

/**
 * Graph Explorer — standalone route `/graph`. Thin host around the reusable
 * {@link GraphExplorer} engine: it owns the deep-link params
 * (`?focus=&depth=&dir=`) and renders the full-screen header (back, title,
 * live stats, fit/relayout/export, theme toggle). Focus is set via the
 * DetailView graph tab, a deep-link or a double-tap (no global search).
 */

// Obergrenze der Tiefe im Deep-Link. Muss zum Backend GRAPH_MAX_DEPTH passen
// (Default 16); der GUI-Default bleibt 4, nur die Opt-in-Erweiterung geht höher.
const GRAPH_MAX_DEPTH = 16;

function clampDepth(raw: string | null): number {
  const n = Number(raw);
  if (!Number.isFinite(n)) return 1;
  return Math.min(GRAPH_MAX_DEPTH, Math.max(1, Math.round(n)));
}

function parseDirection(raw: string | null): SubgraphDirection {
  return raw === 'out' || raw === 'in' || raw === 'both' ? raw : 'both';
}

/** Trace-Budget aus dem Deep-Link (geklemmt); Fallback = Default des Params. */
function clampTraceBudget(raw: string | null, fallback: number, max: number): number {
  const n = Number(raw);
  if (raw === null || !Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(0, Math.round(n)));
}

/** Offenes Diagramm (`way`): Weg-Nummer ≥ 0 (0 = Übersicht); sonst keins. */
function parseWayNo(raw: string | null): number | null {
  if (raw === null || raw === '') return null;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

const TRACE_ENTRIES: TraceEntryKey[] = ['script', 'layout_runtime', 'layout_inbound', 'layout_full'];

function parseTraceEntry(raw: string | null): TraceEntryKey | null {
  return TRACE_ENTRIES.includes(raw as TraceEntryKey) ? (raw as TraceEntryKey) : null;
}

/**
 * Alle Trace-Deep-Link-Params — gemeinsam gelöscht beim Moduswechsel.
 * Ablauf-Trace: dis (deaktivierte Schritte) · wdir (Tab „Ruft auf" = down;
 * Default „Erreicht über" wie „Herkunft" im Datenfluss) · way (offenes
 * Diagramm, 0 = Übersicht, je Richtung).
 * Datenfluss-Trace (`tmode=data`): tdir · flevels · ctl · sinks · reset ·
 * profile · expand (Weg-IDs „Quelle verfolgen").
 */
const TRACE_PARAM_KEYS = [
  'trace', 'trace_file', 'entry', 'up', 'down', 'tdepth', 'vars', 'buttons', 'itrig', 'expup', 'exclude',
  'tmode', 'tdir', 'flevels', 'ctl', 'sinks', 'reset', 'profile', 'expand', 'tstep', 'trole',
  'dis', 'wdir', 'way',
] as const;
const nullPatch = (keys: readonly string[]) => Object.fromEntries(keys.map((k) => [k, null]));

export function GraphExplorerView() {
  const { t } = useTranslation(['explorer', 'common', 'nav']);
  const navigate = useNavigate();
  const location = useLocation();
  const [searchParams, setSearchParams] = useSearchParams();
  const engineRef = useRef<GraphExplorerHandle>(null);
  const [stats, setStats] = useState<GraphExplorerStats | null>(null);

  const focus = searchParams.get('focus');
  // Klon-Disambiguierung: File_Name des Fokus (Graceful Downgrade ohne den Param).
  const focusFile = searchParams.get('focus_file');
  const depth = clampDepth(searchParams.get('depth'));
  const direction = parseDirection(searchParams.get('dir'));
  // Datei-Gruppierung als Deep-Link-Param (`?group=file`) → ein gruppierter Graph ist teilbar.
  const groupByFile = searchParams.get('group') === 'file';

  // Trace-Modus (`?trace=…`) — schließt `focus` aus; `trace` gewinnt (Normalisierung
  // unten). Deep-Link-Kurzformen up/down/tdepth/vars/buttons/expup ↔ API-Params
  // (Übersetzung in useTrace, Muster wie dir ↔ direction).
  const traceStart = searchParams.get('trace');
  const dataMode = searchParams.get('tmode') === 'data';
  const excludeList = (searchParams.get('exclude') ?? '').split(',').filter((s) => s !== '');
  // Datenfluss-Trace ab einem Feld (`tmode=data`) — eigener Param-Satz.
  const dataTrace: DataTraceParamsProp | null = traceStart && dataMode
    ? {
        start: traceStart,
        startFile: searchParams.get('trace_file'),
        dir: searchParams.get('tdir') === 'down' ? 'down' : 'up',
        fieldLevels: clampTraceBudget(searchParams.get('flevels'), DATA_TRACE_DEFAULTS.fieldLevels, DATA_TRACE_FIELD_LEVELS_MAX) || 1,
        includeControl: searchParams.get('ctl') === '1',
        includeSinks: searchParams.get('sinks') !== '0',
        includeReset: searchParams.get('reset') === '1',
        profile: searchParams.get('profile') !== 'off',
        expandWay: (searchParams.get('expand') ?? '').split(',').filter((s) => s !== ''),
        exclude: excludeList,
        // Schritt-Anker einer lokalen Startvariable
        startStep: searchParams.get('tstep'),
        startRole: searchParams.get('trole') === 'set' ? 'set' : searchParams.get('tstep') ? 'read' : null,
      }
    : null;
  const trace: TraceParamsProp | null = traceStart && !dataMode
    ? {
        start: traceStart,
        startFile: searchParams.get('trace_file'),
        entry: parseTraceEntry(searchParams.get('entry')),
        upDepth: clampTraceBudget(searchParams.get('up'), TRACE_DEFAULTS.upDepth, GRAPH_MAX_DEPTH),
        downDepth: clampTraceBudget(searchParams.get('down'), TRACE_DEFAULTS.downDepth, GRAPH_MAX_DEPTH),
        triggerDepth: clampTraceBudget(searchParams.get('tdepth'), TRACE_DEFAULTS.triggerDepth, 3),
        expandUp: searchParams.get('expup') === '1',
        includeLocalVars: searchParams.get('vars') === '1',
        includeButtons: searchParams.get('buttons') === '1',
        includeInteractionTriggers: searchParams.get('itrig') === '1',
        includeDisabled: searchParams.get('dis') === '1',
        // Boundary-Ausschlüsse (Composite-IDs, kommasepariert).
        exclude: excludeList,
        wayDir: searchParams.get('wdir') === 'down' ? 'down' : 'up',
        // „Quelle verfolgen" aufwärts — Weg-IDs, wie im Datenfluss-Modus `expand`.
        expandWay: (searchParams.get('expand') ?? '').split(',').filter((s) => s !== ''),
        way: parseWayNo(searchParams.get('way')),
      }
    : null;

  // Patch a subset of the deep-link params, preserving the rest.
  const patchParams = useCallback(
    (patch: Record<string, string | null>) => {
      const next = new URLSearchParams(searchParams);
      for (const [k, v] of Object.entries(patch)) {
        if (v === null || v === '') next.delete(k);
        else next.set(k, v);
      }
      setSearchParams(next, { replace: true });
    },
    [searchParams, setSearchParams],
  );

  // URL-Normalisierung: `trace` und `focus` schließen sich aus — `trace` gewinnt.
  useEffect(() => {
    if (traceStart && (searchParams.get('focus') || searchParams.get('depth') || searchParams.get('dir'))) {
      patchParams({ focus: null, focus_file: null, depth: null, dir: null });
    }
  }, [traceStart, searchParams, patchParams]);

  // Re-Focus bleibt im Graphen, schreibt aber focus_file mit, damit der Backend-
  // Fokus eine geteilte Klon-UUID eindeutig auflöst (sonst 409). Verlässt einen
  // aktiven Trace-Modus (Nachbarschafts-Sicht auf das Objekt).
  const handleSetFocus = useCallback(
    (uuid: string, file?: string | null) =>
      patchParams({ focus: uuid, focus_file: file ?? null, ...nullPatch(TRACE_PARAM_KEYS) }),
    [patchParams],
  );

  // Trace ab einem Objekt öffnen (Inspect-Panel-Aktion) — frische Defaults,
  // Fokus-Familie raus. Default-Budgets bleiben aus der URL weggelassen.
  const handleOpenTrace = useCallback(
    (uuid: string, file?: string | null) =>
      patchParams({
        ...nullPatch(TRACE_PARAM_KEYS),
        trace: uuid,
        trace_file: file ?? null,
        focus: null,
        focus_file: null,
        depth: null,
        dir: null,
      }),
    [patchParams],
  );

  // Budgets/Schalter/Preset patchen; Default-Werte verschwinden aus der URL
  // (kurze, deterministische Deep-Links — Parität zum Skill /fm-trace).
  const handleTraceParamsChange = useCallback(
    (patch: Partial<TraceControlValues> & {
      entry?: TraceEntryKey; exclude?: string[]; wayDir?: 'up' | 'down'; way?: number | null; expandWay?: string[];
    }) => {
      const urlPatch: Record<string, string | null> = {};
      // Weg-Nummern gelten je Parametersatz und Richtung — jede andere Änderung
      // schließt ein offenes Diagramm. „Quelle verfolgen" hängt neue Wege hinten
      // an, die vorhandenen Nummern bleiben.
      const onlyView = Object.keys(patch).every((k) => k === 'wayDir' || k === 'way' || k === 'expandWay');
      if (patch.expandWay !== undefined) {
        urlPatch.expand = patch.expandWay.length > 0 ? patch.expandWay.join(',') : null;
        // Zurücksetzen entfernt die angehängten Wege — ein offenes Diagramm kann darauf zeigen.
        if (patch.expandWay.length === 0 && patch.way === undefined) urlPatch.way = null;
      }
      if (!onlyView) urlPatch.way = null;
      if (patch.wayDir !== undefined) {
        urlPatch.wdir = patch.wayDir === 'down' ? 'down' : null;
        if (patch.way === undefined) urlPatch.way = null;
      }
      if (patch.way !== undefined) urlPatch.way = patch.way === null ? null : String(patch.way);
      if (patch.includeDisabled !== undefined) urlPatch.dis = patch.includeDisabled ? '1' : null;
      if (patch.entry !== undefined) urlPatch.entry = patch.entry;
      if (patch.exclude !== undefined) {
        urlPatch.exclude = patch.exclude.length > 0 ? patch.exclude.join(',') : null;
      }
      if (patch.upDepth !== undefined) {
        urlPatch.up = patch.upDepth === TRACE_DEFAULTS.upDepth ? null : String(patch.upDepth);
      }
      if (patch.downDepth !== undefined) {
        urlPatch.down = patch.downDepth === TRACE_DEFAULTS.downDepth ? null : String(patch.downDepth);
      }
      if (patch.triggerDepth !== undefined) {
        urlPatch.tdepth = patch.triggerDepth === TRACE_DEFAULTS.triggerDepth ? null : String(patch.triggerDepth);
      }
      if (patch.expandUp !== undefined) urlPatch.expup = patch.expandUp ? '1' : null;
      if (patch.includeLocalVars !== undefined) urlPatch.vars = patch.includeLocalVars ? '1' : null;
      if (patch.includeButtons !== undefined) urlPatch.buttons = patch.includeButtons ? '1' : null;
      if (patch.includeInteractionTriggers !== undefined) urlPatch.itrig = patch.includeInteractionTriggers ? '1' : null;
      patchParams(urlPatch);
    },
    [patchParams],
  );
  // Datenfluss-Trace ab einem Feld/einer Variable öffnen (Inspect-Aktion „Trace").
  const handleOpenDataTrace = useCallback(
    (uuid: string, file: string | null | undefined, dir: 'up' | 'down') =>
      patchParams({
        ...nullPatch(TRACE_PARAM_KEYS),
        trace: uuid,
        trace_file: file ?? null,
        tmode: 'data',
        tdir: dir === 'down' ? 'down' : null,
        focus: null,
        focus_file: null,
        depth: null,
        dir: null,
      }),
    [patchParams],
  );

  // Datenfluss-Parameter patchen; Defaults verschwinden aus der URL. Ein
  // Richtungswechsel verwirft „Quelle verfolgen" (Weg-IDs gelten je Richtung).
  const handleDataTraceParamsChange = useCallback(
    (patch: Partial<DataTraceControlValues> & { expandWay?: string[]; exclude?: string[]; clearAnchor?: boolean }) => {
      const urlPatch: Record<string, string | null> = {};
      if (patch.dir !== undefined) {
        urlPatch.tdir = patch.dir === 'down' ? 'down' : null;
        urlPatch.expand = null;
        // Verwendung ab einem reinen Leser gibt es nicht — Anker dann aufheben.
        if (patch.dir === 'down' && searchParams.get('tstep') && searchParams.get('trole') !== 'set') {
          urlPatch.tstep = null;
          urlPatch.trole = null;
        }
      }
      if (patch.clearAnchor) {
        urlPatch.tstep = null;
        urlPatch.trole = null;
        urlPatch.expand = null;
      }
      if (patch.fieldLevels !== undefined) {
        urlPatch.flevels = patch.fieldLevels === DATA_TRACE_DEFAULTS.fieldLevels ? null : String(patch.fieldLevels);
      }
      if (patch.includeControl !== undefined) urlPatch.ctl = patch.includeControl ? '1' : null;
      if (patch.includeSinks !== undefined) urlPatch.sinks = patch.includeSinks ? null : '0';
      if (patch.includeReset !== undefined) urlPatch.reset = patch.includeReset ? '1' : null;
      if (patch.profile !== undefined) urlPatch.profile = patch.profile ? null : 'off';
      if (patch.expandWay !== undefined) urlPatch.expand = patch.expandWay.length > 0 ? patch.expandWay.join(',') : null;
      if (patch.exclude !== undefined) urlPatch.exclude = patch.exclude.length > 0 ? patch.exclude.join(',') : null;
      patchParams(urlPatch);
    },
    [patchParams, searchParams],
  );

  const handleOpenDetails = useCallback(
    (uuid: string, file?: string | null) => navigate(buildObjectPath(uuid, null, file ?? null)),
    [navigate],
  );

  const handleExportPng = useCallback(() => {
    const dataUrl = engineRef.current?.exportPng();
    if (!dataUrl) return;
    const a = document.createElement('a');
    a.href = dataUrl;
    a.download = `graph-${(stats?.focusLabel ?? 'export').replace(/[^\w.-]+/g, '_')}.png`;
    a.click();
  }, [stats]);

  const handleBack = useCallback(() => {
    if (location.key !== 'default') navigate(-1);
    else navigate('/');
  }, [location.key, navigate]);

  useEscapeStack([
    // Stage: ein aktiver Namensfilter wird zuerst geleert.
    () => engineRef.current?.clearTransientFilters() ?? false,
    // Fallback: Zurück-Navigation.
    () => {
      handleBack();
      return true;
    },
  ]);

  return (
    <div className="graph-explorer-view">
      <SubNav
        breadcrumbs={
          (focus || traceStart) && stats?.focusLabel
            ? buildBreadcrumb({ kind: 'graphNode', nodeName: stats.focusLabel }, t)
            : buildBreadcrumb({ kind: 'graph' }, t)
        }
      />
      <StatusBar
        onBack={handleBack}
        message={stats && (
          <span className="graph-explorer-stats" aria-live="polite">
            {t('explorer:stats.nodes', { count: stats.nodeCount })} ·{' '}
            {t('explorer:stats.edges', { count: stats.edgeCount })}
            {stats.communityCount > 0 && (
              <> · {t('explorer:stats.communities', { count: stats.communityCount })}</>
            )}
          </span>
        )}
      >
        <Filterbar className="graph-explorer-toolbar">
          <button type="button" onClick={() => engineRef.current?.fit()} disabled={!stats}>
            {t('explorer:toolbar.fit')}
          </button>
          <button type="button" onClick={() => engineRef.current?.relayout()} disabled={!stats}>
            {t('explorer:toolbar.relayout')}
          </button>
          <button type="button" onClick={handleExportPng} disabled={!stats}>
            {t('explorer:toolbar.exportPng')}
          </button>
        </Filterbar>
      </StatusBar>

      <GraphExplorer
        ref={engineRef}
        focus={trace || dataTrace ? null : focus}
        focusFile={focusFile}
        depth={depth}
        direction={direction}
        onDepthChange={(d) => patchParams({ depth: String(d) })}
        onDirectionChange={(d) => patchParams({ dir: d })}
        onSetFocus={handleSetFocus}
        onOpenDetails={handleOpenDetails}
        onStats={setStats}
        enableCommunityLens
        groupByFile={groupByFile}
        onGroupByFileChange={(v) => patchParams({ group: v ? 'file' : null })}
        trace={trace}
        onTraceParamsChange={handleTraceParamsChange}
        onOpenTrace={handleOpenTrace}
        dataTrace={dataTrace}
        onDataTraceParamsChange={handleDataTraceParamsChange}
        onOpenDataTrace={handleOpenDataTrace}
      />
    </div>
  );
}
