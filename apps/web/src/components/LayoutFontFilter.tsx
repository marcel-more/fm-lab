import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import type { LayoutObject } from '../hooks/useLayoutData';
import type { LayoutFontsState } from '../hooks/useLayoutFonts';
import {
  dimensionValues,
  facetCounts,
  FONT_DEFAULT,
  FONT_DIMS,
  fontDisplayNames,
  STYLE_NONE,
  styleInfos,
  type FontDim,
  type FontFilter,
  type LayoutFontIndex,
  type StyleInfo,
} from '../lib/layoutFonts';
import { MultiSelectPopover, type MultiSelectOption } from './MultiSelectPopover';

const FACE_KEYS: Record<string, string> = {
  normal: 'normal',
  bold: 'bold',
  italic: 'italic',
  'bold italic': 'boldItalic',
};

type Labels = {
  names: Map<string, string>;
  styles: Map<string, StyleInfo>;
};

/** Caption of one value of a dimension (select entry, pill, tooltip). */
function valueLabel(t: TFunction, dim: FontDim, value: string, labels: Labels | null): string {
  if (dim === 'font') {
    if (value === FONT_DEFAULT) return t('detail:layoutFontFilter.fileDefault') as string;
    return labels?.names.get(value) ?? value;
  }
  if (dim === 'face') {
    const key = FACE_KEYS[value];
    return key ? (t(`detail:layoutFontFilter.faces.${key}`) as string) : value;
  }
  if (dim === 'style') {
    if (value === STYLE_NONE) return t('detail:layoutFontFilter.noStyle') as string;
    const info = labels?.styles.get(value);
    if (!info) return value;
    if (!info.ambiguous) return info.display;
    const types = info.objectTypes
      .map(typ => t(`detail:layoutTypeFilter.types.${typ}`, { defaultValue: typ }) as string)
      .join(', ');
    return `${info.display} (${types})`;
  }
  return value;
}

function useLabels(index: LayoutFontIndex | null, objects: LayoutObject[]): Labels | null {
  return useMemo(
    () => (index ? { names: fontDisplayNames(index), styles: styleInfos(objects, index) } : null),
    [index, objects],
  );
}

type FilterProps = {
  state: LayoutFontsState;
  filter: FontFilter;
  onChange: (dim: FontDim, values: string[]) => void;
  /** Objects of the selected section — the values a select offers. */
  scopedObjects: LayoutObject[];
  /** Objects left by search, type, calculation and section filter — base of the counts. */
  facetBase: LayoutObject[];
};

/**
 * Row of the details stage of the canvas filter bar: font, size, face and style
 * as multi-selects. Entries are the values on this layout (section) with the
 * number of objects that pass every OTHER filter; values with no object stay
 * listed only while chosen, so they can be cleared. Font, size and face appear
 * once an object shows text, style once an object carries a style.
 */
export function LayoutFontFilter({ state, filter, onChange, scopedObjects, facetBase }: FilterProps) {
  const { t } = useTranslation(['detail']);
  const index = state.index;
  const labels = useLabels(index, scopedObjects);

  const scopedUuids = useMemo(() => scopedObjects.map(o => o.object_uuid), [scopedObjects]);
  const baseUuids = useMemo(() => facetBase.map(o => o.object_uuid), [facetBase]);

  const selects = useMemo(() => {
    if (!index || !labels) return [];
    const hasText = scopedUuids.some(u => index.uses.has(u));
    const hasStyle = scopedUuids.some(u => index.styles.has(u));
    const dims = FONT_DIMS.filter(dim => (dim === 'style' ? hasStyle : hasText));
    return dims.map(dim => {
      const counts = facetCounts(baseUuids, index, filter, dim);
      const label = (v: string) => valueLabel(t, dim, v, labels);
      const values = dimensionValues(scopedUuids, index, dim, label)
        .filter(v => (counts.get(v) ?? 0) > 0 || filter[dim].includes(v));
      for (const v of filter[dim]) if (!values.includes(v)) values.push(v);
      const special = dim === 'font' ? FONT_DEFAULT : dim === 'style' ? STYLE_NONE : null;
      const options: MultiSelectOption[] = values.map((v, i) => {
        const opt: MultiSelectOption = { value: v, label: label(v), count: counts.get(v) ?? 0 };
        if (special && v === special && i < values.length - 1) opt.dividerAfter = true;
        if (dim === 'font' && v === FONT_DEFAULT) opt.title = t('detail:layoutFontFilter.fileDefaultTitle') as string;
        if (dim === 'style' && v !== STYLE_NONE) {
          const info = labels.styles.get(v);
          if (info) {
            const types = info.objectTypes
              .map(typ => t(`detail:layoutTypeFilter.types.${typ}`, { defaultValue: typ }) as string)
              .join(', ');
            opt.title = t('detail:layoutFontFilter.styleTypes', { types }) as string;
            if (info.isCustom) opt.badge = t('detail:layoutFontFilter.customStyle') as string;
            if (info.ruleMissing) opt.warning = t('detail:layoutFontFilter.styleMissing') as string;
          }
        }
        return opt;
      });
      return { dim, options };
    });
  }, [index, labels, scopedUuids, baseUuids, filter, t]);

  if (state.status === 'idle') return null;
  if (state.status !== 'ready') {
    const key = state.status === 'loading' ? 'loading' : state.status === 'unavailable' ? 'unavailable' : 'error';
    return (
      <div className="layout-font-filter">
        <span className={`layout-font-filter-note layout-font-filter-note--${key}`}>
          {t(`detail:layoutFontFilter.${key}`)}
        </span>
      </div>
    );
  }
  if (selects.length === 0) return null;

  return (
    <div className="layout-font-filter">
      {selects.map(({ dim, options }) => (
        <MultiSelectPopover
          key={dim}
          className="layout-font-select"
          caption={t(`detail:layoutFontFilter.dims.${dim}`) as string}
          emptyLabel={t(`detail:layoutFontFilter.all.${dim}`) as string}
          options={options}
          selected={filter[dim]}
          onChange={values => onChange(dim, values)}
        />
      ))}
    </div>
  );
}

type PillsProps = {
  state: LayoutFontsState;
  filter: FontFilter;
  onClearDim: (dim: FontDim) => void;
  onOpenDetails: () => void;
  scopedObjects: LayoutObject[];
};

/**
 * Groups stage with an active font or style filter: one short pill per active
 * dimension ("Font: Arial ✕", "Style: 2 ✕"), so the match set stays explainable.
 * A click on the pill opens the details stage, ✕ clears the dimension.
 */
export function LayoutFontPills({ state, filter, onClearDim, onOpenDetails, scopedObjects }: PillsProps) {
  const { t } = useTranslation(['detail']);
  const labels = useLabels(state.index, scopedObjects);
  const active = FONT_DIMS.filter(dim => filter[dim].length > 0);
  if (active.length === 0) return null;
  return (
    <div className="layout-type-filter-group layout-font-pills">
      {active.map(dim => {
        const dimLabel = t(`detail:layoutFontFilter.dims.${dim}`) as string;
        const values = filter[dim].map(v => valueLabel(t, dim, v, labels));
        const value = values.length === 1 ? values[0] : String(values.length);
        return (
          <span key={dim} className="layout-font-pill">
            <button
              type="button"
              className="layout-type-pill layout-calc-pill active"
              onClick={onOpenDetails}
              title={`${dimLabel}: ${values.join(', ')} — ${t('detail:layoutFontFilter.pillOpen')}`}
            >
              {dimLabel}: {value}
            </button>
            <button
              type="button"
              className="layout-font-pill-clear"
              onClick={() => onClearDim(dim)}
              aria-label={t('detail:layoutFontFilter.pillClear', { dim: dimLabel }) as string}
              title={t('detail:layoutFontFilter.pillClear', { dim: dimLabel }) as string}
            >
              ×
            </button>
          </span>
        );
      })}
    </div>
  );
}
