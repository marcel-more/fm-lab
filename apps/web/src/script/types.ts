// Script-Viewer Types — entspricht der Token-API (rest-api/src/formatters/tokens.formatter.js)

export type RefType =
  | 'field'
  | 'script'
  | 'layout'
  | 'customFunction'
  | 'pluginFunction'
  | 'function'        // Engine-Funktion (z.B. Average, JSONSetElement) — Calc-Ref
  | 'variable'
  | 'valueList'
  | 'tableOccurrence';

export type LineKind = 'step' | 'comment' | 'empty';

export type VariableScope = 'local' | 'global' | 'superglobal';
export type VariableUsage = 'set' | 'read';

export interface ScriptRef {
  type: RefType;
  name: string;
  uuid?: string;
  file?: string;
  table?: string;
  baseTable?: string;
  crossFile?: boolean;
  dataSource?: string;
  scope?: VariableScope;
  usage?: VariableUsage;
  subFunction?: string;

  // Reference-DB-Anreicherung für type === 'function' (nur mit ?enrich=<lang>)
  functionId?: number;
  functionCanonical?: string;
  functionSubParameter?: string;
  /** Ungeteilter kanonischer Name = Katalog-Identität, z.B. 'Get(FileName)'. */
  functionCanonicalFull?: string;
  functionDisplayName?: string;
  functionSignature?: string;
  functionPurpose?: string;
  functionReturnType?: string;
  functionHelpUrl?: string;
  functionLocalHelpUrl?: string;
}

export interface ScriptLineToken {
  line: number;
  indent: number;
  kind: LineKind;
  enabled: boolean;
  stepId?: number;
  stepName?: string;
  text?: string;
  refs?: ScriptRef[];

  // ScriptStep-UUID aus StepsForScripts.Step_UUID — Identität des konkreten
  // Steps im aktuellen Script, für Cross-Reference-Highlight: back_references
  // liefert diese UUIDs als Match-Set, wenn Origin=ScriptStepType.
  stepUuid?: string;

  // Synthetischer ScriptStepType-UUID — für Cross-Navigation vom
  // Step-Namen zur ScriptStepType-Detail-Seite. Deterministisch via
  // md5('ScriptStepType::' || Step_Name).
  stepTypeUuid?: string;

  // ScriptStep-Reference (nur mit ?enrich=<lang>)
  stepDisplayName?: string;
  stepDescription?: string;
  stepHelpUrl?: string;
  stepLocalHelpUrl?: string;
  stepCategoryId?: number;
}

export interface ScriptTokens {
  kind: 'script';
  object: {
    uuid: string;
    name: string;
    file: string;
    // Nur bei ScriptStep-Detail gesetzt: Kontext zum übergeordneten Skript,
    // damit der Detail-Header eine Karte mit Sprung-Link rendern kann.
    parentScript?: { uuid: string; name: string; file: string };
    stepIndex?: number;
  };
  lines: ScriptLineToken[];
  plainText?: string;
  /**
   * Nur bei LayoutObject-Detail gesetzt: die Calc-Slot-Instanzen des Objekts
   * (hide, tooltip, portal_filter, web_viewer_url, …) aus dem
   * CalculationsCatalog — das Frontend rendert jeden Slot tokenisiert via
   * get-calc?uuid (DDR-los: plainText-Fallback). Trigger-Parameter und
   * conditional_format-Slots sind in `triggers`/`conditions` konsolidiert,
   * sofern die Tabellen sie abdecken.
   */
  calcSlots?: import('./calcTokens').LayoutObjectCalcSlot[];
  /** Nur bei LayoutObject-Detail: konkreter Objekt-Typ + Eltern-Layout + Panel-Eigenschaften. */
  layoutObject?: import('./calcTokens').LayoutObjectContext | null;
  /** Nur bei LayoutObject-Detail: direkte Kind-Objekte (Z_Order-sortiert). */
  children?: import('./calcTokens').LayoutObjectChild[];
  /** Nur bei LayoutObject-Detail: Script-Trigger-Tabelle (Trigger_ID-sortiert). */
  triggers?: import('./calcTokens').LayoutObjectTrigger[];
  /** Nur bei LayoutObject-Detail: Ziel-Links der Ziel-Leiste. */
  targets?: import('./calcTokens').LayoutObjectTarget[];
  /** Nur bei LayoutObject-Detail: CF-Regeln (LayoutObjectConditions). */
  conditions?: import('./calcTokens').LayoutObjectCondition[];
  /**
   * Nur bei Text-LayoutObjects mit aufgelösten Merge-Ankern: die server-
   * synthetisierte Token-Zeile des Textinhalts (<<Feld>>/<<$$var>>/{{Symbol}}
   * ersetzt durch typisierte Tokens, ƒ-Anker verbatim). Keine Calculation-
   * Instanz dahinter — direkt rendern, kein get-calc-Fetch.
   */
  mergeText?: import('./calcTokens').LayoutObjectMergeText | null;
}

export type FoldKind = 'if' | 'loop' | 'transaction' | 'multiline' | 'comment-block';

export interface FoldRange {
  startLine: number;
  endLine: number;
  kind: FoldKind;
}

export type ViewMode =
  | 'normal'
  | 'compact'
  | 'comments-only'
  | 'control-only'
  | 'subscript-only'
  | 'assignments-only'
  | 'executive-only';

export type MarginRole = 'comment' | 'metadata' | 'executive';
