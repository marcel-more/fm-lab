import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from 'react';
import { useTranslation } from 'react-i18next';
import { ExplorerFilterPanel, type CommunityLegendItem } from './ExplorerFilterPanel';
import { ExplorerGraph, type ExplorerGraphHandle, type FilterMode, type ColorMode, type GraphPartition } from './ExplorerGraph';
import { ExplorerInspectPanel, type InspectNeighbor } from './ExplorerInspectPanel';
import { ExplorerTypeListPanel, type TypeListSort, type TypeListDir } from './ExplorerTypeListPanel';
import {
  useSubgraph,
  fetchNeighbors,
  subgraphToElements,
  type GraphNode,
  type SubgraphDirection,
} from '../hooks/useSubgraph';
import {
  useTrace,
  useTraceEntries,
  EXCLUDABLE_TYPES,
  type TraceEntryKey,
  type TraceExcludedItem,
  type TraceSuggestion,
} from '../hooks/useTrace';
import { ExplorerTracePanel, ExplorerTraceEntryChooser, type TraceControlValues } from './ExplorerTracePanel';
import { useDepthProfile } from '../hooks/useDepthProfile';
import { usePanelResize } from '../hooks/usePanelResize';
import { getCommunityColor } from '../lib/graphColors';
import { formatObjectDisplayName } from '../lib/objectName';
import '../views/GraphExplorerView.css';

/** Backend-Default node_limit von /api/graph/subgraph — Basis des Clipping-Hinweises. */
const NODE_LIMIT = 1000;
/** GUI-Default-Deckel der Tiefe; die Opt-in-Erweiterung „tiefer" geht bis zum Profil-hardCap. */
const DEFAULT_DEPTH_MAX = 4;

/** Default-Breiten der Seitenpanels (px) — zugleich der Doppelklick-Reset-Wert. */
const LEFT_PANEL_DEFAULT = 270;
const RIGHT_PANEL_DEFAULT = 300;
const LEFT_PANEL_KEY = 'fmlab.explorer.leftPanelWidth';
const RIGHT_PANEL_KEY = 'fmlab.explorer.rightPanelWidth';

/** Persistierte Panelbreite lesen (Fallback = Default; ungültige Werte verworfen). */
function readPanelWidth(key: string, fallback: number): number {
  try {
    const v = Number(localStorage.getItem(key));
    return Number.isFinite(v) && v > 0 ? v : fallback;
  } catch {
    return fallback;
  }
}

/**
 * Graph Explorer engine — the reusable workhorse shared by the standalone route
 * (`/graph`, see GraphExplorerView) and the embedded object-view tab
 * (`/object/:uuid?tab=graph`, see ObjectGraphPanel).
 *
 * It owns the client-side lens state (name/file/type filters, inspect panel) and
 * the Cytoscape interaction, and renders the filter panel + canvas + inspect
 * panel (`.graph-explorer-body`). Traversal params (focus/depth/direction/mode)
 * are *controlled* by the parent so each host can decide how they're persisted
 * (URL deep-link vs. local state) and what a re-focus means (re-center in place
 * vs. route to a new object). The parent renders its own toolbar/header and
 * drives the graph via the exposed handle; live counts arrive via `onStats`.
 */

export interface GraphExplorerHandle {
  fit: () => void;
  relayout: () => void;
  exportPng: () => string | null;
  /** Clear active soft filters (name). Returns true if something was cleared. */
  clearTransientFilters: () => boolean;
}

export interface GraphExplorerStats {
  nodeCount: number;
  edgeCount: number;
  totalReachable: number;
  truncated: boolean;
  /** Distinct communities present in the current graph (0 if unclustered). */
  communityCount: number;
  /** Label of the focus node (for the host's PNG filename / heading). */
  focusLabel: string | null;
}

interface GraphExplorerProps {
  focus: string | null;
  /** Klon-Disambiguierung: File_Name des Fokus-Knotens (Graceful Downgrade). */
  focusFile?: string | null;
  depth: number;
  direction: SubgraphDirection;
  onDepthChange: (d: number) => void;
  onDirectionChange: (d: SubgraphDirection) => void;
  /** Re-center request (double-tap / inspect "set focus"). file = Klon-Disambiguierung. */
  onSetFocus: (uuid: string, file?: string | null) => void;
  /** ⌘/Ctrl-tap / inspect "open details". file = Klon-Disambiguierung. */
  onOpenDetails: (uuid: string, file?: string | null) => void;
  /** Live graph stats for the host's toolbar (null while empty). */
  onStats?: (stats: GraphExplorerStats | null) => void;
  /**
   * Enable the community color lens — a Type↔Community recolor toggle
   * plus a community legend. Standalone `/graph` only; the embedded object-view
   * panel omits it (no legend room). Off → nodes are always type-colored.
   */
  enableCommunityLens?: boolean;
  /**
   * Datei-Gruppierung (Compound-Boxen je Datei) — vom Host kontrolliert, damit jeder
   * Host die Persistenz selbst wählt: Standalone `/graph` als Deep-Link-Param,
   * eingebettetes Objekt-Panel als lokaler State. Default aus.
   */
  groupByFile?: boolean;
  onGroupByFileChange?: (v: boolean) => void;
  /**
   * Trace-Modus (selektiver Ablauf-Graph, GET /api/graph/trace) — gesetzt statt
   * `focus`. Die Engine lädt dann über useTrace, ersetzt Tiefe/Richtung im
   * Filter-Panel durch die Trace-Kontrollen und stylt nach traceRole/traceKind;
   * alle Client-Lenses und Panels bleiben unverändert.
   */
  trace?: TraceParamsProp | null;
  /** Trace-Parameter-Patch (Budgets/Schalter/Preset/Excludes) — der Host persistiert (URL). */
  onTraceParamsChange?: (patch: Partial<TraceControlValues> & { entry?: TraceEntryKey; exclude?: string[] }) => void;
  /** Trace ab einem Knoten öffnen (Inspect-Panel-Aktion; v1 nur Script/Layout). */
  onOpenTrace?: (uuid: string, file?: string | null) => void;
}

export interface TraceParamsProp extends TraceControlValues {
  start: string;
  startFile?: string | null;
  /** Gewähltes Einstiegs-Preset; null = noch keins gewählt (Layout → Chooser). */
  entry: TraceEntryKey | null;
  /** Boundary-Ausschlüsse (Composite-Node-IDs); URL ist die Quelle. */
  exclude: string[];
}

export const GraphExplorer = forwardRef<GraphExplorerHandle, GraphExplorerProps>(
  (props, ref) => {
    const {
      focus, focusFile, depth, direction,
      onDepthChange, onDirectionChange,
      onSetFocus, onOpenDetails, onStats,
      enableCommunityLens = false,
      groupByFile = false,
      onGroupByFileChange,
      trace = null,
      onTraceParamsChange,
      onOpenTrace,
    } = props;
    const traceActive = trace !== null;
    // The graph always uses the "logical" view (container-hoisted operational
    // links). The "raw" granularity exposed only isolated, non-navigable
    // ScriptStep nodes, so its GUI control was removed; the backend param stays
    // available for power users via the direct API.
    const mode = 'logical';
    const { t } = useTranslation(['explorer', 'common']);
    const graphRef = useRef<ExplorerGraphHandle>(null);

    // Individuell per Drag verstellbare Breiten der beiden Seitenpanels, in
    // localStorage gemerkt (Listeneinträge werden sonst abgeschnitten). Doppelklick
    // auf den Anfasser stellt den Default wieder her.
    const [leftWidth, setLeftWidth] = useState(() => readPanelWidth(LEFT_PANEL_KEY, LEFT_PANEL_DEFAULT));
    const [rightWidth, setRightWidth] = useState(() => readPanelWidth(RIGHT_PANEL_KEY, RIGHT_PANEL_DEFAULT));
    const onResizeLeft = usePanelResize(leftWidth, setLeftWidth, { side: 'left' });
    const onResizeRight = usePanelResize(rightWidth, setRightWidth, { side: 'right' });
    useEffect(() => {
      try { localStorage.setItem(LEFT_PANEL_KEY, String(leftWidth)); } catch { /* ignore */ }
    }, [leftWidth]);
    useEffect(() => {
      try { localStorage.setItem(RIGHT_PANEL_KEY, String(rightWidth)); } catch { /* ignore */ }
    }, [rightWidth]);

    // Client-side lenses: name/file/type filters act on the
    // already-loaded subgraph — no re-fetch. Type chips are a hard exclusion set;
    // the name + file filters are soft and share one dim/hide mode (default: dim).
    const [deselectedTypes, setDeselectedTypes] = useState<string[]>([]);
    const [nameFilter, setNameFilter] = useState('');
    const [selectedFile, setSelectedFile] = useState<string | null>(null);
    const [filterMode, setFilterMode] = useState<FilterMode>('dim');
    const [colorMode, setColorMode] = useState<ColorMode>('type');
    // Community lens interaction: a selected community gets a colored hull +
    // dims/hides the others; a hovered legend entry transiently previews its hull.
    const [selectedCommunity, setSelectedCommunity] = useState<number | null>(null);
    const [hoveredCommunity, setHoveredCommunity] = useState<number | null>(null);
    const [focusLabel, setFocusLabel] = useState<string | null>(null);

    // Inspect panel state.
    const [selectedNode, setSelectedNode] = useState<GraphNode | null>(null);
    const [expanding, setExpanding] = useState(false);

    // Rechtes Panel, zweiter Modus: Objektliste eines Typs (mutually exclusive mit
    // dem Node-Inspect — beide teilen den Slot). null = keine Liste offen.
    const [typeListType, setTypeListType] = useState<string | null>(null);
    const [typeListSort, setTypeListSort] = useState<TypeListSort>('name');
    // Richtungs-Filter der Typ-Liste relativ zum Fokus (eingehend/ausgehend/beide).
    const [typeListDir, setTypeListDir] = useState<TypeListDir>('both');

    // Verfeinerung C — server-seitiger Typ-Filter (committed). null = wie heute
    // (alle Typen laden, Chips filtern client-seitig). Eine Änderung ⇒ Refetch.
    const [serverTypes, setServerTypes] = useState<string[] | null>(null);

    // Verfeinerung D — Opt-in-Erweiterung des Tiefen-Reglers über DEFAULT_DEPTH_MAX.
    const [depthExtended, setDepthExtended] = useState(false);

    // Stabile Konnektivitäts-Partition der geladenen Knoten (verbunden/Inseln/isoliert).
    // Eine Quelle für die Aufschlüsselung, den Pill und das Default-Verstecken nicht-verbundener.
    const [partition, setPartition] = useState<GraphPartition | null>(null);

    // Nicht mit dem Fokus verbundene Knoten (Inseln + isolierte) werden standardmäßig
    // ausgeblendet (sonst kachelt fcose isolierte in ein Raster); ein Pill auf der Canvas
    // nennt die Anzahl und erlaubt das Einblenden.
    const [showUnconnected, setShowUnconnected] = useState(false);
    // Jeder neu fokussierte Graph startet mit dem Default (nicht-verbundene ausgeblendet).
    useEffect(() => { setShowUnconnected(false); }, [focus, focusFile, trace?.start, trace?.startFile]);

    // serverTypes geht als `types` an den Subgraph-Fetch (Refetch + Re-Layout).
    // Im Trace-Modus ist der Subgraph-Fetch deaktiviert (focus=null) — die Daten
    // kommen dann aus useTrace; beide Antworten teilen die nodes/edges-Grundform.
    const subgraphResult = useSubgraph({
      focus: traceActive ? null : focus,
      focusFile, depth, direction, mode, types: serverTypes,
    });

    // Trace-Modus: erst die Einstiegspfad-Presets laden (Chooser-Entscheid),
    // dann den Trace selbst — ein Layout-Start ohne gewähltes Preset zeigt den
    // Chooser VOR dem ersten Trace-Fetch.
    const { entries: traceEntries, error: traceEntriesError } = useTraceEntries(
      traceActive ? trace.start : null,
      trace?.startFile ?? null,
    );
    const isLayoutStart = (traceEntries ?? []).some((e) => e.entry !== 'script');
    const needsEntryChoice = traceActive && isLayoutStart && !trace?.entry;
    const traceResult = useTrace(
      trace && traceEntries !== null && !needsEntryChoice
        ? {
            start: trace.start,
            startFile: trace.startFile ?? null,
            entry: trace.entry,
            upDepth: trace.upDepth,
            downDepth: trace.downDepth,
            triggerDepth: trace.triggerDepth,
            expandUp: trace.expandUp,
            includeLocalVars: trace.includeLocalVars,
            includeButtons: trace.includeButtons,
            includeInteractionTriggers: trace.includeInteractionTriggers,
            exclude: trace.exclude,
          }
        : null,
    );
    const data = traceActive ? traceResult.data : subgraphResult.data;
    const loading = traceActive ? traceResult.loading : subgraphResult.loading;
    const error = traceActive ? (traceResult.error ?? traceEntriesError) : subgraphResult.error;
    // Typisierter Zugriff auf die Trace-Zusatzfelder (dynamicCalls-Banner).
    const traceData = traceActive ? traceResult.data : null;
    // Chooser auch nach einem leeren Preset (422 TRACE_EMPTY_ENTRY) zeigen.
    const traceChooser = traceActive && (needsEntryChoice || traceResult.emptyEntries !== null);

    // Exclude-Chips: WELCHE Ausschlüsse gelten sagt die URL (trace.exclude); die
    // Server-Antwort reichert nur Label/Typ an. So bleibt ein Chip auch dann
    // entfernbar, wenn der gedämpfte Trace ihn nicht mehr erreicht oder die
    // Antwort noch lädt.
    const traceExcludedChips: TraceExcludedItem[] = (trace?.exclude ?? []).map((id) => {
      const resolved = traceData?.trace.excluded.find((x) => x.id === id);
      if (resolved) return resolved;
      const sep = id.indexOf('::');
      return {
        id,
        uuid: sep === -1 ? id : id.slice(0, sep),
        file: sep === -1 ? null : id.slice(sep + 2),
        label: null,
        type: null,
      };
    });

    // Exclude-Toggle (Inspect-Panel) — patcht die Liste, Host persistiert (URL).
    const handleToggleExclude = useCallback(
      (graphId: string) => {
        if (!trace) return;
        const next = trace.exclude.includes(graphId)
          ? trace.exclude.filter((x) => x !== graphId)
          : [...trace.exclude, graphId];
        onTraceParamsChange?.({ exclude: next });
      },
      [trace, onTraceParamsChange],
    );

    // Vorschläge: bereits ausgeschlossene Kandidaten client-seitig filtern
    // (die URL ist die Quelle; nach dem Klick verschwindet der Chip sofort).
    const traceSuggestionChips: TraceSuggestion[] = (traceData?.trace.suggestions ?? [])
      .filter((s) => !trace?.exclude.includes(s.id));
    const handleApplyAllSuggestions = useCallback(() => {
      if (!trace || !traceData) return;
      const add = traceData.trace.suggestions
        .map((s) => s.id)
        .filter((id) => !trace.exclude.includes(id));
      if (add.length > 0) onTraceParamsChange?.({ exclude: [...trace.exclude, ...add] });
    }, [trace, traceData, onTraceParamsChange]);

    // Tiefen-Profil (max. erreichbare Tiefe + per-Tiefe-Last), richtungsabhängig.
    // serverTypes MUSS mitgehen, damit die Last-/Clipping-Anzeige dieselbe (typgefilterte)
    // erreichbare Menge zählt wie der Subgraph (sonst 2933 statt 1916). Im
    // Trace-Modus deaktiviert (der Regler ist durch die Budgets ersetzt).
    const { profile: depthProfile } = useDepthProfile(
      traceActive ? null : focus, focusFile ?? null, direction, mode, serverTypes,
    );

    // Read the latest name filter from a ref so the imperative handle (mount-only)
    // can clear it without being re-created on every keystroke.
    const nameFilterRef = useRef(nameFilter);
    nameFilterRef.current = nameFilter;

    useImperativeHandle(ref, () => ({
      fit: () => graphRef.current?.fit(),
      relayout: () => graphRef.current?.relayout(),
      exportPng: () => graphRef.current?.exportPng() ?? null,
      clearTransientFilters: () => {
        if (nameFilterRef.current) {
          setNameFilter('');
          return true;
        }
        return false;
      },
    }), []);

    // Derive the focus label from the loaded graph and reconcile the inspected
    // node + file filter against the fresh data.
    useEffect(() => {
      if (!data) return;
      const focusNode = data.nodes.find((n) => n.isFocus);
      if (focusNode) setFocusLabel(formatObjectDisplayName(focusNode.type, focusNode.label));
      setSelectedNode((prev) => (prev ? data.nodes.find((n) => n.id === prev.id) ?? null : null));
      setSelectedFile((prev) => (prev && data.nodes.some((n) => n.file === prev) ? prev : null));
      setSelectedCommunity((prev) => (prev !== null && data.nodes.some((n) => n.community === prev) ? prev : null));
      setHoveredCommunity(null);
      // Eine offene Typ-Liste schließen, wenn der Typ im neuen Graph fehlt.
      setTypeListType((prev) => (prev && data.nodes.some((n) => n.type === prev) ? prev : null));
    }, [data]);

    // Fokus-Knoten (uuid + file) für den „⧉ Details"-Link (Verfeinerung A).
    const focusNode = useMemo(() => data?.nodes.find((n) => n.isFocus) ?? null, [data]);

    // Direkte Nachbarn des Fokus nach Richtung (aus den geladenen Kanten). Speist
    // den Richtungs-Filter der Typ-Liste: 'out' = Fokus → Knoten („verwendet"),
    // 'in' = Knoten → Fokus („verwendet von"). Knoten >1 Hop entfernt liegen in
    // keiner Menge und erscheinen nur unter „beide".
    const focusAdjacency = useMemo(() => {
      const out = new Set<string>();
      const inc = new Set<string>();
      // Rolle der jeweiligen Fokus-Kante je Nachbar-ID (erste gewinnt bei
      // Mehrfachkanten) — speist den Rollen-Klartext + Tooltip der Typ-Liste.
      const roleOut = new Map<string, string>();
      const roleIn = new Map<string, string>();
      const fid = focusNode?.id;
      if (data && fid) {
        for (const e of data.edges) {
          if (e.source === fid) {
            out.add(e.target);
            if (!roleOut.has(e.target)) roleOut.set(e.target, e.role);
          } else if (e.target === fid) {
            inc.add(e.source);
            if (!roleIn.has(e.source)) roleIn.set(e.source, e.role);
          }
        }
      }
      return { out, inc, roleOut, roleIn };
    }, [data, focusNode]);

    // Report stats to the host toolbar. Kanten-Zahl = GRUPPIERTE (gerenderte)
    // Kanten (Nutzerentscheid): parallele Event-Kanten desselben Paars und
    // reziproke Doppel zählen wie im Canvas — nicht die rohen Server-Zeilen.
    useEffect(() => {
      onStats?.(
        data
          ? {
              nodeCount: data.stats.nodeCount,
              edgeCount: subgraphToElements(data.nodes, data.edges)
                .filter((el) => (el.data as { source?: string }).source !== undefined).length,
              totalReachable: data.stats.totalReachable,
              truncated: data.truncated,
              communityCount: new Set(
                data.nodes.filter((n) => n.community !== null).map((n) => n.community),
              ).size,
              focusLabel: (() => { const f = data.nodes.find((n) => n.isFocus); return f ? formatObjectDisplayName(f.type, f.label) : null; })(),
            }
          : null,
      );
    }, [data, onStats]);

    // Type chips: counts from the current graph, unioned with any deselected types.
    const availableTypes = useMemo(() => {
      const counts = new Map<string, number>();
      for (const n of data?.nodes ?? []) counts.set(n.type, (counts.get(n.type) ?? 0) + 1);
      for (const ty of deselectedTypes) if (!counts.has(ty)) counts.set(ty, 0);
      return [...counts.entries()]
        .map(([type, count]) => ({ type, count }))
        .sort((a, b) => b.count - a.count || a.type.localeCompare(b.type));
    }, [data, deselectedTypes]);

    // Clicking a chip toggles its type in the *exclusion* set. Im „Alle Typen"-Modus
    // (serverTypes === null) dimmt/versteckt das nur client-seitig. Im „Nur gewählte
    // Typen"-Modus definiert die Auswahl den Ladefilter → die neue Auswahl wird
    // server-seitig nachgeladen (Achse A, Klick-Matrix).
    const handleToggleType = useCallback((type: string) => {
      setDeselectedTypes((prev) => {
        const next = prev.includes(type) ? prev.filter((x) => x !== type) : [...prev, type];
        if (serverTypes !== null) {
          const selected = availableTypes.map((tt) => tt.type).filter((ty) => !next.includes(ty));
          // Leere Auswahl wäre sinnlos → Fallback „Alle Typen".
          setServerTypes(selected.length > 0 ? selected : null);
        }
        return next;
      });
    }, [serverTypes, availableTypes]);

    // File filter options — distinct files present in the current graph.
    const availableFiles = useMemo(() => {
      const set = new Set<string>();
      for (const n of data?.nodes ?? []) if (n.file) set.add(n.file);
      return [...set].sort((a, b) => a.localeCompare(b));
    }, [data]);

    // Die Datei-Gruppierung ist nur sinnvoll, wenn der Graph mehr als eine Datei umfasst
    // (sonst eine einzige Box). Der gespeicherte Schalter-Wert bleibt erhalten, damit ein
    // Re-Fokus auf einen Mehrdatei-Graphen die Gruppierung wiederherstellt.
    const effectiveGroupByFile = groupByFile && availableFiles.length > 1;

    // Community legend — distinct communities in the current graph with
    // their palette color, display name and member count (most populous first).
    const availableCommunities = useMemo<CommunityLegendItem[]>(() => {
      const m = new Map<number, { name: string | null; count: number }>();
      for (const n of data?.nodes ?? []) {
        if (n.community === null) continue;
        const cur = m.get(n.community);
        if (cur) cur.count++;
        else m.set(n.community, { name: n.communityName, count: 1 });
      }
      return [...m.entries()]
        .map(([id, v]) => ({ id, name: v.name, count: v.count, color: getCommunityColor(id) }))
        .sort((a, b) => b.count - a.count || a.id - b.id);
    }, [data]);

    // Verfeinerung B — Objekte des in der Typ-Liste gewählten Typs (aus dem aktuellen
    // Graph; deckungsgleich mit dem Chip-Zähler). Sortierung clientseitig.
    // Richtungs-Zähler der Typ-Liste (Name-Filter berücksichtigt, Richtungs-Filter
    // NICHT) — beschriftet die Buttons und entscheidet, ob der Filter sinnvoll ist.
    const typeListDirCounts = useMemo(() => {
      if (!data || !typeListType) return { in: 0, out: 0, total: 0 };
      const nf = nameFilter.trim().toLowerCase();
      let inC = 0, outC = 0, total = 0;
      for (const n of data.nodes) {
        if (n.type !== typeListType) continue;
        if (nf && !n.label.toLowerCase().includes(nf)) continue;
        total++;
        if (focusAdjacency.inc.has(n.id)) inC++;
        if (focusAdjacency.out.has(n.id)) outC++;
      }
      return { in: inC, out: outC, total };
    }, [data, typeListType, nameFilter, focusAdjacency]);

    // Richtungs-Filter zeigen, sobald überhaupt eine Richtung vertreten ist
    // (eine Typ-Liste ist oft komplett eingehend ODER ausgehend — z.B. nur
    // Aufrufer eines Scripts). Die leere Richtung wird im Panel deaktiviert.
    const showTypeListDir = typeListDirCounts.in > 0 || typeListDirCounts.out > 0;

    const typeListItems = useMemo<GraphNode[]>(() => {
      if (!data || !typeListType) return [];
      // Die Sucheingabe (nameFilter) filtert auch die Objektliste (Label-Substring).
      const nf = nameFilter.trim().toLowerCase();
      // Bei verstecktem Filter (nur eine Richtung vorhanden) nicht filtern, damit
      // ein „hängender" Richtungswert keine Einträge unsichtbar macht.
      const dir = showTypeListDir ? typeListDir : 'both';
      const items = data.nodes.filter(
        (n) => n.type === typeListType
          && (!nf || n.label.toLowerCase().includes(nf))
          && (dir === 'both'
              || (dir === 'in' && focusAdjacency.inc.has(n.id))
              || (dir === 'out' && focusAdjacency.out.has(n.id))),
      );
      const cmp = typeListSort === 'file'
        ? (a: GraphNode, b: GraphNode) =>
            (a.file ?? '').localeCompare(b.file ?? '') || a.label.localeCompare(b.label)
        : (a: GraphNode, b: GraphNode) => a.label.localeCompare(b.label);
      return [...items].sort(cmp);
    }, [data, typeListType, typeListSort, nameFilter, typeListDir, showTypeListDir, focusAdjacency]);

    // Pro Typ-Listen-Eintrag: Richtung relativ zum Fokus (←/→/↔) + Rolle der
    // Fokus-Kante. Der Fokus selbst und indirekte Knoten (>1 Hop, kein direkter
    // Fokus-Bezug) fehlen bewusst → das Panel zeigt dort keinen Pfeil.
    const typeListDirInfo = useMemo(() => {
      const m = new Map<string, { dir: TypeListDir; role: string | null }>();
      for (const n of typeListItems) {
        const isIn = focusAdjacency.inc.has(n.id);
        const isOut = focusAdjacency.out.has(n.id);
        if (isIn && isOut) {
          m.set(n.id, { dir: 'both', role: focusAdjacency.roleOut.get(n.id) ?? focusAdjacency.roleIn.get(n.id) ?? null });
        } else if (isIn) {
          m.set(n.id, { dir: 'in', role: focusAdjacency.roleIn.get(n.id) ?? null });
        } else if (isOut) {
          m.set(n.id, { dir: 'out', role: focusAdjacency.roleOut.get(n.id) ?? null });
        }
      }
      return m;
    }, [typeListItems, focusAdjacency]);

    // Hamburger-Klick auf einem Typ-Chip → Liste öffnen (schließt das Node-Inspect).
    const handleOpenTypeList = useCallback((type: string) => {
      setSelectedNode(null);
      graphRef.current?.highlightNode(null);
      setTypeListType(type);
      setTypeListDir('both');
    }, []);

    // Node-Tap → Inspect öffnen (schließt eine offene Typ-Liste).
    const handleSelectNode = useCallback((node: GraphNode | null) => {
      if (node) setTypeListType(null);
      setSelectedNode(node);
    }, []);

    // Hover über einen Listeneintrag → transiente Vorschau-Hervorhebung im Graph.
    const handleHoverItem = useCallback((graphId: string | null) => {
      graphRef.current?.previewNode(graphId);
    }, []);

    // Verfeinerung C — aktuelle Client-Typ-Auswahl serverseitig anwenden (Refetch lädt
    // bis node_limit NUR die gewählten Typen → der Deckel deckt sie voll ab).
    const handleApplyServerTypes = useCallback(() => {
      const selected = availableTypes
        .map((t) => t.type)
        .filter((ty) => !deselectedTypes.includes(ty));
      setServerTypes(selected.length > 0 ? selected : null);
    }, [availableTypes, deselectedTypes]);

    // „Alle Typen anzeigen": Client-Abwahl UND den Server-Filter zurücksetzen.
    const handleShowAllTypes = useCallback(() => {
      setDeselectedTypes([]);
      setServerTypes(null);
    }, []);

    // Verfeinerung D — effektiver Schieberegler-Maximalwert.
    const sliderDepthMax = useMemo(() => {
      const cap = depthProfile?.hardCap ?? 16;
      if (!depthExtended) return DEFAULT_DEPTH_MAX;
      const reachable = depthProfile?.maxDepth ?? DEFAULT_DEPTH_MAX;
      return Math.min(Math.max(reachable, DEFAULT_DEPTH_MAX), cap);
    }, [depthExtended, depthProfile]);

    // Tiefe einklemmen, wenn die Erweiterung deaktiviert wird (depth darf nicht >max bleiben).
    useEffect(() => {
      if (depth > sliderDepthMax) onDepthChange(sliderDepthMax);
    }, [sliderDepthMax, depth, onDepthChange]);

    // The lens is only meaningful when clustering data is present in this graph.
    const communityLensActive = enableCommunityLens && availableCommunities.length > 0;
    const effectiveColorMode: ColorMode = communityLensActive ? colorMode : 'type';

    // Don't strand the lens on a graph without community data — revert to type.
    useEffect(() => {
      if (!communityLensActive && colorMode === 'community') setColorMode('type');
    }, [communityLensActive, colorMode]);

    // Leaving community color mode clears any community selection/hover.
    useEffect(() => {
      if (colorMode !== 'community') {
        setSelectedCommunity(null);
        setHoveredCommunity(null);
      }
    }, [colorMode]);

    // Click a legend entry → toggle that community as the selected one.
    const handleSelectCommunity = useCallback((id: number) => {
      setSelectedCommunity((prev) => (prev === id ? null : id));
    }, []);

    // Neighbors of the inspected node, derived from the loaded edges (no fetch).
    // Parallel-Kanten (gleiche Rolle, verschiedene Subroles — z. B. mehrere
    // Trigger-Events) falten zu EINER Zeile und sammeln die Subroles fürs
    // Detail-Label im Panel.
    const neighbors = useMemo<InspectNeighbor[]>(() => {
      if (!data || !selectedNode) return [];
      const byId = new Map(data.nodes.map((n) => [n.id, n]));
      const rows = new Map<string, InspectNeighbor>();
      for (const e of data.edges) {
        let otherId: string | null = null;
        let dir: 'out' | 'in' | null = null;
        if (e.source === selectedNode.id) { otherId = e.target; dir = 'out'; }
        else if (e.target === selectedNode.id) { otherId = e.source; dir = 'in'; }
        if (!otherId || !dir) continue;
        const key = `${dir}-${otherId}-${e.role}`;
        const existing = rows.get(key);
        if (existing) {
          if (e.subrole && !existing.subroles.includes(e.subrole)) existing.subroles.push(e.subrole);
          continue;
        }
        const otherNode = byId.get(otherId);
        if (!otherNode) continue;
        rows.set(key, { node: otherNode, role: e.role, direction: dir, subroles: e.subrole ? [e.subrole] : [] });
      }
      const out = [...rows.values()];
      for (const r of out) r.subroles.sort();
      return out.sort((a, b) => a.node.label.localeCompare(b.node.label));
    }, [data, selectedNode]);

    const handleSelectNeighbor = useCallback((n: GraphNode) => {
      setSelectedNode(n);
      graphRef.current?.highlightNode(n.id);
    }, []);

    const handleExpand = useCallback(
      async (uuid: string, file?: string | null) => {
        setExpanding(true);
        try {
          // Fetch the full neighborhood — type filtering happens client-side.
          // Klon-Disambiguierung: focusFile mitgeben, sonst 409/Klon-Merge beim Nachbar-Fetch.
          const { nodes, edges } = await fetchNeighbors(uuid, { direction, mode, focusFile: file ?? null });
          graphRef.current?.mergeElements(nodes, edges);
        } catch {
          // Expansion is best-effort; a failed merge leaves the graph untouched.
        } finally {
          setExpanding(false);
        }
      },
      [direction, mode],
    );

    const handleCollapse = useCallback((uuid: string) => {
      graphRef.current?.collapseHub(uuid);
    }, []);

    return (
      <div className="graph-explorer-body">
        <ExplorerFilterPanel
          width={leftWidth}
          focusLabel={focusLabel}
          focusUuid={focusNode?.uuid ?? null}
          focusFile={focusNode?.file ?? null}
          nameFilter={nameFilter}
          selectedFile={selectedFile}
          filterMode={filterMode}
          depth={depth}
          depthMax={sliderDepthMax}
          maxDepth={depthProfile?.maxDepth ?? null}
          maxDepthHitCap={depthProfile?.hitCap ?? false}
          depthExtended={depthExtended}
          canExtendDepth={(depthProfile?.maxDepth ?? 0) > DEFAULT_DEPTH_MAX}
          depthCumulative={depthProfile?.perDepth ?? null}
          nodeLimit={NODE_LIMIT}
          direction={direction}
          partition={partition}
          deselectedTypes={deselectedTypes}
          availableTypes={availableTypes}
          availableFiles={availableFiles}
          groupByFile={groupByFile}
          serverTypesActive={serverTypes !== null}
          showColorMode={communityLensActive}
          colorMode={colorMode}
          communities={availableCommunities}
          selectedCommunity={selectedCommunity}
          onOpenFocusDetails={onOpenDetails}
          onOpenTypeList={handleOpenTypeList}
          onNameFilterChange={setNameFilter}
          onSelectedFileChange={setSelectedFile}
          onGroupByFileChange={onGroupByFileChange ?? (() => {})}
          onFilterModeChange={setFilterMode}
          onColorModeChange={setColorMode}
          onSelectCommunity={handleSelectCommunity}
          onHoverCommunity={setHoveredCommunity}
          onDepthChange={onDepthChange}
          onExtendDepthChange={setDepthExtended}
          onDirectionChange={onDirectionChange}
          onToggleType={handleToggleType}
          onShowAllTypes={handleShowAllTypes}
          onApplyServerTypes={handleApplyServerTypes}
          traceControls={trace ? (
            <ExplorerTracePanel
              values={{
                upDepth: trace.upDepth,
                downDepth: trace.downDepth,
                triggerDepth: trace.triggerDepth,
                expandUp: trace.expandUp,
                includeLocalVars: trace.includeLocalVars,
                includeButtons: trace.includeButtons,
            includeInteractionTriggers: trace.includeInteractionTriggers,
              }}
              entry={trace.entry ?? traceData?.trace.entry ?? null}
              entries={traceEntries}
              excluded={traceExcludedChips}
              suggestions={traceSuggestionChips}
              onChange={(patch) => onTraceParamsChange?.(patch)}
              onEntryChange={(e) => onTraceParamsChange?.({ entry: e })}
              onRemoveExclude={handleToggleExclude}
              onClearExcludes={() => onTraceParamsChange?.({ exclude: [] })}
              onApplySuggestion={handleToggleExclude}
              onApplyAllSuggestions={handleApplyAllSuggestions}
              onExitTrace={() => onSetFocus(trace.start, trace.startFile ?? null)}
            />
          ) : undefined}
        />

        <div
          className="explorer-resizer explorer-resizer-left"
          role="separator"
          aria-orientation="vertical"
          aria-label={t('filter.resizePanel', { defaultValue: 'Breite des Filter-Panels ändern' }) as string}
          title={t('filter.resizePanel', { defaultValue: 'Breite des Filter-Panels ändern' }) as string}
          onPointerDown={onResizeLeft}
          onDoubleClick={() => setLeftWidth(LEFT_PANEL_DEFAULT)}
        />

        <main className="graph-explorer-canvas-wrap">
          {data?.truncated && (
            <div className="graph-explorer-banner" role="status">
              {/* Reiner Hinweis — der Lade-Umfang („Alle Typen / Nur gewählte Typen")
                  steuert das Nachladen jetzt im KNOTENTYPEN-Bereich, nicht hier. */}
              {/* Bei minimaler Tiefe ist „Tiefe verringern" eine Sackgasse (Regler steht
                  schon auf 1) — dann nur den weiterhin wirksamen Typ-Filter empfehlen. Die
                  gehaltenen Knoten sind serverseitig die grad-stärksten je Tiefe. */}
              <span>
                {t(traceActive
                  ? 'explorer:trace.truncated'
                  : depth <= 1 ? 'explorer:truncatedMinDepth' : 'explorer:truncated', {
                  kept: data.stats.nodeCount,
                  total: data.stats.totalReachable,
                })}
              </span>
            </div>
          )}

          {/* Blind-Spot-Ausweis des Trace: dynamische Calls (by name) haben keine
              Kante — der Graph ist eine statische Approximation. */}
          {traceData && traceData.stats.dynamicCalls > 0 && (
            <div className="graph-explorer-banner" role="status">
              <span>{t('explorer:trace.dynamicCalls', { count: traceData.stats.dynamicCalls })}</span>
            </div>
          )}

          {!focus && !traceActive && (
            <div className="graph-explorer-placeholder">
              <p>{t('explorer:emptyFocus')}</p>
            </div>
          )}

          {(focus || traceActive) && error && (
            <div className="graph-explorer-error">{t('common:loadError', { message: error })}</div>
          )}

          {/* Layout-Start ohne gewähltes Preset (oder Preset ohne Seeds) —
              Einstiegspfad-Auswahl statt Graph. */}
          {traceChooser && !error && (
            <ExplorerTraceEntryChooser
              entries={traceResult.emptyEntries ?? traceEntries ?? []}
              emptyEntry={traceResult.emptyEntries !== null}
              onChoose={(e) => onTraceParamsChange?.({ entry: e })}
            />
          )}

          {(focus || traceActive) && !error && !traceChooser && loading && !data && (
            <div className="graph-explorer-placeholder">{t('explorer:loading')}</div>
          )}

          {(focus || traceActive) && !error && !traceChooser && (
            <ExplorerGraph
              ref={graphRef}
              data={data}
              nameFilter={nameFilter}
              selectedFile={selectedFile}
              filterMode={filterMode}
              deselectedTypes={deselectedTypes}
              colorMode={effectiveColorMode}
              groupByFile={effectiveGroupByFile}
              selectedCommunity={communityLensActive ? selectedCommunity : null}
              hoveredCommunity={communityLensActive ? hoveredCommunity : null}
              onSetFocus={onSetFocus}
              onOpenDetails={onOpenDetails}
              onSelectNode={handleSelectNode}
              showUnconnected={showUnconnected}
              onPartition={setPartition}
            />
          )}

          {loading && data && <div className="graph-explorer-loading-pill">{t('explorer:loading')}</div>}

          {/* Nicht mit dem Fokus verbundene Knoten (Inseln + isolierte): dezenter Hinweis
              + Einblenden-Toggle (Default: ausgeblendet). */}
          {partition && (partition.island + partition.isolated) > 0 && (
            <div className="graph-explorer-isolated-pill">
              <span>
                {t('explorer:unconnectedHidden', {
                  count: partition.island + partition.isolated,
                  defaultValue_one: '{{count}} Knoten ohne Verbindung zum Fokus',
                  defaultValue_other: '{{count}} Knoten ohne Verbindung zum Fokus',
                  defaultValue: '{{count}} Knoten ohne Verbindung zum Fokus',
                })}
              </span>
              <button
                type="button"
                onClick={() => setShowUnconnected((s) => !s)}
                title={t('explorer:unconnectedToggleHint', {
                  defaultValue: 'Knoten ohne Pfad zum Fokus entstehen durch den Typ-/Tiefenfilter — ein- oder ausblenden',
                }) as string}
              >
                {showUnconnected
                  ? t('explorer:unconnectedToggleHide', { defaultValue: 'ausblenden' })
                  : t('explorer:unconnectedToggleShow', { defaultValue: 'einblenden' })}
              </button>
            </div>
          )}
        </main>

        {/* Anfasser zum rechten Slot — nur wenn ein Panel offen ist. */}
        {(typeListType || selectedNode) && (
          <div
            className="explorer-resizer explorer-resizer-right"
            role="separator"
            aria-orientation="vertical"
            aria-label={t('inspect.resizePanel', { defaultValue: 'Breite des Detail-Panels ändern' }) as string}
            title={t('inspect.resizePanel', { defaultValue: 'Breite des Detail-Panels ändern' }) as string}
            onPointerDown={onResizeRight}
            onDoubleClick={() => setRightWidth(RIGHT_PANEL_DEFAULT)}
          />
        )}

        {/* Rechter Slot — Typ-Liste hat Vorrang (zuletzt geöffnet), sonst Node-Inspect. */}
        {typeListType ? (
          <ExplorerTypeListPanel
            width={rightWidth}
            type={typeListType}
            items={typeListItems}
            sort={typeListSort}
            onSortChange={setTypeListSort}
            dir={typeListDir}
            dirCounts={typeListDirCounts}
            dirInfo={typeListDirInfo}
            focusFile={focusNode?.file ?? null}
            showDir={showTypeListDir}
            onDirChange={setTypeListDir}
            onClose={() => {
              setTypeListType(null);
              graphRef.current?.previewNode(null);
            }}
            onOpenDetails={onOpenDetails}
            onHoverItem={handleHoverItem}
            // Exclude-Toggle je Listenzeile — Gate am Panel (ein Typ pro
            // Instanz): nur im Trace-Modus und nur für ausschließbare Typen.
            onToggleExclude={
              traceActive && EXCLUDABLE_TYPES.has(typeListType)
                ? handleToggleExclude
                : undefined
            }
          />
        ) : selectedNode ? (
          <ExplorerInspectPanel
            width={rightWidth}
            node={selectedNode}
            neighbors={neighbors}
            expanding={expanding}
            onClose={() => {
              setSelectedNode(null);
              graphRef.current?.highlightNode(null);
            }}
            onOpenDetails={onOpenDetails}
            onSetFocus={onSetFocus}
            onExpand={handleExpand}
            onCollapse={handleCollapse}
            onSelectNeighbor={handleSelectNeighbor}
            onTrace={onOpenTrace}
            onToggleExclude={traceActive ? handleToggleExclude : undefined}
            nodeExcluded={trace?.exclude.includes(selectedNode.id) ?? false}
          />
        ) : null}
      </div>
    );
  },
);

GraphExplorer.displayName = 'GraphExplorer';
