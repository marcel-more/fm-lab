import type { components } from '@packages/shared/types';

/**
 * Healing metadata delivered by the object-detail API for objects whose UUID
 * was replaced during duplicate healing (intra-file UUID duplicates): the twin
 * with the smallest internal ID keeps the original UUID, further twins get a
 * synthetic replacement (md5 hex, 32 chars WITHOUT dashes — formally
 * distinguishable from native 8-4-4-4-12 UUIDs). Absent for native UUIDs.
 */
export interface ObjectHealing {
  is_synthetic: boolean;
  /** Original UUID from the source file — ambiguous there (assigned twice). */
  original_uuid: string | null;
  discriminator?: string | null;
}

// Re-export commonly used types
export type FMObject = components['schemas']['FMObject'] & {
  /** Only present for synthetic (healed) UUIDs — see ObjectHealing. */
  healing?: ObjectHealing;
};
export type ObjectType = components['schemas']['ObjectType'];

/**
 * A reference item as returned by the /api/references endpoint (direction=all).
 * The actual API returns a flat array with a direction discriminator,
 * not the nested structure from the OpenAPI spec.
 *
 * Container_UUID/Container_Type sind für Sub-Knoten (LayoutObject, ScriptStep)
 * gesetzt — diese öffnen sich beim Klick im Container-View mit dem Sub-Knoten
 * als ref-Highlight. Für eigenständige Objekte sind beide Felder null.
 *
 * `navigable` ist false für step-eigene Referenzen (ScriptStep-Detail), deren
 * Ziel datei-extern nicht im importierten Datenbestand aufgelöst werden konnte —
 * sie werden als nicht-klickbarer Text gezeigt statt verschluckt. Fehlt das Feld
 * (alle Graph-basierten Referenzen), gilt das Ziel als navigierbar.
 */
export interface ReferenceItem {
  direction: 'parent' | 'child';
  uuid: string;
  Object_Type: string;
  Object_Name: string;
  File_Name: string;
  Link_Role: string;
  /**
   * Normalisierte Slot-Klasse der Kanten-Subrole (calc_kind-Vokabular:
   * 'hide', 'conditional_format', 'tooltip', …). NULL/fehlend bei Kanten ohne
   * semantische Subrole — insbesondere Script-Kanten, deren positionelle
   * Slot-Indizes API-seitig unterdrückt werden. Unbekannte Subroles werden
   * roh durchgereicht (Fallback-Anzeige, nie verschluckt).
   */
  Subrole_Class?: string | null;
  /**
   * Roh-Subrole(n) für den Tooltip: bei direction=all die aggregierten
   * DISTINCT-Werte der Gruppe ('Condition_1, Condition_2'), in den
   * ungruppierten child/parent-Zweigen der einzelne Roh-Wert.
   */
  Subrole_Detail?: string | null;
  /**
   * Aufgelöste Trigger-Event-Namen zu `ScriptTrigger_<id>`-Subroles
   * (Klasse 'script_trigger_parameter') — DISTINCT-Liste kanonischer Events
   * ('OnObjectValidate' bzw. 'OnPanelSwitch, OnObjectValidate'), API-seitig
   * über die fm_spec-Referenz aufgelöst. Fehlt ohne Referenz-DB/ältere
   * fm_spec-Stände — die Anzeige degradiert dann aufs Klassen-Kurzlabel.
   */
  Subrole_Event?: string | null;
  Is_Cross_File: boolean;
  Container_UUID?: string | null;
  Container_Type?: string | null;
  /**
   * Klartext-Name + Datei des Containers (Layout eines ScriptTriggers, Layout eines
   * LayoutObjects, Script eines ScriptSteps). Verortet Sub-Knoten, deren eigener Name
   * generisch ist (z.B. alle „OnLayoutKeystroke"-Trigger eines Scripts) — sie werden
   * erst durch den Container-Namen unterscheidbar. Datei nur relevant, wenn abweichend.
   */
  Container_Name?: string | null;
  Container_File?: string | null;
  /**
   * Nur konsolidierte Spiegel-Zeilen (`triggers_script·<Event>`): Katalog-UUID
   * des ScriptTrigger-Sub-Knotens (`trig_<id>_…`), dessen granulare Zeile die
   * Anzeige-Konsolidierung unterdrückt. Trägt den Sekundär-Absprung auf die
   * Trigger-Detailseite; NULL auf allen anderen Zeilen und älteren API-Ständen.
   */
  Trigger_UUID?: string | null;
  navigable?: boolean;
  /**
   * Nur Pseudo-Aggregat-Typen (ScriptStepType): Anzahl der Schritte dieses Typs,
   * die das Ziel referenzieren (bzw. Vorkommen des Schritts im Script). Dient als
   * Häufigkeits-Hinweis in der Referenzliste.
   */
  Call_Count?: number;
  /**
   * Nur Pseudo-Aggregat-Typen mit gesetztem `?ref=<origin>`: true, wenn diese
   * Referenz aus dem Herkunfts-Objekt heraus erreichbar ist (z.B. das Feld, das
   * der Schritt im Herkunfts-Script schreibt). Die UI pinnt/markiert solche Zeilen.
   */
  Origin_Hit?: boolean;
  /**
   * Incoming rows of objects with a usage notion (meta.usage present): true when
   * the row is a usage in the sense of v_object_usage — these rows add up to
   * meta.usage.refs and form the groups of the "by object" view. Missing on
   * outgoing rows and on older API versions.
   */
  Counts_As_Usage?: boolean;
}

/**
 * Grouped references after client-side splitting.
 * Operational links (Script→Field, LayoutObject→Script, …) und strukturelle
 * Links (parent_folder, parent_object, parent_layout, …) werden parallel
 * geladen und getrennt dargestellt, damit Folder-Hierarchien sichtbar werden,
 * ohne den operationalen Kontext zu überladen.
 */
export interface GroupedReferences {
  parent: ReferenceItem[];
  child: ReferenceItem[];
  structuralParent: ReferenceItem[];
  structuralChild: ReferenceItem[];
  /**
   * Table occurrences only: state of the usages appended from the analysis
   * table (`uses_table_occurrence` rows — TO::Field in formulas, script steps,
   * layout fields, …). `available: false` = catalog older than schema 1.38.0,
   * the list holds the edges alone. Absent for every other object type.
   */
  toUsage?: TableOccurrenceUsageMeta | null;
  /**
   * Usage as the search column shows it (v_object_usage, schema 1.40.0):
   * owners = using objects (an object on a layout counts as its layout),
   * refs = usage links. Absent for types without a usage notion and on older
   * catalogs.
   */
  usage?: ObjectUsageMeta | null;
}

export interface ObjectUsageMeta {
  owners: number;
  users: number | null;
  refs: number | null;
  class: string | null;
}

export interface TableOccurrenceUsageMeta {
  available: boolean;
  /** Usage rows delivered (after the reference limit). */
  rows?: number;
  /** Usage rows in total. */
  total?: number;
  truncated?: boolean;
}

/**
 * Referenz-Kandidat aus `/api/references/candidates`: Richtung × Typgruppe ×
 * Rollenmenge mit serverseitig abgeleitetem Status (present/indirect/missing).
 * Speist die Zeile „Nicht referenziert“ unter den Referenz-Filtern.
 */
export type ReferenceCandidate = components['schemas']['ReferenceCandidate'];

/** Kandidaten eines Objekts samt Meta (Fokus-Typ, Aggregat-Mitglieder, …). */
export interface ReferenceCandidates {
  items: ReferenceCandidate[];
  meta: NonNullable<components['schemas']['ReferenceCandidatesResponse']['meta']>;
}

/**
 * Breadcrumb item for navigation.
 */
export interface BreadcrumbItem {
  label: string;
  path: string | null; // null = current page (no link)
}

// Sort & Group options (Phase 3)
export type SortOption = 'standard' | 'name' | 'type' | 'file' | 'modified' | 'usage';
/** Direction of the usage sort: asc = rarely used first. */
export type UsageDir = 'asc' | 'desc';
/** Comparison of the usage filter: le = usage ≤ n, ge = usage ≥ n. */
export type UsageOp = 'le' | 'ge';
export type GroupOption = 'none' | 'type' | 'file';

export interface GroupHeader {
  _type: 'header';
  groupKey: string;
  groupLabel: string;
  itemCount: number;
  isExpanded: boolean;
}

export interface ListItemWrapper {
  _type: 'item';
  object: FMObject;
}

export type VirtualListRow = GroupHeader | ListItemWrapper;

// Detail View types (Phase 3b)
export type DetailViewTab = 'detail' | 'references' | 'graph' | 'tests' | 'versions' | 'notes';

export interface TabDefinition {
  id: DetailViewTab;
  label: string;
  enabled: boolean; // false = disabled/coming soon
}

/**
 * Sub-navigation tabs for the detail view.
 * Disabled tabs are shown but not clickable.
 */
/**
 * Sub-navigation tab definitions. The `label` carries the i18n key path inside
 * the `nav` namespace (e.g. `detailView.tabs.detail`). Consumers translate it
 * via `t(`nav:${tab.label}`)`.
 */
export const DETAIL_TABS: readonly TabDefinition[] = [
  { id: 'detail',     label: 'detailView.tabs.detail',     enabled: true },
  { id: 'references', label: 'detailView.tabs.references', enabled: true },
  { id: 'graph',      label: 'detailView.tabs.graph',      enabled: true },
  { id: 'tests',      label: 'detailView.tabs.tests',      enabled: true },
  { id: 'versions',   label: 'detailView.tabs.versions',   enabled: false },
  { id: 'notes',      label: 'detailView.tabs.notes',      enabled: false },
];

/**
 * Object types that have a type-specific detail view available.
 * Used by ObjectDetail to determine heading text.
 */
export const DETAIL_VIEW_TYPES: ReadonlySet<string> = new Set([
  'Script',
  'Layout',
  'Field',
  'BaseTable',
  'CustomFunction',
  'ValueList',
]);
