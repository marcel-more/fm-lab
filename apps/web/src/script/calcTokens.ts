// Calc-Token-Typen für CustomFunctions und Calculations (analog
// rest-api/src/formatters/tokens.formatter.js).
//
// Server-seitige Anreicherung über `?enrich=<lang>` fügt für
// Tokens mit `type: 'function'` zusätzliche Felder hinzu (Reference-DB).
// Diese sind optional, damit die Antwort ohne enrich byte-identisch bleibt.

export type CalcTokenType =
  | 'text'
  | 'function'
  | 'customFunction'
  | 'pluginFunction'
  | 'variable'
  | 'field'
  | 'comment';

export interface CalcToken {
  type: CalcTokenType;
  content: string;
  uuid?: string;
  scope?: 'local' | 'global' | 'superglobal';
  subFunction?: string;

  // Reference-DB Anreicherung (nur für type === 'function', wenn enrich=<lang> aktiv)
  functionId?: number;
  functionCanonical?: string;          // z.B. 'Average' oder 'Get' bei Get-Funktionen
  functionSubParameter?: string;       // z.B. 'FileName' bei Get(FileName)
  /** Ungeteilter kanonischer Name = Katalog-Identität, z.B. 'Get(FileName)'. */
  functionCanonicalFull?: string;
  functionDisplayName?: string;        // lokalisierter Name (z.B. 'Mittelwert')
  functionSignature?: string;          // lokalisierte Signatur
  functionPurpose?: string;            // Kurzbeschreibung (1-Zeiler)
  functionReturnType?: string;
  functionUrlSlug?: string;
  functionHelpUrl?: string;            // Claris-Hilfe extern
  functionLocalHelpUrl?: string;       // Lokaler Mirror-Pfad
  functionChunkRole?: 'function' | 'getfunction' | 'getparameter';
  functionMatchSource?: string;
}

export interface CustomFunctionTokens {
  kind: 'customfunction';
  object: { uuid: string; name: string; file: string };
  parameters: string[];
  tokens: CalcToken[];
  plainText: string;
}

/** Ziel-Link einer Calculation-Instanz (abgeleitet, v_calculation_links). */
export interface CalculationTarget {
  linkRole: string;
  uuid: string | null;
  type: string | null;
  name: string | null;
  file: string | null;
  crossFile: boolean;
}

/** Instanz-Metadaten einer Calculation (Owner × Rolle × Index, Schema 1.22.0). */
export interface CalculationMeta {
  role: string;
  kindRaw: string | null;
  index: number;
  sourcePath: string | null;
  isStatic: boolean;
  /** false = DDR-lose Instanz — kein Token-Fetch, plainText-Fallback. */
  hasTokens: boolean;
  hash: string | null;
  contextTo: string | null;
  /** Ergebnistyp einer display_calculation aus dem %X:-Präfix (Schema 1.27.0). */
  resultType?: string | null;
  /** Rekonstruierter Layout-Textanker (`<<ƒ:%X:Formel>>`) — nur display_calculation. */
  layoutFormula?: string | null;
  owner: { uuid: string; type: string; name: string | null; file: string };
}

export interface CalculationTokens {
  kind: 'calculation';
  object: { hash?: string; uuid?: string; name?: string; file?: string };
  tokens: CalcToken[];
  plainText: string;
  /** true = Tokens synthetisch aus der geretteten Formel rekonstruiert
   *  (leere DDR-ChunkList; Builtin-Funktionen bleiben Text). */
  tokensRecovered?: boolean;
  /** Nur im Detail-Pfad (get-details?format=tokens) gesetzt. */
  calc?: CalculationMeta;
  targets?: CalculationTarget[];
}

/** Calc-Slot-Instanz eines LayoutObjects (calcSlots im tokens-Payload). */
export interface LayoutObjectCalcSlot {
  uuid: string;
  role: string;
  index: number;
  sourcePath: string | null;
  isStatic: boolean;
  /** false = DDR-lose Instanz — Klartext-Fallback statt get-calc?uuid. */
  hasTokens: boolean;
  plainText: string | null;
  /** Ergebnistyp einer display_calculation aus dem %X:-Präfix (Schema 1.27.0). */
  resultType?: string | null;
  /** Rekonstruierter Layout-Textanker (`<<ƒ:%X:Formel>>`) — nur display_calculation. */
  layoutFormula?: string | null;
}

/**
 * Aufgelöste Merge-Text-Zeile eines Text-LayoutObjects (mergeText im
 * tokens-Payload): server-synthetisierte Tokens der reinen Merge-Anker —
 * Felder/Variablen navigierbar (Kanten-UUID), valide Symbole als Get-Token-
 * Gruppe, unauflösbare Anker und ƒ-Anker verbatim als Text. `anchors` zählt
 * die Nicht-ƒ-Anker (total) und davon aufgelöste (resolved).
 */
export interface LayoutObjectMergeText {
  tokens: CalcToken[];
  anchors: { total: number; resolved: number };
}

/**
 * Kontext eines LayoutObjects: konkreter Typ + Eltern-Layout für den Rücksprung
 * sowie die Struktur-Eigenschaften des Eigenschaften-Panels (Part, Bounds,
 * Nesting, klickbarer Parent). Die Panel-Felder fehlen bei API-Ständen vor v2.
 */
export interface LayoutObjectContext {
  type: string;
  layoutUuid: string | null;
  layoutName: string | null;
  objectId?: number | null;
  partType?: string | null;
  nestingLevel?: number | null;
  /** Original-Textblock des Objekts (Layout-Wahrheit inkl. Merge-Anker). */
  textContent?: string | null;
  bounds?: { top: number; left: number; bottom: number; right: number } | null;
  /** Parent-LayoutObject (null auf Ebene 0) — Gegenrichtung der Kind-Sektion. */
  parent?: { uuid: string; type: string | null; name: string | null } | null;
}

/** Script-Trigger eines Kind-Objekts (Trigger-Spalte der Kind-Tabelle). */
export interface LayoutObjectChildTrigger {
  /** Kanonischer (englischer) Event-Name, z.B. 'OnObjectSave'. */
  action: string;
  scriptUuid: string | null;
  scriptName: string | null;
  /** Katalog-UUID des ScriptTrigger-Objekts; optional (ältere API-Stände). */
  triggerUuid?: string | null;
}

/**
 * Direktes Kind-Objekt eines LayoutObjects (children im tokens-Payload) — eine
 * Zeile der Kind-Objekt-Sektion (Button-Bar-Segmente, Tab-Panels, Group-
 * Inhalte), in Segment-Reihenfolge (Z_Order). `target` ist das gehoistete Ziel
 * des Kindes nach der v2-Auflösungsregel (displays_field → portal_context →
 * triggers_script[button_action] → navigates_to_layout — Event-Trigger nehmen
 * nicht teil); das Label ist die button_label-Calculation (Fallback-Kette
 * textContent → name → Typ rendert das Frontend).
 */
export interface LayoutObjectChild {
  uuid: string;
  objectId: number;
  type: string;
  name: string | null;
  textContent: string | null;
  /** button_label-Calculation-Instanz; null = Kind ohne Label-Formel. */
  labelCalcUuid: string | null;
  /** false = DDR-lose Label-Instanz — labelText-Fallback. */
  labelHasTokens: boolean;
  labelText: string | null;
  target: {
    uuid: string;
    type: string | null;
    name: string | null;
    file: string | null;
    linkRole: string;
  } | null;
  /**
   * Script-Trigger des Kindes (owner-genau aus ScriptTriggers, Trigger_ID-
   * sortiert); optional, damit ältere API-Stände den Client nicht brechen.
   */
  triggers?: LayoutObjectChildTrigger[];
  /**
   * Button-Aktions-Script, wenn eine button_action-Kante existiert und nicht
   * selbst als target gehoistet wurde (Feld-Control, das zugleich Button ist).
   */
  buttonAction?: {
    uuid: string;
    type: string | null;
    name: string | null;
    file: string | null;
  } | null;
}

/**
 * Script-Trigger eines LayoutObjects (triggers im tokens-Payload) — eine Zeile
 * der Trigger-Tabelle: Event, Modi (B/S/V), Script-Link, Parameter-Calculation.
 */
export interface LayoutObjectTrigger {
  triggerId: number;
  /** Kanonischer (englischer) Event-Name, z.B. 'OnObjectEnter'. */
  action: string;
  browseMode: boolean;
  findMode: boolean;
  previewMode: boolean;
  scriptUuid: string | null;
  scriptName: string | null;
  /** Katalog-UUID des ScriptTrigger-Objekts; optional (ältere API-Stände). */
  triggerUuid?: string | null;
  /** Calculation-Instanz des Script-Parameters; null = ohne Parameter. */
  paramCalcUuid: string | null;
  /** false = DDR-lose Parameter-Instanz — paramText-Fallback. */
  paramHasTokens: boolean;
  paramText: string | null;
}

/** Ziel-Link der Ziel-Leiste (displays_field, portal_context, …). */
export interface LayoutObjectTarget {
  linkRole: string;
  uuid: string;
  type: string | null;
  name: string | null;
  file: string | null;
  crossFile: boolean;
}

/**
 * Geparste Format-Seite einer CF-Regel (C3-CSS-Parser der API). Farb-/
 * Schrift-/Größen-Wahlen sind bit-gegated (nur aktiv Gewähltes ist gesetzt),
 * Stil-Toggles präsenz-basiert; `css` sind fertige Web-Deklarationen in
 * React-Style-Keys für das Vorschau-Sample, `raw` das LocalCSS verbatim.
 */
export interface LayoutObjectConditionFormat {
  textColor: string | null;
  fillColor: string | null;
  fontFamily: string | null;
  fontSize: string | null;
  iconColor: string | null;
  bold: boolean;
  italic: boolean;
  /** 'underline' | 'word-underline' | 'double-underline' */
  underline: string | null;
  strikethrough: boolean;
  smallCaps: boolean;
  /** 'condensed' | 'expanded' */
  stretch: string | null;
  /** 'superscript' | 'subscript' */
  glyphVariant: string | null;
  /** 'uppercase' | 'lowercase' | 'capitalize' */
  textTransform: string | null;
  highlightColor: string | null;
  css: Record<string, string>;
  raw: string | null;
}

/**
 * Conditional-Formatting-Regel aus LayoutObjectConditions (regel-genau,
 * Rule_Index-sortiert; auch rein wertbasierte Bedingungen ohne eigene
 * Calculation-Instanz).
 */
export interface LayoutObjectCondition {
  ruleIndex: number;
  /** Condition/@type roh: 0 = Formel, 1–13 = wertbasierter Operator. */
  conditionType: number;
  conditionKind: string | null;
  /** Options-Bit 0 — im FileMaker-Dialog aktivierte Regel. */
  enabled: boolean;
  /** Options-Bitmaske roh (Bits 1/2/3/4/7 = Farb-/Schrift-/Größen-Wahlen). */
  optionsRaw?: number;
  calcText: string | null;
  rangeStart: string | null;
  rangeEnd: string | null;
  calcHash?: string | null;
  calcUuid: string | null;
  hasTokens: boolean;
  /** C3-Parser-Format; fehlt bei API-Ständen vor C3. */
  format?: LayoutObjectConditionFormat;
}

/** Fortlaufende Nummer (AutoEnter_Type='SerialNumber'). */
export interface FieldSerial {
  generate: string | null;   // OnCreation | OnCommit
  nextValue: string | null;
  increment: string | null;
}

/** Referenzwert / Lookup (AutoEnter_Type='Looked_up'). */
export interface FieldLookup {
  field: string | null;
  /** UUID + aufgelöste Zieldatei des Quellfelds (klickbarer Link); null = nur Text. */
  fieldUuid: string | null;
  fieldFile: string | null;
  /** Herkunfts-BaseTable des Quellfelds — disambiguiert gleichnamige Felder. */
  fieldTable: string | null;
  to: string | null;
  dontCopyIfEmpty: boolean;
  noMatch: string | null;    // DoNotCopy | ConstantData
  /** false = disabled lookup (FileMaker 26 exports it with enable="False"). */
  enabled: boolean;
}

/** Flags einer AutoEnter-Berechnung (AutoEnter_Type='Calculated'). */
export interface FieldAutoEnterCalc {
  overwriteExisting: boolean;
  alwaysEvaluate: boolean;
  /** false = disabled auto-enter calculation (FileMaker 26 export, enable="False"). */
  enabled: boolean;
}

/** Überprüfung / Validierung (nur wenn eine echte Regel gesetzt ist). */
export interface FieldValidation {
  mode: string | null;       // Always | OnlyDuringDataEntry
  allowOverride: boolean;
  notEmpty: boolean;
  unique: boolean;
  existing: boolean;
  valueList: { name: string; uuid: string | null } | null;
  strictType: string | null; // Numeric | FourDigitYear | TimeOfDay
  maxChars: number | null;
  rangeFrom: string | null;
  rangeTo: string | null;
  calcText: string | null;   // „Überprüfung durch Berechnung"
  /** Calculation-Instanz-UUID der Validierungsformel (Token-Rendering); null = DDR-los. */
  calcUuid: string | null;
  /** false = disabled validation calculation (FileMaker 26 export, enable="False"). */
  calcEnabled: boolean;
  message: string | null;    // eigene Fehlermeldung
  /** Fehlermeldungs-FORMEL (validation_message-Slot); uuid null = DDR-los → text-Fallback. */
  messageCalc: { uuid: string | null; text: string | null; enabled: boolean } | null;
}

/** One JSON element of the display-names formula (FileMaker 26, "Feld-Anzeigenamen anpassen"). */
export interface FieldDisplayNameElement {
  seq: number;
  key: string;
  /** Label (kind 'literal', unquoted) or the raw expression (kind 'formula'). */
  value: string | null;
  kind: 'literal' | 'formula';
  jsonType: string | null;   // JSONString | JSONNumber | …
}

/** FileMaker 26 display names of a field: the formula plus its parsed elements. */
export interface FieldDisplayNames {
  enabled: boolean;
  calcText: string | null;
  /** Calculation instance UUID (role display_names) for token rendering; null = DDR-less. */
  calcUuid: string | null;
  elements: FieldDisplayNameElement[];
}

/** Speicher / Indizierung. */
export interface FieldStorage {
  index: string | null;      // None | Minimal | All
  autoIndex: boolean;
  storeCalcResults: boolean;
  indexLanguage: string | null; // Standard-Indexsprache (nur bei indiziertem Feld)
  evaluatesWhenEmpty: boolean;  // Calc-Feld Nicht-Default: rechnet auch bei leeren Ref-Feldern (= alwaysEvaluate)
}

/** Statistikfeld (Field_Type='Summary'). */
export interface FieldSummary {
  operation: string | null;
  field: { name: string; uuid: string | null } | null;
  restartEachGroup: boolean;
  repetitionMode: string | null; // Together | Individually (null = Default Together)
}

export interface FieldMeta {
  table: string | null;
  fieldType: string | null;
  dataType: string | null;
  isGlobal: boolean;
  maxRepetitions: number;
  comment: string | null;
  autoEnterType: string | null;
  /** Fester Vorgabewert bei AutoEnter_Type = 'ConstantData' (sonst null). */
  constantData: string | null;
  /** Änderung durch Benutzer gesperrt (AutoEnter_ProhibitMod). */
  prohibitModification: boolean;
  serial: FieldSerial | null;
  lookup: FieldLookup | null;
  autoEnterCalc: FieldAutoEnterCalc | null;
  validation: FieldValidation | null;
  storage: FieldStorage | null;
  summary: FieldSummary | null;
  /** FileMaker 26: free-text annotation of the field (DDL comment); null when unset. */
  annotation: string | null;
  /** FileMaker 26: display-names feature; null when the export predates it. */
  displayNames: FieldDisplayNames | null;
}

export interface FieldTokens {
  kind: 'field';
  object: { uuid: string; name: string; file: string };
  field: FieldMeta | null;
  tokens: CalcToken[];
  plainText: string;
}

// Custom Menu: mehrere Berechnungen (Menü-eigene + pro-Item) als je ein Token-Block.
export interface CustomMenuCalcBlock {
  label: string;
  isStatic: boolean;
  tokens: CalcToken[];
  plainText: string;
}

export interface CustomMenuTokens {
  kind: 'custommenu';
  object: { uuid: string; name: string; file: string };
  calcs: CustomMenuCalcBlock[];
}

/**
 * Detail-Payload eines ScriptTrigger-Objekts (get-details?format=tokens,
 * Object_Type='ScriptTrigger'): die ScriptTriggers-Zeile als Attribut-Quelle
 * plus Owner-Kette und die Namens-Kandidaten des Transaktions-Parameterfelds.
 */
export interface ScriptTriggerOwner {
  uuid: string;
  /** 'LayoutObject' | 'Layout' | 'File' */
  type: string;
  name: string | null;
  file: string | null;
  /** Eltern-Layout (nur bei LayoutObject-Ownern, via parent_layout). */
  layoutUuid: string | null;
  layoutName: string | null;
}

export interface ScriptTriggerFieldCandidate {
  uuid: string;
  name: string | null;
  file: string | null;
  tableName: string | null;
}

export interface ScriptTriggerDetailPayload {
  kind: 'scripttrigger';
  object: { uuid: string; name: string | null; file: string | null; type: string };
  trigger: {
    triggerId: number;
    /** Roher Event-Name aus Trigger_Action (i.d.R. kanonisch, z.B. 'OnObjectSave'). */
    action: string | null;
    browseMode: boolean;
    findMode: boolean;
    previewMode: boolean;
    scriptUuid: string | null;
    scriptName: string | null;
    scriptFile: string | null;
    /** Calculation-Instanz des Script-Parameters; null = ohne Parameter. */
    paramCalcUuid: string | null;
    paramHasTokens: boolean;
    paramText: string | null;
    /** OnWindowTransaction: name-only Feldbezug des JSON-Parameters. */
    scriptParameterFieldName: string | null;
  };
  owner: ScriptTriggerOwner | null;
  fieldCandidates: ScriptTriggerFieldCandidate[];
}
