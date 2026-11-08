import { useState, useEffect, useRef, useCallback } from 'react';
import { ApiError } from '@packages/shared';
import { api } from '../api/client';
import { useApiLang } from './useApiLang';
import type {
  FMObject, ReferenceItem, GroupedReferences, ReferenceCandidate, ReferenceCandidates, TableOccurrenceUsageMeta, ObjectUsageMeta,
} from '../types';

interface UseObjectDetailResult {
  object: FMObject | null;
  references: GroupedReferences;
  /**
   * Referenz-Kandidaten („Nicht referenziert“-Zeile). `null`, solange nicht
   * geladen oder wenn der Kandidaten-Endpoint fehlschlägt — der Referenzen-Tab
   * bleibt dann unverändert, nur ohne die Zeile.
   */
  candidates: ReferenceCandidates | null;
  loading: boolean;
  error: string | null;
  /**
   * Klon-Disambiguierung (Sicherheitsnetz): bei `409 AMBIGUOUS_UUID` — eine bare
   * UUID, die in mehreren Dateien existiert — die Liste der betroffenen Dateien.
   * Die DetailView rendert daraus einen Datei-Picker. `null` = nicht mehrdeutig.
   */
  ambiguousFiles: string[] | null;
  retry: () => void;
}

// Simple in-memory cache (session-scoped).
// Key = `${uuid}::${file ?? ''}` — Klon-Disambiguierung: zwei Objekte mit
// geteilter UUID aus verschiedenen Dateien dürfen sich nicht den Cache-Eintrag
// teilen. Ohne `file` (Graceful Downgrade) bleibt der Key bare-UUID-äquivalent.
const cache = new Map<string, {
  object: FMObject;
  references: GroupedReferences;
  candidates: ReferenceCandidates | null;
}>();

// `origin` (?ref=) fließt in den Key ein, weil es die operationalen Referenzen
// eines Pseudo-Aggregats (ScriptStepType) verändert (Origin_Hit-Markierung).
// `lang` ebenso, weil BuiltinFunction-Objekte ihre lokalisierte Namensfassung
// mitbringen (Localized_Name) — ohne die Sprache im Key bliebe nach einem
// Sprachwechsel der zuerst geladene Name stehen.
const cacheKeyFor = (
  uuid: string, file?: string | null, origin?: string | null, lang?: string | null,
): string =>
  `${uuid}::${file ?? ''}${origin ? `::${origin}` : ''}::${lang ?? ''}`;

/**
 * Hook to fetch object details and references by UUID.
 * Parallel-fetches both endpoints and splits the flat reference array
 * into parent/child groups.
 */
const EMPTY_REFS: GroupedReferences = {
  parent: [],
  child: [],
  structuralParent: [],
  structuralChild: [],
};

export const useObjectDetail = (
  uuid: string | undefined,
  file?: string | null,
  origin?: string | null,
): UseObjectDetailResult => {
  const [object, setObject] = useState<FMObject | null>(null);
  const [references, setReferences] = useState<GroupedReferences>(EMPTY_REFS);
  const [candidates, setCandidates] = useState<ReferenceCandidates | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [ambiguousFiles, setAmbiguousFiles] = useState<string[] | null>(null);
  const isFetchingRef = useRef(false);
  const lang = useApiLang();

  const fetchData = useCallback(async () => {
    if (!uuid || isFetchingRef.current) return;

    // Check cache first
    const cached = cache.get(cacheKeyFor(uuid, file, origin, lang));
    if (cached) {
      setObject(cached.object);
      setReferences(cached.references);
      setCandidates(cached.candidates);
      setLoading(false);
      setError(null);
      return;
    }

    isFetchingRef.current = true;
    setLoading(true);
    setError(null);
    setAmbiguousFiles(null);

    try {
      // Parallel fetch: object details + operational refs + structural refs.
      // Strukturelle Links (parent_folder, parent_object, parent_layout)
      // landen sonst nicht im Default-Operational-Filter.
      // Hohes Limit, damit z.B. BaseTables mit > 100 Feldern und TOs vollständig
      // ankommen — das API-Default (100) schneidet sonst bei UNION ALL ohne
      // ORDER BY je nach Insertion-Order ganze Typen ab. Filter und Suche im
      // HierarchyTree machen längere Listen handhabbar; obergrenze ist
      // environment.api.maxLimit (10000).
      const REFS_LIMIT = 10000;
      const fileParam = file || undefined;
      // `origin` nur am operationalen Call — er beeinflusst nur die Pseudo-Aggregat-
      // Zielliste (Origin_Hit). Strukturelle Refs sind davon unberührt.
      const originParam = origin || undefined;
      // Kandidaten („Nicht referenziert“) als 4. Aufruf: ein Fehler ist nicht
      // fatal — er setzt nur `candidates = null`, der Tab bleibt funktionsfähig.
      const [objectResponse, opRefsResponse, structRefsResponse, candidatesResponse] = await Promise.all([
        api.get({ uuid, file: fileParam, lang }),
        // `meta` carries the table-occurrence usage state (`to_usage`).
        api.references({ uuid, file: fileParam, origin: originParam, direction: 'all', link_type: 'operational', limit: REFS_LIMIT, meta: true }),
        api.references({ uuid, file: fileParam, direction: 'all', link_type: 'structural', limit: REFS_LIMIT }),
        api.referenceCandidates({ uuid, file: fileParam }).catch((err) => {
          console.warn('Reference candidates fetch failed:', err);
          return null;
        }),
      ]);

      // Extract object data
      const objectData = objectResponse.data as FMObject;

      // Split flat reference arrays into parent/child groups.
      // Die Sektionen sind SEMANTISCH: structuralParent = „Strukturell enthalten
      // in" (meine Container), structuralChild = „Strukturell enthält" (meine
      // Inhalte). Die Kanten-Richtung des Endpoints (parent = eingehend,
      // child = ausgehend) fällt damit je Rollen-Stil anders aus:
      //   - Container→Sub-Rollen (has_calculation): ausgehend = mein Inhalt,
      //     eingehend = mein Container → Richtung direkt übernehmen.
      //   - Sub→Container-Rollen (PARENT_ROLES: parent_*/trigger_owner/
      //     groups_into, Source=Sub → Target=Container): ausgehend = mein
      //     Container, eingehend = mein Inhalt → Richtung INVERTIEREN.
      // Beide Zweige symmetrisch — vorher wurden nur die ausgehenden
      // PARENT_ROLES reklassifiziert, wodurch Container-Seiten ihre Inhalte
      // (Steps eines Scripts, Parts/Trigger eines Layouts, Scripts eines
      // Ordners) invertiert unter „Strukturell enthalten in" zeigten.
      const PARENT_ROLES = new Set([
        'parent_script', 'parent_layout', 'parent_object', 'parent_folder',
        'groups_into', 'trigger_owner',
        // Read path LayoutObject → LayoutPart (API, from LayoutObjects.Part_Seq).
        'parent_part',
        // Field → BaseTable: operational in the catalog (kept as graph affinity),
        // but containment for the reader — see STRUCTURAL_OPERATIONAL_ROLES.
        'parent_table',
      ]);
      // Operational edges that the tab shows as structure — both are Link_Type
      // 'operational' in the catalog on purpose (graph affinity) but no usage:
      //   - parent_table (Field → BaseTable): a field "uses" nothing by belonging
      //     to its table, a base table is not "used by" its fields,
      //   - parent_layout from layout objects (LayoutObject → Layout, registry
      //     kind 'containment'): a layout is not "used by" its own objects.
      // Moved into the structural sections so "used by" / "uses" list references
      // only and the heading matches the usage summary. Display only — catalog,
      // graph and v_object_usage stay untouched.
      const STRUCTURAL_OPERATIONAL_ROLES = new Set(['parent_table', 'parent_layout']);
      const opRefsAll = (opRefsResponse.data ?? []) as unknown as ReferenceItem[];
      const opRefs = opRefsAll.filter(r => !STRUCTURAL_OPERATIONAL_ROLES.has(r.Link_Role));
      // Struktur-Sub-Knoten, die der Owner-Detailview bereits vollständig
      // rendert, sind in der Referenzliste Struktur-Lärm ohne Inhalts-Mehrwert
      // — ausgeblendet wird jeweils NUR die Richtung, deren GELISTETES Objekt
      // der Sub-Knoten ist; die Gegenzeile auf der Sub-Seite („Strukturell
      // enthalten in <Owner>") bleibt als Rücknavigation erhalten:
      //   - has_calculation → Calculation: Formeln sind inline sichtbar
      //     (Slot-/CF-Sektionen, Trigger-Tabellen/-Detailseite, PrivilegeSet-
      //     Zugriffsformeln); erreichbar bleiben Instanzen über Suche
      //     (?type=Calculation) und die Slot-Deeplinks.
      //   - parent_script → ScriptStep: die Steps stehen vollständig im
      //     Detail-Tab (ScriptViewer, mit eigener Suche); der Zeilen-Klick
      //     führte ohnehin nur per Container-Transparenz zur selben
      //     Script-Seite zurück (Scroll-Anchor). Die Step-DETAILSEITE war von
      //     der Script-Seite aus nie verlinkt (Viewer-Klick geht zur
      //     StepType-Doku) — sie bleibt über die Suche erreichbar.
      const structRefs = ((structRefsResponse.data ?? []) as unknown as ReferenceItem[])
        .filter(r => !(
          (r.Link_Role === 'has_calculation' && r.Object_Type === 'Calculation')
          || (r.Link_Role === 'parent_script' && r.Object_Type === 'ScriptStep')
        ))
        .concat(opRefsAll.filter(r => STRUCTURAL_OPERATIONAL_ROLES.has(r.Link_Role)));
      const grouped: GroupedReferences = {
        parent: opRefs.filter(r => r.direction === 'parent'),
        child: opRefs.filter(r => r.direction === 'child'),
        structuralParent: structRefs.filter(r =>
          (r.direction === 'child') === PARENT_ROLES.has(r.Link_Role)
        ),
        structuralChild: structRefs.filter(r =>
          (r.direction === 'parent') === PARENT_ROLES.has(r.Link_Role)
        ),
        toUsage: (opRefsResponse.meta as { to_usage?: TableOccurrenceUsageMeta } | undefined)?.to_usage ?? null,
        usage: (opRefsResponse.meta as { usage?: ObjectUsageMeta } | undefined)?.usage ?? null,
      };

      const candidateData: ReferenceCandidates | null = candidatesResponse?.data && candidatesResponse.meta
        ? { items: candidatesResponse.data as ReferenceCandidate[], meta: candidatesResponse.meta as ReferenceCandidates['meta'] }
        : null;

      // Cache the result
      cache.set(cacheKeyFor(uuid, file, origin, lang), {
        object: objectData, references: grouped, candidates: candidateData,
      });

      setObject(objectData);
      setReferences(grouped);
      setCandidates(candidateData);
    } catch (err) {
      // Sicherheitsnetz: bare-UUID-Navigation auf ein in mehreren Dateien
      // existierendes Objekt → 409 AMBIGUOUS_UUID. Statt eines harten Fehlers
      // die matched_files für den Datei-Picker durchreichen.
      if (err instanceof ApiError && err.code === 'AMBIGUOUS_UUID') {
        const files = (err.details?.matched_files as string[] | undefined) ?? [];
        setAmbiguousFiles(files);
      } else {
        console.error('Detail fetch failed:', err);
        setError(err instanceof Error ? err.message : 'Failed to load object details');
      }
    } finally {
      isFetchingRef.current = false;
      setLoading(false);
    }
    // `lang` gehört in die Liste: sonst wird fetchData beim Sprachwechsel nicht
    // neu erzeugt und der lokalisierte Name des Built-ins bleibt der alte.
  }, [uuid, file, origin, lang]);

  useEffect(() => {
    setObject(null);
    setReferences(EMPTY_REFS);
    setCandidates(null);
    setAmbiguousFiles(null);
    fetchData();
  }, [fetchData]);

  return { object, references, candidates, loading, error, ambiguousFiles, retry: fetchData };
};
