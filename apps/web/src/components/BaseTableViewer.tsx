import React, { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { buildObjectPath } from '../lib/navigation';
import { indexLabel as sharedIndexLabel } from '../lib/fieldOptionLabels';
import './BaseTableViewer.css';

/**
 * Zeilen der BaseTable-Detail-Projektion (object_details_basetable.sql).
 * `section` diskriminiert: 'meta' | 'field' | 'to'. Alle Spalten sind in jeder
 * Zeile vorhanden (NULL wo nicht zutreffend).
 */
export interface BaseTableRow {
  section: 'meta' | 'field' | 'to';
  // meta
  bt_name: string | null;
  file_name: string | null;
  bt_uuid: string | null;
  bt_id: number | null;
  bt_comment: string | null;
  total_fields: number | null;
  normal_fields: number | null;
  calc_fields: number | null;
  summary_fields: number | null;
  other_fields: number | null;
  to_count: number | null;
  to_local_count: number | null;
  to_crossfile_count: number | null;
  // field
  field_name: string | null;
  field_type: string | null;
  data_type: string | null;
  field_comment: string | null;
  field_uuid: string | null;
  is_global: boolean | null;
  field_file: string | null;
  index_mode: string | null;   // Storage_Index normalisiert: 'None' | 'Minimal' | 'All'
  // to
  to_name: string | null;
  to_uuid: string | null;
  to_file: string | null;
  is_cross_file: boolean | null;
  // abgeleitete Feld-Facetten
  auto_enter: string | null;   // Auto-Eingabe-Kategorie: Serial/Lookup/Calc/Constant/Creation/Modification/Other (NULL = keine)
  is_validated: boolean | null; // hat eine echte Validierungsregel
}

interface BaseTableViewerProps {
  data: Array<Record<string, unknown>>;
}

type FieldSortKey = 'field_name' | 'field_type' | 'data_type' | 'storage' | 'index' | 'field_comment';
type ToSortKey = 'to_name' | 'to_file' | 'is_cross_file';
type SortDir = 'asc' | 'desc';
type FacetEntry = [string, number];

// Semantische Reihenfolge der Indizierung (keine → Minimal → Alle).
const INDEX_ORDER = ['None', 'Minimal', 'All'];
const AE_ORDER = ['Serial', 'Lookup', 'Calc', 'Constant', 'Creation', 'Modification', 'Other'];
const BOOL_ORDER = ['yes', 'no'];

// Facetten-Accessoren (rein, ohne t/State — modul-scoped, damit sie nicht als
// useMemo-Dependency auftauchen).
const fieldTypeOf = (f: BaseTableRow) => f.field_type ?? '—';
const dataTypeOf = (f: BaseTableRow) => f.data_type ?? '—';
const storageOf = (f: BaseTableRow) => (f.is_global ? 'global' : 'none');
const indexModeOf = (f: BaseTableRow) => f.index_mode ?? 'None';
const autoEnterOf = (f: BaseTableRow) => f.auto_enter ?? 'none';
const validatedOf = (f: BaseTableRow) => (f.is_validated ? 'yes' : 'no');
const commentedOf = (f: BaseTableRow) => (f.field_comment && f.field_comment.trim() ? 'yes' : 'no');
const AE_LABEL_KEY: Record<string, string> = {
  Serial: 'aeSerial', Lookup: 'aeLookup', Calc: 'aeCalc', Constant: 'aeConstant',
  Creation: 'aeCreation', Modification: 'aeModification', Other: 'aeOther',
};

/**
 * Strukturierter Detail-View einer Basistabelle.
 *  - Top-Block: Metadaten + Feld-Typ-Statistik als Tabelle (Total als letzte
 *    Zeile) + Anzahl Table Occurrences (lokal / Cross-File).
 *  - Felder → sortierbare, klickbare HTML-Tabelle (Name, Typ, Datentyp,
 *    Speicher, Indizierung, Kommentar) → navigiert zum Feld-Detail. Gemeinsame
 *    Volltextsuche + vier Chip-Gruppen (Typ, Datentyp, Speicher, Indizierung)
 *    mit Cross-Facetten-Zählern.
 *  - Table Occurrences → sortierbare, klickbare HTML-Tabelle (Name, Datei,
 *    Scope) → navigiert zum TO-Detail.
 */
export const BaseTableViewer: React.FC<BaseTableViewerProps> = ({ data }) => {
  const { t } = useTranslation(['detail', 'common']);
  const navigate = useNavigate();
  const { uuid: currentUuid } = useParams<{ uuid: string }>();

  const meta = data.find((r) => r.section === 'meta') as unknown as BaseTableRow | undefined;
  const fields = data.filter((r) => r.section === 'field') as unknown as BaseTableRow[];
  const tos = data.filter((r) => r.section === 'to') as unknown as BaseTableRow[];

  // Anzeige-Labels (i18n) für die abgeleiteten Spalten/Chips.
  const scopeLabel = (isCross: boolean | null) =>
    isCross
      ? t('detail:baseTable.scopeCrossFile', { defaultValue: 'Cross-File' })
      : t('detail:baseTable.scopeLocal', { defaultValue: 'Lokal' });
  const storageLabel = (v: string) =>
    v === 'global'
      ? t('detail:baseTable.storageGlobal', { defaultValue: 'global' })
      : t('detail:baseTable.storageNone', { defaultValue: '–' });
  // Gemeinsame Index-Labels mit dem Feld-Detailview (detail:fieldOptions.index.*) —
  // damit „Indizierung" an beiden Stellen identisch benannt ist.
  const indexLabel = (v: string) => sharedIndexLabel(t, v);
  const autoEnterLabel = (v: string) => t(`detail:baseTable.${AE_LABEL_KEY[v] ?? 'aeOther'}`, { defaultValue: v });
  const validatedLabel = (v: string) =>
    v === 'yes' ? t('detail:baseTable.validated', { defaultValue: 'validiert' })
      : t('detail:baseTable.notValidated', { defaultValue: 'nicht validiert' });
  const commentedLabel = (v: string) =>
    v === 'yes' ? t('detail:baseTable.commented', { defaultValue: 'dokumentiert' })
      : t('detail:baseTable.uncommented', { defaultValue: 'undokumentiert' });

  // ── Gemeinsamer Suchfilter (Felder + TOs) + vier Chip-Gruppen ──
  const [search, setSearch] = useState('');
  const [activeFieldTypes, setActiveFieldTypes] = useState<Set<string>>(new Set()); // Typ (Normal/Calculated/Summary)
  const [activeTypes, setActiveTypes] = useState<Set<string>>(new Set());           // Datentyp (Text/Number/…)
  const [activeStorage, setActiveStorage] = useState<Set<string>>(new Set());       // Speicher (global/none)
  const [activeIndex, setActiveIndex] = useState<Set<string>>(new Set());           // Indizierung (None/Minimal/All)
  const [activeAutoEnter, setActiveAutoEnter] = useState<Set<string>>(new Set());   // Auto-Eingabe-Kategorie
  const [activeValidated, setActiveValidated] = useState<Set<string>>(new Set());   // Validierung (yes/no)
  const [activeCommented, setActiveCommented] = useState<Set<string>>(new Set());   // Kommentar (yes/no)
  const searchLower = search.trim().toLowerCase();
  const anyChipActive =
    activeFieldTypes.size > 0 || activeTypes.size > 0 || activeStorage.size > 0 || activeIndex.size > 0
    || activeAutoEnter.size > 0 || activeValidated.size > 0 || activeCommented.size > 0;
  const makeToggle = (setFn: React.Dispatch<React.SetStateAction<Set<string>>>) => (v: string) =>
    setFn((prev) => {
      const next = new Set(prev);
      if (next.has(v)) next.delete(v); else next.add(v);
      return next;
    });
  const toggleFieldType = makeToggle(setActiveFieldTypes);
  const toggleType = makeToggle(setActiveTypes);
  const toggleStorage = makeToggle(setActiveStorage);
  const toggleIndex = makeToggle(setActiveIndex);
  const toggleAutoEnter = makeToggle(setActiveAutoEnter);
  const toggleValidated = makeToggle(setActiveValidated);
  const toggleCommented = makeToggle(setActiveCommented);
  const clearChipFilters = () => {
    setActiveFieldTypes(new Set());
    setActiveTypes(new Set());
    setActiveStorage(new Set());
    setActiveIndex(new Set());
    setActiveAutoEnter(new Set());
    setActiveValidated(new Set());
    setActiveCommented(new Set());
  };

  // ── Sortierung Felder-Tabelle ──
  const [fSortKey, setFSortKey] = useState<FieldSortKey>('field_name');
  const [fSortDir, setFSortDir] = useState<SortDir>('asc');
  const toggleFSort = (key: FieldSortKey) => {
    if (key === fSortKey) setFSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    else { setFSortKey(key); setFSortDir('asc'); }
  };

  // ── Sortierung TO-Tabelle ──
  const [tSortKey, setTSortKey] = useState<ToSortKey>('to_name');
  const [tSortDir, setTSortDir] = useState<SortDir>('asc');
  const toggleTSort = (key: ToSortKey) => {
    if (key === tSortKey) setTSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    else { setTSortKey(key); setTSortDir('asc'); }
  };

  // Volltextsuche über die Feld-Spalten (Name, Typ, Datentyp, Speicher, Indizierung, Kommentar).
  const fieldsSearched = useMemo(() => {
    if (!searchLower) return fields;
    return fields.filter((f) =>
      [f.field_name, f.field_type, f.data_type, f.field_comment,
        storageLabel(storageOf(f)), indexLabel(indexModeOf(f))]
        .some((v) => (v ?? '').toString().toLowerCase().includes(searchLower)));
    // Label-Helfer hängen nur von t ab (stabil); searchLower/fields treiben den Filter.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fields, searchLower]);

  // Cross-Facetten: die Anzahl je Chip berücksichtigt die Suche + die jeweils
  // ANDEREN Chip-Gruppen, nicht die eigene Auswahl (Standard-Facettenverhalten).
  // Aktive Chips bleiben (auch bei 0 Treffern) sichtbar, damit sie abwählbar sind.
  const { fieldsFiltered, facets } = useMemo(() => {
    const dims: Array<{ key: string; get: (f: BaseTableRow) => string; active: Set<string>; order: string[] | null }> = [
      { key: 'field_type', get: fieldTypeOf, active: activeFieldTypes, order: ['Normal', 'Calculated', 'Summary'] },
      { key: 'data_type', get: dataTypeOf, active: activeTypes, order: null },
      { key: 'storage', get: storageOf, active: activeStorage, order: ['global', 'none'] },
      { key: 'index', get: indexModeOf, active: activeIndex, order: INDEX_ORDER },
      { key: 'auto_enter', get: autoEnterOf, active: activeAutoEnter, order: AE_ORDER },
      { key: 'validated', get: validatedOf, active: activeValidated, order: BOOL_ORDER },
      { key: 'commented', get: commentedOf, active: activeCommented, order: BOOL_ORDER },
    ];
    const matchExcept = (f: BaseTableRow, exceptKey: string) =>
      dims.every((d) => d.key === exceptKey || d.active.size === 0 || d.active.has(d.get(f)));

    const facetMap: Record<string, FacetEntry[]> = {};
    for (const d of dims) {
      const m = new Map<string, number>();
      for (const f of fieldsSearched) {
        if (!matchExcept(f, d.key)) continue;
        const v = d.get(f);
        m.set(v, (m.get(v) ?? 0) + 1);
      }
      for (const v of d.active) if (!m.has(v)) m.set(v, 0);
      const entries = [...m.entries()];
      if (d.order) {
        const order = d.order;
        const rank = (v: string) => (order.indexOf(v) === -1 ? order.length : order.indexOf(v));
        entries.sort((a, b) => rank(a[0]) - rank(b[0]) || a[0].localeCompare(b[0]));
      } else {
        entries.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
      }
      facetMap[d.key] = entries;
    }

    const filtered = fieldsSearched.filter((f) =>
      dims.every((d) => d.active.size === 0 || d.active.has(d.get(f))));
    return { fieldsFiltered: filtered, facets: facetMap };
  }, [fieldsSearched, activeFieldTypes, activeTypes, activeStorage, activeIndex, activeAutoEnter, activeValidated, activeCommented]);

  const sortedFields = useMemo(() => {
    const dir = fSortDir === 'asc' ? 1 : -1;
    const val = (f: BaseTableRow): string => {
      switch (fSortKey) {
        case 'storage': return storageOf(f);
        case 'index': return String(INDEX_ORDER.indexOf(indexModeOf(f)));
        default: return (f[fSortKey as keyof BaseTableRow] ?? '').toString();
      }
    };
    return [...fieldsFiltered].sort((a, b) => {
      const cmp = val(a).localeCompare(val(b), undefined, { numeric: true, sensitivity: 'base' });
      // Gleichstand nach Name stabilisieren
      return (cmp !== 0 ? cmp : (a.field_name ?? '').localeCompare(b.field_name ?? '')) * dir;
    });
  }, [fieldsFiltered, fSortKey, fSortDir]);

  // Volltextsuche über die TO-Spalten (Name, Datei, Scope-Label).
  const tosFiltered = useMemo(() => {
    if (!searchLower) return tos;
    return tos.filter((to) =>
      [to.to_name, to.to_file, scopeLabel(to.is_cross_file)]
        .some((v) => (v ?? '').toString().toLowerCase().includes(searchLower)));
    // scopeLabel hängt nur von t ab (stabil); searchLower/tos treiben den Filter.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tos, searchLower]);

  const sortedTos = useMemo(() => {
    const dir = tSortDir === 'asc' ? 1 : -1;
    return [...tosFiltered].sort((a, b) => {
      let cmp: number;
      if (tSortKey === 'is_cross_file') cmp = Number(a.is_cross_file) - Number(b.is_cross_file);
      else cmp = (a[tSortKey] ?? '').toString().localeCompare(
        (b[tSortKey] ?? '').toString(), undefined, { numeric: true, sensitivity: 'base' });
      return (cmp !== 0 ? cmp : (a.to_name ?? '').localeCompare(b.to_name ?? '')) * dir;
    });
  }, [tosFiltered, tSortKey, tSortDir]);

  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const ariaSort = (active: boolean, dir: SortDir): 'ascending' | 'descending' | 'none' =>
    active ? (dir === 'asc' ? 'ascending' : 'descending') : 'none';
  const sortIndicator = (active: boolean, dir: SortDir) => (active ? (dir === 'asc' ? ' ▲' : ' ▼') : '');

  // Klickbare Zeile → Zielobjekt öffnen (currentUuid als ref-Origin, file zur Klon-Disambiguierung)
  const openObject = (targetUuid: string | null, file: string | null) => {
    if (!targetUuid) return;
    navigate(buildObjectPath(targetUuid, currentUuid ?? null, file));
  };

  // Eine Chip-Gruppe rendern (Label + Facetten-Chips mit Anzahl).
  const renderChipGroup = (
    label: string,
    ariaLabel: string,
    entries: FacetEntry[],
    active: Set<string>,
    toggle: (v: string) => void,
    valueLabel: (v: string) => React.ReactNode,
  ) => {
    if (entries.length === 0) return null;
    return (
      <div className="fm-bt-chips" role="group" aria-label={ariaLabel}>
        <span className="fm-bt-chips-label">{label}</span>
        {entries.map(([v, count]) => {
          const on = active.has(v);
          return (
            <button
              key={v}
              type="button"
              className={`fm-bt-chip${on ? ' fm-bt-chip--active' : ''}`}
              aria-pressed={on}
              onClick={() => toggle(v)}
            >
              {valueLabel(v)} <span className="fm-bt-chip-count">({count})</span>
            </button>
          );
        })}
      </div>
    );
  };

  return (
    <div className="object-detail fm-bt" aria-label={t('detail:baseTable.ariaLabel', { defaultValue: 'Tabellen-Details' }) as string}>
      <h2 className="type-detail-heading">{meta.bt_name}</h2>

      {/* ── Top-Block: Metadaten ── */}
      <dl className="fm-bt-meta">
        <dt>{t('detail:baseTable.metaName', { defaultValue: 'Name' })}</dt><dd>{meta.bt_name}</dd>
        <dt>{t('detail:baseTable.metaFile', { defaultValue: 'Datei' })}</dt><dd>{meta.file_name}</dd>
        <dt>UUID</dt><dd>{meta.bt_uuid}</dd>
        <dt>ID</dt><dd>{meta.bt_id}</dd>
        {meta.bt_comment && (
          <>
            <dt>{t('detail:baseTable.metaComment', { defaultValue: 'Kommentar' })}</dt>
            <dd style={{ whiteSpace: 'pre-wrap' }}>{meta.bt_comment}</dd>
          </>
        )}
      </dl>

      {/* ── Top-Block: Feld-Typ-Statistik (Total als letzte Zeile) ── */}
      <div className="fm-bt-stats">
        <table className="fm-bt-table fm-bt-stats-table">
          <thead>
            <tr>
              <th>{t('detail:baseTable.fields', { defaultValue: 'Felder' })}</th>
              <th className="fm-bt-num">{t('detail:baseTable.count', { defaultValue: 'Anzahl' })}</th>
            </tr>
          </thead>
          <tbody>
            <tr><td>Normal</td><td className="fm-bt-num">{meta.normal_fields}</td></tr>
            <tr><td>Calculated</td><td className="fm-bt-num">{meta.calc_fields}</td></tr>
            <tr><td>Summary</td><td className="fm-bt-num">{meta.summary_fields}</td></tr>
            {(meta.other_fields ?? 0) > 0 && (
              <tr><td>{t('detail:baseTable.otherType', { defaultValue: 'Sonstige' })}</td><td className="fm-bt-num">{meta.other_fields}</td></tr>
            )}
          </tbody>
          <tfoot>
            <tr className="fm-bt-total">
              <td>{t('detail:baseTable.total', { defaultValue: 'Total' })}</td>
              <td className="fm-bt-num">{meta.total_fields}</td>
            </tr>
          </tfoot>
        </table>

        {/* TO-Anzahl im Top-Block */}
        <table className="fm-bt-table fm-bt-stats-table">
          <thead>
            <tr>
              <th>{t('detail:baseTable.tableOccurrences', { defaultValue: 'Table Occurrences' })}</th>
              <th className="fm-bt-num">{t('detail:baseTable.count', { defaultValue: 'Anzahl' })}</th>
            </tr>
          </thead>
          <tbody>
            <tr><td>{t('detail:baseTable.scopeLocal', { defaultValue: 'Lokal' })}</td><td className="fm-bt-num">{meta.to_local_count}</td></tr>
            <tr><td>{t('detail:baseTable.scopeCrossFile', { defaultValue: 'Cross-File' })}</td><td className="fm-bt-num">{meta.to_crossfile_count}</td></tr>
          </tbody>
          <tfoot>
            <tr className="fm-bt-total">
              <td>{t('detail:baseTable.total', { defaultValue: 'Total' })}</td>
              <td className="fm-bt-num">{meta.to_count}</td>
            </tr>
          </tfoot>
        </table>
      </div>

      {/* ── Suchfilter (über beiden Tabellen: filtert Felder + TOs) ── */}
      <div className="fm-bt-toolbar">
        <input
          type="search"
          className="fm-bt-search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={t('detail:baseTable.searchPlaceholder', { defaultValue: 'Felder und Table Occurrences filtern…' }) as string}
          aria-label={t('detail:baseTable.searchPlaceholder', { defaultValue: 'Felder und Table Occurrences filtern…' }) as string}
        />
      </div>

      {/* ── Felder-Block ── */}
      {fields.length > 0 && (
        <section className="fm-bt-section">
          <h3 className="fm-bt-section-head">
            {t('detail:baseTable.fields', { defaultValue: 'Felder' })}
            <span className="fm-bt-sec-count">
              {' ('}{sortedFields.length}{sortedFields.length !== fields.length ? ` / ${fields.length}` : ''}{')'}
            </span>
          </h3>

          {/* Filter-Chips: Typ · Datentyp · Speicher · Indizierung */}
          <div className="fm-bt-filters">
            {renderChipGroup(
              t('detail:baseTable.type', { defaultValue: 'Typ' }),
              t('detail:baseTable.filterByFieldType', { defaultValue: 'Nach Typ filtern' }),
              facets.field_type, activeFieldTypes, toggleFieldType, (v) => v)}
            {renderChipGroup(
              t('detail:baseTable.dataType', { defaultValue: 'Datentyp' }),
              t('detail:baseTable.filterByType', { defaultValue: 'Nach Datentyp filtern' }),
              facets.data_type, activeTypes, toggleType, (v) => v)}
            {renderChipGroup(
              t('detail:baseTable.colStorage', { defaultValue: 'Speicher' }),
              t('detail:baseTable.filterByStorage', { defaultValue: 'Nach Speicher filtern' }),
              facets.storage, activeStorage, toggleStorage, (v) => storageLabel(v))}
            {renderChipGroup(
              t('detail:baseTable.colIndex', { defaultValue: 'Indizierung' }),
              t('detail:baseTable.filterByIndex', { defaultValue: 'Nach Indizierung filtern' }),
              facets.index, activeIndex, toggleIndex, (v) => indexLabel(v))}
            {renderChipGroup(
              t('detail:baseTable.groupAutoEnter', { defaultValue: 'Auto-Eingabe' }),
              t('detail:baseTable.filterByAutoEnter', { defaultValue: 'Nach Auto-Eingabe filtern' }),
              // „keine" (Mehrheit) ausblenden — der Filter bleibt korrekt, nur der Chip entfällt.
              facets.auto_enter.filter((e) => e[0] !== 'none'), activeAutoEnter, toggleAutoEnter, (v) => autoEnterLabel(v))}
            {/* Boolean-Facetten nur zeigen, wenn es tatsächlich beide Ausprägungen gibt. */}
            {facets.validated.length > 1 && renderChipGroup(
              t('detail:baseTable.groupValidation', { defaultValue: 'Validierung' }),
              t('detail:baseTable.filterByValidation', { defaultValue: 'Nach Validierung filtern' }),
              facets.validated, activeValidated, toggleValidated, (v) => validatedLabel(v))}
            {facets.commented.length > 1 && renderChipGroup(
              t('detail:baseTable.groupComment', { defaultValue: 'Kommentar' }),
              t('detail:baseTable.filterByComment', { defaultValue: 'Nach Kommentar filtern' }),
              facets.commented, activeCommented, toggleCommented, (v) => commentedLabel(v))}
            {anyChipActive && (
              <button
                type="button"
                className="fm-bt-chip fm-bt-chip--clear"
                onClick={clearChipFilters}
              >
                {t('detail:baseTable.clearFilter', { defaultValue: 'Zurücksetzen' })}
              </button>
            )}
          </div>

          <table className="fm-bt-table fm-bt-table--sortable fm-bt-table--clickable">
            <thead>
              <tr>
                {([
                  ['field_name', t('detail:baseTable.colName', { defaultValue: 'Name' })],
                  ['field_type', t('detail:baseTable.colType', { defaultValue: 'Typ' })],
                  ['data_type', t('detail:baseTable.colDataType', { defaultValue: 'Datentyp' })],
                  ['storage', t('detail:baseTable.colStorage', { defaultValue: 'Speicher' })],
                  ['index', t('detail:baseTable.colIndex', { defaultValue: 'Indizierung' })],
                  ['field_comment', t('detail:baseTable.colComment', { defaultValue: 'Kommentar' })],
                ] as [FieldSortKey, string][]).map(([key, label]) => (
                  <th
                    key={key}
                    className="fm-bt-th-sort"
                    aria-sort={ariaSort(fSortKey === key, fSortDir)}
                    onClick={() => toggleFSort(key)}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleFSort(key); } }}
                    tabIndex={0}
                    role="columnheader"
                  >
                    {label}{sortIndicator(fSortKey === key, fSortDir)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sortedFields.map((f) => (
                <tr
                  key={f.field_uuid ?? f.field_name}
                  className="fm-bt-row"
                  onClick={() => openObject(f.field_uuid, f.field_file)}
                  onKeyDown={(e) => { if (e.key === 'Enter') openObject(f.field_uuid, f.field_file); }}
                  tabIndex={0}
                  role="link"
                  title={t('detail:baseTable.openField', { defaultValue: 'Feld-Detail öffnen' }) as string}
                >
                  <td className="fm-bt-name">{f.field_name}</td>
                  <td>{f.field_type}</td>
                  <td>{f.data_type}</td>
                  <td className={f.is_global ? undefined : 'fm-bt-empty'}>{storageLabel(storageOf(f))}</td>
                  <td>{indexLabel(indexModeOf(f))}</td>
                  <td className={f.field_comment ? undefined : 'fm-bt-empty'}>{f.field_comment ?? '—'}</td>
                </tr>
              ))}
              {sortedFields.length === 0 && (
                <tr><td colSpan={6} className="fm-bt-noresults">{t('detail:baseTable.noMatches', { defaultValue: 'Keine Treffer' })}</td></tr>
              )}
            </tbody>
          </table>
        </section>
      )}

      {/* ── Table-Occurrences-Block ── */}
      {tos.length > 0 && (
        <section className="fm-bt-section">
          <h3 className="fm-bt-section-head">
            {t('detail:baseTable.tableOccurrences', { defaultValue: 'Table Occurrences' })}
            <span className="fm-bt-sec-count">
              {' ('}{sortedTos.length}{sortedTos.length !== tos.length ? ` / ${tos.length}` : ''}{')'}
            </span>
          </h3>
          <table className="fm-bt-table fm-bt-table--sortable fm-bt-table--clickable">
            <thead>
              <tr>
                {([
                  ['to_name', t('detail:baseTable.colName', { defaultValue: 'Name' })],
                  ['to_file', t('detail:baseTable.colFile', { defaultValue: 'Datei' })],
                  ['is_cross_file', t('detail:baseTable.colScope', { defaultValue: 'Scope' })],
                ] as [ToSortKey, string][]).map(([key, label]) => (
                  <th
                    key={key}
                    className="fm-bt-th-sort"
                    aria-sort={ariaSort(tSortKey === key, tSortDir)}
                    onClick={() => toggleTSort(key)}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleTSort(key); } }}
                    tabIndex={0}
                    role="columnheader"
                  >
                    {label}{sortIndicator(tSortKey === key, tSortDir)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sortedTos.map((to) => (
                <tr
                  key={to.to_uuid ?? to.to_name}
                  className="fm-bt-row"
                  onClick={() => openObject(to.to_uuid, to.to_file)}
                  onKeyDown={(e) => { if (e.key === 'Enter') openObject(to.to_uuid, to.to_file); }}
                  tabIndex={0}
                  role="link"
                  title={t('detail:baseTable.openTo', { defaultValue: 'TO-Detail öffnen' }) as string}
                >
                  <td className="fm-bt-name">{to.to_name}</td>
                  <td>{to.to_file}</td>
                  <td>
                    <span className={`fm-bt-scope fm-bt-scope--${to.is_cross_file ? 'cross' : 'local'}`}>
                      {scopeLabel(to.is_cross_file)}
                    </span>
                  </td>
                </tr>
              ))}
              {sortedTos.length === 0 && (
                <tr><td colSpan={3} className="fm-bt-noresults">{t('detail:baseTable.noMatches', { defaultValue: 'Keine Treffer' })}</td></tr>
              )}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
};
