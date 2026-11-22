/**
 * Font and style filter of the layout canvas: index over the rows of the
 * template `display_layout_fonts`, the match per object and the facet counts
 * of the four filter dimensions. Pure functions, no React — tested with
 * `npm test` in apps/web.
 *
 * Values are the ones of the font dashboards (same URL params, separator '|'):
 *   font   font key, lowercase; '#default' = the font is left to the file default
 *   size   '12pt'
 *   face   normal | bold | italic | bold italic
 *   style  style class (`FM-<UUID>` for a custom style); '#none' = no style
 */

/** One row of `display_layout_fonts`. */
export type LayoutFontRow = {
  object_uuid: string;
  kind: 'base' | 'rich_text' | 'chart' | 'style';
  font_key: string | null;
  font_display: string | null;
  font_size: string | null;
  size_num: number | null;
  face: string | null;
  family_source: string | null;
  low_confidence: boolean | null;
  detail: string | null;
  style_name: string | null;
  style_display: string | null;
  style_is_custom: boolean | null;
  style_rule_missing: boolean | null;
};

/** One font use of an object: its base font, a formatted text run or a chart text area. */
export type FontUse = {
  kind: 'base' | 'rich_text' | 'chart';
  font: string;
  fontDisplay: string | null;
  size: string | null;
  sizeNum: number | null;
  face: string;
  familySource: string | null;
  lowConfidence: boolean;
  detail: string | null;
};

export type ObjectStyle = {
  name: string;
  display: string | null;
  isCustom: boolean;
  ruleMissing: boolean;
};

export type LayoutFontIndex = {
  uses: Map<string, FontUse[]>;
  styles: Map<string, ObjectStyle>;
};

export const FONT_DEFAULT = '#default';
export const STYLE_NONE = '#none';
export const FONT_DIMS = ['font', 'size', 'face', 'style'] as const;
export type FontDim = (typeof FONT_DIMS)[number];
export const FACE_ORDER = ['normal', 'bold', 'italic', 'bold italic'] as const;
/** URL params of the four dimensions: same names as in the font dashboards. */
export const FONT_PARAM_SEPARATOR = '|';

export type FontFilter = Record<FontDim, string[]>;

export const EMPTY_FONT_FILTER: FontFilter = { font: [], size: [], face: [], style: [] };

export function buildFontIndex(rows: readonly LayoutFontRow[]): LayoutFontIndex {
  const uses = new Map<string, FontUse[]>();
  const styles = new Map<string, ObjectStyle>();
  for (const r of rows) {
    if (r.kind === 'style') {
      if (r.style_name) {
        styles.set(r.object_uuid, {
          name: r.style_name,
          display: r.style_display,
          isCustom: r.style_is_custom === true,
          ruleMissing: r.style_rule_missing === true,
        });
      }
      continue;
    }
    const list = uses.get(r.object_uuid) ?? [];
    list.push({
      kind: r.kind,
      font: r.font_key ?? FONT_DEFAULT,
      fontDisplay: r.font_display,
      size: r.font_size,
      sizeNum: r.size_num,
      face: r.face || 'normal',
      familySource: r.family_source,
      lowConfidence: r.low_confidence === true,
      detail: r.detail,
    });
    uses.set(r.object_uuid, list);
  }
  return { uses, styles };
}

/** Value of a font use in a font dimension. */
function useValue(u: FontUse, dim: Exclude<FontDim, 'style'>): string | null {
  if (dim === 'font') return u.font;
  if (dim === 'size') return u.size;
  return u.face;
}

const FONT_USE_DIMS = ['font', 'size', 'face'] as const;

/** The use fulfils every active font dimension except `skip`. */
function useMatches(u: FontUse, filter: FontFilter, skip?: FontDim): boolean {
  for (const dim of FONT_USE_DIMS) {
    if (dim === skip || filter[dim].length === 0) continue;
    const v = useValue(u, dim);
    if (v == null || !filter[dim].includes(v)) return false;
  }
  return true;
}

function fontDimsActive(filter: FontFilter, skip?: FontDim): boolean {
  return FONT_USE_DIMS.some(dim => dim !== skip && filter[dim].length > 0);
}

export function styleValue(index: LayoutFontIndex, uuid: string): string {
  return index.styles.get(uuid)?.name ?? STYLE_NONE;
}

export function fontFilterActive(filter: FontFilter): boolean {
  return FONT_DIMS.some(dim => filter[dim].length > 0);
}

/**
 * Does the object pass the font and style filter (all dimensions except `skip`)?
 * Font, size and face are checked per use: ONE use has to fulfil all active font
 * dimensions together ("Arial + 9pt" does not match base Arial 12pt with a run
 * Helvetica 9pt). An object without any font use drops out as soon as a font
 * dimension is active. Style applies to every object type; '#none' = no style.
 */
export function matchesFontFilter(
  uuid: string,
  index: LayoutFontIndex,
  filter: FontFilter,
  skip?: FontDim,
): boolean {
  if (skip !== 'style' && filter.style.length > 0 && !filter.style.includes(styleValue(index, uuid))) {
    return false;
  }
  if (!fontDimsActive(filter, skip)) return true;
  const uses = index.uses.get(uuid);
  return !!uses && uses.some(u => useMatches(u, filter, skip));
}

/**
 * Facet counts of one dimension: per value the number of objects that carry it
 * and pass every OTHER active dimension (the counts of a lens ignore that lens
 * itself). `uuids` = the objects left by the other canvas filters (search, types,
 * calculations, section). An object counts once per value.
 */
export function facetCounts(
  uuids: Iterable<string>,
  index: LayoutFontIndex,
  filter: FontFilter,
  dim: FontDim,
): Map<string, number> {
  const counts = new Map<string, number>();
  for (const uuid of uuids) {
    if (!matchesFontFilter(uuid, index, filter, dim)) continue;
    if (dim === 'style') {
      const v = styleValue(index, uuid);
      counts.set(v, (counts.get(v) ?? 0) + 1);
      continue;
    }
    const values = new Set<string>();
    for (const u of index.uses.get(uuid) ?? []) {
      if (!useMatches(u, filter, dim)) continue;
      const v = useValue(u, dim);
      if (v != null) values.add(v);
    }
    for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  return counts;
}

/**
 * Values of a dimension that occur on the given objects, sorted for the select:
 * font — file default first, then by display name; size — numeric; face — fixed
 * order; style — no style first, then by `labelOf`.
 */
export function dimensionValues(
  uuids: Iterable<string>,
  index: LayoutFontIndex,
  dim: FontDim,
  labelOf: (value: string) => string,
): string[] {
  const values = new Set<string>();
  const sizeNum = new Map<string, number>();
  for (const uuid of uuids) {
    if (dim === 'style') {
      values.add(styleValue(index, uuid));
      continue;
    }
    for (const u of index.uses.get(uuid) ?? []) {
      const v = useValue(u, dim);
      if (v == null) continue;
      values.add(v);
      if (dim === 'size' && u.sizeNum != null) sizeNum.set(v, u.sizeNum);
    }
  }
  const list = [...values];
  const byLabel = (a: string, b: string) => labelOf(a).localeCompare(labelOf(b), undefined, { sensitivity: 'base' });
  if (dim === 'size') {
    return list.sort((a, b) => (sizeNum.get(a) ?? Infinity) - (sizeNum.get(b) ?? Infinity) || a.localeCompare(b));
  }
  if (dim === 'face') {
    const rank = (v: string) => {
      const i = (FACE_ORDER as readonly string[]).indexOf(v);
      return i < 0 ? FACE_ORDER.length : i;
    };
    return list.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
  }
  const special = dim === 'font' ? FONT_DEFAULT : STYLE_NONE;
  return list.sort((a, b) => (a === special ? -1 : b === special ? 1 : byLabel(a, b)));
}

/** Display name per font key (the template already picks one spelling per layout). */
export function fontDisplayNames(index: LayoutFontIndex): Map<string, string> {
  const names = new Map<string, string>();
  for (const uses of index.uses.values()) {
    for (const u of uses) if (u.fontDisplay && !names.has(u.font)) names.set(u.font, u.fontDisplay);
  }
  return names;
}

export type StyleInfo = {
  name: string;
  display: string;
  isCustom: boolean;
  ruleMissing: boolean;
  /** Object types carrying the style on this layout, sorted. */
  objectTypes: string[];
  /** Another style of the layout has the same display name. */
  ambiguous: boolean;
};

/**
 * Styles used by the given objects. Built-in styles often share an Inspector
 * name across object types ("Transparent"); `ambiguous` marks names that occur
 * for more than one style class, the select then adds the object types.
 */
export function styleInfos(
  objects: Iterable<{ object_uuid: string; object_type: string }>,
  index: LayoutFontIndex,
): Map<string, StyleInfo> {
  const infos = new Map<string, StyleInfo & { types: Set<string> }>();
  for (const o of objects) {
    const s = index.styles.get(o.object_uuid);
    if (!s) continue;
    let info = infos.get(s.name);
    if (!info) {
      info = {
        name: s.name,
        display: s.display || s.name,
        isCustom: s.isCustom,
        ruleMissing: s.ruleMissing,
        objectTypes: [],
        ambiguous: false,
        types: new Set(),
      };
      infos.set(s.name, info);
    }
    info.types.add(o.object_type);
    if (s.ruleMissing) info.ruleMissing = true;
  }
  const byDisplay = new Map<string, number>();
  for (const i of infos.values()) byDisplay.set(i.display, (byDisplay.get(i.display) ?? 0) + 1);
  const out = new Map<string, StyleInfo>();
  for (const { types, ...i } of infos.values()) {
    out.set(i.name, { ...i, objectTypes: [...types].sort(), ambiguous: (byDisplay.get(i.display) ?? 0) > 1 });
  }
  return out;
}

/** Reads the four dimensions from URL params. */
export function readFontFilter(get: (name: string) => string | null): FontFilter {
  const read = (name: string) => (get(name) ?? '').split(FONT_PARAM_SEPARATOR).filter(v => v !== '');
  return { font: read('font'), size: read('size'), face: read('face'), style: read('style') };
}
