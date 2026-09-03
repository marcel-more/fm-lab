/**
 * API Constants
 * Defines supported object types, formats, error codes, and other constants
 */

/**
 * FileMaker Object Types (from ObjectCatalog)
 */
const OBJECT_TYPES = [
  "BaseTable",
  "TableOccurrence",
  "Relationship",
  "Field",
  "ValueList",
  "CustomFunction",
  "Script",
  "ScriptStep",
  "Layout",
  "LayoutObject",
  "LayoutPart",
  "Account",
  "PrivilegeSet",
  "ExtendedPrivilege",
  "Theme",
  "CustomMenu",
  "ScriptTrigger",
  "ExternalDataSource",
  "BaseDirectory",
  "Variable",
  "ScriptFolder",
  "LayoutFolder",
  "RelationshipGraph",
  "BuiltinFunction",
  "PluginFunction",
  "ScriptStepType",
  "PluginComponent",
  "File",
  "Calculation",
];

/**
 * Pseudo-Token-Types: synthetische Aggregat-Einträge, die Inline-Filter
 * (?withUsage / ?withCategory / ?category / ?sort) und den /api/list/categories
 * Endpoint unterstützen. PluginComponent ist bewusst NICHT enthalten — es
 * ist selbst die Category-Ebene.
 */
const PSEUDO_TOKEN_TYPES = [
  "ScriptStepType",
  "BuiltinFunction",
  "PluginFunction",
];

/**
 * Folder Pseudo-Types
 * Folder ist im Datenmodell ein einziger Object_Type ('Folder'), aber im API-Sprachgebrauch
 * trennen wir nach Source_Table, damit Konsumenten zwischen Script-/Layout-Folder unterscheiden
 * können.
 */
const FOLDER_PSEUDO_TYPES = {
  ScriptFolder: "ScriptCatalog",
  LayoutFolder: "Layouts",
};

/**
 * Mapping from lowercase type to PascalCase (for database queries)
 * Used for case-insensitive API parameter handling
 */
const OBJECT_TYPE_MAP = {
  basetable: "BaseTable",
  tableoccurrence: "TableOccurrence",
  relationship: "Relationship",
  field: "Field",
  valuelist: "ValueList",
  customfunction: "CustomFunction",
  script: "Script",
  scriptstep: "ScriptStep",
  layout: "Layout",
  layoutobject: "LayoutObject",
  layoutpart: "LayoutPart",
  account: "Account",
  privilegeset: "PrivilegeSet",
  extendedprivilege: "ExtendedPrivilege",
  theme: "Theme",
  custommenu: "CustomMenu",
  scripttrigger: "ScriptTrigger",
  externaldatasource: "ExternalDataSource",
  basedirectory: "BaseDirectory",
  variable: "Variable",
  scriptfolder: "ScriptFolder",
  layoutfolder: "LayoutFolder",
  relationshipgraph: "RelationshipGraph",
  builtinfunction: "BuiltinFunction",
  pluginfunction: "PluginFunction",
  scriptsteptype: "ScriptStepType",
  plugincomponent: "PluginComponent",
  file: "File",
  calculation: "Calculation",
};

/**
 * Link Types (from ObjectLinks)
 */
const LINK_TYPES = {
  OPERATIONAL: "operational",
  STRUCTURAL: "structural",
  ALL: "all",
};

/**
 * Reference Directions
 */
const REFERENCE_DIRECTIONS = {
  ALL: "all",
  PARENT: "parent",
  CHILD: "child",
  RECURSIVE: "recursive",
};

/**
 * Output Formats
 */
const OUTPUT_FORMATS = {
  JSON: "json",
  RAW: "raw",
  TEXT: "text",
  SHORT: "short",
  DETAILED: "detailed",
  HTML: "html",
  MARKDOWN: "markdown",
  CONTENT: "content",
  MERMAID: "mermaid", // HTML-Wrapper mit Mermaid.js
  MERMAID_RAW: "mermaid-raw", // Nur Mermaid-Code
  TOKENS: "tokens", // Strukturierte Token-Sequenz für Editor-Integration
};

/**
 * Error Codes with HTTP Status Codes
 */
const ERROR_CODES = {
  VALIDATION_ERROR: { code: "VALIDATION_ERROR", status: 400 },
  OBJECT_NOT_FOUND: { code: "OBJECT_NOT_FOUND", status: 404 },
  // Clone-Duplikate: dieselbe Objekt-UUID existiert in mehreren Dateien
  // (geklonte/modulare FileMaker-Dateien teilen interne UUIDs).
  // Bare UUID ist dann nicht eindeutig → Client muss ?file=<File_Name> nachreichen.
  AMBIGUOUS_UUID: { code: "AMBIGUOUS_UUID", status: 409 },
  // Synthetic replacement UUID from UUID healing (schema 1.19.0): the object is a
  // healed intra-file duplicate twin; its UUID exists only in FM-Lab, never in the
  // FileMaker source → fmp:// deep links are impossible by design (422, not 404 —
  // the object DOES exist in the catalog).
  SYNTHETIC_UUID: { code: "SYNTHETIC_UUID", status: 422 },
  TEMPLATE_NOT_FOUND: { code: "TEMPLATE_NOT_FOUND", status: 404 },
  DATABASE_ERROR: { code: "DATABASE_ERROR", status: 500 },
  TEMPLATE_ERROR: { code: "TEMPLATE_ERROR", status: 500 },
  // Lösung mit älterem Katalog-Schema importiert als die App erwartet — die
  // Query referenziert Spalten/Tabellen, die es in dieser DB (noch) nicht gibt.
  // 409 (Conflict): behebbarer Zustands-Mismatch, Aktion = XML neu konvertieren.
  SCHEMA_DRIFT: { code: "SCHEMA_DRIFT", status: 409 },
  FILE_NOT_FOUND: { code: "FILE_NOT_FOUND", status: 404 },
  IMPORT_ERROR: { code: "IMPORT_ERROR", status: 500 },
  INTERNAL_ERROR: { code: "INTERNAL_ERROR", status: 500 },
  REF_NOT_ATTACHED: { code: "REF_NOT_ATTACHED", status: 503 },
  REF_STEP_NOT_FOUND: { code: "REF_STEP_NOT_FOUND", status: 404 },
  REF_FUNCTION_NOT_FOUND: { code: "REF_FUNCTION_NOT_FOUND", status: 404 },
  REF_LANG_INVALID: { code: "REF_LANG_INVALID", status: 400 },
  REF_HELP_NOT_FOUND: { code: "REF_HELP_NOT_FOUND", status: 404 },
  // Codegen (fmgen-Pipeline als Compute-Endpoint, kein Katalog-Write):
  // NOT_AVAILABLE = Skill/Referenz-DB fehlt in dieser Installation (degradierbar),
  // TIMEOUT = Subprozess-Limit, ERROR = Umgebungs-/Ausführungsfehler.
  CODEGEN_NOT_AVAILABLE: { code: "CODEGEN_NOT_AVAILABLE", status: 503 },
  CODEGEN_TIMEOUT: { code: "CODEGEN_TIMEOUT", status: 504 },
  CODEGEN_ERROR: { code: "CODEGEN_ERROR", status: 500 },
  // Graph-Trace (v1): Startobjekt-Typ ohne Trace-Semantik (nur Script/Layout) —
  // 422, nicht 404: das Objekt existiert, der Trace ist fuer den Typ (noch) nicht
  // definiert. EMPTY_ENTRY = gewaehltes Einstiegspfad-Preset liefert 0 Seed-Scripts;
  // details tragen die verfuegbaren Presets mit Zaehlern (statt leerem Graph).
  TRACE_UNSUPPORTED_START: { code: "TRACE_UNSUPPORTED_START", status: 422 },
  TRACE_EMPTY_ENTRY: { code: "TRACE_EMPTY_ENTRY", status: 422 },
};

/**
 * Reference-DB: unterstützte Sprachen pro Domain.
 * Steps haben 11 Sprachen (inkl. en + zh-Hans), Functions nur 9 (kein en, kein zh-Hans).
 * Für Functions in 'en' liefert der Service `canonical_name` als Display-Name.
 */
const REFERENCE_STEP_LANGUAGES = [
  "en",
  "de",
  "es",
  "fr",
  "it",
  "nl",
  "pt",
  "sv",
  "ja",
  "ko",
  "zh-Hans",
];
const REFERENCE_FUNCTION_LANGUAGES = [
  "en",
  "de",
  "es",
  "fr",
  "it",
  "nl",
  "pt",
  "sv",
  "ja",
  "ko",
];
const REFERENCE_CONTENT_LEVELS = ["meta", "summary", "full"];

/**
 * Mapping DB-Sprachcode ↔ Mirror-Verzeichnis-Code. Die DB nutzt 'zh-Hans', der
 * vom Skill `install-claris-docs` gepflegte Mirror verwendet 'zh' (URL-Segment
 * der Claris-Site).
 */
const REFERENCE_LANG_TO_MIRROR_DIR = { "zh-Hans": "zh" };

/**
 * Default Values
 */
const DEFAULTS = {
  FORMAT: OUTPUT_FORMATS.JSON,
  LIMIT: 100,
  MAX_LIMIT: 10000,
  DIRECTION: REFERENCE_DIRECTIONS.ALL,
  LINK_TYPE: LINK_TYPES.OPERATIONAL,
  RECURSIVE_MAX_DEPTH: 10,
};

/**
 * Mermaid Themes
 */
const MERMAID_THEMES = {
  DEFAULT: "default",
  DARK: "dark",
  FOREST: "forest",
  NEUTRAL: "neutral",
};

/**
 * Mermaid Graph Directions
 */
const MERMAID_DIRECTIONS = {
  TOP_DOWN: "TD",
  BOTTOM_UP: "BT",
  LEFT_RIGHT: "LR",
  RIGHT_LEFT: "RL",
};

/**
 * Detail Template Map
 * Maps Object_Type (PascalCase) to the SQL template name in templates/sql/
 * Used by /get-details endpoint to dispatch to type-specific detail views
 */
const DETAIL_TEMPLATE_MAP = {
  Script: "object_details_script",
  Layout: "object_details_layout",
  LayoutObject: "object_details_layoutobject",
  Field: "object_details_field",
  Relationship: "object_details_relationship",
  PrivilegeSet: "object_details_privilegeset",
  BaseTable: "object_details_basetable",
  CustomFunction: "object_details_customfunction",
  ValueList: "object_details_valuelist",
  Variable: "object_details_variable",
  Folder: "object_details_folder",
  ScriptFolder: "object_details_folder",
  LayoutFolder: "object_details_folder",
  BuiltinFunction: "object_details_builtinfunction",
  PluginFunction: "object_details_pluginfunction",
  ScriptStepType: "object_details_scriptsteptype",
  PluginComponent: "object_details_plugincomponent",
  CustomMenu: "object_details_custommenu",
  CustomMenuItem: "object_details_custommenuitem",
  Theme: "object_details_theme",
  Calculation: "object_details_calculation",
};

/**
 * HTTP Status Codes
 */
const HTTP_STATUS = {
  OK: 200,
  CREATED: 201,
  BAD_REQUEST: 400,
  NOT_FOUND: 404,
  INTERNAL_SERVER_ERROR: 500,
};

module.exports = {
  OBJECT_TYPES,
  OBJECT_TYPE_MAP,
  PSEUDO_TOKEN_TYPES,
  FOLDER_PSEUDO_TYPES,
  DETAIL_TEMPLATE_MAP,
  LINK_TYPES,
  REFERENCE_DIRECTIONS,
  OUTPUT_FORMATS,
  MERMAID_THEMES,
  MERMAID_DIRECTIONS,
  ERROR_CODES,
  DEFAULTS,
  HTTP_STATUS,
  REFERENCE_STEP_LANGUAGES,
  REFERENCE_FUNCTION_LANGUAGES,
  REFERENCE_CONTENT_LEVELS,
  REFERENCE_LANG_TO_MIRROR_DIR,
};
