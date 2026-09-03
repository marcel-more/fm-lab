import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { LayoutObject } from '../hooks/useLayoutData';
import {
  CALC_CATEGORY_KEYS,
  CALC_PREDICATES,
  type CalcCategoryKey,
} from '../hooks/useLayoutSearch';
import { useLayoutObjectPalette } from './layoutObjectTheme';
import { useTriggerEventFormat } from '../lib/triggerEvents';

type Props = {
  objects: LayoutObject[];
  activeTypes: Set<string>;
  onToggle: (type: string) => void;
  onSetTypes: (types: string[], active: boolean) => void;
  onClear: () => void;
  detailsMode: boolean;
  onToggleDetailsMode: () => void;
  activeCalc: Set<string>;
  onToggleCalc: (key: string) => void;
  /**
   * Deeplinks „↗" pro Calc-Chip in die jeweilige Inventar-Query
   * (Layout-Scope via file + scope_uuids). Fehlender Eintrag = kein Link.
   */
  calcInventoryUrls?: Partial<Record<CalcCategoryKey, string>>;
};

type Category = {
  label: string;
  types: string[];
};

// Filter-Kategorien — sechs Gruppen, semantisch nach FileMaker-Verhalten getrennt.
// `Viewer` (vorm. Spezial) bündelt nicht-tabellenartige Anzeige-Container; `Controls`
// die echten interaktiven Container-Typen, `Groups` separat für reine Layout-Gruppierungen.
const CATEGORIES: Category[] = [
  {
    label: 'Input',
    types: [
      'Edit Box', 'Drop-down List', 'Pop-up Menu', 'Radio Button Set',
      'Checkbox Set', 'Drop-down Calendar', 'Concealed Edit Box',
    ],
  },
  { label: 'Display',  types: ['Text', 'Graphic'] },
  { label: 'Viewer',   types: ['Container', 'Web Viewer', 'Chart'] },
  { label: 'Action',   types: ['Button', 'Grouped Button', 'Button Bar', 'Popover Button'] },
  { label: 'Controls', types: ['Portal', 'Panel', 'Slide Control', 'Tab Control'] },
  { label: 'Groups',   types: ['Group'] },
  { label: 'Graphic',  types: ['Rectangle', 'Line', 'Oval', 'Rounded Rectangle'] },
];

type GroupActive = 'none' | 'partial' | 'all';

function groupActivation(types: string[], activeTypes: Set<string>): GroupActive {
  let activeCount = 0;
  for (const t of types) if (activeTypes.has(t)) activeCount++;
  if (activeCount === 0) return 'none';
  if (activeCount === types.length) return 'all';
  return 'partial';
}

export function LayoutTypeFilter({
  objects,
  activeTypes,
  onToggle,
  onSetTypes,
  onClear,
  detailsMode,
  onToggleDetailsMode,
  activeCalc,
  onToggleCalc,
  calcInventoryUrls,
}: Props) {
  const { t } = useTranslation(['detail']);
  const palette = useLayoutObjectPalette();
  const fmtEvent = useTriggerEventFormat();
  const counts = useMemo(() => {
    const m = new Map<string, number>();
    for (const o of objects) m.set(o.object_type, (m.get(o.object_type) ?? 0) + 1);
    return m;
  }, [objects]);

  // Calc-Kategorien: Träger-Anzahl pro Kategorie (Objekte, nicht Regeln) +
  // distinct Event-Namen für den Trigger-Chip-Tooltip.
  const calcStats = useMemo(() => {
    const catCounts = new Map<CalcCategoryKey, number>();
    const events = new Set<string>();
    for (const o of objects) {
      for (const key of CALC_CATEGORY_KEYS) {
        if (CALC_PREDICATES[key](o)) catCounts.set(key, (catCounts.get(key) ?? 0) + 1);
      }
      if (o.trigger_count > 0 && o.trigger_events) {
        for (const ev of o.trigger_events.split(',')) {
          if (ev) events.add(fmtEvent(ev));
        }
      }
    }
    return { catCounts, eventNames: Array.from(events).sort() };
  }, [objects, fmtEvent]);

  const hasAnyActive = activeTypes.size > 0 || activeCalc.size > 0;
  const visibleCalcKeys = CALC_CATEGORY_KEYS.filter(k => (calcStats.catCounts.get(k) ?? 0) > 0);

  return (
    <div className="layout-type-filter">
      {CATEGORIES.map(cat => {
        // Im aktuellen Layout vorhandene Typen — leere Gruppen ganz ausblenden,
        // damit z.B. „Web Viewer" nicht in jedem Layout auftaucht.
        const visible = cat.types.filter(t => (counts.get(t) ?? 0) > 0);
        if (visible.length === 0) return null;

        if (!detailsMode) {
          // Stufe 1: nur ein Gruppen-Pille pro Kategorie. Toggle wirkt auf alle Typen
          // der Gruppe gleichzeitig — Anzeige als „aktiv" sobald mindestens ein Typ aktiv ist.
          const groupCount = visible.reduce((sum, t) => sum + (counts.get(t) ?? 0), 0);
          const state = groupActivation(visible, activeTypes);
          // Repräsentative Farbe = erste Typ-Farbe der Gruppe (alle Typen einer Gruppe
          // teilen ohnehin dieselbe Kategorie-Farbe im SVG).
          const fill = palette.fillFor(visible[0]);
          const stroke = palette.strokeFor(visible[0]);
          const targetActive = state !== 'all';
          const catLabel = t(`detail:layoutTypeFilter.categories.${cat.label}`, { defaultValue: cat.label });
          // Übersetzte Typennamen für den Tooltip ("Edit Box" → "Eingabefeld" etc.)
          const visibleLabels = visible.map(typ =>
            t(`detail:layoutTypeFilter.types.${typ}`, { defaultValue: typ }) as string
          );
          return (
            <button
              key={cat.label}
              type="button"
              className={`layout-type-pill layout-type-pill-group${state !== 'none' ? ' active' : ''}${state === 'partial' ? ' partial' : ''}`}
              style={state !== 'none'
                ? { background: fill, borderColor: stroke, color: stroke }
                : undefined}
              onClick={() => onSetTypes(visible, targetActive)}
              title={`${catLabel}: ${visibleLabels.join(', ')} (${groupCount})`}
            >
              {catLabel}<span className="layout-type-pill-count">({groupCount})</span>
            </button>
          );
        }

        // Stufe 2: detaillierte Einzel-Typen mit Gruppen-Header.
        return (
          <div key={cat.label} className="layout-type-filter-group">
            <span className="layout-type-filter-cat">{t(`detail:layoutTypeFilter.categories.${cat.label}`, { defaultValue: cat.label })}</span>
            {visible.map(type => {
              const count = counts.get(type) ?? 0;
              const active = activeTypes.has(type);
              const fill = palette.fillFor(type);
              const stroke = palette.strokeFor(type);
              const typeLabel = t(`detail:layoutTypeFilter.types.${type}`, { defaultValue: type }) as string;
              return (
                <button
                  key={type}
                  type="button"
                  className={`layout-type-pill${active ? ' active' : ''}`}
                  style={active
                    ? { background: fill, borderColor: stroke, color: stroke }
                    : undefined}
                  onClick={() => onToggle(type)}
                  title={`${typeLabel} (${count})`}
                >
                  {typeLabel}<span className="layout-type-pill-count">({count})</span>
                </button>
              );
            })}
          </div>
        );
      })}
      {/* Calculation-Chips: markieren Träger unsichtbarer Layout-Logik (CF/Hide/
          Trigger/QuickInfo). Stufen-unabhängig immer als Einzel-Chips mit
          Gruppen-Label — eine Sammel-Pille wäre semantisch leer. Neutraler
          Akzent-Stil statt Typ-Palette: deren Farben kodieren SVG-Objekt-Typen. */}
      {visibleCalcKeys.length > 0 && (
        <div className="layout-type-filter-group layout-calc-filter-group">
          <span className="layout-type-filter-cat">
            {t('detail:layoutTypeFilter.calcGroupLabel', { defaultValue: 'Calculations' })}
          </span>
          {visibleCalcKeys.map(key => {
            const count = calcStats.catCounts.get(key) ?? 0;
            const active = activeCalc.has(key);
            const label = t(`detail:layoutTypeFilter.calcCategories.${key}`, { defaultValue: key }) as string;
            const title = key === 'trigger' && calcStats.eventNames.length > 0
              ? `${label} (${count}): ${calcStats.eventNames.join(', ')}`
              : `${label} (${count})`;
            const inventoryUrl = calcInventoryUrls?.[key];
            return (
              <span key={key} className="layout-calc-chip">
                <button
                  type="button"
                  className={`layout-type-pill layout-calc-pill${active ? ' active' : ''}`}
                  onClick={() => onToggleCalc(key)}
                  title={title}
                >
                  {label}<span className="layout-type-pill-count">({count})</span>
                </button>
                {inventoryUrl && (
                  <Link
                    to={inventoryUrl}
                    className="layout-calc-pill-jump"
                    title={`${label} — ${t('detail:layoutTypeFilter.calcInventoryOpen', { defaultValue: 'Open inventory' })}`}
                  >
                    ↗
                  </Link>
                )}
              </span>
            );
          })}
        </div>
      )}
      <div className="layout-type-filter-actions">
        <button
          type="button"
          className="layout-type-filter-link"
          onClick={onToggleDetailsMode}
          title={(detailsMode
            ? t('detail:layoutTypeFilter.detailsToggleToGroups')
            : t('detail:layoutTypeFilter.detailsToggleToDetails')) as string}
        >
          {detailsMode ? t('detail:layoutTypeFilter.groupsLabel') : t('detail:layoutTypeFilter.detailsLabel')}
        </button>
        {hasAnyActive && (
          <button
            type="button"
            className="layout-type-filter-link"
            onClick={onClear}
            title={t('detail:layoutTypeFilter.clearTitle') as string}
          >
            {t('detail:layoutTypeFilter.clearLabel')}
          </button>
        )}
      </div>
    </div>
  );
}
