import { forwardRef, useCallback, useImperativeHandle, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  GraphExplorer,
  type GraphExplorerHandle,
  type GraphExplorerStats,
} from './GraphExplorer';
import type { FMObject } from '../types';
import type { SubgraphDirection } from '../hooks/useSubgraph';
import { buildObjectPath, buildDataTracePath } from '../lib/navigation';
import { dataflowUsable, useDataflowCapability } from '../hooks/useDataTrace';

/**
 * Embedded Graph Explorer for the object DetailView "Graph" tab
 * (`/object/:uuid?tab=graph`). Reuses the {@link GraphExplorer} engine but
 * renders only a **compact toolbar** ([Einpassen] [Neu anordnen] [Vollbild]
 * + live counts) instead of the standalone header — the object view supplies
 * the meta-navigation (back, theme). "Vollbild" switches to the full-screen
 * standalone explorer at `/graph?focus=…`. Traversal params live in local
 * state (they don't pollute the object URL, which only carries `?tab=graph`).
 *
 * A double-tap re-centers by **navigating the DetailView to that object's graph
 * tab** (keeping the object header consistent); ⌘/Ctrl-tap opens its details.
 *
 * Exposes {@link ObjectGraphPanelHandle} so the DetailView's escape stack can
 * clear an active name filter on ESC instead of navigating back (mirrors the
 * HierarchyTree handle used by the references tab).
 */

export interface ObjectGraphPanelHandle {
  /** Clear active soft filters (name). Returns true if something was cleared. */
  clearTransientFilters: () => boolean;
}

export const ObjectGraphPanel = forwardRef<ObjectGraphPanelHandle, { object: FMObject }>(
  ({ object }, ref) => {
  const { t } = useTranslation(['explorer']);
  const navigate = useNavigate();
  const engineRef = useRef<GraphExplorerHandle>(null);
  const [stats, setStats] = useState<GraphExplorerStats | null>(null);

  useImperativeHandle(ref, () => ({
    clearTransientFilters: () => engineRef.current?.clearTransientFilters() ?? false,
  }), []);

  // Local (non-URL) traversal state — the object URL stays `?tab=graph` only.
  const [depth, setDepth] = useState(1);
  const [direction, setDirection] = useState<SubgraphDirection>('both');
  // Datei-Gruppierung: im eingebetteten Panel rein lokaler State (keine eigene URL).
  const [groupByFile, setGroupByFile] = useState(false);

  const focus = object.Object_UUID;

  const handleSetFocus = useCallback(
    // Klon-Disambiguierung: Zieldatei des Knotens als `?file=` mitführen.
    (uuid: string, file?: string | null) => navigate(buildObjectPath(uuid, null, file ?? null, { tab: 'graph' })),
    [navigate],
  );
  const handleOpenDetails = useCallback(
    (uuid: string, file?: string | null) => navigate(buildObjectPath(uuid, null, file ?? null)),
    [navigate],
  );
  const handleFullscreen = useCallback(() => {
    const q = new URLSearchParams({ focus, depth: String(depth), dir: direction });
    // Klon-Disambiguierung: Fokus-Datei in den Vollbild-Deeplink übernehmen.
    if (object.File_Name) q.set('focus_file', object.File_Name);
    navigate(`/graph?${q.toString()}`);
  }, [navigate, focus, depth, direction, object.File_Name]);

  // Trace-Modus des Standalone-Explorers öffnen (Deep-Link-Parität zu /fm-trace).
  const handleOpenTrace = useCallback((uuid: string, file?: string | null) => {
    const q = new URLSearchParams({ trace: uuid });
    if (file) q.set('trace_file', file);
    navigate(`/graph?${q.toString()}`);
  }, [navigate]);
  // Ein Einstieg „Trace" für alle Starttypen (ab Schema 1.43.0): Script/Layout
  // öffnen den Ablauf-Trace, Feld/Variable den Datenfluss-Trace. Die Richtung
  // wählt erst der Explorer (Tabs der Wege-Liste) — Default jeweils „oben"
  // (Erreicht über · Herkunft).
  const dataflowCap = useDataflowCapability();
  const usable = dataflowUsable(dataflowCap);
  const traceable = (object.Object_Type === 'Script' || object.Object_Type === 'Layout') && usable;
  const dataTraceable = (object.Object_Type === 'Field' || object.Object_Type === 'Variable') && usable;
  // Schritt-Anker: kam der Klick aus einer Script-Zeile (`at_step`, Rolle
  // `at_use` = read | set), startet der Trace an diesem Schritt; das Trace-Panel
  // zeigt den Anker und hebt ihn auf („Ganzes Script").
  const [searchParams] = useSearchParams();
  const atStep = object.Object_Type === 'Variable' ? searchParams.get('at_step') : null;
  const atUse = searchParams.get('at_use');
  const anchor = atStep && (atUse === 'read' || atUse === 'set') ? { step: atStep, role: atUse } as const : null;
  const openDataTrace = () => navigate(buildDataTracePath(focus, object.File_Name ?? null, 'up', anchor));
  // Inspect-Aktion „Trace" eines Nachbarknotens (Feld/Variable) im eingebetteten Explorer.
  const handleOpenDataTrace = useCallback(
    (uuid: string, file: string | null | undefined, dir: 'up' | 'down') => navigate(buildDataTracePath(uuid, file, dir)),
    [navigate],
  );
  const traceHint = dataTraceable
    ? `explorer:trace.data.actionHint${anchor ? 'Anchored' : object.Object_Type === 'Variable' ? 'Variable' : ''}`
    : 'explorer:trace.actionHint';

  return (
    <div className="detail-graph-panel">
      <div className="detail-graph-toolbar">
        <button type="button" onClick={() => engineRef.current?.fit()} disabled={!stats}>
          {t('explorer:toolbar.fit')}
        </button>
        <button type="button" onClick={() => engineRef.current?.relayout()} disabled={!stats}>
          {t('explorer:toolbar.relayout')}
        </button>
        <button
          type="button"
          className="detail-graph-fullscreen"
          onClick={handleFullscreen}
          title={t('explorer:toolbar.fullscreenTitle') as string}
        >
          {t('explorer:toolbar.fullscreen')}
        </button>
        {(traceable || dataTraceable) && (
          <button
            type="button"
            className="detail-graph-fullscreen"
            onClick={() => (dataTraceable ? openDataTrace() : handleOpenTrace(focus, object.File_Name ?? null))}
            title={t(traceHint) as string}
          >
            {/* Eigenname „Trace" bewusst unübersetzt. */}
            Trace
          </button>
        )}
        <span className="detail-graph-stats" aria-live="polite">
          {stats && (
            <>
              {t('explorer:stats.nodes', { count: stats.nodeCount })} ·{' '}
              {t('explorer:stats.edges', { count: stats.edgeCount })}
            </>
          )}
        </span>
      </div>

      <GraphExplorer
        ref={engineRef}
        focus={focus}
        focusFile={object.File_Name ?? null}
        depth={depth}
        direction={direction}
        onDepthChange={setDepth}
        onDirectionChange={setDirection}
        onSetFocus={handleSetFocus}
        onOpenDetails={handleOpenDetails}
        onStats={setStats}
        groupByFile={groupByFile}
        onGroupByFileChange={setGroupByFile}
        onOpenTrace={handleOpenTrace}
        onOpenDataTrace={handleOpenDataTrace}
      />
    </div>
  );
  },
);

ObjectGraphPanel.displayName = 'ObjectGraphPanel';
