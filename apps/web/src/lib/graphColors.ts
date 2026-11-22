/**
 * Shared object-type → color palette for the graph visualizations.
 *
 * Single source of truth for the Graph Explorer
 * ([ExplorerGraph.tsx](../components/ExplorerGraph.tsx)), used both on the
 * standalone `/graph` route and in the embedded object-view "Graph" tab
 * ([ObjectGraphPanel.tsx](../components/ObjectGraphPanel.tsx)). Colors are tuned
 * for a dark canvas, so both surfaces
 * stay visually consistent.
 */
export const typeColors: Record<string, string> = {
  Script:             '#4fc3f7',
  ScriptStep:         '#4fc3f7',
  Field:              '#81c784',
  Layout:             '#ffb74d',
  LayoutObject:       '#ffb74d',
  LayoutPart:         '#ffcc80',
  BaseTable:          '#e57373',
  TableOccurrence:    '#e57373',
  CustomFunction:     '#ce93d8',
  ValueList:          '#f48fb1',
  Relationship:       '#90a4ae',
  Variable:           '#fff176',
  Account:            '#a1887f',
  PrivilegeSet:       '#bcaaa4',
  CustomMenu:         '#80cbc4',
  Theme:              '#9fa8da',
  ScriptTrigger:      '#7986cb',
  ExternalDataSource: '#8d6e63',
  BuiltinFunction:    '#b0bec5',
  PluginFunction:     '#4db6ac',
  // Calculation (Schema 1.22.0) — Formel-Familie nahe CustomFunction, heller
  Calculation:        '#b39ddb',
};

/** Fallback color for object types not in the palette. */
export const DEFAULT_TYPE_COLOR = '#aaa';

/** Map an Object_Type to its node color (palette lookup with fallback). */
export const getTypeColor = (type: string): string => typeColors[type] ?? DEFAULT_TYPE_COLOR;

/**
 * Categorical palette for the community color lens (P5).
 *
 * Community ids are dense integers (Louvain yields 0..k); the explorer only ever
 * shows a handful at once in a focus subgraph, so a cycling 12-color palette
 * keeps adjacent communities distinguishable. Tuned for a
 * dark canvas — distinct hues, similar luminance.
 */
export const communityPalette: string[] = [
  '#4fc3f7', '#81c784', '#ffb74d', '#e57373', '#ce93d8', '#f06292',
  '#4db6ac', '#fff176', '#9575cd', '#a1887f', '#90a4ae', '#aed581',
];

/** Color for nodes without a community assignment (unclustered). */
export const UNCLUSTERED_COLOR = '#5a5a66';

/** Map a community id to a stable palette color (cycling); null → unclustered gray. */
export const getCommunityColor = (community: number | null): string =>
  community === null || community === undefined
    ? UNCLUSTERED_COLOR
    : communityPalette[((community % communityPalette.length) + communityPalette.length) % communityPalette.length];

/**
 * Theme-aware graph surface tokens (F1) — the non-palette colors of the Cytoscape
 * graphs (edge line/arrow/label/label-bg/structural, node outline/label, rest node).
 *
 * Cytoscape stylesheets are plain JS objects and cannot read CSS variables, so we
 * resolve the `--color-graph-*` tokens from the document root via getComputedStyle.
 * The components rebuild their stylesheet from this on every theme change (the
 * tokens are already theme-resolved at read time). Hardcoded fallbacks mirror the
 * dark values in case a token is missing (SSR / very old build).
 */
export type GraphThemeTokens = {
  edge: string;
  edgeArrow: string;
  edgeLabel: string;
  edgeLabelBg: string;
  edgeStructural: string;
  nodeOutline: string;
  nodeLabel: string;
  rest: string;
};

export function readGraphThemeTokens(): GraphThemeTokens {
  const fallback: GraphThemeTokens = {
    edge: '#7a7a8c',
    edgeArrow: '#b8b8c8',
    edgeLabel: '#888888',
    edgeLabelBg: '#1a1a1a',
    edgeStructural: '#5a5a66',
    nodeOutline: '#1a1a1a',
    nodeLabel: '#e6e6ea',
    rest: '#5a5a66',
  };
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return fallback;
  const cs = getComputedStyle(document.documentElement);
  const read = (name: string, fb: string) => cs.getPropertyValue(name).trim() || fb;
  return {
    edge: read('--color-graph-edge', fallback.edge),
    edgeArrow: read('--color-graph-edge-arrow', fallback.edgeArrow),
    edgeLabel: read('--color-graph-edge-label', fallback.edgeLabel),
    edgeLabelBg: read('--color-graph-edge-label-bg', fallback.edgeLabelBg),
    edgeStructural: read('--color-graph-edge-structural', fallback.edgeStructural),
    nodeOutline: read('--color-graph-node-outline', fallback.nodeOutline),
    nodeLabel: read('--color-graph-node-label', fallback.nodeLabel),
    rest: read('--color-graph-rest', fallback.rest),
  };
}

/**
 * Border colours per data-trace flow role (Graph Explorer `mode=data`). Same
 * tones as the server-built way diagrams (rest-api graph-trace-mermaid
 * ROLE_COLORS) so canvas, legend and Mermaid read alike; mid-tones stay
 * readable in light and dark.
 */
export const DATA_FLOW_ROLE_COLORS: Readonly<Record<string, string>> = Object.freeze({
  start: '#f59e0b',
  field: '#22c55e',
  step: '#0ea5e9',
  variable: '#ca8a04',
  param: '#a855f7',
  result: '#a855f7',
  calc: '#8b5cf6',
  entry: '#ec4899',
  control: '#64748b',
  sink: '#94a3b8',
  blind: '#ef4444',
});
