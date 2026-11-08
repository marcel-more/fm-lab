import React from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildObjectPath } from '../lib/navigation';
import {
  BODY_KIND,
  decodePartOptions,
  partKindKey,
  partLabel,
  SUB_SUMMARY_KINDS,
  undecodedOptionBits,
  type PartTranslate,
} from '../lib/layoutParts';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './FieldViewer.css';
import './LayoutPartDetail.css';

/** Rows of object_details_layoutpart.sql (`section` discriminates). */
interface LayoutPartMetaRow {
  section: 'meta';
  part_uuid: string;
  part_seq: number;
  part_kind: number;
  part_type: string | null;
  definition_type: string | null;
  part_name: string | null;
  part_size: number;
  part_top: number;
  part_bottom: number;
  part_options: number | null;
  break_every: number | null;
  object_count_root: number | null;
  object_count_total: number | null;
  part_position: number | null;
  part_total: number | null;
  prev_part_uuid: string | null;
  prev_part_kind: number | null;
  prev_part_type: string | null;
  prev_part_break_field: string | null;
  next_part_uuid: string | null;
  next_part_kind: number | null;
  next_part_type: string | null;
  next_part_break_field: string | null;
  break_field_id: number | null;
  break_field_name: string | null;
  break_field_uuid: string | null;
  break_field_file: string | null;
  break_to_name: string | null;
  break_to_uuid: string | null;
  layout_uuid: string | null;
  layout_name: string | null;
  layout_id: number | null;
  layout_to_name: string | null;
  layout_to_uuid: string | null;
  base_table_name: string | null;
  base_table_uuid: string | null;
  base_table_file: string | null;
  file_name: string;
  local_style_name: string | null;
  local_style_type: string | null;
  theme_name: string | null;
  theme_display: string | null;
  theme_uuid: string | null;
  theme_is_classic: boolean | null;
  alt_row: boolean | null;
  alt_row_source: RowStateSource | null;
  active_row: boolean | null;
  active_row_source: RowStateSource | null;
}

type RowStateSource = 'local' | 'style' | 'theme' | 'default';

/** "com.filemaker.theme.apex_blue" → "Apex Blue" (fallback without a display name). */
function prettyTheme(name: string | null): string | null {
  if (!name) return null;
  return name
    .replace(/^com\.filemaker\.theme\./, '')
    .split(/[_.]/)
    .filter(Boolean)
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

const Check: React.FC<{ on: boolean; label: string; onText: string; offText: string; muted?: boolean }> = ({
  on, label, onText, offText, muted,
}) => (
  <span className={'fm-lp-check' + (on ? ' is-on' : '') + (muted ? ' is-muted' : '')}>
    <span className="fm-lp-check-box" role="img" aria-label={on ? onText : offText}>{on ? '✓' : ''}</span>
    <span className="fm-lp-check-label">{label}</span>
  </span>
);

interface LayoutPartDetailProps {
  uuid: string;
}

/**
 * Detail view of a layout part (section): type in the wording of the FileMaker
 * "Part Definition" dialog, position among the layout's parts with neighbour
 * links, geometry, break field (sub-summaries), context (layout, TO, base table),
 * the dialog options O1–O7 — O6/O7 with the origin of their effective value
 * (local → part style → theme → off). The objects of the part are listed in the
 * references tab (read path parent_part). "Show in layout" opens the layout with this part as section filter.
 */
export const LayoutPartDetail: React.FC<LayoutPartDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common', 'types']);
  const tr: PartTranslate = (k, o) => t(k, o) as string;
  const navigate = useNavigate();
  const currentFile = useCurrentFile();
  const { data, loading, error, retry } = useObjectDetails(uuid, currentFile);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  const meta = data?.find(r => r.section === 'meta') as unknown as LayoutPartMetaRow | undefined;
  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const file = meta.file_name;
  const link = (target: string | null, label: string, targetFile?: string | null): React.ReactNode =>
    target ? (
      <button type="button" className="fm-field-link" onClick={() => navigate(buildObjectPath(target, uuid, targetFile ?? file))}>
        {label}
      </button>
    ) : (
      label
    );
  const pt = (v: number | null) => (v == null ? '—' : t('detail:layoutPartDetail.unitPt', { value: v }));
  const isSub = SUB_SUMMARY_KINDS.has(meta.part_kind);
  const isBody = meta.part_kind === BODY_KIND;
  const heading = partLabel(tr, meta);
  const kindLabel = t(partKindKey(meta.part_kind), { defaultValue: meta.part_type ?? String(meta.part_kind) });
  // Exported @type only when it differs from the canonical type (localized / kind-5 mislabel).
  const showExportedType = !!meta.definition_type && meta.definition_type !== meta.part_type;
  const opts = decodePartOptions(meta.part_options);
  const rawExtra = undecodedOptionBits(meta.part_options);
  const on = t('detail:layoutPartDetail.optionOn') as string;
  const off = t('detail:layoutPartDetail.optionOff') as string;
  const themeName = meta.theme_display?.trim() || prettyTheme(meta.theme_name) || '';
  const sourceText = (src: RowStateSource | null): string | null => {
    switch (src) {
      case 'local': return t('detail:layoutPartDetail.sourceLocal') as string;
      case 'style': return t('detail:layoutPartDetail.sourceStyle', { name: meta.local_style_name ?? '' }) as string;
      case 'theme': return t('detail:layoutPartDetail.sourceTheme', { name: themeName }) as string;
      case 'default': return (meta.theme_is_classic
        ? t('detail:layoutPartDetail.sourceClassic')
        : t('detail:layoutPartDetail.sourceDefault')) as string;
      default: return null;
    }
  };
  const neighbour = (partUuid: string | null, kind: number | null, type: string | null, breakField: string | null) =>
    partUuid && kind != null
      ? link(partUuid, partLabel(tr, { part_kind: kind, part_type: type, break_field_name: breakField }))
      : '—';
  const breakFieldLabel = meta.break_field_name
    ? (meta.break_to_name ? `${meta.break_to_name}::${meta.break_field_name}` : meta.break_field_name)
    : null;
  const breakToDiffers = !!meta.break_to_name && !!meta.layout_to_name && meta.break_to_name !== meta.layout_to_name;

  return (
    <div className="fm-customfunction fm-field fm-lp" aria-label={t('detail:layoutPartDetail.ariaLabel') as string}>
      <div className="fm-customfunction-header">
        <h2 className="type-detail-heading">{heading}</h2>
        <span className="fm-customfunction-meta">{meta.layout_name ?? ''} · {file}</span>
      </div>

      {meta.layout_uuid && (
        <div className="fm-lp-actions">
          <Link
            to={buildObjectPath(meta.layout_uuid, null, file, { part: String(meta.part_seq) })}
            className="fm-lp-show-in-layout"
            title={t('detail:layoutPartDetail.showInLayoutTitle') as string}
          >
            {t('detail:layoutPartDetail.showInLayout')}
          </Link>
        </div>
      )}

      <div className="fm-field-sections">
        {/* Allgemein | Bereichsdefinition nebeneinander; schmal untereinander (Container-Query). */}
        <div className="fm-lp-cols">
          <section className="fm-field-section">
            <h3 className="fm-field-section-title">{t('detail:layoutPartDetail.groupGeneral')}</h3>
            <dl className="fm-field-props">
              <dt>{t('detail:layoutPartDetail.kind')}</dt>
              <dd>{kindLabel}{isSub && ` (${t(`detail:layoutParts.position.${meta.part_kind === 3 ? 'leading' : 'trailing'}`)})`}</dd>
              {showExportedType && (
                <>
                  <dt title={t('detail:layoutPartDetail.exportedTypeTitle') as string}>{t('detail:layoutPartDetail.exportedType')}</dt>
                  <dd><code>{meta.definition_type}</code></dd>
                </>
              )}
              {meta.part_name && (
                <>
                  <dt>{t('detail:layoutPartDetail.partName')}</dt>
                  <dd><code>{meta.part_name}</code></dd>
                </>
              )}
              {meta.part_position != null && meta.part_total != null && (
                <>
                  <dt>{t('detail:layoutPartDetail.position')}</dt>
                  <dd>{t('detail:layoutPartDetail.positionValue', { pos: meta.part_position, total: meta.part_total })}</dd>
                </>
              )}
              {meta.prev_part_uuid && (
                <>
                  <dt>{t('detail:layoutPartDetail.previous')}</dt>
                  <dd>{neighbour(meta.prev_part_uuid, meta.prev_part_kind, meta.prev_part_type, meta.prev_part_break_field)}</dd>
                </>
              )}
              {meta.next_part_uuid && (
                <>
                  <dt>{t('detail:layoutPartDetail.next')}</dt>
                  <dd>{neighbour(meta.next_part_uuid, meta.next_part_kind, meta.next_part_type, meta.next_part_break_field)}</dd>
                </>
              )}
              <dt>{t('detail:layoutPartDetail.height')}</dt>
              <dd>{pt(meta.part_size)}</dd>
              <dt>{t('detail:layoutPartDetail.top')}</dt>
              <dd>{pt(meta.part_top)}</dd>
              <dt>{t('detail:layoutPartDetail.bottom')}</dt>
              <dd>{pt(meta.part_bottom)}</dd>
              <dt>{t('detail:layoutPartDetail.objects')}</dt>
              <dd>
                {/* The objects themselves are listed in the references tab
                    ("contains", role parent_part — one filter chip per type). */}
                <Link
                  className="fm-field-link"
                  to={buildObjectPath(meta.part_uuid, null, file, { tab: 'references' })}
                  title={t('detail:layoutPartDetail.objectsShowInReferences') as string}
                >
                  {t('detail:layoutPartDetail.objectsValue', {
                    total: meta.object_count_total ?? 0,
                    root: meta.object_count_root ?? 0,
                  })}
                </Link>
              </dd>
            </dl>
          </section>
          <section className="fm-field-section">
            <h3 className="fm-field-section-title">{t('detail:layoutPartDetail.groupOptions')}</h3>
            <ul className="fm-lp-options">
              <li><Check on={opts.pageBreakBefore} label={t('detail:layoutParts.option.o1') as string} onText={on} offText={off} /></li>
              <li><Check
                on={opts.pageBreakAfterEvery}
                label={t('detail:layoutParts.option.o2', { n: meta.break_every ?? 'n' }) as string}
                onText={on}
                offText={off}
              /></li>
              <li><Check on={opts.restartPageNumbers} label={t('detail:layoutParts.option.o3') as string} onText={on} offText={off} /></li>
              <li><Check on={opts.allowBreakAcrossPages} label={t('detail:layoutParts.option.o4') as string} onText={on} offText={off} /></li>
              <li className="fm-lp-option-sub"><Check
                on={opts.discardRemainder}
                label={t('detail:layoutParts.option.o5') as string}
                onText={on}
                offText={off}
                muted={!opts.allowBreakAcrossPages}
              /></li>
              {(['alt', 'active'] as const).map(key => {
                const value = key === 'alt' ? meta.alt_row : meta.active_row;
                const src = key === 'alt' ? meta.alt_row_source : meta.active_row_source;
                const label = t(`detail:layoutParts.option.${key === 'alt' ? 'o6' : 'o7'}`) as string;
                return (
                  <li key={key}>
                    <Check on={isBody && !!value} label={label} onText={on} offText={off} muted={!isBody} />
                    <span className="fm-lp-option-source">
                      {isBody ? sourceText(src) : t('detail:layoutPartDetail.bodyOnly')}
                    </span>
                  </li>
                );
              })}
            </ul>
          </section>
        </div>

        {isSub && (
          <section className="fm-field-section">
            <h3 className="fm-field-section-title">{t('detail:layoutPartDetail.groupSort')}</h3>
            <dl className="fm-field-props">
              <dt>{t('detail:layoutPartDetail.sortedBy')}</dt>
              <dd>
                {breakFieldLabel ? (
                  meta.break_field_uuid
                    ? link(meta.break_field_uuid, breakFieldLabel, meta.break_field_file)
                    : <span className="fm-field-disabled" title={t('detail:layoutPartDetail.fieldUnresolved') as string}>{breakFieldLabel}</span>
                ) : '—'}
                {breakToDiffers && (
                  <span className="fm-field-origin"> — {t('detail:layoutPartDetail.sortToDiffers', { to: meta.layout_to_name })}</span>
                )}
              </dd>
            </dl>
          </section>
        )}

        <section className="fm-field-section">
          <h3 className="fm-field-section-title">{t('detail:layoutPartDetail.groupContext')}</h3>
          <dl className="fm-field-props">
            <dt>{t('detail:layoutPartDetail.layout')}</dt>
            <dd>{meta.layout_name ? link(meta.layout_uuid, meta.layout_name) : '—'}</dd>
            {meta.layout_to_name && (
              <>
                <dt>{t('detail:layoutPartDetail.contextTable')}</dt>
                <dd>{link(meta.layout_to_uuid, meta.layout_to_name)}</dd>
              </>
            )}
            {meta.base_table_name && (
              <>
                <dt>{t('detail:layoutPartDetail.baseTable')}</dt>
                <dd>{link(meta.base_table_uuid, meta.base_table_name, meta.base_table_file)}</dd>
              </>
            )}
            <dt>{t('detail:layoutPartDetail.file')}</dt>
            <dd>{file}</dd>
          </dl>
        </section>

        <section className="fm-field-section">
          <h3 className="fm-field-section-title">{t('detail:layoutPartDetail.groupTechnical')}</h3>
          <dl className="fm-field-props">
            <dt>{t('detail:layoutPartDetail.optionsRaw')}</dt>
            <dd>
              <code>{meta.part_options ?? 0}</code>
              {rawExtra !== 0 && (
                <span className="fm-field-origin"> — {t('detail:layoutPartDetail.optionsUndecoded', { bits: rawExtra })}</span>
              )}
            </dd>
            <dt>Part_Kind · Part_Seq</dt>
            <dd><code>{meta.part_kind} · {meta.part_seq}</code></dd>
            {meta.local_style_name && (
              <>
                <dt>LocalCSS</dt>
                <dd><code>{meta.local_style_name}{meta.local_style_type ? ` (${meta.local_style_type})` : ''}</code></dd>
              </>
            )}
          </dl>
        </section>
      </div>
    </div>
  );
};
