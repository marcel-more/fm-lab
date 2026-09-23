import { useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { PrimitiveProps } from '../types';
import { formatTableCell, formatKpiValue } from './_format';
import { translateCellValue } from './_cellTranslate';
import { badgeToneClass, type BadgeTone } from './_badgeTone';
import { useRowSearch } from './_useRowSearch';
import { dispatchAction } from '../actions';
import { isActionActive } from '../actionState';
import { useSelection } from '../selectionContext';
import type { ActionSpec } from '../actions';
import { useXmlConvertFileStates, type XmlConvertFileState } from './useXmlConvertFileStates';

// Live-Status → Icon für die `liveStatusField`-Spalte (Datei-Status-Tabelle der
// XML-Konvertierung). Voller Lebenszyklus 🟡 → 🔥 → 🟢 → ✴️ → ✅, plus ⏭️ (Skip)
// und ⚠️ (Fehler).
const LIVE_STATE_ICON: Record<XmlConvertFileState, string> = {
  planned:   '🟡',
  skipped:   '⏭️',
  chunking:  '🔥',
  chunked:   '🟢',
  importing: '✴️',
  imported:  '✅',
  failed:    '⚠️',
};

interface ColumnSpec {
  field: string;
  label: string;
  align?: 'left' | 'right' | 'center';
  // Formats: everything _format.ts knows (number, count, badge, filesize,
  // date:*) plus 'copy' — renders the cell as a subtle copy-to-clipboard
  // button whose tooltip reveals the raw value (for long identifiers like
  // UUIDs that would waste column width as plain text).
  format?: string;
  // Semantic colour per badge value, overriding the value-derived class
  // (see _badgeTone.ts). Only meaningful with `format: 'badge'`.
  badgeTone?: BadgeTone;
}

interface ChipFilterGroup {
  label: string;
  values: string[];
}

interface ChipFilterSpec {
  field: string;
  allLabel?: string;
  // Gruppierung mehrerer Feld-Werte unter einem gemeinsamen Chip (z.B.
  // "If / Else If" → values ["If", "Else If"]). Ein Wert in mehreren
  // Gruppen würde mehrfach erscheinen — vermeiden. Werte, die in keiner
  // Gruppe stehen, erhalten weiterhin einen eigenen Chip.
  groups?: ChipFilterGroup[];
}

interface ChipOption {
  // Stabile ID des Chips. Bei Gruppen: "group:<label>", sonst der Wert selbst.
  id: string;
  label: string;
  count: number;
  // Welche Feld-Werte filtert dieser Chip? Bei Einzel-Chip: [value], bei Gruppe: alle Mitglieder.
  values: string[];
}

export function Table({ node, dataset, navigate }: PrimitiveProps) {
  const { t, i18n } = useTranslation(['common', 'detail', 'dashboard']);
  const lang = i18n.language;
  const props = node.props ?? {};
  const columns = (props.columns as ColumnSpec[]) ?? [];
  const rowKey = (props.rowKey as string) ?? undefined;
  const density = (props.density as string) ?? 'comfortable';
  const onRowClick = props.onRowClick as ActionSpec | undefined;
  const empty = props.empty as { message?: string } | undefined;
  // Selection lens (see selectionContext): `selectField` makes this table the
  // SOURCE — a row click toggles its value on the named channel; `highlightField`
  // makes it a TARGET — rows whose (comma-separated) field contains the selected
  // value get tinted. A table may be both. Costs no column width, unlike a
  // per-lens column on an already wide list.
  const selectionKey = props.selectionKey as string | undefined;
  const selectField = props.selectField as string | undefined;
  const highlightField = props.highlightField as string | undefined;
  const { selection, toggle } = useSelection();
  const selectedValue = selectionKey ? (selection[selectionKey] ?? null) : null;
  // Sortierung ist Opt-in. Default false, damit Bestands-Dashboards mit
  // bewusster Reihenfolge (z.B. die führende "Alle"-Zeile in api_families)
  // ihre Sortierung nicht verlieren, sobald sie einen Sort-State bekämen.
  const sortable = (props.sortable as boolean) ?? false;
  const chipFilter = props.chipFilter as ChipFilterSpec | undefined;
  // Opt-in: Live-Markierung der XML-Konvertierung. `liveHighlightField` (z.B.
  // "filename") wird gegen die `file_start`/`file`-Dateinamen abgeglichen und
  // markiert pro Zeile den Status: orange = gerade in Arbeit (im Parallel-Modus
  // mehrere gleichzeitig), grün = in diesem Lauf fertig, rot = fehlgeschlagen.
  // `liveStatusField` (z.B. "emoji") benennt zusätzlich die Spalte, deren Inhalt
  // während eines Laufs vom Live-Status überschrieben wird (Checkmark-Reset +
  // Pro-Datei-Checkmark). Nur die xml_convert-Datei-Status-Tabelle setzt das.
  const liveHighlightField = props.liveHighlightField as string | undefined;
  const liveStatusField = props.liveStatusField as string | undefined;
  // Opt-in Summary-Zusätze in der Zähler-Zeile über der Tabelle (nur die
  // xml_convert-Datei-Status-Tabelle nutzt das): `summaryNewField`/`summaryNewValue`
  // zählen die Zeilen mit einem bestimmten Feld-Wert (z.B. status="new") → "· N neu";
  // `summarySizeField` summiert ein Byte-Feld (z.B. size) → "· Gesamtgröße X".
  const summaryNewField = props.summaryNewField as string | undefined;
  const summaryNewValue = props.summaryNewValue as string | undefined;
  const summarySizeField = props.summarySizeField as string | undefined;
  // `summaryFlagField`/`summaryFlagValue` zählen Zeilen mit einem Feld-Wert und
  // rendern bei ≥ 1 Treffer ein hervorgehobenes Warn-Label (`summaryFlagLabelKey`,
  // i18n-Key, erhält { count, total }; Suffix `_partial` wenn nicht alle Zeilen
  // betroffen sind) plus optionalen Hinweistext (`summaryFlagHintKey`). Erster
  // Nutzer: „DDR-Info fehlt" auf der XML-Import-Seite (ddr_info === false).
  // null/undefined-Werte zählen nie als Treffer.
  const summaryFlagField = props.summaryFlagField as string | undefined;
  const summaryFlagValue = props.summaryFlagValue as unknown;
  const summaryFlagLabelKey = props.summaryFlagLabelKey as string | undefined;
  const summaryFlagHintKey = props.summaryFlagHintKey as string | undefined;
  // Opt-in: Zähler-/Status-Zeile immer rendern, auch wenn das Suchfeld (noch)
  // ausgeblendet ist (z.B. wenige Dateien). Ohne diese Prop erscheint die Zeile
  // wie bisher nur zusammen mit dem Suchfeld.
  const alwaysShowCount = (props.alwaysShowCount as boolean) ?? false;
  const liveStates = useXmlConvertFileStates(!!liveHighlightField);
  // Breite des Zeilen-Fortschrittsbalkens: der Balken spannt die ganze Zeile,
  // hängt aber als absolut positioniertes Overlay in der ERSTEN Zelle — ein
  // Hintergrund auf der <tr> ist keine Option, weil WebKit (Safari) den
  // Zeilenhintergrund pro Zelle neu anlegt und ein Verlauf dort in ebenso viele
  // Fragmente zerfällt, wie die Tabelle Spalten hat (siehe dashboard.css,
  // .dash-table__row--filling). Die Zeilenbreite ist die Tabellenbreite, also
  // messen wir die einmal und halten sie per ResizeObserver aktuell — nur
  // während eines laufenden Imports.
  const tableRef = useRef<HTMLTableElement>(null);
  const [tableWidth, setTableWidth] = useState(0);
  const measureTable = !!liveHighlightField && liveStates.active;
  useEffect(() => {
    if (!measureTable) return;
    const el = tableRef.current;
    if (!el) return;
    const measure = () => setTableWidth(el.getBoundingClientRect().width);
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [measureTable]);
  const rows = dataset?.data ?? [];
  const [searchParams] = useSearchParams();

  // Chip-Filter: Werte des konfigurierten Felds plus Counts, sortiert nach
  // Häufigkeit. Wird VOR der Volltextsuche angewendet, damit Counts und
  // Suchresultate konsistent bleiben. `chipValue` hält die Chip-ID (nicht den
  // Roh-Wert), damit Gruppen-Chips eindeutig adressierbar sind.
  const [chipValue, setChipValue] = useState<string | null>(null);
  const chipOptions = useMemo<ChipOption[]>(() => {
    if (!chipFilter) return [];

    // 1) Roh-Counts pro Wert.
    const counts = new Map<string, number>();
    for (const row of rows) {
      const v = row[chipFilter.field];
      if (v == null) continue;
      const key = String(v);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }

    // 2) Gruppen vorne anstellen, alle gruppierten Werte aus counts entfernen.
    const grouped = new Set<string>();
    const groupChips: ChipOption[] = (chipFilter.groups ?? []).map(g => {
      const sum = g.values.reduce((acc, v) => {
        grouped.add(v);
        return acc + (counts.get(v) ?? 0);
      }, 0);
      return { id: `group:${g.label}`, label: g.label, count: sum, values: g.values };
    }).filter(c => c.count > 0);

    // 3) Einzelne Chips für nicht-gruppierte Werte.
    const singleChips: ChipOption[] = Array.from(counts.entries())
      .filter(([value]) => !grouped.has(value))
      .map(([value, count]) => ({ id: value, label: value, count, values: [value] }));

    // 4) Sortierung: alle Chips gemeinsam nach Count (desc), bei Tie alphabetisch.
    return [...groupChips, ...singleChips].sort(
      (a, b) => b.count - a.count || a.label.localeCompare(b.label, lang),
    );
  }, [rows, chipFilter, lang]);

  const chipFiltered = useMemo(() => {
    if (!chipFilter || !chipValue) return rows;
    const active = chipOptions.find(c => c.id === chipValue);
    if (!active) return rows;
    const allowed = new Set(active.values);
    return rows.filter(r => allowed.has(String(r[chipFilter.field] ?? '')));
  }, [rows, chipFilter, chipValue, chipOptions]);

  // Generischer Volltext-Filter — sichtbar je nach `searchable`-Prop (true /
  // false / 'auto', Default 'auto' → ab >10 Rows). Greift VOR Sortierung,
  // damit der sortierte Output dem Suchergebnis entspricht.
  const search = useRowSearch(chipFiltered, {
    searchable: props.searchable as boolean | 'auto' | undefined,
    autoThreshold: props.searchAutoThreshold as number | undefined,
    placeholder: props.searchPlaceholder as string | undefined,
  });

  const [sortField, setSortField] = useState<string | null>(null);
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  // 'copy'-format cells: id of the cell whose value was just copied (brief
  // checkmark feedback, auto-reset).
  const [copiedCell, setCopiedCell] = useState<string | null>(null);

  const sortedRows = useMemo(() => {
    if (!sortField) return search.filtered;
    const dir = sortDir === 'asc' ? 1 : -1;
    return [...search.filtered].sort(
      (a, b) => compareValues(a[sortField], b[sortField], lang) * dir,
    );
  }, [search.filtered, sortField, sortDir, lang]);

  // Summary-Kennzahlen über den aktuell sichtbaren (gefilterten) Zeilen, damit
  // sie konsistent zum angezeigten "N Einträge" bleiben.
  const summaryNewCount = useMemo(() => {
    if (!summaryNewField) return null;
    const want = String(summaryNewValue ?? '');
    return sortedRows.reduce(
      (acc, r) => acc + (String(r[summaryNewField] ?? '') === want ? 1 : 0),
      0,
    );
  }, [sortedRows, summaryNewField, summaryNewValue]);

  const summaryTotalSize = useMemo(() => {
    if (!summarySizeField) return null;
    return sortedRows.reduce((acc, r) => acc + (Number(r[summarySizeField]) || 0), 0);
  }, [sortedRows, summarySizeField]);

  const summaryFlagCount = useMemo(() => {
    if (!summaryFlagField || !summaryFlagLabelKey) return null;
    const want = String(summaryFlagValue ?? '');
    return sortedRows.reduce((acc, r) => {
      const v = r[summaryFlagField];
      return acc + (v != null && String(v) === want ? 1 : 0);
    }, 0);
  }, [sortedRows, summaryFlagField, summaryFlagValue, summaryFlagLabelKey]);

  if (rows.length === 0) {
    return <div className="dash-table__empty">{empty?.message ?? t('common:noEntries')}</div>;
  }

  const selectable = !!(selectionKey && selectField);
  const clickable = !!onRowClick || selectable;
  const hasQuery = search.query.trim() !== '';

  const handleRowClick = (row: Record<string, unknown>) => {
    if (selectable) toggle(selectionKey as string, String(row[selectField as string] ?? ''));
    if (onRowClick) dispatchAction(onRowClick, row, { navigate });
  };

  /** Selected source row, or a target row belonging to the selected value. */
  const isSelected = (row: Record<string, unknown>): boolean => {
    if (!selectionKey || !selectedValue) return false;
    if (selectField && String(row[selectField] ?? '') === selectedValue) return true;
    if (!highlightField) return false;
    const raw = row[highlightField];
    if (raw == null) return false;
    return String(raw).split(',').map(s => s.trim()).filter(Boolean).includes(selectedValue);
  };

  const handleHeaderClick = (field: string) => {
    if (!sortable) return;
    if (sortField === field) {
      setSortDir(d => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortDir('asc');
    }
  };

  return (
    <div className={`dash-table-wrap dash-table--${density}`}>
      {chipFilter && chipOptions.length > 0 && (
        <div className="dash-chip-bar" role="group" aria-label={chipFilter.allLabel ?? t('common:all') as string}>
          <button
            type="button"
            className={`dash-chip${chipValue === null ? ' dash-chip--active' : ''}`}
            onClick={() => setChipValue(null)}
          >
            {chipFilter.allLabel ?? (t('common:all') as string)}
            <span className="dash-chip__count">{rows.length}</span>
          </button>
          {chipOptions.map(opt => (
            <button
              key={opt.id}
              type="button"
              className={`dash-chip${chipValue === opt.id ? ' dash-chip--active' : ''}`}
              onClick={() => setChipValue(opt.id)}
            >
              {opt.label}
              <span className="dash-chip__count">{opt.count}</span>
            </button>
          ))}
        </div>
      )}
      {(alwaysShowCount || search.visible) && (
        <div className="dash-search-bar">
          <span className="dash-search-bar__count">
            {t('detail:autoTable.rowCount', { count: sortedRows.length })}
            {hasQuery && sortedRows.length !== search.totalCount && (
              <> · {t('detail:autoTable.filteredFrom', { count: search.totalCount })}</>
            )}
            {summaryNewCount != null && summaryNewCount > 0 && (
              <> · {t('detail:autoTable.newCount', { count: summaryNewCount })}</>
            )}
            {summaryTotalSize != null && (
              <> · {t('detail:autoTable.totalSize', {
                size: formatKpiValue(summaryTotalSize, 'filesize', lang),
              })}</>
            )}
            {summaryFlagCount != null && summaryFlagCount > 0 && summaryFlagLabelKey && (
              <>
                {' · '}
                <span className="dash-search-bar__flag">
                  {t(
                    summaryFlagCount === sortedRows.length
                      ? summaryFlagLabelKey
                      : `${summaryFlagLabelKey}_partial`,
                    { count: summaryFlagCount, total: sortedRows.length },
                  ) as string}
                </span>
                {summaryFlagHintKey && <> – {t(summaryFlagHintKey) as string}</>}
              </>
            )}
          </span>
          {search.visible && (
            <input
              type="search"
              className="dash-search-bar__input"
              placeholder={search.placeholder}
              value={search.query}
              onChange={e => search.setQuery(e.target.value)}
            />
          )}
        </div>
      )}
      <table className="dash-table" ref={tableRef}>
        <thead>
          <tr>
            {columns.map(c => {
              const alignClass = c.align ? `dash-table__th--${c.align}` : '';
              const sortClass = sortable ? 'dash-autotable__th--sortable' : '';
              const className = [alignClass, sortClass].filter(Boolean).join(' ') || undefined;
              const isSorted = sortField === c.field;
              const indicator = isSorted ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
              return (
                <th
                  key={c.field}
                  className={className}
                  onClick={sortable ? () => handleHeaderClick(c.field) : undefined}
                >
                  {c.label}{indicator}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {sortedRows.map((row, i) => {
            // Index immer mit anhängen — Datasets dürfen mehrfache Werte in
            // rowKey-Spalten haben (z.B. mehrere Variablen mit gleichem
            // Variable_Name in unterschiedlichen Files).
            const key = rowKey ? `${String(row[rowKey] ?? '')}-${i}` : String(i);
            // Aktive-Filter-Markierung: wenn die onRowClick-Action einen
            // Filter setzen würde, der im URL bereits aktiv ist (z.B. die
            // Tabelle führt zu sich selbst mit `?api_family=X`), markieren
            // wir die Zeile farbig.
            const isActive = clickable && isActionActive(onRowClick, row, searchParams);
            // Live-Status dieser Zeile (nur während eines aktiven Laufs).
            const liveEntry = liveHighlightField && liveStates.active
              ? liveStates.states.get(String(row[liveHighlightField] ?? ''))
              : undefined;
            const liveState = liveEntry?.state;
            // Importierende Datei mit bekannter Chunk-Gesamtzahl → determinierter
            // Fortschrittsbalken (done/total) als linksbündiger Balken hinter der
            // Zeile. Solange total fehlt (kurz nach import_start im Fallback) bzw.
            // während des Splittens (chunking) bleibt es beim indeterminaten Puls.
            const fillTotal = liveState === 'importing' ? liveEntry?.total : undefined;
            const isFilling = typeof fillTotal === 'number' && fillTotal > 0;
            const fillPct = isFilling
              ? Math.max(0, Math.min(100, ((liveEntry?.done ?? 0) / fillTotal) * 100))
              : 0;
            // Zeilen-Highlight: chunking (+ importing ohne total) = indeterminater Puls,
            // importing mit total = wachsender Chunk-Balken, imported = grün, failed = rot.
            // planned/skipped/chunked bleiben neutral (nur das Status-Icon signalisiert sie).
            const rowClass = [
              clickable ? 'dash-table__row--clickable' : '',
              isActive ? 'dash-table__row--active' : '',
              isSelected(row) ? 'dash-table__row--selected' : '',
              isFilling ? 'dash-table__row--filling' : '',
              (!isFilling && (liveState === 'chunking' || liveState === 'importing')) ? 'dash-table__row--processing' : '',
              liveState === 'imported' ? 'dash-table__row--done' : '',
              liveState === 'failed' ? 'dash-table__row--failed' : '',
            ].filter(Boolean).join(' ') || undefined;
            // Fortschritts-Overlay: linksbündiger Balken bis fillPct der
            // ZEILEN-Breite, gerendert als absolut positioniertes <span> in der
            // ersten Zelle (siehe `tableWidth` oben). Die Farbe kommt aus der
            // theme-fähigen --fill-color (gesetzt von .dash-table__row--filling).
            const fillOverlay = isFilling ? (
              <span
                className="dash-table__fill"
                aria-hidden="true"
                style={{ width: `${(fillPct / 100) * tableWidth}px` }}
              />
            ) : null;
            return (
              <tr
                key={key}
                className={rowClass}
                onClick={clickable ? () => handleRowClick(row) : undefined}
                aria-current={isActive ? 'true' : undefined}
                aria-selected={selectable ? isSelected(row) : undefined}
              >
                {columns.map((c, ci) => {
                  let rawValue = row[c.field];
                  // Live-Status-Spalte (z.B. "emoji") während eines Laufs vom
                  // Live-Status überschreiben: beim Start alle Checkmarks leeren
                  // (Reset), pro fertiger Datei ✅ bzw. ⚠️ setzen. In Arbeit /
                  // noch nicht gestartet → leer. Nach Lauf-Ende (active=false)
                  // zeigt wieder der nachgeladene DB-Wert.
                  if (liveStatusField && c.field === liveStatusField && liveStates.active) {
                    rawValue = liveState ? LIVE_STATE_ICON[liveState] : '';
                  }
                  // Categorical cells (badges) frequently carry canonical
                  // English keys emitted from SQL — translate them so the UI
                  // matches the active language. Unknown values pass through.
                  // 'copy' format: no text — a subtle clipboard button whose
                  // tooltip shows the raw value; the click must not bubble into
                  // the row's onRowClick navigation.
                  if (c.format === 'copy') {
                    const copyValue = rawValue == null ? '' : String(rawValue);
                    const cellId = `${key}:${c.field}`;
                    const isCopied = copiedCell === cellId;
                    return (
                      <td
                        key={c.field}
                        className={c.align ? `dash-table__td--${c.align}` : undefined}
                      >
                        {ci === 0 && fillOverlay}
                        {copyValue !== '' && (
                          <button
                            type="button"
                            className={`dash-table__copy${isCopied ? ' dash-table__copy--copied' : ''}`}
                            title={copyValue}
                            aria-label={copyValue}
                            onClick={e => {
                              e.stopPropagation();
                              navigator.clipboard?.writeText(copyValue)
                                .then(() => {
                                  setCopiedCell(cellId);
                                  setTimeout(
                                    () => setCopiedCell(cur => (cur === cellId ? null : cur)),
                                    1500,
                                  );
                                })
                                .catch(() => { /* clipboard blocked */ });
                            }}
                          >
                            {isCopied ? (
                              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                                <polyline points="20 6 9 17 4 12" />
                              </svg>
                            ) : (
                              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
                              </svg>
                            )}
                          </button>
                        )}
                      </td>
                    );
                  }
                  const isBadge = c.format === 'badge';
                  const value = isBadge ? translateCellValue(rawValue, t) : rawValue;
                  const formatted = formatTableCell(value, c.format, lang);
                  // Chunk-Zähler „k von N" hinter dem Dateinamen, solange diese
                  // Datei importiert wird (Phase D). Nur in der Highlight-Spalte.
                  const chunkCounter =
                    liveHighlightField && c.field === liveHighlightField &&
                    liveState === 'importing' && liveEntry?.total != null
                      ? (t('dashboard:xmlConvert.chunkCounter', {
                          done: liveEntry.done ?? 0,
                          total: liveEntry.total,
                          defaultValue: '{{done}} von {{total}}',
                        }) as string)
                      : null;
                  return (
                    <td
                      key={c.field}
                      className={c.align ? `dash-table__td--${c.align}` : undefined}
                    >
                      {ci === 0 && fillOverlay}
                      {isBadge ? (
                        // A badge is a category, and an absent value is no
                        // category — render nothing rather than a pill around
                        // the "—" placeholder. This is what lets a column show
                        // only the exceptions (XML import: `ddr_flag` is set on
                        // the files MISSING DDR info and null on all others).
                        rawValue == null || rawValue === '' ? null : (
                          <span
                            className={`dash-badge ${badgeToneClass(rawValue, c.badgeTone)}`}
                          >
                            {formatted}
                          </span>
                        )
                      ) : (
                        <>
                          {formatted}
                          {chunkCounter && (
                            <span className="dash-table__chunk-counter">{chunkCounter}</span>
                          )}
                        </>
                      )}
                    </td>
                  );
                })}
              </tr>
            );
          })}
        </tbody>
      </table>
      {hasQuery && sortedRows.length === 0 && (
        <div className="dash-search-bar__empty">
          {t('detail:autoTable.noMatches', { query: search.query })}
        </div>
      )}
    </div>
  );
}


function compareValues(a: unknown, b: unknown, lang: string): number {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1;
  if (b === null || b === undefined) return -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'bigint' && typeof b === 'bigint') {
    return a < b ? -1 : a > b ? 1 : 0;
  }
  return String(a).localeCompare(String(b), lang, { numeric: true, sensitivity: 'base' });
}
