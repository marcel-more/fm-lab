import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { LayoutObject } from './useLayoutData';
import { useUrlState, stringSetCodec } from './useUrlState';

const EMPTY_TYPES = new Set<string>();

/**
 * Kategorie-Prädikate der Calculation-Chips: markiert Objekte, die unsichtbare
 * Layout-Logik tragen. Signale kommen katalog-basiert aus dem Canvas-Payload
 * (cf_count aus LayoutObjectConditions, hide/tooltip aus den LayoutObjects-
 * Spalten, trigger_count aus ScriptTriggers mit Owner_Type='LayoutObject',
 * display_calc_count aus CalculationsCatalog mit Rolle display_calculation).
 * Der Chip zählt TRÄGER, nicht Regeln — deaktivierte CF-Regeln zählen mit.
 */
export const CALC_CATEGORY_KEYS = ['cf', 'hide', 'trigger', 'tooltip', 'display'] as const;
export type CalcCategoryKey = (typeof CALC_CATEGORY_KEYS)[number];

export const CALC_PREDICATES: Record<CalcCategoryKey, (o: LayoutObject) => boolean> = {
  cf: o => o.cf_count > 0,
  hide: o => o.hide_text != null,
  trigger: o => o.trigger_count > 0,
  tooltip: o => o.tooltip_text != null,
  display: o => o.display_calc_count > 0,
};

function matchesCalc(o: LayoutObject, activeCalc: Set<string>): boolean {
  // OR innerhalb der Gruppe — ein Objekt matcht, sobald EINE aktive Kategorie greift.
  for (const key of CALC_CATEGORY_KEYS) {
    if (activeCalc.has(key) && CALC_PREDICATES[key](o)) return true;
  }
  return false;
}

/** URL param of the section (layout part) filter — value = Part_Seq. */
export const SECTION_PARAM = 'part';

/** Parses the section param; null = all parts. */
export function parseSectionParam(raw: string | null | undefined): number | null {
  if (!raw) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * Removes the reference-mode params (`ref`, findings context) from a param set —
 * a user interaction ends the reference mode in the SAME URL update.
 */
export function clearRefParams(next: URLSearchParams): void {
  next.delete('ref');
  next.delete('ref_src');
  next.delete('ref_msgid');
  next.delete('marks');
  for (const k of Array.from(next.keys())) {
    if (k.startsWith('ref_arg_')) next.delete(k);
  }
}

/**
 * Section filter outside the canvas (part list of the properties panel): reads
 * the same URL param and sets it atomically together with ending the
 * reference mode, exactly like a filter change inside the canvas.
 */
export function useSectionParam(): [number | null, (seq: number | null) => void] {
  const [searchParams, setSearchParams] = useSearchParams();
  const section = parseSectionParam(searchParams.get(SECTION_PARAM));
  const setSection = useCallback((seq: number | null) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      if (seq == null) next.delete(SECTION_PARAM);
      else next.set(SECTION_PARAM, String(seq));
      clearRefParams(next);
      return next;
    }, { replace: true });
  }, [setSearchParams]);
  return [section, setSection];
}

export type LayoutSearchAPI = {
  query: string;
  setQuery: (q: string) => void;

  activeTypes: Set<string>;
  toggleType: (type: string) => void;
  setTypes: (types: string[], active: boolean) => void;
  clearTypes: () => void;

  activeCalc: Set<string>;
  toggleCalc: (key: string) => void;

  /** Selected section (Part_Seq) or null = all parts. */
  section: number | null;
  setSection: (seq: number | null) => void;
  /** Objects of the selected section (all objects without a section). */
  scopedObjects: LayoutObject[];

  matchUuids: Set<string>;
  matches: LayoutObject[];

  selectedUuid: string | null;
  selectNext: () => void;
  selectPrev: () => void;
  clear: () => void;

  filterActive: boolean;
};

/**
 * Konsolidierter Such-Text pro Layout-Objekt:
 * deckt Feldname, Script-Caption, Text-Inhalt, Object_Name, Object_Type sowie
 * Hide- und Tooltip-Formeln ab, sodass eine einzelne Substring-Eingabe alle
 * relevanten Bezeichnungen und die unsichtbare Layout-Logik findet.
 */
function buildSearchText(o: LayoutObject): string {
  return [
    o.field_name ?? '',
    o.script_name ?? '',
    o.text_content ?? '',
    o.object_name ?? '',
    o.object_type,
    o.hide_text ?? '',
    o.tooltip_text ?? '',
  ].join(' ').toLowerCase();
}

/**
 * Steuert Such-Filter, Typ-Pillen-Filter und Selektion (TAB-Cursor) für die Layout-Ansicht.
 *
 * Sortierung der Fundmenge entspricht der SVG-Render-Reihenfolge: (Nesting_Level, Object_ID).
 * Die Daten kommen bereits sortiert aus dem SQL-Template, deshalb reicht ein einfacher Filter.
 *
 * Cross-Reference Highlight:
 * `externalMatchUuids` injiziert eine Vor-Auswahl, die als weicher Filter wirkt,
 * solange der User nicht selbst interagiert. Sobald der User aktiv sucht oder
 * einen Typ-Filter aktiviert, wird der `?ref=`-Param ATOMAR im selben URL-Update
 * mitentfernt — der Referenz-Modus war kontextuell, neue Interaktion beendet ihn.
 *
 * Warum atomar? Andernfalls würde der separate `setRefParam('')`-Call aus
 * DetailView (anderes useSearchParams-Hook) mit dem Filter-`setSearchParams`
 * kollidieren — beide Hook-Instanzen halten je eine eigene Memo-Closure auf
 * `searchParams`, und der zweite Aufruf würde den Stand des ersten überschreiben.
 */
export function useLayoutSearch(
  allObjects: LayoutObject[],
  externalMatchUuids?: Set<string> | null,
  onUserInteraction?: () => void,
  /** object_uuid → Part_Seq (catalog value or fallback rule); scopes the section filter. */
  partOf?: Map<string, number | null> | null,
): LayoutSearchAPI {
  // Such- und Filter-State liegt in der URL — Stack erhält den State beim
  // Zurück-Navigieren. selectedUuid bleibt transient (Cursor pro TAB-Schritt
  // soll nicht in jedem Render die URL fluten).
  //
  // Lesen via useUrlState, Schreiben für User-Interaktionen via setSearchParams
  // direkt (atomarer Multi-Param-Update mit ref-Clear).
  const [query, setQueryState] = useUrlState<string>('q', '');
  const [activeTypes] = useUrlState<Set<string>>('types', EMPTY_TYPES, stringSetCodec);
  const [activeCalc] = useUrlState<Set<string>>('calc', EMPTY_TYPES, stringSetCodec);
  const [searchParams, setSearchParams] = useSearchParams();
  const section = parseSectionParam(searchParams.get(SECTION_PARAM));

  // Section scope comes BEFORE every other dimension: search, type/calc chips,
  // match counts and the TAB cursor all work inside the selected part. The
  // section itself is no match filter (in-scope objects keep their normal look).
  const objects = useMemo(() => {
    if (section == null || !partOf) return allObjects;
    return allObjects.filter(o => partOf.get(o.object_uuid) === section);
  }, [allObjects, partOf, section]);
  const [selectedUuid, setSelectedUuid] = useState<string | null>(null);

  // Bei Layout-Wechsel: nur Selektion zurücksetzen — Suche/Filter bleiben durch
  // URL-Persistenz intakt; auto-select-Effekt greift im neuen Match-Set.
  useEffect(() => {
    setSelectedUuid(null);
  }, [objects]);

  // Stable empty-set Identität für externalMatchUuids, damit useMemo nicht
  // bei jedem Render neue Refs sieht, wenn das Set extern leer übergeben wird.
  const externalHasItems = !!(externalMatchUuids && externalMatchUuids.size > 0);

  const matches = useMemo<LayoutObject[]>(() => {
    // UND zwischen den Dimensionen: Suchtext ∩ Typ-Filter ∩ Calc-Filter.
    const typeFiltered = activeTypes.size === 0
      ? objects
      : objects.filter(o => activeTypes.has(o.object_type));

    let result = activeCalc.size === 0
      ? typeFiltered
      : typeFiltered.filter(o => matchesCalc(o, activeCalc));
    if (query !== '') {
      const q = query.toLowerCase();
      result = result.filter(o => buildSearchText(o).includes(q));
    } else if (activeTypes.size === 0 && activeCalc.size === 0 && externalHasItems) {
      // Ref-Vorauswahl wirkt NUR, solange weder Suche noch Typ-Filter aktiv sind.
      // Sobald der User selbst filtert, gewinnt seine Wahl — der ref-Param wird
      // zusätzlich im URL-Update mit entfernt (siehe runUserUpdate unten).
      result = result.filter(o => externalMatchUuids!.has(o.object_uuid));
    }
    return result;
  }, [objects, activeTypes, activeCalc, query, externalHasItems, externalMatchUuids]);

  const matchUuids = useMemo(() => {
    const s = new Set<string>();
    for (const o of matches) s.add(o.object_uuid);
    return s;
  }, [matches]);

  const anyDimensionActive =
    query !== '' || activeTypes.size > 0 || activeCalc.size > 0 || externalHasItems;

  // Selektion mit Fundmenge synchronisieren — analog useGraphSearch:
  //  - genau 1 Treffer → diesen automatisch selektieren (rote Umrandung sofort);
  //    NUR bei aktiver Filter-Dimension — ohne Filter ist die Fundmenge „alle
  //    Objekte" und ein Ein-Objekt-Layout würde sich sonst selbst selektieren
  //  - selektierte UUID nicht mehr in der Fundmenge → Selektion verwerfen
  useEffect(() => {
    if (anyDimensionActive && matches.length === 1) {
      const only = matches[0].object_uuid;
      if (selectedUuid !== only) setSelectedUuid(only);
      return;
    }
    if (selectedUuid !== null && !matchUuids.has(selectedUuid)) {
      setSelectedUuid(null);
    }
  }, [matches, matchUuids, selectedUuid, anyDimensionActive]);

  // Auto-Selektion beim Zurücknehmen des LETZTEN Filters räumen: ohne Filter
  // enthält die Fundmenge wieder alle Objekte, der Verwerfen-Zweig oben greift
  // also nie — der rote Selektions-Ring eines 1-Treffer-Filters bliebe sonst
  // dauerhaft stehen. Flanken-getriggert (aktiv → inaktiv), damit ein manuell
  // per TAB gesetzter Cursor ohne Filter nicht sofort wieder gelöscht wird.
  const prevDimensionActiveRef = useRef(anyDimensionActive);
  useEffect(() => {
    if (prevDimensionActiveRef.current && !anyDimensionActive) {
      setSelectedUuid(null);
    }
    prevDimensionActiveRef.current = anyDimensionActive;
  }, [anyDimensionActive]);

  // Live-Ref auf externalHasItems, damit der atomare Setter den aktuellen Wert
  // ohne Re-Bind sieht — sonst müsste jeder Callback bei jedem ref-Toggle neu
  // erstellt werden.
  const refActiveRef = useRef(externalHasItems);
  refActiveRef.current = externalHasItems;
  const interactionRef = useRef(onUserInteraction);
  interactionRef.current = onUserInteraction;

  /**
   * Atomarer URL-Update für User-Interaktionen: führt einen Updater auf den
   * URLSearchParams aus UND entfernt im selben Tick den `?ref=`-Param, falls
   * gerade ein Cross-Reference Highlight aktiv ist. Beide Mutationen landen
   * in EINEM `setSearchParams`-Call — keine Race-Condition zwischen separaten
   * useUrlState-Hook-Instanzen.
   */
  const runUserUpdate = useCallback(
    (updater: (p: URLSearchParams) => void) => {
      // Audit hook FIRST: consumers (DetailView.dismissRefOrigin) call their own
      // setSearchParams. React Router hands every functional update the params of
      // the current render, so a later call would overwrite this update (the
      // first chip click/section choice in reference mode was lost). Called
      // before, its navigation is superseded by ours — which clears the
      // reference params itself.
      if (refActiveRef.current) interactionRef.current?.();
      setSearchParams(prev => {
        const next = new URLSearchParams(prev);
        updater(next);
        if (refActiveRef.current && next.has('ref')) {
          // Findings-Kontext-Params gehören zum Referenz-Modus und enden mit ihm
          // — sonst bliebe die Quelle-Zeile der RefOriginPill nach der User-
          // Interaktion als Waise stehen.
          clearRefParams(next);
        }
        return next;
      }, { replace: true });
    },
    [setSearchParams],
  );

  const setQuery = useCallback((q: string) => {
    // Programmatic Clear (z.B. via ESC-Stack) soll NICHT den ref entfernen —
    // dafür nimmt es den ungetrappten Setter aus useUrlState.
    if (q === '') {
      setQueryState('');
      return;
    }
    runUserUpdate(p => {
      p.set('q', q);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runUserUpdate]);

  const toggleType = useCallback((type: string) => {
    runUserUpdate(p => {
      const current = new Set(
        (p.get('types') ?? '').split(',').map(s => s.trim()).filter(Boolean),
      );
      if (current.has(type)) current.delete(type);
      else current.add(type);
      if (current.size === 0) p.delete('types');
      else p.set('types', Array.from(current).join(','));
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runUserUpdate]);

  // Bulk-Setter für Gruppen-Pillen: aktiviert oder deaktiviert mehrere Typen auf einen Schlag,
  // ohne die anderen aktiven Typen zu verlieren.
  const setTypes = useCallback((types: string[], active: boolean) => {
    runUserUpdate(p => {
      const current = new Set(
        (p.get('types') ?? '').split(',').map(s => s.trim()).filter(Boolean),
      );
      if (active) {
        for (const t of types) current.add(t);
      } else {
        for (const t of types) current.delete(t);
      }
      if (current.size === 0) p.delete('types');
      else p.set('types', Array.from(current).join(','));
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runUserUpdate]);

  // Calc-Chip-Toggle: gleiche URL-Semantik wie toggleType, eigener Param `calc`
  // (Set-Codec). Ref-Vorauswahl erlischt wie bei jedem User-Filter.
  const toggleCalc = useCallback((key: string) => {
    runUserUpdate(p => {
      const current = new Set(
        (p.get('calc') ?? '').split(',').map(s => s.trim()).filter(Boolean),
      );
      if (current.has(key)) current.delete(key);
      else current.add(key);
      if (current.size === 0) p.delete('calc');
      else p.set('calc', Array.from(current).join(','));
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runUserUpdate]);

  // Section choice is an explicit user interaction → ends the reference mode
  // (same as search and chips).
  const setSection = useCallback((seq: number | null) => {
    runUserUpdate(p => {
      if (seq == null) p.delete(SECTION_PARAM);
      else p.set(SECTION_PARAM, String(seq));
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runUserUpdate]);

  const clearTypes = useCallback(() => {
    // clearTypes wird vom ESC-Stack und vom "Filter zurücksetzen"-Link genutzt
    // — beides ist eine programmatische Zurücknahme, nicht die Anlage eines
    // neuen Filters. ref bleibt unverändert. Räumt BEIDE Filter-Dimensionen
    // (Typen + Calc) in EINEM setSearchParams-Call — zwei separate
    // useUrlState-Setter würden sich gegenseitig überschreiben (je eigene
    // Memo-Closure auf searchParams, siehe Header-Kommentar).
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      next.delete('types');
      next.delete('calc');
      // The section belongs to the filter stage (ESC, "reset filters").
      next.delete(SECTION_PARAM);
      return next;
    }, { replace: true });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [setSearchParams]);

  const selectByOffset = useCallback((offset: 1 | -1) => {
    if (matches.length === 0) return;
    const currentIdx = selectedUuid
      ? matches.findIndex(o => o.object_uuid === selectedUuid)
      : -1;
    let nextIdx: number;
    if (currentIdx < 0) {
      nextIdx = offset === 1 ? 0 : matches.length - 1;
    } else {
      nextIdx = (currentIdx + offset + matches.length) % matches.length;
    }
    setSelectedUuid(matches[nextIdx].object_uuid);
  }, [matches, selectedUuid]);

  const selectNext = useCallback(() => selectByOffset(1), [selectByOffset]);
  const selectPrev = useCallback(() => selectByOffset(-1), [selectByOffset]);

  const clear = useCallback(() => {
    setQueryState('');
    setSelectedUuid(null);
  }, []);

  const filterActive = anyDimensionActive;

  return {
    query,
    setQuery,
    activeTypes,
    toggleType,
    setTypes,
    clearTypes,
    activeCalc,
    toggleCalc,
    section,
    setSection,
    scopedObjects: objects,
    matchUuids,
    matches,
    selectedUuid,
    selectNext,
    selectPrev,
    clear,
    filterActive,
  };
}
