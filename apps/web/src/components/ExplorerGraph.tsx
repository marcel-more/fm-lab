import {
  forwardRef,
  useImperativeHandle,
  useMemo,
  useRef,
  useEffect,
  useState,
} from 'react';
import { useTranslation } from 'react-i18next';
import cytoscape from 'cytoscape';
import type { GraphNode, GraphEdge } from '../hooks/useSubgraph';
import { subgraphToElements } from '../hooks/useSubgraph';
import { getCommunityColor, readGraphThemeTokens } from '../lib/graphColors';
import { useTheme } from '../hooks/useTheme';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import { makeEdgeLabeler, edgeTooltipLines, type EdgeLabelStrings } from '../lib/graphEdgeLabels';

/**
 * Graph-Explorer canvas.
 *
 * Renders the focus-centered subgraph with an `fcose` force-directed layout
 * (lazy-loaded for code-splitting). The Cytoscape instance is created once and
 * its elements are replaced whenever `data` changes. Nodes are drawn as
 * degree-scaled circles with labels only on hubs / focus /
 * hover / selection. Name- and type-filters work purely client-side (visibility
 * toggles, no re-layout); a single tap re-centers (`onSetFocus`) and ⌘/Ctrl-tap
 * opens the object in the DetailView (`onOpenDetails`).
 */

/** How the soft filters (name / file) treat non-matching nodes. */
export type FilterMode = 'dim' | 'hide';
/** Node color lens: by object type (default) or by P5 community. */
export type ColorMode = 'type' | 'community';

/**
 * Stable connectivity breakdown of the loaded subgraph — a topology property of
 * the loaded nodes/edges (independent of soft view filters), so the three counts
 * always sum to `loaded`. Single source of truth for the "geladen = verbunden +
 * Inseln + isoliert" hint, the isolated pill, and the "Nur verbunden" hide pass.
 */
export interface GraphPartition {
  /** Total real nodes loaded (focus + neighbors), halos excluded. */
  loaded: number;
  /** Reachable from the focus over loaded edges (includes the focus itself). */
  connectedToFocus: number;
  /** Degree ≥ 1 but no path to the focus — small islands the filter cut loose. */
  island: number;
  /** Degree 0 — edgeless filter-orphans. */
  isolated: number;
}

export interface ExplorerGraphHandle {
  /** Fit the whole graph into the viewport. */
  fit: () => void;
  /** Re-run the force layout from scratch. */
  relayout: () => void;
  /** Export the current canvas as a PNG data-URL (full graph, transparent bg). */
  exportPng: () => string | null;
  /** Merge expand results into the graph without re-fetching (1-hop expand). */
  mergeElements: (nodes: GraphNode[], edges: GraphEdge[]) => void;
  /** Collapse a hub: drop its leaf neighbors (only reachable via this hub). */
  collapseHub: (uuid: string) => void;
  /** Mark a node as the inspected one (selection ring) without re-centering. */
  highlightNode: (uuid: string | null) => void;
  /** Transiente Vorschau-Hervorhebung (Hover über die Typ-Liste). Eigene Klasse,
   *  damit eine aktive Klick-Auswahl (.selected) nicht überschrieben wird. */
  previewNode: (id: string | null) => void;
}

/**
 * Minimaler Daten-Vertrag der Canvas — Subgraph- UND Trace-Antworten erfüllen
 * ihn (die Trace-Zusatzfelder reisen als optionale Member auf Node/Edge mit).
 */
export type ExplorerGraphData = { nodes: GraphNode[]; edges: GraphEdge[] };

interface ExplorerGraphProps {
  data: ExplorerGraphData | null;
  /** Client-side name filter — non-matching nodes are dimmed or hidden (focus stays). */
  nameFilter: string;
  /** Client-side file filter (null = all files) — non-matching nodes dimmed/hidden. */
  selectedFile: string | null;
  /** Whether name/file non-matches are dimmed (default) or removed. */
  filterMode: FilterMode;
  /** Deselected node types (exclusion set) — these are hidden; focus always stays. */
  deselectedTypes: string[];
  /** Node color lens — 'type' (default) or 'community' (standalone färb-lens). */
  colorMode?: ColorMode;
  /** Datei-Gruppierung — Knoten in Compound-Boxen je Datei (Layout-Schalter). */
  groupByFile?: boolean;
  /** Selected community (hull + dims others); null = none. */
  selectedCommunity?: number | null;
  /** Hovered community (transient hull preview); null = none. */
  hoveredCommunity?: number | null;
  /** Double tap on a node — re-center the graph on it. (file = Klon-Disambiguierung) */
  onSetFocus: (uuid: string, file?: string | null) => void;
  /** ⌘/Ctrl tap on a node — open it in the DetailView. (file = Klon-Disambiguierung) */
  onOpenDetails: (uuid: string, file?: string | null) => void;
  /** Single tap selects a node — parent shows its metadata in the inspect panel. */
  onSelectNode?: (node: GraphNode | null) => void;
  /** Nicht mit dem Fokus verbundene Knoten (Inseln + isolierte) anzeigen. Default
   *  false → ausgeblendet (sonst kachelt fcose isolierte in ein Raster). */
  showUnconnected?: boolean;
  /** Meldet die stabile Konnektivitäts-Partition der geladenen Knoten (null = leer). */
  onPartition?: (partition: GraphPartition | null) => void;
}

// fcose has no bundled type declarations; register it once, lazily, so the
// ~heavy layout code is split out of the main bundle.
let fcoseReady: Promise<void> | null = null;
function ensureFcose(): Promise<void> {
  if (!fcoseReady) {
    fcoseReady = import('cytoscape-fcose').then((mod) => {
      cytoscape.use(mod.default ?? mod);
    });
  }
  return fcoseReady;
}

// Layout tuning: more breathing room, components packed.
const fcoseLayout = {
  name: 'fcose',
  quality: 'default',
  animate: false,
  randomize: true,
  nodeRepulsion: 12000,
  idealEdgeLength: 120,
  nodeSeparation: 110,
  gravity: 0.15,
  gravityRange: 3.8,
  packComponents: true,
  padding: 40,
} as unknown as cytoscape.LayoutOptions;

// Variante für die Datei-Gruppierung: ruhiger/dichter. Weniger Abstoßung & Separation, kürzere
// Kanten und kein hartes Komponenten-Packing → die Compound-Boxen rücken näher zusammen und dürfen
// sich etwas überlappen, statt weit auseinandergedrückt zu werden.
const fcoseLayoutGrouped = {
  ...fcoseLayout,
  nodeRepulsion: 7000,
  idealEdgeLength: 90,
  nodeSeparation: 70,
  gravity: 0.25,
  packComponents: false,
  padding: 30,
} as unknown as cytoscape.LayoutOptions;

// Ab dieser Knotenzahl wird das Force-Layout gedeckelt (siehe layoutFor). Grad-starke
// Hubs bringen bis zum Ladedeckel (node_limit) einige hundert bis tausend Knoten mit;
// ein Force-Layout in voller Qualität läuft dann als schwerer, teils wiederholter
// synchroner Durchlauf und lässt die Canvas sichtbar flackern. Bis in die Größenordnung
// einiger hundert Nachbarn bleibt das Layout unverändert.
const LARGE_GRAPH_NODES = 400;
// Gedeckeltes Profil für große Graphen: geringere Qualität + fixe Iterationszahl statt
// des adaptiven Default-Refinements, damit der Layout-Lauf beschränkt und einmalig bleibt.
const fcoseLayoutLarge = {
  ...fcoseLayout,
  quality: 'draft',
  numIter: 1000,
} as unknown as cytoscape.LayoutOptions;
const fcoseLayoutGroupedLarge = {
  ...fcoseLayoutGrouped,
  quality: 'draft',
  numIter: 1000,
} as unknown as cytoscape.LayoutOptions;

/**
 * Layout-Profil je nach aktiver Datei-Gruppierung (ruhiger im Gruppen-Modus) und
 * Graphgröße: ab LARGE_GRAPH_NODES ein gedeckeltes Profil (Draft-Qualität, feste
 * Iterationszahl), sonst das volle Profil. `nodeCount` optional → ohne Angabe (bzw.
 * unterhalb der Schwelle) bleibt das Verhalten wie bisher.
 */
function layoutFor(grouped: boolean, nodeCount = 0): cytoscape.LayoutOptions {
  if (nodeCount >= LARGE_GRAPH_NODES) {
    return grouped ? fcoseLayoutGroupedLarge : fcoseLayoutLarge;
  }
  return grouped ? fcoseLayoutGrouped : fcoseLayout;
}

/** Zahl echter Objekt-Knoten (ohne Halos/Datei-Boxen) — Schwellwert-Eingang für layoutFor. */
function realNodeCount(cy: cytoscape.Core): number {
  return selectRealNodes(cy).length;
}

// Degree-scaled diameter: 12 px (leaf) … 48 px (max-degree hub).
const NODE_MIN_PX = 12;
const NODE_RANGE_PX = 36;
// Persistent label only for "important" nodes (≥15 % maxDeg).
const LABEL_DEGREE_FRACTION = 0.15;

// ── Datei-Gruppierung (Compound-Boxen) ───────────────────────────
// Ein synthetischer Parent-Node je Datei; `file === null` (synthetische Objekte) bekommt
// eine eigene Box. Die `id` ist deterministisch aus dem Dateinamen abgeleitet, getrennt vom
// Halo-Prefix. Knoten werden via `node.move({ parent })` ein-/ausgehängt (kein Refetch).
const FILE_GROUP_ID_PREFIX = '__file__::';
const FILE_GROUP_NULL_ID = '__file__::__null__';
const FILE_GROUP_CLASS = 'file-group';

/**
 * Theme-aware Stylesheet: aus den `--color-graph-*`-Tokens gebaut. Cytoscape-
 * Stylesheets sind statische JS-Objekte und kennen keine CSS-Vars — die Tokens
 * werden hier JS-seitig (getComputedStyle) aufgelöst und das Stylesheet bei jedem
 * Theme-Wechsel via `cy.style()` neu gesetzt (ohne Re-Layout). Akzent-/State-Farben
 * (Fokus-Ring #646cff, Auswahl #ffd54f, Halo/Preview #ff3b30, Cross-File-Orange)
 * bleiben hartkodiert — sie liegen auf eingefärbten Knoten und lesen in beiden Themes.
 */
function buildExplorerStylesheet(): cytoscape.StylesheetStyle[] {
  const g = readGraphThemeTokens();
  return [
  {
    selector: 'node',
    style: {
      // Hidden by default — only hubs/focus/hover/selection reveal a label.
      'label': '',
      'text-valign': 'bottom',
      'text-halign': 'center',
      'text-margin-y': 4,
      'font-size': '11px',
      'font-family': 'system-ui, -apple-system, sans-serif',
      'color': g.nodeLabel,
      'text-outline-width': 2,
      'text-outline-color': g.nodeOutline,
      'text-wrap': 'wrap',
      'text-max-width': '120px',
      'width': 'data(sizePx)',
      'height': 'data(sizePx)',
      'shape': 'ellipse',
      'background-color': 'data(color)',
      'border-width': 1.5,
      'border-color': 'data(color)',
      'cursor': 'pointer',
    } as unknown as cytoscape.Css.Node,
  },
  // High-degree nodes carry a permanent label.
  {
    selector: 'node[?showLabel]',
    style: { 'label': 'data(label)' } as unknown as cytoscape.Css.Node,
  },
  // Datei-Gruppe (Compound-Parent): neutrale, einheitliche Box (NICHT je Datei eingefärbt) mit
  // Datei-Label oben links. Compound-Parents sizen sich automatisch auf ihre Kinder (+ padding);
  // width/height aus dem Basis-`node`-Style werden dabei ignoriert.
  {
    selector: 'node[?isFileGroup]',
    style: {
      'shape': 'round-rectangle',
      'corner-radius': '12px',
      'background-color': g.rest,
      'background-opacity': 0.07,
      'border-color': g.edgeStructural,
      'border-width': 1,
      'border-opacity': 0.7,
      'label': 'data(label)',
      'color': g.nodeLabel,
      // Doppelte Schriftgröße, als transparentes „Watermark"-Label (70 % transparent) oben mittig.
      'font-size': '22px',
      'font-weight': 'bold',
      'text-opacity': 0.3,
      'text-valign': 'top',
      'text-halign': 'center',
      'text-margin-y': 2,
      'text-outline-width': 2,
      'text-outline-color': g.nodeOutline,
      'padding': '18px',
      'z-index': 0,
      'cursor': 'grab',
    } as unknown as cytoscape.Css.Node,
  },
  // Über das Datei-Dropdown gewählte Datei: die zugehörige Box bekommt einen transluzenten
  // Akzent-Hintergrund (Hervorhebung). Muss NACH der Basis-`isFileGroup`-Regel stehen, damit
  // background-color/opacity gewinnen.
  {
    selector: 'node.file-group-selected',
    style: {
      'background-color': '#646cff',
      'background-opacity': 0.16,
      'border-color': '#646cff',
      'border-width': 1.5,
      'border-opacity': 0.9,
    } as unknown as cytoscape.Css.Node,
  },
  // Community color lens — recolor by P5 community when the standalone
  // färb-lens is on. Declared BEFORE the hub/focus/hover/selected rules so those
  // state borders still win; only the fill + the resting border switch to the
  // community color. Unclustered nodes carry the neutral gray (UNCLUSTERED_COLOR).
  {
    selector: 'node.color-community',
    style: {
      'background-color': 'data(communityColor)',
      'border-color': 'data(communityColor)',
    } as unknown as cytoscape.Css.Node,
  },
  // ── Trace-Modus (Knoten) — Styling nach traceRole (Daten-Attribut aus
  // /api/graph/trace). Chain betont, Kaskade markiert, Kontext zurückgenommen;
  // 'touched' bleibt bewusst neutral (dezent = Grundzustand). Die Regeln stehen
  // VOR hub/focus/hover/selected, damit deren State-Ringe weiterhin gewinnen.
  {
    selector: 'node[traceRole = "chain_down"], node[traceRole = "chain_up"]',
    style: {
      'border-width': 2.5,
      'border-color': '#646cff',
    } as unknown as cytoscape.Css.Node,
  },
  {
    selector: 'node[traceRole = "triggered"]',
    style: {
      'border-width': 3,
      'border-style': 'double',
      'border-color': '#b45ce8',
    } as unknown as cytoscape.Css.Node,
  },
  {
    selector: 'node[traceRole = "trigger_touched"]',
    style: { 'opacity': 0.8 } as unknown as cytoscape.Css.Node,
  },
  {
    selector: 'node[traceRole = "trigger_owner"]',
    style: {
      'opacity': 0.55,
      'border-style': 'dashed',
    } as unknown as cytoscape.Css.Node,
  },
  // Boundary-Knoten (Exclude-Liste): sichtbar, aber nicht expandiert.
  // Steht NACH den traceRole-Regeln (Ausschluss übermalt die Rolle), aber vor
  // hub/focus/hover/selected, damit deren State-Ringe weiterhin gewinnen.
  {
    selector: 'node[?traceExcluded]',
    style: {
      'opacity': 0.45,
      'border-width': 2.5,
      'border-style': 'dashed',
      'border-color': '#e8a33d',
    } as unknown as cytoscape.Css.Node,
  },
  // Hub node — bright accent border (no longer a diamond; all nodes are circles).
  {
    selector: 'node[?isHub]',
    style: {
      'border-width': 2.5,
      'border-color': '#ffffff',
    } as unknown as cytoscape.Css.Node,
  },
  // Focus node — accent ring + bold, always labelled.
  {
    selector: 'node[?isFocus]',
    style: {
      'label': 'data(label)',
      'border-color': '#646cff',
      'border-width': 3,
      'font-weight': 'bold',
      'font-size': '12px',
    } as unknown as cytoscape.Css.Node,
  },
  // Hover neighborhood — reveal labels for context.
  {
    selector: 'node.nbr-hl',
    style: { 'label': 'data(label)' } as unknown as cytoscape.Css.Node,
  },
  // Hovered node itself — accent ring + label.
  {
    selector: 'node.hover',
    style: {
      'label': 'data(label)',
      'border-width': 3,
      'border-color': '#646cff',
    } as unknown as cytoscape.Css.Node,
  },
  // Selected (inspected) node — persistent ring while the inspect panel is open.
  {
    selector: 'node.selected',
    style: {
      'label': 'data(label)',
      'border-width': 4,
      'border-color': '#ffd54f',
    } as unknown as cytoscape.Css.Node,
  },
  // List-preview — transient hover highlight from the type-list panel. The node
  // itself shows its label + a bright red ring; a separate `.preview-halo` node
  // adds the red focus-style halo so the hovered object reads unmistakably.
  {
    selector: 'node.list-preview',
    style: {
      'label': 'data(label)',
      'border-width': 4,
      'border-color': '#ff3b30',
      'z-index': 31,
    } as unknown as cytoscape.Css.Node,
  },
  // Preview halo — red ring like the focus halo (but brighter/larger), spawned on
  // hover over a type-list entry. Non-interactive, sits outside the node.
  {
    selector: 'node.preview-halo',
    style: {
      'shape': 'ellipse',
      'width': 'data(haloSize)',
      'height': 'data(haloSize)',
      'background-opacity': 0,
      'border-color': '#ff3b30',
      'border-width': 4,
      'border-opacity': 0.85,
      'label': '',
      'events': 'no',
      'z-index': 30,
    } as unknown as cytoscape.Css.Node,
  },
  // Focus halo — a separate, non-interactive ring at 1.5× the focus node's radius
  // (red, 50 % opacity, double line width). A dedicated node so the ring sits
  // *outside* the focus node with a visible gap (user request).
  {
    selector: 'node.focus-halo',
    style: {
      'shape': 'ellipse',
      'width': 'data(haloSize)',
      'height': 'data(haloSize)',
      'background-opacity': 0,
      'border-color': '#ff3b30',
      'border-width': 3,
      'border-opacity': 0.5,
      'label': '',
      'events': 'no',
      'z-index': 0,
    } as unknown as cytoscape.Css.Node,
  },
  {
    selector: 'edge',
    style: {
      'width': 1,
      'line-color': g.edge,
      // Lighter arrowhead + full scale so the "uses" direction reads clearly.
      'target-arrow-color': g.edgeArrow,
      'target-arrow-shape': 'triangle',
      'arrow-scale': 1,
      'curve-style': 'bezier',
      'control-point-step-size': 40,
      'label': 'data(label)',
      'font-size': '8px',
      'color': g.edgeLabel,
      'text-rotation': 'autorotate',
      'text-background-color': g.edgeLabelBg,
      'text-background-opacity': 0.8,
      'text-background-padding': '2px',
      'font-family': 'system-ui, -apple-system, sans-serif',
    } as unknown as cytoscape.Css.Edge,
  },
  // Structural links — lighter, dotted (hierarchy, not a call/usage).
  {
    selector: 'edge[linkType = "structural"]',
    style: {
      'line-style': 'dotted',
      'line-color': g.edgeStructural,
      'target-arrow-color': '#9a9aa8',
    } as unknown as cytoscape.Css.Edge,
  },
  // ── Trace-Modus (Kanten) — traceKind aus /api/graph/trace. Trigger violett,
  // induzierte Kontext-Kanten gepunktet/blass; VOR der Cross-File-Regel, damit
  // das Datei-Grenzen-Orange auf solchen Kanten weiterhin gewinnt.
  {
    selector: 'edge[traceKind = "trigger"]',
    style: {
      'width': 2,
      'line-color': '#b45ce8',
      'target-arrow-color': '#b45ce8',
    } as unknown as cytoscape.Css.Edge,
  },
  {
    selector: 'edge[traceKind = "induced"]',
    style: {
      'line-style': 'dotted',
      'opacity': 0.45,
    } as unknown as cytoscape.Css.Edge,
  },
  // Cross-file links — orange dashed, slightly heavier.
  {
    selector: 'edge[?isCrossFile]',
    style: {
      'width': 1.5,
      'line-color': '#ff9800',
      'target-arrow-color': '#ffb74d',
      'line-style': 'dashed',
    } as unknown as cytoscape.Css.Edge,
  },
  // Chain-Kanten (calls_script im Trace) — breit betont; steht NACH der
  // Cross-File-Regel, damit die Breite auch dort greift (Farbe bleibt orange).
  {
    selector: 'edge[traceKind = "chain"]',
    style: { 'width': 3 } as unknown as cytoscape.Css.Edge,
  },
  // Name filter, "dim" mode — non-matches stay laid out but recede (spec refinement).
  {
    selector: '.name-dimmed',
    style: { 'opacity': 0.2 } as unknown as cytoscape.Css.Node,
  },
  // Hover dimming (strong fade of the non-neighborhood). Declared
  // after `.name-dimmed` so a hover fade wins over a filter dim on the same element.
  {
    selector: '.faded',
    style: { 'opacity': 0.12 } as unknown as cytoscape.Css.Node,
  },
  // Type exclusion + name filter "hide" mode — removed from layout + render,
  // positions kept.
  {
    selector: '.filtered-hidden',
    style: { 'display': 'none' } as unknown as cytoscape.Css.Node,
  },
  // Not-connected-to-focus nodes (islands + isolated) hidden by default — see applyUnconnectedVisibility.
  {
    selector: '.unconnected-hidden',
    style: { 'display': 'none' } as unknown as cytoscape.Css.Node,
  },
  ];
}

/** Recompute degree-scaled size + label visibility across all real nodes. */
function recomputeNodeVisuals(cy: cytoscape.Core): void {
  const realNodes = cy.nodes().not('.focus-halo').not(`.${FILE_GROUP_CLASS}`);
  let maxDeg = 0;
  realNodes.forEach((n) => {
    const d = (n.data('degree') as number) ?? 0;
    if (d > maxDeg) maxDeg = d;
  });
  const denom = Math.max(maxDeg, 1);
  cy.batch(() => {
    realNodes.forEach((n) => {
      const d = (n.data('degree') as number) ?? 0;
      n.data('sizePx', Math.round(NODE_MIN_PX + NODE_RANGE_PX * (d / denom)));
      n.data('showLabel', d >= LABEL_DEGREE_FRACTION * denom);
    });
  });
}

// ── Community hull overlay ────────────────────────────────────
// A selected community is wrapped in a translucent colored convex hull drawn on a
// canvas *behind* the cytoscape layers (so it reads as a background blob). A hover
// in the legend previews another hull on top and weakens the selected one.
const HULL_ALPHA_SELECTED = 0.12;
const HULL_ALPHA_HOVERED = 0.20;
const HULL_ALPHA_SELECTED_WEAK = 0.06;
const HULL_PAD_PX = 16;

/** Andrew's monotone-chain convex hull over screen-space points `[x,y][]`. */
function convexHull(points: number[][]): number[][] {
  if (points.length <= 2) return points.slice();
  const pts = points.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cross = (o: number[], a: number[], b: number[]) =>
    (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lower: number[][] = [];
  for (const p of pts) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) lower.pop();
    lower.push(p);
  }
  const upper: number[][] = [];
  for (let i = pts.length - 1; i >= 0; i--) {
    const p = pts[i];
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) upper.pop();
    upper.push(p);
  }
  lower.pop();
  upper.pop();
  return lower.concat(upper);
}

/**
 * Redraw the community hulls. Uses model→screen projection (`pos·zoom + pan`) so
 * it tracks pan/zoom and works even for `display:none`/faded nodes. A solid blob
 * is rendered on an offscreen canvas (alpha 1) and composited at the per-hull
 * alpha → uniform translucency without stroke/fill seams.
 */
function drawCommunityHulls(
  cy: cytoscape.Core,
  canvas: HTMLCanvasElement,
  off: HTMLCanvasElement,
  selected: number | null,
  hovered: number | null,
): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  // Bound the backing store: the standalone graph breaks out to full viewport
  // width, so on a hi-DPI wide screen an unclamped clientWidth·dpr canvas
  // (×2 with the offscreen) can reach hundreds of MB and OOM the renderer.
  const HULL_MAX_PX = 4096;
  const cw = canvas.clientWidth;
  const ch = canvas.clientHeight;
  if (cw < 2 || ch < 2) return; // not laid out yet
  // One `scale` for both the backing-store size AND the projection so the buffer
  // never exceeds HULL_MAX_PX per side (bounded memory) without clipping the hull.
  const scale = Math.min(window.devicePixelRatio || 1, 2, HULL_MAX_PX / cw, HULL_MAX_PX / ch);
  const pxW = Math.max(1, Math.round(cw * scale));
  const pxH = Math.max(1, Math.round(ch * scale));
  if (canvas.width !== pxW || canvas.height !== pxH) { canvas.width = pxW; canvas.height = pxH; }
  if (off.width !== pxW || off.height !== pxH) { off.width = pxW; off.height = pxH; }
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, pxW, pxH);
  if (selected === null && hovered === null) return;

  // Draw the selected hull first, the hovered one on top (overlap).
  const order: number[] = [];
  if (selected !== null) order.push(selected);
  if (hovered !== null && hovered !== selected) order.push(hovered);

  const zoom = cy.zoom();
  const pan = cy.pan();
  const octx = off.getContext('2d');
  if (!octx) return;

  for (const id of order) {
    const nodes = cy.nodes().filter((n) => !n.hasClass('focus-halo') && !n.hasClass(FILE_GROUP_CLASS) && n.data('community') === id);
    if (nodes.empty()) continue;
    const pts: number[][] = [];
    let maxR = NODE_MIN_PX / 2;
    nodes.forEach((n) => {
      const p = n.position();
      pts.push([(p.x * zoom + pan.x) * scale, (p.y * zoom + pan.y) * scale]);
      const r = ((n.data('sizePx') as number) ?? NODE_MIN_PX) / 2;
      if (r > maxR) maxR = r;
    });
    const hull = convexHull(pts);
    if (!hull.length) continue;
    const padPx = (maxR * zoom + HULL_PAD_PX) * scale;

    let alpha = HULL_ALPHA_SELECTED;
    if (id === hovered) alpha = HULL_ALPHA_HOVERED;
    else if (id === selected) {
      alpha = hovered !== null && hovered !== selected ? HULL_ALPHA_SELECTED_WEAK : HULL_ALPHA_SELECTED;
    }
    const color = getCommunityColor(id);

    // Solid blob on the offscreen (fill + thick round stroke = padded outline).
    octx.setTransform(1, 0, 0, 1, 0, 0);
    octx.clearRect(0, 0, pxW, pxH);
    octx.lineJoin = 'round';
    octx.lineCap = 'round';
    octx.beginPath();
    if (hull.length === 1) {
      octx.arc(hull[0][0], hull[0][1], padPx, 0, 2 * Math.PI);
    } else {
      octx.moveTo(hull[0][0], hull[0][1]);
      for (let i = 1; i < hull.length; i++) octx.lineTo(hull[i][0], hull[i][1]);
      octx.closePath();
    }
    octx.fillStyle = color;
    octx.fill();
    octx.lineWidth = padPx * 2;
    octx.strokeStyle = color;
    octx.stroke();

    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.drawImage(off, 0, 0);
    ctx.restore();
  }
}

/** Toggle the community color lens across all real nodes (halo + file-groups excluded). */
function applyColorMode(cy: cytoscape.Core, mode: ColorMode): void {
  const real = cy.nodes().not('.focus-halo').not(`.${FILE_GROUP_CLASS}`);
  if (mode === 'community') real.addClass('color-community');
  else real.removeClass('color-community');
}

/** Compound-Parent-id einer Datei (synthetische NULL-File → eigene „Ohne Datei"-Box). */
function fileGroupIdFor(file: string | null | undefined): string {
  return file == null ? FILE_GROUP_NULL_ID : FILE_GROUP_ID_PREFIX + file;
}

/** Echte Objekt-Knoten (ohne Halos und ohne die Datei-Gruppen-Parents). */
function selectRealNodes(cy: cytoscape.Core): cytoscape.NodeCollection {
  return cy
    .nodes()
    .filter((n) => !n.hasClass('focus-halo') && !n.hasClass(PREVIEW_HALO_CLASS) && !n.hasClass(FILE_GROUP_CLASS));
}

/**
 * Datei-Gruppierung an-/ausschalten. Legt je vorkommender Datei einen Compound-Parent an und
 * schiebt die Knoten via `node.move({ parent })` hinein (Klone landen über ihren `file`-Wert
 * datei-getrennt); `file === null` bekommt eine eigene Box `nullLabel`. Beim Abschalten werden
 * alle Knoten gelöst und die Parents entfernt. **Idempotent** — kann nach jedem Merge/Rebuild
 * erneut laufen. Muss in `cy.batch()` keine Sorge tragen (kapselt selbst).
 */
function applyFileGrouping(cy: cytoscape.Core, on: boolean, nullLabel: string): void {
  cy.batch(() => {
    const real = selectRealNodes(cy);
    if (!on) {
      real.forEach((n) => { if (n.parent().nonempty()) n.move({ parent: null }); });
      cy.nodes(`.${FILE_GROUP_CLASS}`).remove();
      return;
    }
    // (1) Benötigte Parents anlegen (Felder, die das Basis-`node`-Style mappt, mitgeben, sonst
    //     warnt Cytoscape über fehlende Mappings auf dem Parent).
    const needed = new Set<string>();
    real.forEach((n) => { needed.add(fileGroupIdFor(n.data('file') as string | null)); });
    needed.forEach((gid) => {
      if (!cy.getElementById(gid).empty()) return;
      const isNull = gid === FILE_GROUP_NULL_ID;
      cy.add({
        group: 'nodes',
        data: {
          id: gid,
          label: isNull ? nullLabel : gid.slice(FILE_GROUP_ID_PREFIX.length),
          isFileGroup: true,
          color: 'transparent',
          communityColor: 'transparent',
          sizePx: 1,
        },
        selectable: false,
        grabbable: true,
      }).addClass(FILE_GROUP_CLASS);
    });
    // (2) Knoten in ihren Parent verschieben (nur wenn nötig).
    real.forEach((n) => {
      const gid = fileGroupIdFor(n.data('file') as string | null);
      const parent = n.parent();
      const parentId = parent.nonempty() ? parent.first().id() : null;
      if (parentId !== gid) n.move({ parent: gid });
    });
    // (3) Leere Parents entfernen (z. B. wenn beim Rebuild eine Datei wegfällt).
    cy.nodes(`.${FILE_GROUP_CLASS}`).forEach((p) => { if (p.children().empty()) p.remove(); });
  });
}

/**
 * Datei-Boxen ohne ein einziges *sichtbares* Kind ausblenden (sonst rendert Cytoscape eine leere
 * Mini-Box). „Sichtbar" = weder vom Soft-Filter (`filtered-hidden`) noch als nicht-verbunden
 * (`unconnected-hidden`) versteckt. Wird aus dem Filter- UND dem Unconnected-Pass aufgerufen, da
 * beide die Kind-Sichtbarkeit verändern.
 */
function hideEmptyFileGroups(cy: cytoscape.Core): void {
  cy.nodes(`.${FILE_GROUP_CLASS}`).forEach((p) => {
    const hasVisibleChild = p
      .children()
      .filter((c) => !c.hasClass('filtered-hidden') && !c.hasClass(UNCONNECTED_HIDDEN_CLASS))
      .nonempty();
    p.toggleClass('filtered-hidden', !hasVisibleChild);
  });
}

/**
 * Das an `fcose` zu übergebende Element-Subset bauen. Schließt die nicht-verbundenen Knoten aus
 * (wie bisher) UND **leere Datei-Boxen**: ein Compound-Parent ohne im Layout sichtbares Kind bringt
 * fcose mit NaN-Bounds zum Absturz (leerer Graph). Tritt z. B. bei „Nur gewählte Typen" auf, wenn
 * der Typ-Filter eine ganze Datei in lauter nicht-verbundene Inseln zerlegt. Markiert solche Boxen
 * zugleich als `filtered-hidden` (kein Geister-Compound). No-op ohne Gruppierung.
 */
function layoutEles(cy: cytoscape.Core): cytoscape.CollectionReturnValue {
  hideEmptyFileGroups(cy);
  // `.file-group.filtered-hidden` = leere Box (beide Klassen) → nur diese, nicht normale
  // typgefilterte Knoten, aus dem Layout nehmen (deren Positionen sollen erhalten bleiben).
  return cy
    .elements()
    .not(`.${UNCONNECTED_HIDDEN_CLASS}`)
    .not(`.${FILE_GROUP_CLASS}.filtered-hidden`);
}

const HALO_ID_PREFIX = '__focus_halo__';
// Transienter Hover-Halo (Typ-Liste) — eigener Prefix/Klasse, getrennt vom Fokus-Halo.
const PREVIEW_HALO_PREFIX = '__preview_halo__';
const PREVIEW_HALO_CLASS = 'preview-halo';

// Filter-orphans: nodes left edgeless by the server-side type/depth filter. They
// carry no relational signal in the current view and fcose tiles them into a
// confusing grid, so they're hidden by default (opt-in via the canvas pill).
const UNCONNECTED_HIDDEN_CLASS = 'unconnected-hidden';

/**
 * Hide every non-focus node without a path to the focus (islands + isolated)
 * unless `show`. Uses the precomputed focus-connected id set, so it stays
 * consistent with the partition counts; the focus itself is always shown.
 */
function applyUnconnectedVisibility(cy: cytoscape.Core, connected: Set<string>, show: boolean): void {
  cy.batch(() => {
    cy.nodes().forEach((n) => {
      if (n.hasClass('focus-halo') || n.hasClass(PREVIEW_HALO_CLASS) || n.hasClass(FILE_GROUP_CLASS)) return;
      if (n.data('isFocus') || connected.has(n.id())) {
        n.removeClass(UNCONNECTED_HIDDEN_CLASS);
      } else {
        n.toggleClass(UNCONNECTED_HIDDEN_CLASS, !show);
      }
    });
  });
}

/**
 * Partition the loaded graph by connectivity to the focus — a pure topology pass
 * over the *loaded* edges (BFS, undirected), independent of any soft view filter,
 * so the result is stable and the counts always sum to `loaded`. Returns the
 * focus-connected id set (for the "Nur verbunden" hide pass) alongside the counts.
 */
function computeConnectivity(cy: cytoscape.Core): { connected: Set<string> } & GraphPartition {
  const real = cy.nodes().filter((n) => !n.hasClass('focus-halo') && !n.hasClass(PREVIEW_HALO_CLASS) && !n.hasClass(FILE_GROUP_CLASS));
  const focusNodes = real.filter((n) => Boolean(n.data('isFocus')));
  const connected = new Set<string>();
  if (focusNodes.nonempty()) {
    cy.elements().bfs({
      roots: focusNodes,
      directed: false,
      visit: (v) => { if (v.isNode()) connected.add(v.id()); },
    });
  }
  let connectedToFocus = 0;
  let island = 0;
  let isolated = 0;
  real.forEach((n) => {
    if (connected.has(n.id())) connectedToFocus++;
    else if (n.degree(false) === 0) isolated++;
    else island++;
  });
  return { connected, loaded: real.length, connectedToFocus, island, isolated };
}

/**
 * Recompute the connectivity partition, hide isolated orphans per `show`, and
 * report the counts to the host. Returns the partition (incl. the connected id
 * set) so the caller can stash it for the "Nur verbunden" hide pass.
 */
function refreshPartition(
  cy: cytoscape.Core,
  show: boolean,
  report?: (p: GraphPartition | null) => void,
): { connected: Set<string> } & GraphPartition {
  const part = computeConnectivity(cy);
  applyUnconnectedVisibility(cy, part.connected, show);
  report?.({
    loaded: part.loaded,
    connectedToFocus: part.connectedToFocus,
    island: part.island,
    isolated: part.isolated,
  });
  return part;
}

/**
 * Create/update the red focus halo — a non-interactive ring node at 1.5× the
 * focus node's radius, sitting concentrically behind it (user request). Removes
 * any stale halo first so a re-focus moves the ring. Must run after node sizing
 * (`recomputeNodeVisuals`) and after the layout settles (positions final).
 */
function syncFocusHalo(cy: cytoscape.Core): void {
  cy.batch(() => {
    cy.nodes('.focus-halo').remove();
    const focus = cy.nodes().filter((n) => Boolean(n.data('isFocus')) && !n.hasClass('focus-halo'));
    if (focus.empty()) return;
    const f = focus[0];
    const size = (f.data('sizePx') as number) ?? NODE_MIN_PX;
    const pos = f.position();
    const halo = cy.add({
      group: 'nodes',
      // Carry the data fields the base `node` style maps (color/communityColor/
      // sizePx) so cytoscape doesn't warn about missing mappings on the halo; the
      // `.focus-halo` rules override the visuals (transparent fill, red ring).
      data: {
        id: `${HALO_ID_PREFIX}${f.id()}`,
        isHalo: true,
        haloSize: Math.round(size * 1.5),
        color: 'transparent',
        communityColor: 'transparent',
        sizePx: Math.round(size),
      },
      position: { x: pos.x, y: pos.y },
      selectable: false,
      grabbable: false,
    });
    halo.addClass('focus-halo');
  });
}

/**
 * Run the force layout and only fit *after* it settles, against a fresh viewport.
 * The layout is given a `boundingBox` matching the current (wide)
 * canvas so the graph spreads across the full window width instead of collapsing
 * into a centered square with empty side gutters.
 */
function runLayout(
  cy: cytoscape.Core,
  opts: cytoscape.LayoutOptions,
  eles?: cytoscape.CollectionReturnValue,
): void {
  cy.resize();
  const boundingBox = {
    x1: 0,
    y1: 0,
    w: Math.max(cy.width(), 400),
    h: Math.max(cy.height(), 400),
  };
  // Lay out (and fit to) an explicit subset when given — used to keep the
  // edgeless filter-orphans out of the layout so fcose doesn't tile them into a
  // grid. Falls back to the whole graph.
  const hasSubset = !!eles && eles.length > 0;
  const target = hasSubset ? eles! : cy.elements();

  // fcose-Falle (2.2.0): `quality: 'draft'` liest bei `randomize: false`
  // BEDINGUNGSLOS das Spektral-Ergebnis (relocateComponent → nodeIndexes) —
  // das läuft aber nur bei randomize:true → "Cannot read properties of
  // undefined (reading 'nodeIndexes')", React räumt den Baum ab (weißes
  // Fenster). Traf jeden inkrementellen Lauf (Diff-Merge, Lazy-Expand)
  // auf Groß-Graphen ≥ LARGE_GRAPH_NODES (Draft-Profil). Draft ist nur mit
  // randomize:true sicher → inkrementelle Läufe auf 'default' heben
  // (headless gegen fcose 2.2.0 verifiziert).
  const o = opts as { randomize?: boolean; quality?: string };
  const safeOpts = o.randomize === false && o.quality === 'draft'
    ? ({ ...opts, quality: 'default' } as unknown as cytoscape.LayoutOptions)
    : opts;

  const runOnce = (layoutOpts: cytoscape.LayoutOptions) => {
    const layout = target.layout({ ...layoutOpts, boundingBox } as cytoscape.LayoutOptions);
    layout.one('layoutstop', () => {
      cy.resize();
      cy.fit(hasSubset ? eles : undefined, 40);
    });
    layout.run();
  };
  // Gurt: ein Layout-Absturz darf die App nie abräumen. Letzter Ausweg ist der
  // volle Neuaufbau der Positionen (randomize:true verträgt jede Qualität);
  // schlägt auch der fehl, bleiben die Positionen stehen („Neu anordnen" als
  // Escape-Hatch).
  try {
    runOnce(safeOpts);
  } catch {
    try {
      runOnce({ ...safeOpts, randomize: true } as cytoscape.LayoutOptions);
    } catch { /* Positionen unangetastet lassen */ }
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export const ExplorerGraph = forwardRef<ExplorerGraphHandle, ExplorerGraphProps>(
  ({ data, nameFilter, selectedFile, filterMode, deselectedTypes, colorMode = 'type', groupByFile = false, selectedCommunity = null, hoveredCommunity = null, onSetFocus, onOpenDetails, onSelectNode, showUnconnected = false, onPartition }, ref) => {
    const { t } = useTranslation(['explorer']);
    const { theme } = useTheme();
    const containerRef = useRef<HTMLDivElement>(null);
    const tooltipRef = useRef<HTMLDivElement>(null);
    const cyRef = useRef<cytoscape.Core | null>(null);
    const [ready, setReady] = useState(false);
    // Read inside the mount-only mergeElements handle so freshly merged nodes
    // inherit the current color lens without re-binding the imperative handle.
    const colorModeRef = useRef(colorMode);
    colorModeRef.current = colorMode;
    // Datei-Gruppierung, gelesen in mount-only-Handlern (mergeElements) und im Render-Tick
    // (Hüllen-Unterdrückung). Der Klartext „Ohne Datei" wird über tRef gezogen.
    const groupByFileRef = useRef(groupByFile);
    groupByFileRef.current = groupByFile;

    // Community hull overlay: a canvas behind the cytoscape layers,
    // a reusable offscreen buffer, and refs the mount-only `render` handler reads.
    const hullCanvasRef = useRef<HTMLCanvasElement>(null);
    const offscreenRef = useRef<HTMLCanvasElement | null>(null);
    const selCommunityRef = useRef(selectedCommunity);
    selCommunityRef.current = selectedCommunity;
    const hovCommunityRef = useRef(hoveredCommunity);
    hovCommunityRef.current = hoveredCommunity;
    // Coalesce redraws to one per animation frame (cytoscape fires `render` many
    // times per second during pan/zoom/fade — a synchronous full-canvas redraw on
    // each, plus the per-hover effect, can pile up). `lastDrew` lets idle frames
    // skip the canvas entirely when nothing is (or was) drawn.
    const hullRafRef = useRef(0);
    const hullLastDrewRef = useRef(false);
    const redrawHulls = () => {
      if (hullRafRef.current) return; // a frame is already scheduled
      hullRafRef.current = window.requestAnimationFrame(() => {
        hullRafRef.current = 0;
        const cy = cyRef.current;
        const canvas = hullCanvasRef.current;
        if (!cy || !canvas) return;
        const sel = selCommunityRef.current;
        const hov = hovCommunityRef.current;
        // Bei aktiver Datei-Gruppierung wird die Community-Hülle komplett unterdrückt
        // (die Compound-Boxen liefern bereits die räumliche Gruppierung); Färbung bleibt.
        const willDraw = (sel !== null || hov !== null) && !groupByFileRef.current;
        if (!willDraw && !hullLastDrewRef.current) return; // nothing to draw or clear
        hullLastDrewRef.current = willDraw;
        if (!offscreenRef.current) offscreenRef.current = document.createElement('canvas');
        try {
          drawCommunityHulls(cy, canvas, offscreenRef.current, sel, hov);
        } catch {
          // A draw failure must never break the graph; drop this frame.
        }
      });
    };

    // Keep the latest callbacks in refs so the cytoscape init effect can stay
    // mount-only (handlers never need re-binding).
    const setFocusRef = useRef(onSetFocus);
    setFocusRef.current = onSetFocus;
    const openDetailsRef = useRef(onOpenDetails);
    openDetailsRef.current = onOpenDetails;
    const selectRef = useRef(onSelectNode);
    selectRef.current = onSelectNode;
    // Stable connectivity partition: the report callback + the latest computed
    // partition (incl. the focus-connected id set used by the "Nur verbunden" pass).
    const partitionReportRef = useRef(onPartition);
    partitionReportRef.current = onPartition;
    const partitionRef = useRef<({ connected: Set<string> } & GraphPartition) | null>(null);
    // Unconnected-node visibility, read inside mount-only handlers (mergeElements).
    const showUnconnectedRef = useRef(showUnconnected);
    showUnconnectedRef.current = showUnconnected;
    // Tooltip label strings (read inside mount-only handlers).
    const tRef = useRef(t);
    tRef.current = t;

    // Kanten-Beschriftung: Trigger-Events als Label (lokalisiert, adaptiv
    // aggregiert) + Platzierungs-Label „repräsentiert" für displays_field von
    // LayoutObject-Quellen. Der Formatter lädt seine Label-Map nach → Labels
    // werden dann in-place aktualisiert (eigener Effekt, kein Re-Layout).
    const formatTriggerEvent = useTriggerEventFormat();
    const edgeStrings = useMemo<EdgeLabelStrings>(() => ({
      buttonAction: t('edge.buttonAction', { defaultValue: 'Button-Aktion' }) as string,
      represents: t('edge.represents', { defaultValue: 'repräsentiert' }) as string,
    }), [t]);
    const edgeLabeler = useMemo(
      () => makeEdgeLabeler(formatTriggerEvent, edgeStrings),
      [formatTriggerEvent, edgeStrings],
    );
    const edgeLabelerRef = useRef(edgeLabeler);
    edgeLabelerRef.current = edgeLabeler;
    // Tooltip-Zeilen für Kanten-Hover (volle Subrole-Liste — hält das kompakte
    // „×N"-Label ehrlich); als Ref, damit der mount-only Handler aktuell bleibt.
    const edgeTipRef = useRef<(role: string, subroles: string[]) => string[]>(() => []);
    edgeTipRef.current = (role, subroles) =>
      edgeTooltipLines(role, subroles, formatTriggerEvent, edgeStrings);

    useImperativeHandle(ref, () => ({
      fit: () => {
        const cy = cyRef.current;
        if (!cy) return;
        cy.resize();
        cy.fit(undefined, 40);
      },
      relayout: () => {
        const cy = cyRef.current;
        if (!cy) return;
        runLayout(cy, layoutFor(groupByFileRef.current, realNodeCount(cy)), layoutEles(cy));
      },
      exportPng: () =>
        cyRef.current?.png({ full: true, scale: 2, bg: 'transparent' }) ?? null,
      mergeElements: (nodes, edges) => {
        const cy = cyRef.current;
        if (!cy) return;
        const incoming = subgraphToElements(nodes, edges, edgeLabelerRef.current);
        // Only add elements not already present (cytoscape throws on dup ids).
        const fresh = incoming.filter((el) => cy.getElementById(el.data.id as string).empty());
        if (fresh.length === 0) return;
        cy.add(fresh);
        recomputeNodeVisuals(cy);
        applyColorMode(cy, colorModeRef.current);
        // A merged hop may have connected former orphans (or added new ones) — re-evaluate.
        partitionRef.current = refreshPartition(cy, showUnconnectedRef.current, partitionReportRef.current);
        // Bei aktiver Gruppierung die frisch gemergten Knoten ihrer Datei-Box zuordnen
        // (Parent ggf. neu anlegen), sonst erscheinen sie außerhalb aller Boxen.
        if (groupByFileRef.current) {
          applyFileGrouping(cy, true, tRef.current('filter.fileGroupNone', { defaultValue: 'Ohne Datei' }) as string);
        }
        // Re-layout keeping existing positions as the starting point so the
        // graph grows outward instead of reshuffling (incremental expand).
        runLayout(cy, { ...layoutFor(groupByFileRef.current, realNodeCount(cy)), randomize: false } as cytoscape.LayoutOptions, layoutEles(cy));
      },
      collapseHub: (uuid) => {
        const cy = cyRef.current;
        if (!cy) return;
        const hub = cy.getElementById(uuid);
        if (hub.empty()) return;
        // Leaf neighbors = degree-1 nodes whose only edge is to the hub, and
        // never the focus node. Removing them folds the hub's fan-out away.
        const leaves = hub
          .neighborhood()
          .nodes()
          .filter((n) => n.degree(false) <= 1 && !n.data('isFocus'));
        leaves.remove();
        // Eine Datei-Box, die dadurch leer wurde, mit entfernen (kein Geister-Compound).
        cy.nodes(`.${FILE_GROUP_CLASS}`).forEach((p) => { if (p.children().empty()) p.remove(); });
      },
      highlightNode: (uuid) => {
        const cy = cyRef.current;
        if (!cy) return;
        cy.nodes().removeClass('selected');
        if (uuid) cy.getElementById(uuid).addClass('selected');
      },
      previewNode: (id) => {
        const cy = cyRef.current;
        if (!cy) return;
        // Vorherige Vorschau entfernen (Klasse am Knoten + transienter Halo-Knoten).
        cy.nodes().removeClass('list-preview');
        cy.nodes(`.${PREVIEW_HALO_CLASS}`).remove();
        if (!id) return;
        const target = cy.getElementById(id);
        if (target.empty() || !target.isNode()) return;
        target.addClass('list-preview');
        // Rotes Halo wie beim Fokus-Knoten — ein separater, nicht-interaktiver
        // Ring-Knoten am Ort des Ziels (statisch beim Hover, kein Re-Layout).
        const size = (target.data('sizePx') as number) ?? NODE_MIN_PX;
        const pos = target.position();
        cy.add({
          group: 'nodes',
          data: {
            id: `${PREVIEW_HALO_PREFIX}${id}`,
            isHalo: true,
            haloSize: Math.round(size * 1.6),
            color: 'transparent',
            communityColor: 'transparent',
            sizePx: Math.round(size),
          },
          position: { x: pos.x, y: pos.y },
          selectable: false,
          grabbable: false,
        }).addClass(PREVIEW_HALO_CLASS);
      },
    }));

    // Bei Theme-Wechsel das Stylesheet aus den neuen Tokens neu setzen (kein
    // Re-Layout — Positionen/Zoom bleiben). Initial setzt der Mount das Stylesheet.
    useEffect(() => {
      cyRef.current?.style(buildExplorerStylesheet());
    }, [theme]);

    // Init once: register fcose, create the instance, bind handlers.
    useEffect(() => {
      let disposed = false;
      let resizeObserver: ResizeObserver | null = null;

      const hideTooltip = () => {
        if (tooltipRef.current) tooltipRef.current.hidden = true;
      };

      ensureFcose().then(() => {
        if (disposed || !containerRef.current) return;

        const cy = cytoscape({
          container: containerRef.current,
          elements: [],
          style: buildExplorerStylesheet(),
          minZoom: 0.15,
          maxZoom: 3,
          wheelSensitivity: 0.3,
        });

        // Single tap node: ⌘/Ctrl → details, plain → select (inspect panel).
        cy.on('tap', 'node', (evt) => {
          const node = evt.target;
          // Eine Datei-Box (Compound-Parent) ist kein Objekt — Klick ignorieren.
          if (node.data('isFileGroup')) return;
          // data('id') ist der composite Graph-Key (uuid::file) — für Navigation die
          // ROHE uuid + file nutzen (Klon-Disambiguierung).
          const uuid = node.data('uuid') as string;
          const oe = evt.originalEvent as MouseEvent;
          if (oe.metaKey || oe.ctrlKey) {
            openDetailsRef.current(uuid, (node.data('file') as string | null) ?? null);
            return;
          }
          cy.nodes().removeClass('selected');
          node.addClass('selected');
          selectRef.current?.(nodeFromData(node.data()));
        });

        // Double tap node: re-center the graph on it.
        cy.on('dbltap', 'node', (evt) => {
          if (evt.target.data('isFileGroup')) return; // Box ist kein Re-Focus-Ziel
          // Re-Focus über die ROHE uuid + file (nicht den composite Graph-Key).
          const uuid = evt.target.data('uuid') as string;
          if (!evt.target.data('isFocus')) setFocusRef.current(uuid, (evt.target.data('file') as string | null) ?? null);
        });

        // Tap empty background: clear selection.
        cy.on('tap', (evt) => {
          if (evt.target === cy) {
            cy.nodes().removeClass('selected');
            selectRef.current?.(null);
          }
        });

        // Hover: highlight node + direct neighbors + linking
        // edges, strongly dim the rest, and show a metadata tooltip.
        cy.on('mouseover', 'node', (evt) => {
          const node = evt.target;
          if (node.data('isFileGroup')) return; // kein Hover-Highlight/Tooltip für Boxen
          const keep = node.closedNeighborhood();
          // The focus halo stays bright as a persistent locator, never dimmed.
          cy.elements().not(keep).not('.focus-halo').addClass('faded');
          keep.addClass('nbr-hl');
          node.addClass('hover');
          if (containerRef.current) containerRef.current.style.cursor = 'pointer';

          const tip = tooltipRef.current;
          if (tip) {
            const tt = tRef.current;
            const file = node.data('file') as string | null;
            const community = node.data('communityName') as string | null;
            // "Role" = structural status (no per-node link role exists in the model);
            // mirrors the inspect panel. Focus takes precedence over hub.
            const roleLabel = node.data('isFocus')
              ? tt('inspect.focus')
              : node.data('isHub')
                ? tt('inspect.hub')
                : null;
            const lines = [
              `<strong>${escapeHtml(String(node.data('label') ?? ''))}</strong>`,
              `${tt('inspect.type')}: ${escapeHtml(String(node.data('type') ?? ''))}`,
              file ? `${tt('inspect.file')}: ${escapeHtml(file)}` : null,
              community ? `${tt('inspect.community')}: ${escapeHtml(community)}` : null,
              roleLabel ? `${tt('inspect.role')}: ${escapeHtml(roleLabel)}` : null,
              `${tt('inspect.degree')}: ${node.data('degree') ?? 0}`,
            ].filter(Boolean);
            tip.innerHTML = lines.join('<br/>');
            const pos = node.renderedPosition();
            tip.style.left = `${pos.x}px`;
            tip.style.top = `${pos.y}px`;
            tip.hidden = false;
          }
        });
        cy.on('mouseout', 'node', () => {
          cy.elements().removeClass('faded nbr-hl hover');
          if (containerRef.current) containerRef.current.style.cursor = 'default';
          hideTooltip();
        });

        // Kanten-Hover: Rolle + vollständige (lokalisierte) Subrole-Liste als
        // Tooltip — hält das adaptive/kompakte Kanten-Label ehrlich (das „×N"-
        // Label und ein „repräsentiert" zeigen hier ihre technische Wahrheit).
        cy.on('mouseover', 'edge', (evt) => {
          const edge = evt.target;
          const tip = tooltipRef.current;
          if (!tip) return;
          const role = edge.data('role') as string | undefined;
          if (!role) return;
          const subroles = (edge.data('subroles') as string[] | null) ?? [];
          const lines = edgeTipRef.current(role, subroles);
          if (lines.length === 0) return;
          tip.innerHTML = lines
            .map((l, i) => (i === 0 ? `<strong>${escapeHtml(l)}</strong>` : escapeHtml(l)))
            .join('<br/>');
          const pos = evt.renderedPosition ?? edge.midpoint();
          tip.style.left = `${pos.x}px`;
          tip.style.top = `${pos.y}px`;
          tip.hidden = false;
        });
        cy.on('mouseout', 'edge', hideTooltip);

        // Any pan/zoom invalidates the tooltip anchor — just hide it.
        cy.on('pan zoom drag', hideTooltip);

        // Repaint the community hulls on every render tick so they track pan/zoom/
        // drag. Cheap no-op when nothing is selected/hovered (early return).
        cy.on('render', redrawHulls);

        // Keep the focus halo in sync: re-create it after every layout settles
        // (positions/sizes final) and move it live while the focus node is dragged.
        cy.on('layoutstop', () => syncFocusHalo(cy));
        cy.on('drag', 'node', (evt) => {
          const node = evt.target;
          if (!node.data('isFocus')) return;
          const halo = cy.getElementById(`${HALO_ID_PREFIX}${node.id()}`);
          if (!halo.empty()) halo.position(node.position());
        });

        cyRef.current = cy;

        // Keep the renderer in sync with the canvas size: when the
        // inspect panel opens/closes the canvas width changes, and without a
        // resize() cy.fit() would compute against stale dimensions → the graph
        // lands off-screen ("disappears" until a hover forces a redraw).
        if (typeof ResizeObserver !== 'undefined' && containerRef.current) {
          resizeObserver = new ResizeObserver(() => {
            cyRef.current?.resize();
          });
          resizeObserver.observe(containerRef.current);
        }

        setReady(true);
      });

      return () => {
        disposed = true;
        resizeObserver?.disconnect();
        if (hullRafRef.current) { cancelAnimationFrame(hullRafRef.current); hullRafRef.current = 0; }
        if (offscreenRef.current) { offscreenRef.current.width = 0; offscreenRef.current.height = 0; offscreenRef.current = null; }
        cyRef.current?.destroy();
        cyRef.current = null;
        setReady(false);
      };
    }, []);

    // Elemente aktualisieren, wenn die Daten wechseln (Diff-Merge).
    //
    // Dataset-Weiche: nur ein ECHTER Datensatzwechsel (anderer Fokus/Start oder
    // Subgraph↔Trace-Moduswechsel) macht den Voll-Rebuild mit randomize:true.
    // Innerhalb desselben Datensatzes (Exclude-Klick, Budget-/Schalter-Wechsel,
    // Tiefe/Richtung, Server-Typ-Filter) läuft ein positions-erhaltender
    // Diff-Merge nach dem Muster des Lazy-Expand-Pfads: entfallene Elemente
    // raus, bestehende per data() gepatcht (Trace-Rollen verschieben sich nach
    // einem Exclude!), neue dazu. Layout nur, wenn NEUE Knoten hinzukamen —
    // dann mit randomize:false ab Bestandspositionen; reine Schrumpfung oder
    // Attribut-Änderung lässt Positionen UND Viewport unangetastet (kein
    // Auto-Fit). „Neu anordnen" bleibt der Escape-Hatch für verfahrene Fälle.
    // Kein Subset-Kurzschluss: bei gekapptem Trace (truncated) rücken nach
    // einem Exclude Knoten für freigewordene Deckel-Plätze nach.
    const datasetKeyRef = useRef<string | null>(null);
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      const elements = data ? subgraphToElements(data.nodes, data.edges, edgeLabelerRef.current) : [];

      // Datensatz-Identität: Modus (Trace-Daten tragen traceRole) + Fokus-/Start-
      // Composite-ID. Ohne Fokus-Knoten (leerer Graph) gibt es keinen Datensatz.
      const focusNode = data?.nodes.find((n) => n.isFocus) ?? null;
      const isTraceData = data?.nodes.some((n) => n.traceRole !== undefined) ?? false;
      const datasetKey = data && focusNode ? `${isTraceData ? 'trace' : 'subgraph'}:${focusNode.id}` : null;
      const sameDataset =
        datasetKey !== null && datasetKey === datasetKeyRef.current && selectRealNodes(cy).length > 0;
      datasetKeyRef.current = datasetKey;

      if (elements.length === 0) {
        cy.elements().remove();
        partitionRef.current = null;
        partitionReportRef.current?.(null);
        return;
      }

      if (!sameDataset) {
        // Voll-Rebuild (Fokus-/Moduswechsel) — bisheriges Verhalten.
        cy.batch(() => {
          cy.elements().remove();
          cy.add(elements);
        });
        recomputeNodeVisuals(cy);
        applyColorMode(cy, colorMode);
        // Compute the stable partition + hide not-connected nodes (islands + isolated)
        // BEFORE the layout so fcose never grids them; stash the connected set.
        partitionRef.current = refreshPartition(cy, showUnconnected, partitionReportRef.current);
        // Der Rebuild hat die Datei-Boxen mitentfernt → bei aktiver Gruppierung neu aufbauen,
        // BEVOR das Layout läuft (sonst werden die Parents nicht mit angeordnet).
        if (groupByFileRef.current) {
          applyFileGrouping(cy, true, tRef.current('filter.fileGroupNone', { defaultValue: 'Ohne Datei' }) as string);
        }
        runLayout(cy, layoutFor(groupByFileRef.current, realNodeCount(cy)), layoutEles(cy));
        return;
      }

      // ── Diff-Merge (gleicher Datensatz) ──
      const incomingById = new Map(elements.map((el) => [el.data.id as string, el]));
      let added = 0;
      cy.batch(() => {
        // (a) Entfallene Elemente entfernen — Halos und Datei-Boxen sind
        // synthetisch (nie in den Server-Daten) und bleiben unangetastet;
        // Kanten entfallener Knoten räumt Cytoscape mit ab.
        cy.elements().forEach((ele) => {
          if (ele.hasClass('focus-halo') || ele.hasClass(PREVIEW_HALO_CLASS) || ele.hasClass(FILE_GROUP_CLASS)) return;
          if (!incomingById.has(ele.id())) ele.remove();
        });
        // (b) Bestehende patchen / (c) neue addieren. id/source/target sind in
        // Cytoscape unveränderlich → aus dem data()-Patch heraushalten.
        for (const el of elements) {
          const existing = cy.getElementById(el.data.id as string);
          if (existing.nonempty()) {
            const { id: _id, source: _src, target: _tgt, ...patch } = el.data as Record<string, unknown>;
            existing.data(patch);
          } else {
            cy.add(el);
            added += 1;
          }
        }
      });
      recomputeNodeVisuals(cy);
      applyColorMode(cy, colorMode);
      partitionRef.current = refreshPartition(cy, showUnconnected, partitionReportRef.current);
      if (groupByFileRef.current) {
        // Neue Knoten in ihre Datei-Box, leer gewordene Boxen entfernen (idempotent).
        applyFileGrouping(cy, true, tRef.current('filter.fileGroupNone', { defaultValue: 'Ohne Datei' }) as string);
      }
      if (added > 0) {
        // Wachstum: inkrementelles Layout ab Bestandspositionen (Expand-Muster).
        runLayout(cy, { ...layoutFor(groupByFileRef.current, realNodeCount(cy)), randomize: false } as cytoscape.LayoutOptions, layoutEles(cy));
      } else {
        // Reine Schrumpfung/Attribut-Änderung: kein Layout, kein Fit — nur den
        // Fokus-Halo nachziehen (läuft sonst über layoutstop) und Hüllen neu malen.
        syncFocusHalo(cy);
        redrawHulls();
      }
      // colorMode/showUnconnected intentionally omitted — their own effects react
      // without forcing a full element rebuild.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [data, ready]);

    // Kanten-Labels in place aktualisieren, wenn der Labeler wechselt (die
    // lokalisierte Event-Map lädt asynchron nach) — reines Text-Upgrade, kein
    // Element-Rebuild, kein Re-Layout.
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      cy.batch(() => {
        cy.edges().forEach((edge) => {
          const role = edge.data('role') as string | undefined;
          if (!role) return;
          edge.data('label', edgeLabeler(
            role,
            (edge.data('subroles') as string[] | null) ?? [],
            (edge.data('sourceType') as string | null) ?? null,
          ));
        });
      });
    }, [edgeLabeler, ready]);

    // Toggle not-connected visibility without rebuilding the graph (preserves any
    // incrementally expanded nodes). Skips the initial paint — the data effect
    // above already applied the default-hidden state + ran the first layout.
    const isoInitRef = useRef(false);
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      if (!isoInitRef.current) { isoInitRef.current = true; return; }
      // Toggling visibility doesn't change the partition counts — just show/hide + relayout.
      if (partitionRef.current) applyUnconnectedVisibility(cy, partitionRef.current.connected, showUnconnected);
      // layoutEles() bewertet die Box-Sichtbarkeit (hideEmptyFileGroups) selbst neu — Ein-/Ausblenden
      // nicht-verbundener Knoten kann eine Datei-Box leeren/füllen.
      if (cy.elements().length) {
        runLayout(cy, layoutFor(groupByFileRef.current, realNodeCount(cy)), layoutEles(cy));
      }
    }, [showUnconnected, ready]);

    // Recolor in place when the färb-lens toggles (no re-layout, just the class).
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      applyColorMode(cy, colorMode);
    }, [colorMode, ready]);

    // Redraw hulls when the selection/hover (or data) changes — a selection change
    // alone doesn't trigger a cytoscape `render` tick. `groupByFile` mit drin, damit beim
    // Einschalten der Gruppierung eine evtl. gezeichnete Hülle sofort gelöscht wird.
    useEffect(() => {
      if (!ready) return;
      redrawHulls();
      // redrawHulls reads the latest selection/hover from refs; deps drive the call.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [selectedCommunity, hoveredCommunity, colorMode, groupByFile, data, ready]);

    // Datei-Gruppierung umschalten ohne Refetch: Knoten in/aus Compound-Boxen schieben (via
    // node.move) + Re-Layout. Der erste Lauf wird übersprungen — die Daten-Effekte oben wenden
    // die Gruppierung beim Aufbau bereits an (liest groupByFileRef); hier nur echte Toggles.
    const groupInitRef = useRef(false);
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      if (!groupInitRef.current) { groupInitRef.current = true; return; }
      applyFileGrouping(cy, groupByFile, tRef.current('filter.fileGroupNone', { defaultValue: 'Ohne Datei' }) as string);
      if (cy.elements().length) {
        runLayout(cy, layoutFor(groupByFileRef.current, realNodeCount(cy)), layoutEles(cy));
      }
    }, [groupByFile, ready]);

    // Client-side filters: toggle visibility only — no
    // re-layout, positions stay put. Type chips are a hard *exclusion* set
    // (deselected types are always hidden); the name and file filters are *soft*
    // — their non-matches are dimmed or hidden per `filterMode`. A node is a soft
    // non-match if it fails the name OR the file filter. The focus node is always
    // fully visible.
    useEffect(() => {
      const cy = cyRef.current;
      if (!cy || !ready) return;
      const nf = nameFilter.trim().toLowerCase();
      const excludedTypes = new Set(deselectedTypes);
      const nameActive = nf !== '';
      const fileActive = selectedFile !== null;
      const communityActive = selectedCommunity !== null;
      cy.batch(() => {
        cy.nodes().forEach((n) => {
          // Datei-Boxen werden nicht direkt gefiltert — ihre Sichtbarkeit ergibt sich aus den
          // Kindern (siehe Pass unten); hier überspringen.
          if (n.data('isFileGroup')) return;
          // The focus node + halos (focus + transient hover preview) stay fully visible.
          if (n.data('isFocus') || n.hasClass('focus-halo') || n.hasClass(PREVIEW_HALO_CLASS)) {
            n.removeClass('filtered-hidden name-dimmed');
            return;
          }
          const typeHidden = excludedTypes.has(n.data('type') as string);
          const nameMatch = !nameActive || String(n.data('label') ?? '').toLowerCase().includes(nf);
          const fileMatch = !fileActive || n.data('file') === selectedFile;
          // A selected community keeps its members; the rest become soft non-matches.
          const communityMatch = !communityActive || n.data('community') === selectedCommunity;
          // User-ausgeblendete Knoten (Noise-Filter) sind ebenfalls Soft-Non-Matches →
          // dimmen bzw. ausblenden nach filterMode (analog Name/Datei-Filter, rücknehmbar
          // über den Atlas-Hidden-Manager).
          const userHidden = Boolean(n.data('userHidden'));
          const softMatch = nameMatch && fileMatch && communityMatch && !userHidden;
          // Type exclusion always hides; a soft non-match dims or hides per mode.
          const hidden = typeHidden || (!softMatch && filterMode === 'hide');
          const dimmed = !hidden && !softMatch && filterMode === 'dim';
          n.toggleClass('filtered-hidden', hidden);
          n.toggleClass('name-dimmed', dimmed);
        });

        // Not-connected-to-focus nodes (islands + isolated) sind über die Klasse
        // `unconnected-hidden` separat versteckt (Default, via applyUnconnectedVisibility) —
        // dieser Soft-Filter-Pass behandelt nur Name/Datei/Typ/Community.

        // An edge follows its endpoints: hidden if either is hidden (no dangling
        // arrows), otherwise dimmed if either endpoint is dimmed.
        cy.edges().forEach((e) => {
          const s = e.source();
          const t = e.target();
          const hide = s.hasClass('filtered-hidden') || t.hasClass('filtered-hidden');
          e.toggleClass('filtered-hidden', hide);
          e.toggleClass('name-dimmed', !hide && (s.hasClass('name-dimmed') || t.hasClass('name-dimmed')));
        });

        // Datei-Boxen ohne sichtbares Kind ausblenden (sonst leere Mini-Box) — greift z. B.
        // wenn der Datei-Filter im „hide"-Modus eine ganze Datei wegblendet.
        hideEmptyFileGroups(cy);

        // Die per Dropdown gewählte Datei-Box hervorheben (transluzenter Akzent-Hintergrund).
        cy.nodes(`.${FILE_GROUP_CLASS}`).removeClass('file-group-selected');
        if (selectedFile !== null) {
          cy.getElementById(`${FILE_GROUP_ID_PREFIX}${selectedFile}`).addClass('file-group-selected');
        }
      });
      // groupByFile mit drin: nach dem Ein-/Ausschalten die Box-Sichtbarkeit neu bewerten.
    }, [nameFilter, selectedFile, filterMode, deselectedTypes, selectedCommunity, groupByFile, data, ready]);

    return (
      <div className="explorer-graph-canvas-host">
        <canvas ref={hullCanvasRef} className="explorer-hull-canvas" aria-hidden="true" />
        <div ref={containerRef} className="explorer-graph-canvas" role="img" aria-label="Graph" />
        <div ref={tooltipRef} className="explorer-graph-tooltip" hidden />
      </div>
    );
  },
);

ExplorerGraph.displayName = 'ExplorerGraph';

/** Reconstruct a partial GraphNode from cytoscape node data (for the inspect panel). */
function nodeFromData(d: Record<string, unknown>): GraphNode {
  return {
    id: d.id as string,
    uuid: (d.uuid as string) ?? (d.id as string),
    label: (d.label as string) ?? '',
    type: (d.type as string) ?? '',
    file: (d.file as string | null) ?? null,
    depth: (d.depth as number) ?? 0,
    degree: (d.degree as number) ?? 0,
    isHub: Boolean(d.isHub),
    isFocus: Boolean(d.isFocus),
    community: (d.community as number | null) ?? null,
    communityName: (d.communityName as string | null) ?? null,
    traceRole: (d.traceRole as string | undefined) ?? undefined,
    traceDepth: (d.traceDepth as number | undefined) ?? undefined,
    isExcluded: d.traceExcluded === true || undefined,
  };
}
