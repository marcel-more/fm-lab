// Pure helpers of the theme (design) detail view: rows of object_details_theme
// (+ companion object_details_theme_styles, schema 1.46.0) → header and style
// list; the client-side filter (all / used / unused, name search), sorting and
// the counts of the filter buttons; the cut of a style's layout list (loaded on
// expand, display_theme_style_layouts). No React, no i18n — covered by
// tests/themeDetail.test.ts.

/** `section = 'meta'` row of object_details_theme (every catalog). */
export interface ThemeMetaRow {
  section: 'meta';
  theme_uuid: string;
  theme_id: number | null;
  internal_name: string | null;
  display_name: string | null;
  file_name: string;
  is_classic: boolean | null;
  layout_count: number | null;
}

/** `section = 'header'` row of object_details_theme_styles. */
export interface ThemeHeaderRow {
  section: 'header';
  theme_group: string | null;
  is_custom_theme: boolean | null;
  base_name: string | null;
  base_version: string | null;
  base_uuid: string | null;
  base_display: string | null;
  theme_version: string | null;
  theme_locale: string | null;
  theme_platform: string | null;
  is_default: boolean | null;
  has_named_styles: boolean | null;
  custom_count: number | null;
  custom_used: number | null;
  builtin_count: number | null;
  builtin_used: number | null;
}

/** `section = 'style'` row: one named style of the theme. */
export interface ThemeStyleRow {
  section: 'style';
  style_seq: number;
  style_class: string;
  style_display: string | null;
  is_custom: boolean;
  type_tokens: string[] | null;
  objects: number;
  layouts: number;
}

/** Row of display_theme_style_layouts: one layout carrying a style. */
export interface ThemeStyleLayoutRow {
  layout_uuid: string;
  layout_name: string | null;
  objects: number;
}

export type StyleFilter = 'all' | 'used' | 'unused';

export interface ThemeDetailModel {
  meta: ThemeMetaRow | null;
  header: ThemeHeaderRow | null;
  custom: ThemeStyleRow[];
  builtin: ThemeStyleRow[];
}

const num = (v: unknown): number => (typeof v === 'number' ? v : Number(v ?? 0) || 0);

const nameOf = (s: Pick<ThemeStyleRow, 'style_display' | 'style_class'>): string =>
  s.style_display?.trim() || s.style_class;

/** Sort by Inspector name (case- and accent-insensitive), class as tiebreak. */
export function compareStyles(a: ThemeStyleRow, b: ThemeStyleRow): number {
  return nameOf(a).localeCompare(nameOf(b), undefined, { sensitivity: 'base', numeric: true })
    || a.style_class.localeCompare(b.style_class);
}

/** Split the flat template rows into the view model. */
export function buildThemeModel(rows: ReadonlyArray<Record<string, unknown>> | null | undefined): ThemeDetailModel {
  const model: ThemeDetailModel = { meta: null, header: null, custom: [], builtin: [] };
  for (const r of rows ?? []) {
    switch (r.section) {
      case 'meta':
        if (!model.meta) model.meta = r as unknown as ThemeMetaRow;
        break;
      case 'header':
        if (!model.header) model.header = r as unknown as ThemeHeaderRow;
        break;
      case 'style': {
        const s = r as unknown as ThemeStyleRow;
        const row: ThemeStyleRow = {
          ...s,
          objects: num(s.objects),
          layouts: num(s.layouts),
          type_tokens: Array.isArray(s.type_tokens) ? s.type_tokens : [],
          is_custom: !!s.is_custom,
        };
        (row.is_custom ? model.custom : model.builtin).push(row);
        break;
      }
      default:
        break;
    }
  }
  model.custom.sort(compareStyles);
  model.builtin.sort(compareStyles);
  return model;
}

/** Normalize the rows of display_theme_style_layouts (order as delivered: most objects first). */
export function toStyleLayouts(rows: ReadonlyArray<Record<string, unknown>> | null | undefined): ThemeStyleLayoutRow[] {
  return (rows ?? []).map(r => ({
    layout_uuid: String(r.layout_uuid),
    layout_name: (r.layout_name as string | null) ?? null,
    objects: num(r.objects),
  }));
}

/** Normalize for the name search: lower case, accents folded. */
function fold(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

/** Apply the usage filter and the name search (Inspector name or class). */
export function filterStyles(styles: readonly ThemeStyleRow[], filter: StyleFilter, query: string): ThemeStyleRow[] {
  const q = fold(query.trim());
  return styles.filter(s => {
    if (filter === 'used' && s.objects === 0) return false;
    if (filter === 'unused' && s.objects > 0) return false;
    if (!q) return true;
    return fold(nameOf(s)).includes(q) || fold(s.style_class).includes(q);
  });
}

/** Counts for the filter buttons, after the name search. */
export function styleCounts(styles: readonly ThemeStyleRow[], query = ''): Record<StyleFilter, number> {
  const all = filterStyles(styles, 'all', query);
  const used = all.filter(s => s.objects > 0).length;
  return { all: all.length, used, unused: all.length - used };
}

/** Layouts shown of an expanded style before "show all"; the search field appears above it. */
export const LAYOUT_PREVIEW = 25;

export interface LayoutCut {
  /** rows to render */
  shown: ThemeStyleLayoutRow[];
  /** rows matching the search */
  matched: number;
  /** matching rows not rendered (behind "show all") */
  hidden: number;
}

/**
 * Cut of a style's layout list: the name search first, then at most `limit`
 * rows unless `showAll`. The list stays in the delivered order (most objects
 * first), so the preview shows the layouts that carry the style most.
 */
export function cutLayouts(
  layouts: readonly ThemeStyleLayoutRow[],
  query: string,
  showAll: boolean,
  limit = LAYOUT_PREVIEW,
): LayoutCut {
  const q = fold(query.trim());
  const matched = q ? layouts.filter(l => fold(l.layout_name ?? l.layout_uuid).includes(q)) : layouts.slice();
  const shown = showAll ? matched : matched.slice(0, limit);
  return { shown, matched: matched.length, hidden: matched.length - shown.length };
}

/** The 23 type tokens of theme CSS with a translation (`detail:themeDetail.tokens.<token>`). */
export const KNOWN_TYPE_TOKENS: ReadonlySet<string> = new Set([
  'text_box', 'edit_box', 'button', 'button_bar', 'button_bar_segment', 'pop_up', 'drop_down',
  'calendar', 'checkbox_set', 'radio_set', 'container', 'portal', 'tab_control', 'tab_panel',
  'dot_control', 'popover', 'web_viewer', 'chart', 'shape', 'line', 'part', 'body_alt',
  'layout_background',
]);

/** i18n key of a token, or null for an unknown token (shown raw). */
export function tokenKey(token: string): string | null {
  return KNOWN_TYPE_TOKENS.has(token) ? `detail:themeDetail.tokens.${token}` : null;
}
