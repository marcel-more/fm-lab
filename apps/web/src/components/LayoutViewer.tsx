import React, { useEffect, useMemo, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { LayoutMeta, LayoutPart, LayoutTrigger } from '../hooks/useLayoutData';
import { useSectionParam } from '../hooks/useLayoutSearch';
import { buildObjectPath } from '../lib/navigation';
import { partKindKey, partLabel, subSummaryPosition, type PartTranslate } from '../lib/layoutParts';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import './FieldViewer.css';
import './LayoutViewer.css';

interface LayoutViewerProps {
  meta: LayoutMeta;
  triggers: LayoutTrigger[];
  /** Origin-UUID (das betrachtete Layout) für die ref-Navigation zu TO/Script. */
  originUuid?: string;
  /**
   * Cross-Reference Highlight: kam die Navigation per `?ref=trig_<id>_…` von einem
   * Script hierher, steht die synthetische Trigger-UUID im Set — der passende
   * Trigger wird hervorgehoben und in den Sichtbereich gescrollt.
   */
  highlightUuids?: Set<string> | null;
  /** Layout parts in vertical order (display_layout_parts_data). */
  parts?: LayoutPart[];
  /** Objects per part (Part_Seq → count, all nesting levels). */
  partCounts?: Map<number, number>;
}

/** Trigger-IDs aus synthetischen ScriptTrigger-UUIDs (`trig_<id>_…`) im Highlight-Set. */
function highlightedTriggerIds(uuids: Set<string> | null | undefined): Set<number> {
  const ids = new Set<number>();
  if (!uuids) return ids;
  for (const u of uuids) {
    const m = /^trig_(\d+)_/.exec(u);
    if (m) ids.add(Number(m[1]));
  }
  return ids;
}

/**
 * Prettify des internen Theme-Namens: "com.filemaker.theme.apex_blue" → "Apex Blue".
 */
function prettyTheme(name: string | null): string | null {
  if (!name) return null;
  const base = name.replace(/^com\.filemaker\.theme\./, '');
  return base
    .split(/[_.]/)
    .filter(Boolean)
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

/**
 * Eigenschaften-Panel der Layout-Detailansicht — 2-spaltig:
 *   links  = alle Einzel-Optionen (Kontext-TO, Design, Menüset, Breite, Ansichten,
 *            Standardansicht, Layout-Menü-Sichtbarkeit; der Änderungsstempel steht in der
 *            Kopfzeile, ObjectChangeLine),
 *   rechts = die aktivierten Script-Trigger mit Link zum hinterlegten Script.
 * Bei zu schmaler Breite kollabieren die Spalten untereinander (CSS auto-fit).
 */
export const LayoutViewer: React.FC<LayoutViewerProps> = ({
  meta, triggers, originUuid, highlightUuids, parts = [], partCounts,
}) => {
  const { t } = useTranslation(['detail']);
  const tr: PartTranslate = (k, o) => t(k, o) as string;
  const [activeSection, setSection] = useSectionParam();
  // `?ref=part_…` (e.g. from the references of a break field) → highlight + scroll.
  const hlPartIdx = parts.findIndex(p => !!p.part_uuid && !!highlightUuids?.has(p.part_uuid));
  const hlPartRef = useRef<HTMLLIElement>(null);
  useEffect(() => {
    if (hlPartIdx >= 0 && hlPartRef.current) {
      hlPartRef.current.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }, [hlPartIdx]);
  const navigate = useNavigate();
  const fmtEvent = useTriggerEventFormat();
  const hlTriggerIds = useMemo(() => highlightedTriggerIds(highlightUuids), [highlightUuids]);
  const firstHlIndex = triggers.findIndex(tr => hlTriggerIds.has(tr.trigger_id));
  const firstHlRef = useRef<HTMLLIElement>(null);
  const hlSig = Array.from(hlTriggerIds).sort().join(',');
  useEffect(() => {
    if (firstHlIndex >= 0 && firstHlRef.current) {
      firstHlRef.current.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }, [hlSig, firstHlIndex]);

  const viewLabel: Record<'Form' | 'List' | 'Table', string> = {
    Form: t('detail:layoutViewer.viewForm') as string,
    List: t('detail:layoutViewer.viewList') as string,
    Table: t('detail:layoutViewer.viewTable') as string,
  };
  const views: Array<{ key: 'Form' | 'List' | 'Table'; available: boolean | null }> = [
    { key: 'Form', available: meta.view_form_available },
    { key: 'List', available: meta.view_list_available },
    { key: 'Table', available: meta.view_table_available },
  ];

  // Echter lokalisierter FileMaker-Anzeigename (z.B. „Apex Blau"); nur wenn nicht
  // vorhanden auf das aus dem internen Namen abgeleitete „Apex Blue" zurückfallen.
  const theme = meta.theme_display?.trim() || prettyTheme(meta.theme_name);
  const baseTheme = prettyTheme(meta.theme_base);
  const menuSet = meta.menuset_name ?? (t('detail:layoutViewer.menuSetDefault') as string);
  const defaultLabel = meta.default_view ? viewLabel[meta.default_view] : '—';
  const yes = t('detail:layoutViewer.yes') as string;
  const no = t('detail:layoutViewer.no') as string;
  return (
    <div className="fm-layout-props" aria-label={t('detail:layoutViewer.propertiesHeading') as string}>
      <div className="fm-layout-cols">
        {/* Links: Einzel-Optionen */}
        <dl className="fm-field-props fm-layout-col-left">
          {meta.to_name && (
            <>
              <dt>{t('detail:layoutViewer.contextTable')}</dt>
              <dd>
                {meta.to_uuid ? (
                  <button
                    type="button"
                    className="fm-field-link"
                    onClick={() => navigate(buildObjectPath(meta.to_uuid!, originUuid, meta.file_name))}
                  >
                    {meta.to_name}
                  </button>
                ) : (
                  meta.to_name
                )}
              </dd>
            </>
          )}

          {theme && (
            <>
              <dt>{t('detail:layoutViewer.theme')}</dt>
              <dd>
                {meta.theme_uuid ? (
                  <button
                    type="button"
                    className="fm-field-link"
                    onClick={() => navigate(buildObjectPath(meta.theme_uuid!, originUuid, meta.file_name))}
                  >
                    {theme}
                  </button>
                ) : (
                  theme
                )}
              </dd>
            </>
          )}
          {baseTheme && baseTheme !== theme && (
            <>
              <dt>{t('detail:layoutViewer.baseTheme')}</dt>
              <dd>{baseTheme}</dd>
            </>
          )}

          <dt>{t('detail:layoutViewer.menuSet')}</dt>
          <dd>{menuSet}</dd>

          {meta.width != null && (
            <>
              <dt>{t('detail:layoutViewer.width')}</dt>
              <dd>{meta.width}&nbsp;px</dd>
            </>
          )}

          <dt>{t('detail:layoutViewer.availableViews')}</dt>
          <dd className="fm-layout-views">
            {views.map(v => (
              <span
                key={v.key}
                className={
                  'fm-layout-view-chip' +
                  (v.available ? ' is-available' : ' is-disabled') +
                  (meta.default_view === v.key ? ' is-default' : '')
                }
                title={meta.default_view === v.key ? (t('detail:layoutViewer.defaultView') as string) : undefined}
              >
                {viewLabel[v.key]}
              </span>
            ))}
          </dd>

          <dt>{t('detail:layoutViewer.defaultView')}</dt>
          <dd>{defaultLabel}</dd>

          {meta.is_hidden != null && (
            <>
              <dt>{t('detail:layoutViewer.inLayoutMenus')}</dt>
              <dd>{meta.is_hidden ? no : yes}</dd>
            </>
          )}

          {/* Weitere „Allgemein"-Checkboxen (aus dem <Options>-Bitfeld). */}
          {([
            ['optAutoSave', meta.auto_save_changes],
            ['optFieldFrames', meta.show_field_frames],
            ['optFrameCurrentOnly', meta.frame_current_record_only],
            ['optShowCurrentInList', meta.show_current_record_list],
            ['optQuickFind', meta.quick_find_enabled],
          ] as const).map(([key, val]) => val != null && (
            <React.Fragment key={key}>
              <dt>{t(`detail:layoutViewer.${key}`)}</dt>
              <dd>{val ? yes : no}</dd>
            </React.Fragment>
          ))}

        </dl>

        {/* Rechts: aktivierte Script-Trigger */}
        <div className="fm-layout-col-right">
          <div className="fm-layout-triggers-heading">{t('detail:layoutViewer.triggersHeading')}</div>
          {triggers.length === 0 ? (
            <div className="fm-layout-no-triggers">{t('detail:layoutViewer.noTriggers')}</div>
          ) : (
            <ul className="fm-layout-triggers">
              {triggers.map((tr, idx) => {
                const isHl = hlTriggerIds.has(tr.trigger_id);
                const isFirstHl = idx === firstHlIndex;
                return (
                <li
                  key={tr.trigger_id}
                  ref={isFirstHl ? firstHlRef : undefined}
                  className={'fm-layout-trigger' + (isHl ? ' is-highlighted' : '')}
                >
                  {/* Event-Name als Link auf die ScriptTrigger-Detailseite;
                      reiner Text auf älteren API-Ständen ohne trigger_uuid. */}
                  {tr.trigger_uuid ? (
                    <button
                      type="button"
                      className="fm-field-link fm-layout-trigger-event"
                      title={t('detail:scriptTriggerDetail.openTrigger', { defaultValue: 'Script-Trigger öffnen' }) as string}
                      onClick={() => navigate(buildObjectPath(tr.trigger_uuid!, originUuid, tr.file_name))}
                    >
                      {fmtEvent(tr.trigger_action)}
                    </button>
                  ) : (
                    <span className="fm-layout-trigger-event">{fmtEvent(tr.trigger_action)}</span>
                  )}
                  {(tr.browse_mode || tr.find_mode || tr.preview_mode) && (
                    <span className="fm-layout-trigger-modes">
                      {tr.browse_mode && (
                        <span className="fm-layout-trigger-mode" title={t('detail:layoutObjectDetail.modeBrowse', { defaultValue: 'Browse mode' }) as string}>
                          {t('detail:layoutObjectDetail.colBrowse', { defaultValue: 'B' })}
                        </span>
                      )}
                      {tr.find_mode && (
                        <span className="fm-layout-trigger-mode" title={t('detail:layoutObjectDetail.modeFind', { defaultValue: 'Find mode' }) as string}>
                          {t('detail:layoutObjectDetail.colFind', { defaultValue: 'F' })}
                        </span>
                      )}
                      {tr.preview_mode && (
                        <span className="fm-layout-trigger-mode" title={t('detail:layoutObjectDetail.modePreview', { defaultValue: 'Preview mode' }) as string}>
                          {t('detail:layoutObjectDetail.colPreview', { defaultValue: 'P' })}
                        </span>
                      )}
                    </span>
                  )}
                  <span className="fm-layout-trigger-arrow" aria-hidden="true">→</span>
                  {tr.script_uuid ? (
                    <button
                      type="button"
                      className="fm-field-link"
                      onClick={() => navigate(buildObjectPath(tr.script_uuid!, originUuid, tr.file_name))}
                    >
                      {tr.script_name ?? tr.script_uuid}
                    </button>
                  ) : (
                    <span className="fm-layout-muted">{tr.script_name ?? '—'}</span>
                  )}
                </li>
                );
              })}
            </ul>
          )}

          {/* Layout-Sektionen in vertikaler Reihenfolge (wie der Dialog „Bereichseinrichtung"). */}
          {parts.length > 0 && (
            <>
              <div className="fm-layout-triggers-heading fm-layout-parts-heading">{t('detail:layoutViewer.partsHeading')}</div>
              <ul className="fm-layout-parts">
                {parts.map((p, idx) => {
                  const seq = p.part_seq;
                  const count = seq != null ? (partCounts?.get(seq) ?? 0) : p.object_count;
                  const isActive = seq != null && activeSection === seq;
                  const isHl = idx === hlPartIdx;
                  // Sub-summaries read like the dialog: "Sub-summary when sorted by ‹field› (trailing)" —
                  // term = part link, field = field link, position as suffix.
                  const pos = subSummaryPosition(p.part_kind);
                  const label = pos && p.break_field_name
                    ? t(partKindKey(p.part_kind), { defaultValue: p.part_type }) as string
                    : partLabel(tr, p);
                  const fieldText = p.break_to_name ? `${p.break_to_name}::${p.break_field_name}` : p.break_field_name;
                  return (
                    <li
                      key={seq ?? `idx-${idx}`}
                      ref={isHl ? hlPartRef : undefined}
                      className={'fm-layout-part' + (isHl ? ' is-highlighted' : '') + (isActive ? ' is-active' : '')}
                    >
                      <div className="fm-layout-part-row">
                        {p.part_uuid ? (
                          <button
                            type="button"
                            className="fm-field-link fm-layout-part-name"
                            onClick={() => navigate(buildObjectPath(p.part_uuid!, originUuid, meta.file_name))}
                          >
                            {label}
                          </button>
                        ) : (
                          <span className="fm-layout-part-name">{label}</span>
                        )}
                        {pos && p.break_field_name && (
                          <span className="fm-layout-part-break">
                            {p.break_field_uuid ? (
                              <button
                                type="button"
                                className="fm-field-link"
                                onClick={() => navigate(buildObjectPath(p.break_field_uuid!, originUuid, p.break_field_file ?? meta.file_name))}
                              >
                                {fieldText}
                              </button>
                            ) : (
                              <span className="fm-layout-muted" title={t('detail:layoutViewer.partsFieldUnresolved') as string}>
                                {fieldText}
                              </span>
                            )}
                            <span className="fm-layout-muted"> ({t(`detail:layoutParts.position.${pos}`)})</span>
                          </span>
                        )}
                        <span className="fm-layout-part-meta">
                          {t('detail:layoutViewer.partsHeight', { size: p.part_size })}
                          {' · '}
                          {t('detail:layoutViewer.partsObjects', { count })}
                        </span>
                        {seq != null && (
                          <button
                            type="button"
                            className={'fm-layout-part-filter' + (isActive ? ' is-active' : '')}
                            aria-pressed={isActive}
                            title={(isActive
                              ? t('detail:layoutViewer.partsFilterActiveTitle')
                              : t('detail:layoutViewer.partsFilterTitle')) as string}
                            onClick={() => setSection(isActive ? null : seq)}
                          >
                            <svg width="12" height="12" viewBox="0 0 16 16" aria-hidden="true">
                              <path d="M1.5 2h13l-5 6.2V13l-3 1.5V8.2z" fill={isActive ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
                            </svg>
                          </button>
                        )}
                      </div>
                    </li>
                  );
                })}
              </ul>
            </>
          )}
        </div>
      </div>
    </div>
  );
};
