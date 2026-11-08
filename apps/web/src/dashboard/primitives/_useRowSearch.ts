import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useSearchParams } from 'react-router-dom';

/**
 * Optionen für `useRowSearch`.
 *
 * - `searchable: true`        → Suchfeld immer sichtbar.
 * - `searchable: false`       → Suchfeld nie sichtbar.
 * - `searchable: 'auto' | undefined` → automatisch sichtbar, sobald die
 *   Eingangs-Liste mehr Einträge als `autoThreshold` hat. Der Default ist 0:
 *   das Suchfeld steht damit über jeder nicht-leeren Liste. Bundles, die es
 *   erst ab einer bestimmten Länge wollen, setzen `searchAutoThreshold`.
 *
 * `placeholder` überschreibt den Default-Hinweistext im `<input>`.
 *
 * `searchParam` macht einen URL-Parameter zur Quelle der Wahrheit für den
 * Suchbegriff (statt des lokalen States). Damit übersteht die Eingabe Reload
 * und Zurück-Navigation, ist per Link teilbar und kann beim Wechsel auf eine
 * andere Seite mitgenommen werden. Opt-in: ohne die Option bleibt alles wie
 * bisher — der Param-Name wird vom Layout deklariert, nie hier hartkodiert.
 *
 * `resetParams` (only with `searchParam`): URL params dropped in the same
 * update whenever the search term changes — e.g. the page param of a
 * server-paged table, so a new term starts on page 1.
 *
 * `clientFilter: false` (only with `searchParam`): the SQL filters on the URL
 * term itself, the rows come back already matched — possibly on columns the
 * rows do not show — so the hook must not filter them a second time.
 *
 * `debounceMs` (only with `searchParam`): the input keeps the typed text and
 * writes the trimmed term into the URL after this pause — for a server-side
 * search, where every URL change is a request. A term set from outside (deep
 * link, back navigation) still fills the input.
 */
export interface RowSearchOptions {
  searchable?: boolean | 'auto';
  autoThreshold?: number;
  placeholder?: string;
  searchParam?: string;
  resetParams?: string[];
  clientFilter?: boolean;
  debounceMs?: number;
  extraText?: (row: Record<string, unknown>) => string;
}

export interface RowSearchResult<T> {
  /** Soll das Suchfeld gerendert werden? */
  visible: boolean;
  /** Aktueller Suchstring (kontrollierter Input). */
  query: string;
  setQuery: (q: string) => void;
  /** Eingangsliste, ggf. gefiltert. Identität referentiell stabil pro Render. */
  filtered: T[];
  /** Placeholder-Text für den `<input>`. */
  placeholder: string;
  /** Anzahl der Eingangs-Rows (vor Filter) — für Anzeigen wie „X von Y". */
  totalCount: number;
}

const DEFAULT_THRESHOLD = 0;

/**
 * Technische Spalten, die ihren Namen nicht ändern können, weil er Vertrag ist:
 *   `nav_uuid`  Anker der Analysis-Tests (Default von `analysis.scope.anchor`,
 *               von der Scope-Prüfung erwartet und von der Findings-Navigation
 *               im Frontend gelesen) — auch in User-Bundles unter tests-custom/
 *   `row_key`   Zeilen-Identität der Findings-Datasets
 *   `uuid`      Objekt-UUID der Custom-Queries (steht in deren @click_args)
 * AutoTable schließt `uuid` aus demselben Grund namentlich aus; hier gilt
 * dieselbe Liste, damit Table/List/TileGrid sich gleich verhalten.
 */
const EXCLUDED_FIELDS = new Set(['uuid', 'nav_uuid', 'row_key']);

/**
 * Generischer Volltext-Filter für Listen-Primitives (Table, List, TileGrid).
 * Eine Row matched, sobald irgendeines ihrer Feld-Werte den Suchstring
 * (case-insensitive) enthält. Nur skalare Werte werden durchsucht — Objekte
 * und Arrays werden über `JSON.stringify` flachgemacht (defensiv).
 *
 * Felder mit `_`-Präfix gelten als technisch (Navigations-Argumente, interne
 * IDs, Konventionsspalten wie `_chip_facets`) und bleiben außen vor — dieselbe
 * Konvention, die AutoTable schon für die Spaltenauswahl verwendet; dazu die
 * namentlich festgelegten Vertragsspalten aus `EXCLUDED_FIELDS`. Ohne diese
 * Grenze schlägt jede Suche fehl, deren Begriff zufällig in einem Klick-
 * Argument steckt: `type=PluginFunction` in jeder Zeile lässt die Suche nach
 * „plugin" jede Zeile treffen, die Liste bleibt unverändert und wirkt tot.
 *
 * Bei leerem Query wird die Originalliste referenziell zurückgegeben — kein
 * unnötiger Re-Render in nachgelagerten Memos.
 */
export function useRowSearch<T extends Record<string, unknown>>(
  rows: T[],
  options: RowSearchOptions = {},
): RowSearchResult<T> {
  const { t } = useTranslation();
  const { searchable, autoThreshold = DEFAULT_THRESHOLD, placeholder, searchParam, resetParams } = options;
  const clientFilter = !searchParam || options.clientFilter !== false;
  const resetKey = (resetParams ?? []).join('\u0000');
  const effectivePlaceholder = placeholder ?? (t('searchPlaceholder') as string);
  const [searchParams, setSearchParams] = useSearchParams();
  const debounceMs = searchParam && (options.debounceMs ?? 0) > 0 ? (options.debounceMs as number) : 0;
  const extraText = options.extraText;

  // URL-Modus (searchParam gesetzt) vs. Komponenten-State. Das Eingabefeld
  // zeigt immer `input`; im URL-Modus gilt für das Filtern der URL-Wert, den
  // `input` sofort oder (mit `debounceMs`) nach einer Pause schreibt. Ein
  // gemeinsamer State hält den Begriff auch über einen Wechsel des Modus.
  const urlQuery = searchParam ? (searchParams.get(searchParam) ?? '') : '';
  const [input, setInput] = useState(urlQuery);
  // Term this hook last wrote into the URL — such URL changes must not be
  // synced back into the input (the user may have typed on meanwhile).
  const written = useRef<string | null>(null);

  const writeUrl = useCallback(
    (next: string) => {
      if (!searchParam) return;
      // `replace`, damit nicht jeder Tastenanschlag einen History-Eintrag
      // erzeugt — sonst wäre „Zurück" ein Rückwärts-Tippen.
      setSearchParams(
        prev => {
          const merged = new URLSearchParams(prev);
          if (next) merged.set(searchParam, next);
          else merged.delete(searchParam);
          if (resetKey) for (const key of resetKey.split('\u0000')) merged.delete(key);
          return merged;
        },
        { replace: true },
      );
    },
    [searchParam, setSearchParams, resetKey],
  );

  const setQuery = useCallback(
    (next: string) => {
      setInput(next);
      if (searchParam && !debounceMs) writeUrl(next);
    },
    [searchParam, debounceMs, writeUrl],
  );

  // Debounced: the typed term reaches the URL after a pause.
  useEffect(() => {
    if (!debounceMs) return;
    const term = input.trim();
    if (term === urlQuery.trim()) return;
    const handle = setTimeout(() => {
      written.current = term;
      writeUrl(term);
    }, debounceMs);
    return () => clearTimeout(handle);
  }, [input, urlQuery, debounceMs, writeUrl]);

  // A URL term set from outside (deep link, back navigation, a reset by the
  // host) fills the input.
  useEffect(() => {
    if (written.current !== null && urlQuery.trim() === written.current) return;
    written.current = null;
    setInput(prev => (prev.trim() === urlQuery.trim() ? prev : urlQuery));
    // Reacts to URL changes only; typing is handled above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlQuery]);

  const query = input;
  const filterTerm = searchParam ? urlQuery : input;

  const visible =
    searchable === true
      ? true
      : searchable === false
        ? false
        : rows.length > autoThreshold; // 'auto' oder undefined

  const filtered = useMemo(() => {
    if (!visible || !clientFilter) return rows;
    const needle = filterTerm.trim().toLowerCase();
    if (!needle) return rows;
    return rows.filter(row =>
      rowMatches(row, needle) || (!!extraText && extraText(row).toLowerCase().includes(needle)));
  }, [rows, filterTerm, visible, clientFilter, extraText]);

  return {
    visible,
    query,
    setQuery,
    filtered,
    placeholder: effectivePlaceholder,
    totalCount: rows.length,
  };
}

function rowMatches(row: Record<string, unknown>, needle: string): boolean {
  for (const [key, value] of Object.entries(row)) {
    if (key.startsWith('_') || EXCLUDED_FIELDS.has(key.toLowerCase())) continue;
    if (value == null) continue;
    if (typeof value === 'object') {
      // Defensiv: verschachtelte Objekte/Arrays in String wandeln. Selten in
      // Dashboard-Datasets (DuckDB liefert primitive Skalare); abgesichert
      // für JSON-Spalten.
      if (JSON.stringify(value).toLowerCase().includes(needle)) return true;
      continue;
    }
    if (String(value).toLowerCase().includes(needle)) return true;
  }
  return false;
}
