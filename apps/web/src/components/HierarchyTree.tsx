import React, { forwardRef, useCallback, useImperativeHandle, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { GroupedReferences, ReferenceCandidates, ReferenceItem } from '../types';
import { ReferencesFilter } from './ReferencesFilter';
import { ReferencesMissing } from './ReferencesMissing';
import { useUrlState, stringSetCodec, type UrlStateCodec } from '../hooks/useUrlState';
import { LAYOUT_PART_MEMBER_ROLE, referenceRoleKey } from '../lib/referenceRoleKey';
import { buildUsageGroups, isGroupExpandable, refWeight, sumRefs, usageOwnerOf, type UsageGroup, type UsageOwner } from '../lib/usageGroups';
import { buildNavigablePath, buildObjectPath } from '../lib/navigation';
import { useCurrentFile } from '../lib/currentFileContext';
import { formatObjectDisplayName } from '../lib/objectName';
import { parsePartKey, partLabel, subSummaryPosition } from '../lib/layoutParts';

const EMPTY_TYPES = new Set<string>();

/** fm-lab docs page that explains "usage (internal)" vs. "references". */
const USAGE_DOCS_PATH = `/docs/fm-lab/schema/${encodeURIComponent('schema/Usage and References')}`;
/** Placeholder markers for splicing nodes into a translated sentence. */
const USAGE_SLOT = (name: string) => `\u0000${name}\u0000`;
const USAGE_SLOT_RE = /\u0000(\w+)\u0000/;

/**
 * Richtungs-Filter der Referenzliste. Semantisch aufwärts/abwärts: parent
 * („wird verwendet von") und structuralParent („strukturell enthalten in")
 * zählen als eingehend (←), child („verwendet") und structuralChild
 * („strukturell enthält") als ausgehend (→). Die strukturellen Gruppen sind
 * dabei bereits semantisch einsortiert (useObjectDetail invertiert die
 * Kanten-Richtung der Sub→Container-Rollen), nicht roh kanten-gerichtet.
 * 'both' ist Default und fällt aus der URL heraus (saubere URLs).
 */
type DirFilter = 'in' | 'out' | 'both';
const dirFilterCodec: UrlStateCodec<DirFilter> = {
  parse: (raw) => (raw === 'in' || raw === 'out' ? raw : 'both'),
  serialize: (value) => (value === 'both' ? null : value),
};

/**
 * Grouping of the incoming references (URL `rgroup`): 'owner' = one row per
 * using object — the "n objects" of the usage summary (a layout object or
 * layout part counts as its layout); 'flat' (default, dropped from the URL) =
 * every reference. Applies to the incoming direction only (`rdir=in`).
 */
type GroupMode = 'owner' | 'flat';
const groupModeCodec: UrlStateCodec<GroupMode> = {
  parse: (raw) => (raw === 'owner' ? 'owner' : 'flat'),
  serialize: (value) => (value === 'owner' ? 'owner' : null),
};

const NO_USAGE_GROUP_KEY = '\u0000no-usage';

interface HierarchyTreeProps {
  references: GroupedReferences;
  /** Kandidaten der Zeile „Nicht referenziert“ (null = nicht verfügbar). */
  candidates?: ReferenceCandidates | null;
}

/**
 * Imperatives Handle, das DetailView via Ref konsumiert, um den ESC-Stack
 * zu speisen. Status-Getter werden bei jedem ESC-Druck frisch aufgerufen
 * (nicht zur Mount-Zeit gecached) — daher live, ohne Re-Render.
 */
export type HierarchyTreeHandle = {
  hasQuery: () => boolean;
  hasFilters: () => boolean;
  clearQuery: () => void;
  clearFilters: () => void;
};

function buildSearchText(ref: ReferenceItem, subroleLabels: string): string {
  return [
    ref.Object_Name ?? '',
    ref.Object_Type ?? '',
    ref.Link_Role ?? '',
    ref.Subrole_Class ?? '',
    ref.Subrole_Event ?? '',
    subroleLabels,
    ref.File_Name ?? '',
    ref.Container_Name ?? '',
  ].join(' ').toLowerCase();
}

/** Chip-/Filter-Identität einer Referenzzeile (siehe lib/referenceRoleKey). */
function roleKeyOf(ref: ReferenceItem): string {
  return referenceRoleKey(ref.Link_Role, ref.Subrole_Class);
}

/**
 * Klassen-Key → i18n-Key-Segment. Roh durchgereichte Subroles können ':' / '.'
 * enthalten (calc_kinds wie `conditional_format:2`) — beides sind i18next-
 * Separatoren. Ohne Treffer greift ohnehin der defaultValue (Roh-Anzeige).
 */
function subroleI18nKey(cls: string): string {
  return cls.replace(/[:.]/g, '_');
}

/**
 * Generische Sortier-Schlüssel für Referenzen — unabhängig vom Objekttyp.
 * 'origin' = Herkunft (Datei → Typ → Name); 'name' = Objektname → Datei;
 * 'role' = Link-Rolle (die rechts eingeblendete reads_variable/sets_variable/…),
 * dann Objektname als Tiebreaker.
 * Die Datei ist die abstrakte Herkunfts-Ebene (bei Feldern implizit über die TO,
 * bei Scripts/Layouts/etc. direkt), daher für ALLE Referenz-Typen sinnvoll.
 */
type RefSortKey = 'origin' | 'name' | 'role';
interface RefSortState { key: RefSortKey; dir: 'asc' | 'desc'; }

/**
 * Layout parts of the same layout in layout order (Part_Seq) instead of
 * alphabetically (Body, Footer, Header) — 0 for every other pair.
 */
function comparePartOrder(a: ReferenceItem, b: ReferenceItem): number {
  if (a.Object_Type !== 'LayoutPart' || b.Object_Type !== 'LayoutPart') return 0;
  const pa = parsePartKey(a.uuid);
  const pb = parsePartKey(b.uuid);
  if (!pa || !pb || pa.layoutId !== pb.layoutId) return 0;
  return pa.seq - pb.seq;
}

function compareRefs(a: ReferenceItem, b: ReferenceItem, key: RefSortKey): number {
  const cmp = (x: string, y: string) =>
    (x ?? '').localeCompare(y ?? '', undefined, { sensitivity: 'base', numeric: true });
  if (key === 'origin') {
    // Zwei-gliedrig: Datei → (Container-/Layout-Name) → Typ → Objektname. Der
    // Container-Name verortet Sub-Knoten, deren Objektname generisch identisch ist
    // (z.B. alle „OnLayoutKeystroke"-Trigger) — ohne ihn blieben sie unsortiert.
    return cmp(a.File_Name, b.File_Name)
      || cmp(a.Container_Name ?? '', b.Container_Name ?? '')
      || cmp(a.Object_Type, b.Object_Type)
      || comparePartOrder(a, b)
      || cmp(a.Object_Name, b.Object_Name);
  }
  if (key === 'role') {
    // Sekundärschlüssel Slot-Klasse: Hide-/CF-Blöcke gruppieren sich innerhalb
    // der Rolle automatisch untereinander — ohne eigenen Sortier-Button.
    return cmp(a.Link_Role, b.Link_Role)
      || cmp(a.Subrole_Class ?? '', b.Subrole_Class ?? '')
      || cmp(a.Object_Name, b.Object_Name) || cmp(a.File_Name, b.File_Name);
  }
  return cmp(a.Object_Name, b.Object_Name) || cmp(a.File_Name, b.File_Name);
}

/**
 * Hierarchy Tree Component
 * Displays parent (upstream) and child (downstream) references as clickable lists.
 * Includes a type-filter pill bar and a live search input above the lists.
 */
export const HierarchyTree = forwardRef<HierarchyTreeHandle, HierarchyTreeProps>(({ references, candidates = null }, externalRef) => {
  const { t } = useTranslation(['detail', 'types']);
  const navigate = useNavigate();
  const { uuid: currentUuid } = useParams<{ uuid: string }>();
  // Heimat-Datei = Datei des aktuell geöffneten Objekts (der Fokus, in dem die
  // Referenzen aufgelöst werden). Referenzen aus derselben Datei blenden den
  // Dateinamen aus (Platzersparnis); nur datei-fremde Treffer zeigen ihn.
  const focusFile = useCurrentFile();
  // URL als Single Source of Truth — Stack erhält Such- und Filterstand
  // beim Zurück-Navigieren automatisch (Tab-Param 'tab' liegt in DetailView).
  //
  // Lesen via useUrlState; Schreiben für User-Interaktionen via setSearchParams
  // direkt — analog useLayoutSearch. Begründung: bei expliziter User-Aktion
  // (Pille klicken, Tippen) wird `?ref=` ATOMAR im selben URL-Update mitentfernt,
  // damit der Filter sich nicht mit dem Referenz-Modus schneidet.
  const [query, setQuery] = useUrlState<string>('q', '');
  const [activeTypes, setActiveTypes] = useUrlState<Set<string>>('types', EMPTY_TYPES, stringSetCodec);
  const [activeRoles, setActiveRoles] = useUrlState<Set<string>>('roles', EMPTY_TYPES, stringSetCodec);
  const [dirFilter] = useUrlState<DirFilter>('rdir', 'both', dirFilterCodec);
  const [groupMode] = useUrlState<GroupMode>('rgroup', 'flat', groupModeCodec);
  // Expanded groups of the "by object" view (owner key; NO_USAGE_GROUP_KEY).
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(() => new Set());
  const [, setSearchParams] = useSearchParams();
  const treeRef = useRef<HTMLElement>(null);
  // Generische Referenz-Sortierung. Default: Herkunft (Datei) aufsteigend.
  const [refSort, setRefSort] = useState<RefSortState>({ key: 'origin', dir: 'asc' });

  /**
   * Atomarer URL-Update für User-Interaktionen: führt einen Updater auf den
   * URLSearchParams aus UND entfernt im selben Tick den `?ref=`-Param. Beide
   * Mutationen landen in EINEM `setSearchParams`-Call — keine Race-Condition
   * zwischen separaten useUrlState-Hook-Instanzen (siehe useLayoutSearch).
   */
  const runUserUpdate = useCallback(
    (updater: (p: URLSearchParams) => void) => {
      setSearchParams(prev => {
        const next = new URLSearchParams(prev);
        updater(next);
        if (next.has('ref')) next.delete('ref');
        return next;
      }, { replace: true });
    },
    [setSearchParams],
  );

  const queryRef = useRef(query);
  queryRef.current = query;
  const activeTypesRef = useRef(activeTypes);
  activeTypesRef.current = activeTypes;
  const activeRolesRef = useRef(activeRoles);
  activeRolesRef.current = activeRoles;

  useImperativeHandle(externalRef, () => ({
    hasQuery: () => queryRef.current.trim() !== '',
    hasFilters: () => activeTypesRef.current.size > 0 || activeRolesRef.current.size > 0,
    clearQuery: () => setQuery(''),
    // Beide Setter arbeiten funktional auf den URLSearchParams — die Updates
    // komponieren racefrei im selben Render-Zyklus.
    clearFilters: () => { setActiveTypes(EMPTY_TYPES); setActiveRoles(EMPTY_TYPES); },
  // Setter sind stabil per useUrlState; eslint-disable verhindert false-positive deps.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }), []);

  /**
   * Kurz-/Langlabel einer Slot-Klasse. Kurzlabels sind sprachneutrale
   * Quasi-Eigennamen (CF, Hide, PSoS, …) und in allen Locales identisch;
   * nur die Langlabels (Tooltip) sind übersetzt. Fallback-Prinzip: unbekannte
   * Klasse → Roh-Anzeige des Keys, niemals verschlucken.
   */
  // parent_part (objects of a layout part): the class is the layout-object type →
  // its localized type name (same dictionary as the canvas type chips).
  const subroleShort = useCallback((cls: string, role?: string) =>
    (role === LAYOUT_PART_MEMBER_ROLE
      ? t(`detail:layoutTypeFilter.types.${cls}`, { defaultValue: cls })
      : t(`detail:hierarchyTree.subroles.${subroleI18nKey(cls)}.short`, { defaultValue: cls })) as string, [t]);
  const subroleLong = useCallback((cls: string, role?: string) =>
    (role === LAYOUT_PART_MEMBER_ROLE
      ? t(`detail:layoutTypeFilter.types.${cls}`, { defaultValue: cls })
      : t(`detail:hierarchyTree.subroles.${subroleI18nKey(cls)}.long`, { defaultValue: cls })) as string, [t]);

  /**
   * Sub-Knoten-Referenzen MIT eigener Detail-Seite (LayoutObject, ScriptTrigger)
   * haben ZWEI sinnvolle Ziele: die eigene Detail-Seite und den umgebenden
   * Container (Layout bzw. Datei) mit Hervorhebung. Der normale Klick öffnet
   * die Detail-Seite; den Container erreicht man über den Pfeil-Button hinter
   * der Typ-Pille oder Alt+Klick/Alt+Enter auf der Zeile (gleicher Modifier
   * wie der Cross-Nav-Klick im LayoutCanvas).
   */
  const DETAIL_SUB_NODE_TYPES = new Set(['LayoutObject', 'ScriptTrigger']);
  const isDetailSubNode = (ref: ReferenceItem) =>
    DETAIL_SUB_NODE_TYPES.has(ref.Object_Type) && !!ref.Container_UUID && ref.Container_UUID !== ref.uuid;

  const handleReferenceClick = (ref: ReferenceItem, opts?: { toContainer?: boolean }) => {
    // Container-Resolution:
    // - Aktuelles Objekt als Origin mitgeben (Standard-Highlight-Mechanik).
    // - Sub-Knoten OHNE eigene Detail-Seite (Container_UUID gesetzt) öffnen
    //   transparent den Container und setzen den Sub-Knoten als ref — der
    //   spezifischere Treffer ist die nützlichere Hervorhebung.
    // - Sub-Knoten MIT eigener Detail-Seite (LayoutObject, ScriptTrigger):
    //   der normale Klick öffnet SIE; nur toContainer (Pfeil-Button / Alt)
    //   springt in den Container (Layout bzw. Datei).
    //
    // Sonderfall parent_script: aus einer ScriptStep-Detail-Seite springt der
    // Klick auf den "enthalten in Script"-Eintrag zur Script-Detail-Seite.
    // Wir hängen `?step=<currentUuid>` an, damit der ScriptViewer dort direkt
    // zur passenden Zeile scrollt und sie kurz hervorhebt (siehe
    // ScriptViewer.tsx stepAnchor-useEffect).
    if (isDetailSubNode(ref) && !opts?.toContainer) {
      navigate(buildObjectPath(ref.uuid, currentUuid ?? null, ref.File_Name ?? null));
      return;
    }
    const extras = ref.Link_Role === 'parent_script' && currentUuid
      ? { step: currentUuid }
      : undefined;
    navigate(buildNavigablePath(ref.uuid, currentUuid ?? null, ref.Container_UUID ?? null, ref.File_Name ?? null, extras));
  };

  // Item-Handler: Enter/Space löst Navigation aus (Alt+Enter → Layout-Sprung,
  // analog Alt+Klick). Pfeiltasten werden hier bewusst NICHT abgefangen — sie
  // laufen via Bubbling in den Container-Handler, damit eine einzige Quelle
  // die Auf-/Abwärts-Logik kontrolliert.
  const handleItemKeyDown = (e: React.KeyboardEvent, ref: ReferenceItem) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleReferenceClick(ref, { toContainer: e.altKey });
    }
  };

  // Container-Handler: Pfeil-Navigation über alle sichtbaren `.reference-item`
  // hinweg (auch Sektions-übergreifend), inkl. Home/End und Wrap-around.
  // Bewusst getrennt vom Browser-TAB-Verhalten — TAB läuft weiter über die
  // tabIndex={0}-Reihenfolge der Items, sodass beide Navigations-Modi
  // koexistieren und das Verhalten nicht von Browser-Heuristiken abhängt.
  const handleTreeKeyDown = useCallback((e: React.KeyboardEvent<HTMLElement>) => {
    const root = treeRef.current;
    if (!root) return;
    const items = Array.from(
      root.querySelectorAll<HTMLLIElement>('.reference-item'),
    );
    if (items.length === 0) return;

    const active = document.activeElement as HTMLElement | null;
    const currentIndex = active ? items.indexOf(active as HTMLLIElement) : -1;

    let nextIndex: number | null = null;
    if (e.key === 'ArrowDown') {
      nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % items.length;
    } else if (e.key === 'ArrowUp') {
      nextIndex = currentIndex < 0
        ? items.length - 1
        : (currentIndex - 1 + items.length) % items.length;
    } else if (e.key === 'Home') {
      nextIndex = 0;
    } else if (e.key === 'End') {
      nextIndex = items.length - 1;
    }

    if (nextIndex !== null) {
      e.preventDefault();
      items[nextIndex].focus();
    }
  }, []);

  // Richtung → aktive Sektionen. Bei 'in'/'out' wird die jeweils andere Richtung
  // komplett ausgeblendet (leere Sektionen), 'both' zeigt alle vier.
  const inOn = dirFilter !== 'out';
  const outOn = dirFilter !== 'in';

  // Referenz-Menge im Geltungsbereich des Richtungs-Filters — speist Typ-Pillen
  // und Gesamtzähler, damit die Zahlen zur sichtbaren Auswahl passen.
  const directionScopedRefs = useMemo(() => [
    ...(inOn ? references.parent : []),
    ...(outOn ? references.child : []),
    ...(inOn ? references.structuralParent : []),
    ...(outOn ? references.structuralChild : []),
  ], [references, inOn, outOn]);

  // "By object" view: only with a usage summary and for the incoming direction.
  const grouped = references.usage != null && groupMode === 'owner' && dirFilter === 'in';

  // Chip counts: references (Σ ×N); in the "by object" view the rows of
  // "used by" count as their using objects instead (how many groups a click on
  // the chip leaves), structural rows stay references.
  const chipCounts = useCallback((keyOf: (r: ReferenceItem) => string) => {
    const m = new Map<string, number>();
    const usedBy = grouped ? new Set(references.parent) : null;
    const seen = new Set<string>();
    for (const r of directionScopedRefs) {
      const key = keyOf(r);
      if (usedBy?.has(r)) {
        const ownerKey = `${key}\u0001${usageOwnerOf(r).key}`;
        if (seen.has(ownerKey)) continue;
        seen.add(ownerKey);
        m.set(key, (m.get(key) ?? 0) + 1);
      } else {
        m.set(key, (m.get(key) ?? 0) + refWeight(r));
      }
    }
    return m;
  }, [directionScopedRefs, grouped, references.parent]);

  const typeCounts = useMemo(() => chipCounts(r => r.Object_Type), [chipCounts]);

  // Zähler der kombinierten Rollen-Chips (Rolle bzw. Rolle~Klasse) — wie die
  // Typ-Pillen richtungs-skopiert, von Typ-/Such-Filter unabhängig.
  const roleCounts = useMemo(() => chipCounts(roleKeyOf), [chipCounts]);

  // Gegentypen je Richtung, wie sie die Typ-Pillen zeigen (in = parent +
  // structuralParent, out = child + structuralChild) — die Kandidaten-Zeile
  // hängt bei Überschneidung die Kandidaten-Rolle ans Label.
  const presentTypes = useMemo(() => ({
    in: new Set([...references.parent, ...references.structuralParent].map(r => r.Object_Type)),
    out: new Set([...references.child, ...references.structuralChild].map(r => r.Object_Type)),
  }), [references]);

  const queryLower = query.trim().toLowerCase();
  const filterFn = useCallback((r: ReferenceItem) => {
    if (activeTypes.size > 0 && !activeTypes.has(r.Object_Type)) return false;
    if (activeRoles.size > 0 && !activeRoles.has(roleKeyOf(r))) return false;
    if (queryLower !== '') {
      // Slot-Klasse + Labels in den Suchindex aufnehmen — `hide`, `cf`,
      // „bedingte" werden tippbar.
      const subroleLabels = r.Subrole_Class
        ? `${subroleShort(r.Subrole_Class, r.Link_Role)} ${subroleLong(r.Subrole_Class, r.Link_Role)}`
        : '';
      if (!buildSearchText(r, subroleLabels).includes(queryLower)) return false;
    }
    return true;
  }, [activeTypes, activeRoles, queryLower, subroleShort, subroleLong]);

  const matches = useMemo(() => ({
    parent: inOn ? references.parent.filter(filterFn) : [],
    child: outOn ? references.child.filter(filterFn) : [],
    structuralParent: inOn ? references.structuralParent.filter(filterFn) : [],
    structuralChild: outOn ? references.structuralChild.filter(filterFn) : [],
  }), [references, filterFn, inOn, outOn]);

  // Treffer je Richtung (Typ-/Such-Filter berücksichtigt, Richtungs-Filter NICHT)
  // — beschriftet die Richtungs-Buttons und bleibt beim Umschalten stabil.
  // Alle Zähler in Referenzen (Σ ×N), nicht in Zeilen — siehe refWeight.
  const dirCounts = useMemo(() => ({
    in: sumRefs(references.parent.filter(filterFn)) + sumRefs(references.structuralParent.filter(filterFn)),
    out: sumRefs(references.child.filter(filterFn)) + sumRefs(references.structuralChild.filter(filterFn)),
  }), [references, filterFn]);

  // Referenzen je Sektion (gesamt bzw. nach Filter) für die Überschriften.
  const sectionTotals = useMemo(() => ({
    parent: sumRefs(references.parent),
    child: sumRefs(references.child),
    structuralParent: sumRefs(references.structuralParent),
    structuralChild: sumRefs(references.structuralChild),
  }), [references]);
  const sectionMatches = useMemo(() => ({
    parent: sumRefs(matches.parent),
    child: sumRefs(matches.child),
    structuralParent: sumRefs(matches.structuralParent),
    structuralChild: sumRefs(matches.structuralChild),
  }), [matches]);

  const usageGroups = useMemo(
    () => (grouped ? buildUsageGroups(matches.parent) : null),
    [grouped, matches.parent],
  );
  const usageGroupsTotal = useMemo(
    () => (grouped ? buildUsageGroups(references.parent).groups.length : 0),
    [grouped, references.parent],
  );

  const totalCount = sumRefs(directionScopedRefs);
  const matchCount = sectionMatches.parent + sectionMatches.child
    + sectionMatches.structuralParent + sectionMatches.structuralChild;

  // Richtungs-Leiste nur, wenn beide Richtungen überhaupt Referenzen haben (sonst
  // ist der Filter sinnlos). Basiert auf den Rohdaten, nicht auf dem aktiven Filter.
  const hasIncomingTotal = references.parent.length + references.structuralParent.length > 0;
  const hasOutgoingTotal = references.child.length + references.structuralChild.length > 0;
  const showDirBar = hasIncomingTotal && hasOutgoingTotal;

  // User-Klick auf Filter-Pille: atomar Filter setzen + ref-Param entfernen.
  const toggleType = (type: string) => {
    runUserUpdate(p => {
      const current = new Set(
        (p.get('types') ?? '').split(',').map(s => s.trim()).filter(Boolean),
      );
      if (current.has(type)) current.delete(type);
      else current.add(type);
      if (current.size === 0) p.delete('types');
      else p.set('types', Array.from(current).join(','));
    });
  };

  // "Filter zurücksetzen"-Link und ESC-Stack — programmatische Zurücknahme,
  // ref-Modus wird nicht angerührt (kein User-Filter-Eingriff).
  const clearTypes = () => setActiveTypes(EMPTY_TYPES);
  const clearRoles = () => setActiveRoles(EMPTY_TYPES);

  // User-Klick auf Rollen-Chip: exakt die Typ-Pillen-Mechanik (Multi-Select OR,
  // atomares ref-Clearing im selben URL-Update).
  const toggleRole = (roleKey: string) => {
    runUserUpdate(p => {
      const current = new Set(
        (p.get('roles') ?? '').split(',').map(s => s.trim()).filter(Boolean),
      );
      if (current.has(roleKey)) current.delete(roleKey);
      else current.add(roleKey);
      if (current.size === 0) p.delete('roles');
      else p.set('roles', Array.from(current).join(','));
    });
  };

  // Richtungs-Filter: gleiche atomare Mechanik wie die Typ-Pillen (ref-Param
  // wird im selben Update entfernt). 'both' ist Default → Param fällt weg.
  const setDirFilter = (d: DirFilter) => {
    runUserUpdate(p => {
      if (d === 'both') p.delete('rdir');
      else p.set('rdir', d);
    });
  };

  // Grouping toggle (the two numbers of the usage summary). "By object" also
  // switches to the incoming direction — the groups exist for it only.
  const setGroupMode = (m: GroupMode) => {
    runUserUpdate(p => {
      if (m === 'owner') {
        p.set('rgroup', 'owner');
        p.set('rdir', 'in');
      } else {
        p.delete('rgroup');
      }
    });
  };

  // Sucheingabe: bei nicht-leerer Eingabe atomar mit ref-Clear; leerer Wert
  // (Backspace, Clear-Button, ESC) ist programmatisch und lässt ref unverändert.
  const handleQueryChange = (q: string) => {
    if (q === '') {
      setQuery('');
      return;
    }
    runUserUpdate(p => {
      p.set('q', q);
    });
  };

  // Vom Suchfeld via Pfeil-Down/-Up zum ersten/letzten Listenelement springen.
  // Vermeidet das mehrfache TAB-Springen über Pillen und Reset-Link.
  const jumpToList = useCallback((direction: 'first' | 'last') => {
    const root = treeRef.current;
    if (!root) return;
    const items = root.querySelectorAll<HTMLLIElement>('.reference-item');
    if (items.length === 0) return;
    const target = direction === 'first' ? items[0] : items[items.length - 1];
    target.focus();
  }, []);

  const renderReferenceItem = (ref: ReferenceItem, idx: number, dir: 'in' | 'out') => {
    // Step-eigene Referenzen mit datei-extern nicht auflösbarem Ziel (navigable=false)
    // werden als nicht-klickbarer, gedimmter Text gezeigt — kein Klick/Enter, nicht im
    // TAB-Fluss. Graph-Referenzen haben kein `navigable`-Feld → gelten als navigierbar.
    const isNavigable = ref.navigable !== false;
    // Fokus-Objekt selbst (z.B. Self-Reference eines Scripts) hervorheben.
    const isFocus = currentUuid != null && ref.uuid === currentUuid;
    // Slot-Klasse der Kanten-Subrole: inline die Kurzform (`reads_field · CF`,
    // Middot als Haus-Konvention), im Pfeil-Tooltip die Langform samt Roh-
    // Detail (Regelnummern etc.). Das Detail entfällt, wenn es nur den
    // Klassen-Key wiederholt (z.B. Roh-Wert 'Hide' zur Klasse 'hide').
    const subroleCls = ref.Subrole_Class ?? null;
    // Aufgelöste Trigger-Events (API-Feld Subrole_Event, fm_spec ≥ 1.18.0):
    // genau EIN Event ersetzt das Kurzlabel „Trigger" inline
    // (`reads_field · OnObjectValidate`); mehrere Events bleiben beim
    // Kurzlabel und wandern in den Pfeil-Tooltip hinter die Langform. Ohne
    // Referenz-DB fehlt das Feld → exakt bisheriges Verhalten.
    const subroleEvents = subroleCls === 'script_trigger_parameter' && ref.Subrole_Event
      ? ref.Subrole_Event.split(',').map(s => s.trim()).filter(Boolean)
      : [];
    // Layout parts: the subrole of their edges (parent_layout, breaks_on_field) is
    // the canonical English part type → show the localized dialog term of the part
    // kind instead (catalog name stays English). The part is either the listed row
    // or the focus object itself (its layout / break field listed).
    const partKey = ref.Object_Type === 'LayoutPart' ? parsePartKey(ref.uuid) : null;
    const focusPartKey = !partKey && (ref.Link_Role === 'parent_layout' || ref.Link_Role === 'breaks_on_field')
      ? parsePartKey(currentUuid)
      : null;
    const subroleKind = partKey?.kind ?? focusPartKey?.kind;
    // breaks_on_field exists on sub-summaries only — the kind term says nothing
    // new there (the part name carries it), the position does: "· trailing".
    const subrolePos = ref.Link_Role === 'breaks_on_field' && subroleKind != null
      ? subSummaryPosition(subroleKind)
      : null;
    const partSubrole = subrolePos
      ? t(`detail:layoutParts.position.${subrolePos}`) as string
      : subroleKind != null
      ? partLabel((k, o) => t(k, o) as string, { part_kind: subroleKind, part_type: ref.Subrole_Detail ?? subroleCls })
      : null;
    // A part's catalog name already names its layout ("Layout [Body]") → no
    // second container name behind it; the file moves into the name tooltip.
    const showContainer = !!ref.Container_Name && ref.Object_Type !== 'LayoutPart';
    const roleLabel = partSubrole
      ? `${ref.Link_Role} · ${partSubrole}`
      : subroleCls
      ? `${ref.Link_Role} · ${subroleEvents.length === 1 ? subroleEvents[0] : subroleShort(subroleCls, ref.Link_Role)}`
      : ref.Link_Role;
    const subroleDetail = subroleCls
      && ref.Subrole_Detail
      && ref.Subrole_Detail.toLowerCase() !== subroleCls.toLowerCase()
      ? ref.Subrole_Detail : null;
    const roleTitle = subroleCls
      ? `${ref.Link_Role} · ${subroleLong(subroleCls, ref.Link_Role)}`
        + (subroleEvents.length > 0 ? ` · ${subroleEvents.join(', ')}` : '')
        + (subroleDetail ? ` (${subroleDetail})` : '')
      : ref.Link_Role;
    return (
      <li
        key={`${ref.uuid}-${ref.Link_Role}-${idx}`}
        className={`reference-item${isNavigable ? '' : ' is-not-navigable'}${isFocus ? ' is-focus' : ''}`}
        aria-current={isFocus ? 'true' : undefined}
        onClick={isNavigable ? (e) => handleReferenceClick(ref, { toContainer: e.altKey }) : undefined}
        onKeyDown={isNavigable ? (e) => handleItemKeyDown(e, ref) : undefined}
        tabIndex={isNavigable ? 0 : -1}
        role={isNavigable ? 'button' : undefined}
        title={isNavigable ? undefined : t('detail:hierarchyTree.notNavigable', {
          defaultValue: 'Ziel nicht im importierten Datenbestand',
        }) as string}
        aria-label={isNavigable
          ? t('detail:hierarchyTree.itemAriaLabel', {
              type: ref.Object_Type,
              name: formatObjectDisplayName(ref.Object_Type, ref.Object_Name),
            }) as string
          : `${ref.Object_Type}: ${formatObjectDisplayName(ref.Object_Type, ref.Object_Name)}`}
      >
        <span className="object-type">
          {t(`types:objectTypes.${ref.Object_Type}`, { defaultValue: ref.Object_Type })}
        </span>
        {/* Container-Sprung: Zweitziel direkt hinter der Typ-Pille (Pfeil-Button,
            analog Dashboard-Row-Action und TO-Graph-Link). Der Zeilen-Klick
            öffnet die Detail-Seite des Sub-Knotens (LayoutObject/ScriptTrigger);
            der Pfeil (oder Alt+Klick auf die Zeile) den umgebenden Container —
            Layout bzw. Datei (File-Trigger) — mit Hervorhebung. */}
        {isNavigable && isDetailSubNode(ref) && (
          <button
            type="button"
            className="ref-layout-jump"
            title={(ref.Container_Type === 'File'
              ? t('detail:hierarchyTree.showInFile', { defaultValue: 'In der Datei zeigen (Alt+Klick)' })
              : t('detail:hierarchyTree.showInLayout', { defaultValue: 'Im Layout zeigen (Alt+Klick)' })) as string}
            aria-label={(ref.Container_Type === 'File'
              ? t('detail:hierarchyTree.showInFile', { defaultValue: 'In der Datei zeigen (Alt+Klick)' })
              : t('detail:hierarchyTree.showInLayout', { defaultValue: 'Im Layout zeigen (Alt+Klick)' })) as string}
            onClick={(e) => {
              // Nicht auch noch den Zeilen-Klick (Detail-Seite) feuern.
              e.stopPropagation();
              handleReferenceClick(ref, { toContainer: true });
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                handleReferenceClick(ref, { toContainer: true });
              }
            }}
          >
            →
          </button>
        )}
        {/* Trigger-Absprung: konsolidierte Spiegel-Zeilen (triggers_script·Event)
            vertreten ihren unterdrückten ScriptTrigger-Sub-Knoten — der ↗-Button
            öffnet dessen Detailseite (der Zeilen-Klick gehört dem Owner-Objekt). */}
        {isNavigable && ref.Trigger_UUID && (
          <button
            type="button"
            className="ref-layout-jump ref-trigger-jump"
            title={t('detail:scriptTriggerDetail.openTrigger', { defaultValue: 'Script-Trigger öffnen' }) as string}
            aria-label={t('detail:scriptTriggerDetail.openTrigger', { defaultValue: 'Script-Trigger öffnen' }) as string}
            onClick={(e) => {
              e.stopPropagation();
              navigate(buildObjectPath(ref.Trigger_UUID!, currentUuid ?? null, ref.File_Name ?? null));
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                navigate(buildObjectPath(ref.Trigger_UUID!, currentUuid ?? null, ref.File_Name ?? null));
              }
            }}
          >
            ↗
          </button>
        )}
        <span
          className="ref-name"
          title={ref.Object_Type === 'LayoutPart' && ref.File_Name && ref.File_Name !== focusFile
            ? `${ref.Object_Name} (${ref.File_Name})`
            : ref.Object_Name}
        >
          {formatObjectDisplayName(ref.Object_Type, ref.Object_Name)}
        </span>
        {/* Container-Verortung (z.B. Layout eines ScriptTriggers): macht sonst
            identische Sub-Knoten unterscheidbar. Dateiname nur bei Abweichung vom
            Fokus-Objekt (referenziertes Script/Layout). */}
        {showContainer && (
          <span className="ref-container" title={ref.Container_Name ?? undefined}>
            <span className="ref-container-sep" aria-hidden="true">›</span>
            {ref.Container_Name}
            {ref.Container_File && ref.Container_File !== focusFile && (
              <span className="ref-container-file"> ({ref.Container_File})</span>
            )}
          </span>
        )}
        {/* Meta-Gruppe (Zähler · Rolle · Datei · Badges · Pfeil) — wrappt als EIN
            Block unter den Namen, sobald die Breite nicht reicht; erst bei ganz
            wenig Platz brechen ihre Einzelteile weiter um (stufenweise via
            flex-wrap, kein hartes Spalten-Umbrechen mehr ab 768px). */}
        <span className="ref-meta">
          {typeof ref.Call_Count === 'number' && ref.Call_Count > 1 && (
            <span className="ref-call-count" title={t('detail:hierarchyTree.callCountTitle', {
              count: ref.Call_Count,
              defaultValue: '{{count}} Vorkommen',
            }) as string}>×{ref.Call_Count}</span>
          )}
          {ref.Link_Role && (
            // Rohe Link-Rolle als Klartext, plus Slot-Klasse als Kurzlabel
            // (`reads_field · Hide`). Per Container-Query nur eingeblendet,
            // wenn die Referenz-Spalte breit genug ist (sonst trägt der
            // Pfeil-Tooltip Rolle und Slot weiter).
            <span className="ref-role-label" title={subroleDetail ?? undefined}>{roleLabel}</span>
          )}
          {ref.File_Name && ref.File_Name !== focusFile && !ref.Container_Name && ref.Object_Type !== 'LayoutPart' && (
            <span className="ref-file">
              ({ref.File_Name})
            </span>
          )}
          {ref.Is_Cross_File && (
            <span className="cross-file-badge">
              {t('detail:hierarchyTree.crossFileBadge')}
            </span>
          )}
          {ref.Origin_Hit && (
            <span
              className="origin-hit-badge"
              title={t('detail:hierarchyTree.originHitTitle', {
                defaultValue: 'Aus dem Herkunftsobjekt (ref) erreichbar',
              }) as string}
            >
              {t('detail:hierarchyTree.originHitBadge', { defaultValue: '↩ Herkunft' })}
            </span>
          )}
          <span className="ref-role">
            {/* Rolle nicht mehr als Text — nur ein Richtungs-Pfeil; die konkrete
                Rolle (calls_script, reads_field, …) steht im Tooltip. */}
            <span
              className={`ref-dir ref-dir-${dir}`}
              title={`${dir === 'in'
                ? t('detail:hierarchyTree.dirIn', { defaultValue: 'Eingehend' })
                : t('detail:hierarchyTree.dirOut', { defaultValue: 'Ausgehend' })} · ${roleTitle}`}
              aria-hidden="true"
            >
              {dir === 'in' ? '←' : '→'}
            </span>
          </span>
        </span>
      </li>
    );
  };

  // Generische Sortierung aller Referenz-Items (Zeilen-Darstellung bleibt unverändert,
  // nur die Reihenfolge + der Sortier-Header ändern sich).
  const sortItems = (items: ReferenceItem[]) => {
    if (items.length < 2) return items;
    const sign = refSort.dir === 'asc' ? 1 : -1;
    return [...items].sort((a, b) => {
      // Origin-Treffer (aus dem ?ref=-Herkunftsobjekt erreichbar, z.B. das im
      // Herkunfts-Script geschriebene Feld) immer zuoberst — unabhängig vom
      // gewählten Sortierschlüssel, damit der kontextuell relevante Treffer
      // nicht in einer langen Aggregat-Liste untergeht.
      const ao = a.Origin_Hit ? 0 : 1;
      const bo = b.Origin_Hit ? 0 : 1;
      if (ao !== bo) return ao - bo;
      return sign * compareRefs(a, b, refSort.key);
    });
  };
  const toggleSort = (key: RefSortKey) => {
    setRefSort(s => s.key === key ? { key, dir: s.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' });
  };
  const sortArrow = (key: RefSortKey) => refSort.key === key ? (refSort.dir === 'asc' ? ' ▲' : ' ▼') : '';

  // Sortier-Steuerung (links) + Richtungs-Filter (rechtsbündig) in einer Zeile.
  const renderToolbar = () => (
    <div className="reference-toolbar">
      <div className="reference-sort-bar" role="group" aria-label={t('detail:hierarchyTree.sortAriaLabel', { defaultValue: 'Sortierung' }) as string}>
        <span className="reference-sort-label">{t('detail:hierarchyTree.sortBy', { defaultValue: 'Sortieren nach' })}:</span>
        <button
          type="button"
          className={`reference-sort-btn${refSort.key === 'origin' ? ' is-active' : ''}`}
          onClick={() => toggleSort('origin')}
        >
          {t('detail:hierarchyTree.sortOrigin', { defaultValue: 'Herkunft' })}{sortArrow('origin')}
        </button>
        <button
          type="button"
          className={`reference-sort-btn${refSort.key === 'name' ? ' is-active' : ''}`}
          onClick={() => toggleSort('name')}
        >
          {t('detail:hierarchyTree.sortName', { defaultValue: 'Name' })}{sortArrow('name')}
        </button>
        <button
          type="button"
          className={`reference-sort-btn${refSort.key === 'role' ? ' is-active' : ''}`}
          onClick={() => toggleSort('role')}
        >
          {t('detail:hierarchyTree.sortRole', { defaultValue: 'Link Rolle' })}{sortArrow('role')}
        </button>
      </div>
      {showDirBar && renderDirectionFilter()}
    </div>
  );

  // Kompakter Richtungs-Filter: nur Pfeil-Glyph + Zähler; das Wort (Eingehend/
  // Ausgehend/Beide) steht im title/aria-label.
  const renderDirectionFilter = () => {
    const opts: Array<{ key: DirFilter; glyph: string; label: string; count: number }> = [
      { key: 'in', glyph: '←', label: t('detail:hierarchyTree.dirIn', { defaultValue: 'Eingehend' }) as string, count: dirCounts.in },
      { key: 'out', glyph: '→', label: t('detail:hierarchyTree.dirOut', { defaultValue: 'Ausgehend' }) as string, count: dirCounts.out },
      { key: 'both', glyph: '↔', label: t('detail:hierarchyTree.dirBoth', { defaultValue: 'Beide' }) as string, count: dirCounts.in + dirCounts.out },
    ];
    return (
      <div
        className="reference-dir-bar"
        role="radiogroup"
        aria-label={t('detail:hierarchyTree.dirFilterAria', { defaultValue: 'Richtung filtern' }) as string}
      >
        <span className="reference-dir-prefix">{t('detail:hierarchyTree.dirFilterLabel', { defaultValue: 'Richtung' })}:</span>
        {opts.map(o => (
          <button
            key={o.key}
            type="button"
            role="radio"
            aria-checked={dirFilter === o.key}
            aria-label={`${o.label} (${o.count})`}
            className={`reference-dir-btn${dirFilter === o.key ? ' is-active' : ''}`}
            onClick={() => setDirFilter(o.key)}
            title={`${o.label} (${o.count})`}
          >
            <span className="reference-dir-glyph" aria-hidden="true">{o.glyph}</span>
            <span className="reference-dir-count">{o.count}</span>
          </button>
        ))}
      </div>
    );
  };

  /**
   * Tab header "Used internally by n objects · m references" (same two numbers
   * and words as the search column) + ⓘ link to the docs page that explains
   * the counting. The sentence comes from ONE template with the placeholders
   * {{objects}} / {{refs}} (word order differs per language); the two numbers
   * are spliced in as their own nodes.
   */
  const renderUsageSummary = (owners: number, refs: number) => {
    // The two numbers switch the view: "by object" (groups) / "all references".
    const parts: Record<string, React.ReactNode> = {
      objects: (
        <button
          type="button"
          className={`references-usage-count references-usage-toggle${grouped ? ' is-active' : ''}`}
          aria-pressed={grouped}
          title={t('detail:hierarchyTree.groupByObjectHint') as string}
          onClick={() => setGroupMode('owner')}
        >
          {t('detail:hierarchyTree.usageObjects', { count: owners })}
        </button>
      ),
      refs: (
        <button
          type="button"
          className={`references-usage-count references-usage-toggle${grouped ? '' : ' is-active'}`}
          aria-pressed={!grouped}
          title={t('detail:hierarchyTree.groupAllRefsHint') as string}
          onClick={() => setGroupMode('flat')}
        >
          {t('detail:hierarchyTree.usageRefs', { count: refs })}
        </button>
      ),
    };
    const template = t('detail:hierarchyTree.usageSummary', {
      objects: USAGE_SLOT('objects'), refs: USAGE_SLOT('refs'),
    }) as string;
    const docsLabel = t('detail:hierarchyTree.usageDocs') as string;
    return (
      <div className="references-usage-summary" title={t('detail:hierarchyTree.usageSummaryHint') as string}>
        {template.split(USAGE_SLOT_RE).map((chunk, i) => (
          i % 2 === 1 ? <React.Fragment key={i}>{parts[chunk] ?? chunk}</React.Fragment> : chunk
        ))}
        <Link className="references-usage-docs" to={USAGE_DOCS_PATH} title={docsLabel} aria-label={docsLabel}>ⓘ</Link>
      </div>
    );
  };

  const toggleGroup = (key: string) => {
    setExpandedGroups(prev => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const openOwner = (owner: UsageOwner) => {
    navigate(buildObjectPath(owner.uuid, currentUuid ?? null, owner.file ?? null));
  };

  // Groups in the order of the sort bar (owner as the listed object).
  const sortGroups = (groups: UsageGroup[]) => {
    const sign = refSort.dir === 'asc' ? 1 : -1;
    const asItem = (g: UsageGroup) => ({
      uuid: g.owner.uuid, Object_Type: g.owner.type, Object_Name: g.owner.name,
      File_Name: g.owner.file, Link_Role: g.roles[0] ?? '', Container_Name: null,
    }) as ReferenceItem;
    return [...groups].sort((a, b) => sign * compareRefs(asItem(a), asItem(b), refSort.key));
  };

  /**
   * Role of a single reference as the row shows it (`reads_field · CF`; one
   * resolved trigger event replaces the class label) — the head of a group
   * without toggle carries it, so the slot class stays visible.
   */
  const shortRoleLabel = (ref: ReferenceItem) => {
    const cls = ref.Subrole_Class;
    if (!cls) return ref.Link_Role;
    const events = cls === 'script_trigger_parameter' && ref.Subrole_Event
      ? ref.Subrole_Event.split(',').map(s => s.trim()).filter(Boolean)
      : [];
    return `${ref.Link_Role} · ${events.length === 1 ? events[0] : subroleShort(cls, ref.Link_Role)}`;
  };

  /**
   * One using object: head row (type, name, file, references, roles) opens the
   * object; ▸ expands its references (the usual rows). Arrow right/left on the
   * head expand/collapse. A group whose expansion would only repeat the head
   * (isGroupExpandable) gets an empty slot of the toggle's width instead, so
   * pills and names stay aligned.
   */
  const renderGroupHead = (
    key: string, open: boolean, expandable: boolean, onOpen: (() => void) | null,
    content: React.ReactNode, ariaLabel: string, title?: string,
  ) => (
    <div
      className="reference-item reference-group-head"
      tabIndex={0}
      role="button"
      aria-expanded={expandable ? open : undefined}
      aria-label={ariaLabel}
      title={title}
      onClick={() => (onOpen ? onOpen() : toggleGroup(key))}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          if (onOpen) onOpen(); else toggleGroup(key);
        } else if (expandable && e.key === 'ArrowRight' && !open) {
          e.preventDefault();
          toggleGroup(key);
        } else if (expandable && e.key === 'ArrowLeft' && open) {
          e.preventDefault();
          toggleGroup(key);
        }
      }}
    >
      {expandable ? (
        <button
          type="button"
          className="reference-group-toggle"
          aria-label={(open
            ? t('detail:hierarchyTree.groupCollapse')
            : t('detail:hierarchyTree.groupExpand')) as string}
          aria-expanded={open}
          tabIndex={-1}
          onClick={(e) => { e.stopPropagation(); toggleGroup(key); }}
        >
          {open ? '▾' : '▸'}
        </button>
      ) : (
        <span className="reference-group-toggle reference-group-toggle--none" aria-hidden="true" />
      )}
      {content}
    </div>
  );

  const renderUsageGroups = ({ groups, noUsage }: { groups: UsageGroup[]; noUsage: ReferenceItem[] }) => (
    <ul className="reference-list reference-group-list">
      {sortGroups(groups).map(g => {
        const expandable = isGroupExpandable(g);
        const open = expandable && expandedGroups.has(g.owner.key);
        // Without toggle the head stands for its single reference: show the role
        // with its slot class (`reads_field · CF`) instead of the bare role list.
        const roles = expandable ? g.roles.join(', ') : shortRoleLabel(g.rows[0]);
        return (
          <li key={g.owner.key} className="reference-group">
            {renderGroupHead(g.owner.key, open, expandable, () => openOwner(g.owner), (
              <>
                <span className="object-type">
                  {t(`types:objectTypes.${g.owner.type}`, { defaultValue: g.owner.type })}
                </span>
                <span className="ref-name" title={g.owner.name}>
                  {formatObjectDisplayName(g.owner.type, g.owner.name)}
                </span>
                <span className="ref-meta">
                  <span className="ref-call-count">{t('detail:hierarchyTree.usageRefs', { count: g.refs })}</span>
                  <span className="ref-role-label" title={roles}>{roles}</span>
                  {g.owner.file && g.owner.file !== focusFile && (
                    <span className="ref-file">({g.owner.file})</span>
                  )}
                </span>
              </>
            ), t('detail:hierarchyTree.itemAriaLabel', {
              type: g.owner.type, name: formatObjectDisplayName(g.owner.type, g.owner.name),
            }) as string)}
            {open && renderSectionList(g.rows, 'in')}
          </li>
        );
      })}
      {noUsage.length > 0 && (() => {
        const open = expandedGroups.has(NO_USAGE_GROUP_KEY);
        return (
          <li key={NO_USAGE_GROUP_KEY} className="reference-group reference-group--no-usage">
            {renderGroupHead(NO_USAGE_GROUP_KEY, open, true, null, (
              <>
                <span className="ref-name">{t('detail:hierarchyTree.noUsageGroup')}</span>
                <span className="ref-meta">
                  <span className="ref-call-count">{t('detail:hierarchyTree.usageRefs', { count: sumRefs(noUsage) })}</span>
                </span>
              </>
            ), t('detail:hierarchyTree.noUsageGroup') as string, t('detail:hierarchyTree.noUsageGroupHint') as string)}
            {open && renderSectionList(noUsage, 'in')}
          </li>
        );
      })()}
    </ul>
  );

  const renderSectionList = (items: ReferenceItem[], dir: 'in' | 'out') => (
    <ul className="reference-list">
      {sortItems(items).map((ref, idx) => renderReferenceItem(ref, idx, dir))}
    </ul>
  );

  const hasParents = matches.parent.length > 0;
  const hasChildren = matches.child.length > 0;
  const hasStructParents = matches.structuralParent.length > 0;
  const hasStructChildren = matches.structuralChild.length > 0;
  const hasAny = hasParents || hasChildren || hasStructParents || hasStructChildren;
  const hasAnyTotal = totalCount > 0;
  const filterActive = activeTypes.size > 0 || activeRoles.size > 0 || queryLower !== '';

  return (
    <div className="hierarchy-tree-wrapper">
      {hasAnyTotal && (
        <ReferencesFilter
          typeCounts={typeCounts}
          activeTypes={activeTypes}
          onToggleType={toggleType}
          onClearTypes={clearTypes}
          roleCounts={roleCounts}
          activeRoles={activeRoles}
          onToggleRole={toggleRole}
          onClearRoles={clearRoles}
          subroleShort={subroleShort}
          query={query}
          onQueryChange={handleQueryChange}
          matchCount={matchCount}
          totalCount={totalCount}
          onJumpToList={jumpToList}
          footer={(
            <ReferencesMissing candidates={candidates} dirFilter={dirFilter} presentTypes={presentTypes} />
          )}
        />
      )}
      <nav
        ref={treeRef}
        className="hierarchy-tree"
        aria-label={t('detail:hierarchyTree.ariaLabel') as string}
        onKeyDown={handleTreeKeyDown}
      >
        {(hasAny || showDirBar) && renderToolbar()}
        {references.toUsage && (references.toUsage.available === false || references.toUsage.truncated) && (
          <div className="references-notice" role="note">
            {references.toUsage.available === false
              ? t('detail:hierarchyTree.toUsageUnavailable')
              : t('detail:hierarchyTree.toUsageTruncated', {
                count: references.toUsage.rows ?? 0, total: references.toUsage.total ?? 0,
              })}
          </div>
        )}
        {references.usage && renderUsageSummary(references.usage.owners, references.usage.refs ?? 0)}
        {hasParents && (
          <section className="hierarchy-section">
            <h2>{usageGroups
              ? (filterActive
                ? t('detail:hierarchyTree.usedByGroupedFiltered', { count: usageGroups.groups.length, total: usageGroupsTotal })
                : t('detail:hierarchyTree.usedByGrouped', { count: usageGroups.groups.length }))
              : filterActive
              ? t('detail:hierarchyTree.usedByFiltered', { count: sectionMatches.parent, total: sectionTotals.parent })
              : t('detail:hierarchyTree.usedBy', { count: sectionMatches.parent })}</h2>
            {usageGroups ? renderUsageGroups(usageGroups) : renderSectionList(matches.parent, 'in')}
          </section>
        )}

        {hasChildren && (
          <section className="hierarchy-section">
            <h2>{filterActive
              ? t('detail:hierarchyTree.usesFiltered', { count: sectionMatches.child, total: sectionTotals.child })
              : t('detail:hierarchyTree.uses', { count: sectionMatches.child })}</h2>
            {renderSectionList(matches.child, 'out')}
          </section>
        )}

        {hasStructParents && (
          <section className="hierarchy-section">
            <h2>{filterActive
              ? t('detail:hierarchyTree.structurallyContainedByFiltered', { count: sectionMatches.structuralParent, total: sectionTotals.structuralParent })
              : t('detail:hierarchyTree.structurallyContainedBy', { count: sectionMatches.structuralParent })}</h2>
            {renderSectionList(matches.structuralParent, 'in')}
          </section>
        )}

        {hasStructChildren && (
          <section className="hierarchy-section">
            <h2>{filterActive
              ? t('detail:hierarchyTree.structurallyContainsFiltered', { count: sectionMatches.structuralChild, total: sectionTotals.structuralChild })
              : t('detail:hierarchyTree.structurallyContains', { count: sectionMatches.structuralChild })}</h2>
            {renderSectionList(matches.structuralChild, 'out')}
          </section>
        )}

        {!hasAny && hasAnyTotal && (
          <div className="no-references">
            {t('detail:hierarchyTree.noFilterMatches')}
          </div>
        )}

        {!hasAnyTotal && (
          <div className="no-references">
            {t('detail:hierarchyTree.noReferences')}
          </div>
        )}

        {/* Ohne jede Referenz entfällt die Filter-Box — die Kandidaten-Zeile
            steht dann eigenständig unter dem Leerzustand. Beide Richtungen:
            ohne Referenzen gibt es keine Richtungs-Leiste, ein übrig gebliebener
            `rdir`-Param wäre dort nicht mehr umschaltbar. */}
        {!hasAnyTotal && (
          <ReferencesMissing candidates={candidates} dirFilter="both" presentTypes={presentTypes} standalone />
        )}
      </nav>
    </div>
  );
});

HierarchyTree.displayName = 'HierarchyTree';
