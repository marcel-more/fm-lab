/**
 * Border colours of the Mermaid node classes per object type.
 *
 * Same hue per type as the Graph Explorer (apps/web/src/lib/graphColors.ts),
 * but mid-tones: a `classDef` sets only the border, which has to stay visible on
 * a light page, a dark page and a standalone SVG with a white background.
 */
const TYPE_BORDER_COLORS = Object.freeze({
  Script: '#0ea5e9',
  ScriptStep: '#0ea5e9',
  Field: '#22c55e',
  Layout: '#f59e0b',
  LayoutObject: '#f59e0b',
  LayoutPart: '#fb923c',
  BaseTable: '#ef4444',
  TableOccurrence: '#ef4444',
  CustomFunction: '#a855f7',
  ValueList: '#ec4899',
  Relationship: '#64748b',
  Variable: '#ca8a04',
  Account: '#a16207',
  PrivilegeSet: '#a8a29e',
  CustomMenu: '#14b8a6',
  Theme: '#6366f1',
  ScriptTrigger: '#6366f1',
  ExternalDataSource: '#92400e',
  BuiltinFunction: '#94a3b8',
  PluginFunction: '#0d9488',
  Calculation: '#8b5cf6',
});

module.exports = { TYPE_BORDER_COLORS };
