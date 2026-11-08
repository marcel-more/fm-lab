import React from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { buildObjectPath } from '../lib/navigation';
import { operatorSymbol } from '../lib/relationshipOperator';
import './RelationshipViewer.css';

/**
 * Zeilen der Relationship-Detail-Projektion (object_details_relationship.sql).
 * `section` diskriminiert: 'meta' (eine Zeile, Relations-Skalare) | 'predicate' (je Join-Bedingung).
 */
export interface RelationshipRow {
  section: 'meta' | 'predicate';
  predicate_index: number | null;
  rel_id: number | null;
  object_uuid: string | null;
  rel_name: string | null;
  file_name: string | null;
  left_to_name: string | null;
  left_to_uuid: string | null;
  right_to_name: string | null;
  right_to_uuid: string | null;
  left_create: boolean | null;
  left_delete: boolean | null;
  right_create: boolean | null;
  right_delete: boolean | null;
  left_sort_enabled: boolean | null;
  left_sort_fields: string | null;
  right_sort_enabled: boolean | null;
  right_sort_fields: string | null;
  operator: string | null;
  left_field_name: string | null;
  left_field_uuid: string | null;
  right_field_name: string | null;
  right_field_uuid: string | null;
}

interface RelationshipViewerProps {
  data: Array<Record<string, unknown>>;
}

export const RelationshipViewer: React.FC<RelationshipViewerProps> = ({ data }) => {
  const { t } = useTranslation(['detail', 'common']);
  const { uuid: currentUuid } = useParams<{ uuid: string }>();

  const meta = data.find((r) => r.section === 'meta') as unknown as RelationshipRow | undefined;
  const predicates = (data.filter((r) => r.section === 'predicate') as unknown as RelationshipRow[])
    .sort((a, b) => (a.predicate_index ?? 0) - (b.predicate_index ?? 0));

  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  // Klon-Disambiguierung: `file` ist die Zieldatei. TableOccurrences sind
  // datei-lokal (liegen im Relationship-Graph derselben Datei) → meta.file_name
  // ist korrekt. Prädikat-Felder können über externe TOs cross-file sein → kein
  // file (Graceful Downgrade, kein 404-Risiko).
  const link = (label: string | null, uuid: string | null, className: string, file?: string | null) => {
    if (label && uuid) {
      return <Link to={buildObjectPath(uuid, currentUuid ?? null, file ?? null)} className={className}>{label}</Link>;
    }
    return <span className={className}>{label ?? '—'}</span>;
  };

  // Optionen je Seite (nur aktivierte werden gelistet — wie im FileMaker-Dialog).
  const sideOptions = (side: 'left' | 'right') => {
    const create = side === 'left' ? meta.left_create : meta.right_create;
    const del = side === 'left' ? meta.left_delete : meta.right_delete;
    const sortOn = side === 'left' ? meta.left_sort_enabled : meta.right_sort_enabled;
    const sortFields = side === 'left' ? meta.left_sort_fields : meta.right_sort_fields;
    const opts: React.ReactNode[] = [];
    if (create) opts.push(t('detail:relationship.allowCreate', { defaultValue: 'Erstellung von Datensätzen in dieser Tabelle über diese Beziehung zulassen' }));
    if (del) opts.push(t('detail:relationship.cascadeDelete', { defaultValue: 'Bezugsdatensätze in dieser Tabelle löschen, wenn ein Datensatz in der anderen Tabelle gelöscht wird' }));
    if (sortOn) {
      const fields = (sortFields ?? '').split(', ').filter((f) => f.length > 0);
      opts.push(
        <>
          {t('detail:relationship.sortRecords', { defaultValue: 'Datensätze sortieren' })}:
          {fields.length > 0 && (
            <ul className="fm-rel-sort-fields">
              {fields.map((f, i) => <li key={i}>{f}</li>)}
            </ul>
          )}
        </>
      );
    }
    return opts;
  };

  const leftOpts = sideOptions('left');
  const rightOpts = sideOptions('right');

  return (
    <div className="fm-relationship" aria-label={t('detail:relationship.ariaLabel', { defaultValue: 'Relationship Details' }) as string}>
      {/* ── Metadaten (wie gehabt) ── */}
      <h2 className="type-detail-heading">{meta.rel_name}</h2>
      <dl className="fm-rel-meta">
        <dt>{t('detail:relationship.metaName', { defaultValue: 'Name' })}</dt><dd>{meta.rel_name}</dd>
        <dt>{t('detail:relationship.metaType', { defaultValue: 'Type' })}</dt><dd>Relationship</dd>
        <dt>{t('detail:relationship.metaFile', { defaultValue: 'File' })}</dt><dd>{meta.file_name}</dd>
        <dt>UUID</dt><dd>{meta.object_uuid}</dd>
        <dt>{t('detail:relationship.metaSource', { defaultValue: 'Source Table' })}</dt><dd>RelationshipCatalog</dd>
        <dt>ID</dt><dd>{meta.rel_id}</dd>
      </dl>

      {/* ── Grafische Beziehungs-Darstellung ── */}
      <div className="fm-rel-graph" role="group">
        {/* Titelbalken der beiden TOs + bidirektionaler Pfeil (gleiche Spalten wie die Prädikat-Zeilen) */}
        <div className="fm-rel-titles">
          <span className="fm-rel-spacer" aria-hidden="true" />
          <div className="fm-rel-title-box">{link(meta.left_to_name, meta.left_to_uuid, 'fm-rel-to-link', meta.file_name)}</div>
          <div className="fm-rel-arrow" aria-hidden="true">⟷</div>
          <div className="fm-rel-title-box">{link(meta.right_to_name, meta.right_to_uuid, 'fm-rel-to-link', meta.file_name)}</div>
        </div>

        {/* Prädikat-Zeilen: [UND] linkes Feld = rechtes Feld */}
        <div className="fm-rel-predicates">
          {predicates.map((p, i) => (
            <div className="fm-rel-pred-row" key={p.predicate_index ?? i}>
              <span className="fm-rel-and">{i > 0 ? t('detail:relationship.and', { defaultValue: 'UND' }) : ''}</span>
              <span className="fm-rel-field fm-rel-field--left">
                {link(p.left_field_name, p.left_field_uuid, 'fm-rel-field-link')}
              </span>
              <span className="fm-rel-op">{operatorSymbol(p.operator)}</span>
              <span className="fm-rel-field fm-rel-field--right">
                {link(p.right_field_name, p.right_field_uuid, 'fm-rel-field-link')}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* ── Optionen je Seite (nur aktivierte) ── */}
      <hr className="fm-rel-sep" />
      <div className="fm-rel-options">
        <div className="fm-rel-opt-col">
          <div className="fm-rel-opt-head">{meta.left_to_name}</div>
          {leftOpts.length > 0
            ? <ul>{leftOpts.map((o, i) => <li key={i}>{o}</li>)}</ul>
            : <div className="fm-rel-opt-none">{t('detail:relationship.noOptions', { defaultValue: '— keine Optionen aktiv —' })}</div>}
        </div>
        <div className="fm-rel-opt-col">
          <div className="fm-rel-opt-head">{meta.right_to_name}</div>
          {rightOpts.length > 0
            ? <ul>{rightOpts.map((o, i) => <li key={i}>{o}</li>)}</ul>
            : <div className="fm-rel-opt-none">{t('detail:relationship.noOptions', { defaultValue: '— keine Optionen aktiv —' })}</div>}
        </div>
      </div>
    </div>
  );
};
