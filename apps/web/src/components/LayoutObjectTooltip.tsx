import { useLayoutEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { LayoutObject } from '../hooks/useLayoutData';
import { FIELD_NAV_TYPES, SCRIPT_NAV_TYPES } from '../lib/layoutObjectNav';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import { FONT_DEFAULT, type FontUse, type ObjectStyle } from '../lib/layoutFonts';

type Props = {
  object: LayoutObject;
  x: number;
  y: number;
  /** Font uses of the object (base font, rich-text runs, chart areas); null = none or not loaded. */
  fontUses?: FontUse[] | null;
  /** Applied style; null = none or not loaded. */
  fontStyle?: ObjectStyle | null;
  /** Font data loaded — only then the font and style rows show. */
  fontsReady?: boolean;
};

const FACE_KEYS: Record<string, string> = { bold: 'bold', italic: 'italic', 'bold italic': 'boldItalic' };

const CURSOR_OFFSET_X = 14;
const CURSOR_OFFSET_Y = 18;
const VIEWPORT_MARGIN = 12;

/**
 * Gehoistetes Cross-Nav-Ziel für die Ziel-Zeile (Typ-Label + Name) — kündigt
 * zugleich an, wohin der Modifier-Klick (Alt) führt. `extra` = weitere
 * Script-Ziele („+n weitere").
 */
function resolveTargetLine(o: LayoutObject): { typeKey: string; name: string; extra: number } | null {
  if (FIELD_NAV_TYPES.has(o.object_type) && o.field_name) {
    return { typeKey: 'Field', name: o.field_name, extra: 0 };
  }
  if (SCRIPT_NAV_TYPES.has(o.object_type)) {
    if (o.script_name) {
      return { typeKey: 'Script', name: o.script_name, extra: Math.max(0, o.script_count - 1) };
    }
    if (o.nav_layout_name) {
      return { typeKey: 'Layout', name: o.nav_layout_name, extra: 0 };
    }
  }
  if (o.object_type === 'Portal' && o.portal_to_name) {
    return { typeKey: 'TableOccurrence', name: o.portal_to_name, extra: 0 };
  }
  return null;
}

/**
 * Kompakter Read-only-Hover-Indikator eines Layout-Objekts: Typ/Name,
 * Ziel-Zeile (gehoistetes Ziel = Modifier-Klick-Ziel), Script-Trigger
 * (Anzahl + ALLE Event-Namen, ungedeckelt), Logik-Indikatoren
 * (Tooltip/Hide-Präsenz, CF-Regelanzahl) und typspezifische Slot-Indikatoren.
 * Keine Formeln, keine Links — Details liefert die LayoutObject-Detailansicht
 * per Primärklick.
 */
export function LayoutObjectTooltip({ object, x, y, fontUses, fontStyle, fontsReady = false }: Props) {
  const { t } = useTranslation(['detail', 'types']);
  const fmtEvent = useTriggerEventFormat();
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: x + CURSOR_OFFSET_X, top: y + CURSOR_OFFSET_Y });

  // Edge-Detection: Tooltip an die andere Seite des Cursors flippen, wenn er rechts/unten
  // aus dem Viewport ragt.
  useLayoutEffect(() => {
    if (!ref.current) return;
    const rect = ref.current.getBoundingClientRect();
    const viewportW = window.innerWidth;
    const viewportH = window.innerHeight;

    let left = x + CURSOR_OFFSET_X;
    let top = y + CURSOR_OFFSET_Y;

    if (left + rect.width > viewportW - VIEWPORT_MARGIN) {
      left = x - rect.width - CURSOR_OFFSET_X;
    }
    if (top + rect.height > viewportH - VIEWPORT_MARGIN) {
      top = y - rect.height - CURSOR_OFFSET_Y;
    }
    if (left < VIEWPORT_MARGIN) left = VIEWPORT_MARGIN;
    if (top < VIEWPORT_MARGIN) top = VIEWPORT_MARGIN;

    setPos({ left, top });
  }, [x, y, object.object_uuid]);

  const target = resolveTargetLine(object);
  const triggerEvents = object.trigger_count > 0 && object.trigger_events
    ? object.trigger_events.split(',').map(fmtEvent).join(', ')
    : null;

  // Logik-Zeile: Präsenz-Häkchen für Tooltip/Hide, CF als Regel-Anzahl
  // (regel-genau aus LayoutObjectConditions — nie mehr ein Regex-Boolean).
  const logicParts: string[] = [];
  if (object.tooltip_text) {
    logicParts.push(`${t('detail:calculationDetail.roles.tooltip', { defaultValue: 'Tooltip' })} ✓`);
  }
  if (object.hide_text) {
    logicParts.push(`${t('detail:calculationDetail.roles.hide', { defaultValue: 'Hide condition' })} ✓`);
  }
  if (object.cf_count > 0) {
    logicParts.push(`${t('detail:calculationDetail.roles.conditional_format', { defaultValue: 'Conditional formatting' })} (${object.cf_count})`);
  }

  // Slot-Zeile: belegte typspezifische Slots namentlich (Labels aus den
  // vorhandenen Rollen-Keys) — pro Typ kommen faktisch höchstens 1–2 vor.
  const slotParts = (object.other_calc_roles ?? '')
    .split(',')
    .filter(Boolean)
    .map(role => `${t(`detail:calculationDetail.roles.${role}`, { defaultValue: role })} ✓`);

  // Font row: base font with size, face and source; rich-text runs and chart
  // areas with their own font as additions. File default is named as such —
  // the export does not contain the font.
  const fontName = (u: FontUse) => (u.font === FONT_DEFAULT
    ? t('detail:layoutCanvas.tooltip.fileDefault')
    : (u.fontDisplay ?? u.font)) as string;
  const faceName = (face: string) => (FACE_KEYS[face]
    ? t(`detail:layoutFontFilter.faces.${FACE_KEYS[face]}`) as string
    : null);
  const uses = fontsReady ? (fontUses ?? []) : [];
  const baseUse = uses.find(u => u.kind === 'base') ?? null;
  const runFonts = [...new Set(uses.filter(u => u.kind === 'rich_text').map(fontName))];
  const runCount = uses.filter(u => u.kind === 'rich_text').length;
  const chartFonts = [...new Set(uses.filter(u => u.kind === 'chart').map(fontName))];
  const baseText = baseUse
    ? [fontName(baseUse), baseUse.size, faceName(baseUse.face)].filter(Boolean).join(' ')
    : null;
  const sourceText = baseUse?.familySource
    ? t(`detail:layoutCanvas.tooltip.sources.${baseUse.familySource}`, { defaultValue: baseUse.familySource }) as string
    : null;
  const style = fontsReady ? fontStyle : null;

  return (
    <div
      ref={ref}
      role="tooltip"
      className="layout-object-tooltip"
      style={{ left: pos.left, top: pos.top }}
    >
      <div className="layout-tooltip-head">
        <span className="layout-tooltip-type">{object.object_type}</span>
        {object.object_name && <span className="layout-tooltip-name"> · {object.object_name}</span>}
      </div>
      {target && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">{t('detail:layoutCanvas.tooltip.target', { defaultValue: 'Target' })}</span>
          <span className="layout-tooltip-val">
            {t(`types:objectTypes.${target.typeKey}`, { defaultValue: target.typeKey })} „{target.name}“
            {target.extra > 0 && (
              <span className="layout-tooltip-muted"> {t('detail:layoutCanvas.tooltip.moreTargets', { n: target.extra, defaultValue: '(+{{n}} more)' })}</span>
            )}
          </span>
        </div>
      )}
      {triggerEvents && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">
            {t('detail:layoutViewer.triggersHeading', { defaultValue: 'Script triggers' })} ({object.trigger_count})
          </span>
          <span className="layout-tooltip-val">{triggerEvents}</span>
        </div>
      )}
      {logicParts.length > 0 && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">{t('detail:layoutCanvas.tooltip.logic', { defaultValue: 'Logic' })}</span>
          <span className="layout-tooltip-val">{logicParts.join(' · ')}</span>
        </div>
      )}
      {(baseText || runCount > 0 || chartFonts.length > 0) && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">{t('detail:layoutCanvas.tooltip.font')}</span>
          <span className="layout-tooltip-val">
            {baseText}
            {sourceText && (
              <span className="layout-tooltip-muted"> · {t('detail:layoutCanvas.tooltip.source')}: {sourceText}</span>
            )}
            {baseUse?.lowConfidence && (
              <span className="layout-tooltip-warn" title={t('detail:layoutCanvas.tooltip.lowConfidence') as string}> ⚠</span>
            )}
            {runCount > 0 && (
              <span className="layout-tooltip-muted">
                {baseText ? ' ' : ''}({t('detail:layoutCanvas.tooltip.richRuns', { count: runCount, fonts: runFonts.join(', ') })})
              </span>
            )}
            {chartFonts.length > 0 && (
              <span>
                {baseText || runCount > 0 ? ' · ' : ''}
                {t('detail:layoutCanvas.tooltip.chartFonts', { fonts: chartFonts.join(', ') })}
              </span>
            )}
          </span>
        </div>
      )}
      {style && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">{t('detail:layoutCanvas.tooltip.style')}</span>
          <span className="layout-tooltip-val">
            {style.display || style.name}
            {style.isCustom && (
              <span className="layout-tooltip-muted"> · {t('detail:layoutFontFilter.customStyle')}</span>
            )}
            {style.ruleMissing && (
              <span className="layout-tooltip-warn" title={t('detail:layoutFontFilter.styleMissing') as string}> ⚠</span>
            )}
          </span>
        </div>
      )}
      {slotParts.length > 0 && (
        <div className="layout-tooltip-row">
          <span className="layout-tooltip-key">{t('detail:layoutCanvas.tooltip.slots', { defaultValue: 'Slots' })}</span>
          <span className="layout-tooltip-val">{slotParts.join(' · ')}</span>
        </div>
      )}
    </div>
  );
}
