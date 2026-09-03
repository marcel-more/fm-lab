const Joi = require('joi');
const { createError } = require('./error-handler');
const { OBJECT_TYPES, OUTPUT_FORMATS, REFERENCE_DIRECTIONS, LINK_TYPES, PSEUDO_TOKEN_TYPES } = require('../config/constants');
const environment = require('../config/environment');

/**
 * Request Validation Middleware using Joi
 */

/**
 * Validation schemas for different endpoints
 */
const schemas = {
  // GET /api/get
  get: Joi.object({
    uuid: Joi.string().required(),
    // Clone-Disambiguierung: optionaler File_Name. Bei geteilter UUID (Klon)
    // grenzt er auf die richtige Datei ein; ohne ihn gilt Graceful Downgrade
    // (eindeutig → ok, mehrdeutig → AMBIGUOUS_UUID).
    file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/list
  // Neue Pseudo-Token-Parameter:
  //   ?with_usage / ?with_category / ?category=A,B,C / ?sort=usage|name|category
  // (snake_case konsistent mit link_type/group_by; index.js normalisiert
  // Query-Keys automatisch zu lowercase, deshalb keine camelCase-Form möglich.)
  // Diese sind nur für Pseudo-Token-Typen + PluginComponent (nur Usage/Sort) sinnvoll;
  // bei anderen Typen werden sie ignoriert (kein Fehler).
  list: Joi.object({
    type: Joi.string().lowercase().valid(...OBJECT_TYPES.map(t => t.toLowerCase())).required(),
    file: Joi.string().optional(),
    limit: Joi.number().integer().min(0).max(environment.api.maxLimit).default(environment.api.defaultLimit),
    with_usage: Joi.boolean().default(false),
    with_category: Joi.boolean().default(false),
    // Komma-getrennte Liste; Joi-String, splitting im Service. URL-Beispiel:
    // ?category=Get%20Functions,Text%20Functions
    category: Joi.string().optional(),
    sort: Joi.string().lowercase().valid('usage', 'name', 'category').optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/list/categories - Filter-Pillen-Daten für einen Pseudo-Token-Typ.
  // Liefert { category, token_count, total_usage } pro Kategorie.
  // Nur für PSEUDO_TOKEN_TYPES gültig; PluginComponent → HTTP 400.
  listCategories: Joi.object({
    type: Joi.string()
      .lowercase()
      .valid(...PSEUDO_TOKEN_TYPES.map(t => t.toLowerCase()))
      .required(),
    file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/list-with-folders - Hierarchische Liste (Scripts/Layouts/CFs) mit nesting_level.
  // Kein limit: Tree muss komplett geliefert werden, sonst bricht die Folder-Stack-Konsistenz.
  listWithFolders: Joi.object({
    type: Joi.string()
      .lowercase()
      .valid('script', 'layout', 'customfunction')
      .required(),
    file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/count
  count: Joi.object({
    type: Joi.string().lowercase().valid(...OBJECT_TYPES.map(t => t.toLowerCase())).optional(),
    file: Joi.string().optional(),
    group_by: Joi.string().optional(), // e.g., "type,file"
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/search
  search: Joi.object({
    name: Joi.string().required(),
    type: Joi.string().lowercase().valid(...OBJECT_TYPES.map(t => t.toLowerCase())).optional(),
    file: Joi.string().optional(),
    limit: Joi.number().integer().min(0).max(environment.api.maxLimit).default(environment.api.defaultLimit),
    offset: Joi.number().integer().min(0).default(0),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/search/count
  searchCount: Joi.object({
    name: Joi.string().required(),
    type: Joi.string().lowercase().valid(...OBJECT_TYPES.map(t => t.toLowerCase())).optional(),
    file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/references
  references: Joi.object({
    uuid: Joi.string().required(),
    file: Joi.string().optional(), // Clone-Scoping der Fokus-Seite (s. get-Schema)
    origin: Joi.string().optional(), // Herkunfts-Script (?ref=) — markiert Origin_Hit bei Pseudo-Typen (ScriptStepType)
    direction: Joi.string().lowercase().valid(...Object.values(REFERENCE_DIRECTIONS)).default('all'),
    link_type: Joi.string().lowercase().valid(...Object.values(LINK_TYPES)).default('operational'),
    limit: Joi.number().integer().min(0).max(environment.api.maxLimit).default(environment.api.defaultLimit),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/back-references - Cross-Reference Highlight Lookup
  backReferences: Joi.object({
    destination: Joi.string().required(),
    origin: Joi.string().required(),
    dest_file: Joi.string().optional(),   // Clone-Disambiguierung der Destination-UUID
    origin_file: Joi.string().optional(), // Clone-Disambiguierung der Origin-UUID
    mode: Joi.string().lowercase().valid('uuid', 'name', 'auto').default('auto'),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/info
  info: Joi.object({
    file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
  }),

  // GET /api/get-details - Object type-specific detail view
  getDetails: Joi.object({
    uuid: Joi.string().required(),
    file: Joi.string().optional(), // Clone-Disambiguierung (s. get-Schema)
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
    // Optionale Token-Anreicherung mit Reference-DB pro Sprache
    enrich: Joi.string().optional(),
  }),

  // GET /api/get-calc - Standalone calculation (token format only).
  // Primärpfad seit Schema 1.22.0: ?uuid=<Calculation_UUID> (instanz-eindeutig,
  // CalculationsCatalog); ?hash= bleibt als Alias (hash-dedupliziert, bei
  // Mehrdeutigkeit best-effort-Pick + Instanzliste in meta).
  // GET /api/conditional-formatting - CF-Regeln eines Layout-Objekts
  // (LayoutObjectConditions + C3-CSS-Parser). Nur JSON — die Regel-Struktur
  // hat keine sinnvolle Flat-Format-Projektion.
  conditionalFormatting: Joi.object({
    uuid: Joi.string().required(),
    file: Joi.string().optional(), // Clone-Disambiguierung wie bei get/get-details
    format: Joi.string().lowercase().valid('json').default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  getCalc: Joi.object({
    uuid: Joi.string().optional(),
    hash: Joi.string().optional(),
    file: Joi.string().optional(), // Clone-Disambiguierung beim uuid-Pfad
    format: Joi.string().lowercase().valid('tokens', 'json').default('tokens'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
    // Optionale Calc-Token-Anreicherung über function_name_lookup
    enrich: Joi.string().optional(),
  }).or('uuid', 'hash'),

  // GET/POST /api/query - Execute custom SQL template
  query: Joi.object({
    template: Joi.string().required(),
    params: Joi.alternatives().try(
      Joi.object().unknown(true), // Object with any properties
      Joi.string() // JSON string (for GET requests)
    ).optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
    // Mermaid-specific parameters
    theme: Joi.string().valid('default', 'dark', 'forest', 'neutral').optional(),
    direction: Joi.string().valid('TD', 'LR', 'BT', 'RL').optional(),
    title: Joi.string().max(200).optional(),
  }).unknown(true), // Allow additional parameters for template variables

  // GET /api/relationship-graph/:fileName - Beziehungsdiagramm einer Datei
  relationshipGraph: Joi.object({
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/subgraph - Fokus-zentrierter k-Hop-Subgraph (Graph Explorer)
  // types/roles sind optionale Komma-Listen (CSV); Split + NULL-Handling im SQL.
  graphSubgraph: Joi.object({
    focus: Joi.string().required(),
    focus_file: Joi.string().optional(), // Clone-Disambiguierung des Fokus-Knotens
    depth: Joi.number().integer().min(1).max(environment.duckdb.graphMaxDepth).default(1),
    direction: Joi.string().lowercase().valid('out', 'in', 'both').default('both'),
    mode: Joi.string().lowercase().valid('logical', 'raw').default('logical'),
    types: Joi.string().optional(),
    roles: Joi.string().optional(),
    include_builtins: Joi.boolean().default(false),
    node_limit: Joi.number().integer().min(1).max(environment.api.maxLimit).default(1000),
    hub_degree: Joi.number().integer().min(1).default(100),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/neighbors - 1-Hop-Expansion (Lazy-Expand). Wie subgraph, ohne depth.
  graphNeighbors: Joi.object({
    focus: Joi.string().required(),
    focus_file: Joi.string().optional(), // Clone-Disambiguierung des Fokus-Knotens
    direction: Joi.string().lowercase().valid('out', 'in', 'both').default('both'),
    mode: Joi.string().lowercase().valid('logical', 'raw').default('logical'),
    types: Joi.string().optional(),
    roles: Joi.string().optional(),
    include_builtins: Joi.boolean().default(false),
    node_limit: Joi.number().integer().min(1).max(environment.api.maxLimit).default(1000),
    hub_degree: Joi.number().integer().min(1).default(100),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/depth-profile - Max. erreichbare Tiefe (Exzentrizität) + per-Tiefe-Count.
  // Richtungsabhängig (out|in|both); leichtgewichtig (nur Walk-Aggregat, keine Projektion).
  graphDepthProfile: Joi.object({
    focus: Joi.string().required(),
    focus_file: Joi.string().optional(), // Clone-Disambiguierung des Fokus-Knotens
    direction: Joi.string().lowercase().valid('out', 'in', 'both').default('both'),
    mode: Joi.string().lowercase().valid('logical', 'raw').default('logical'),
    // Typ-Filter (CSV) — spiegelt graphSubgraph, damit die Last-/Clipping-Anzeige des
    // Reglers dieselbe (typgefilterte) erreichbare Menge zählt wie der Subgraph.
    types: Joi.string().optional(),
    include_builtins: Joi.boolean().default(false),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/trace - Selektiver Ablauf-Graph (Trace-Modus des Explorers).
  // Budgets getrennt nach Richtung (up/down) + Trigger-Kaskade (trigger_depth);
  // Schalter sind bewusst Opt-in. ACHTUNG: der Trace-Cache-Key wird
  // in graph.service.js AUS DIESEM SCHEMA generiert — jeder neue fachliche
  // Parameter wandert automatisch in den Key (format/meta/debug ausgenommen).
  graphTrace: Joi.object({
    start: Joi.string().required(),
    start_file: Joi.string().optional(), // Clone-Disambiguierung des Startobjekts
    entry: Joi.string().lowercase()
      .valid('script', 'layout_runtime', 'layout_inbound', 'layout_full')
      .optional(), // Einstiegspfad-Preset (nur Nicht-Script-Starts; Default typabhängig)
    up_depth: Joi.number().integer().min(0).max(environment.duckdb.graphMaxDepth).default(3),
    down_depth: Joi.number().integer().min(0).max(environment.duckdb.graphMaxDepth).default(6),
    trigger_depth: Joi.number().integer().min(0).max(3).default(1),
    expand_up: Joi.boolean().default(false),
    include_local_vars: Joi.boolean().default(false),
    include_buttons: Joi.boolean().default(false),
    include_builtins: Joi.boolean().default(false),
    // Interaktions-Events (Keystroke/GestureTap/ObjectModify/
    // ExternalCommand) zünden per Default keine Kaskade — sie feuern während
    // eines Script-Ablaufs nicht. TRUE nimmt sie wieder hinein.
    include_interaction_triggers: Joi.boolean().default(false),
    node_limit: Joi.number().integer().min(1).max(environment.api.maxLimit).default(1000),
    hub_degree: Joi.number().integer().min(1).default(100),
    // Boundary-Ausschlussliste — kommaseparierte Composite-IDs
    // `uuid::file` (File-Teil optional; UUID-Teil 8-64 Hex-/Bindestrich-Zeichen,
    // deckt Katalog-UUIDs und md5-basierte Variablen-UUIDs). Ausgeschlossene
    // Knoten bleiben als Boundary sichtbar, werden aber nicht expandiert und
    // zünden keine Kaskade. Dateinamen mit Komma sind nicht adressierbar (v1).
    exclude: Joi.string().max(4096)
      .pattern(/^[0-9A-Fa-f][0-9A-Fa-f-]{7,63}(::[^,]+)?(,[0-9A-Fa-f][0-9A-Fa-f-]{7,63}(::[^,]+)?)*$/)
      .optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/trace/entries - Einstiegspfad-Vorschau (Presets + Seed-Zähler)
  graphTraceEntries: Joi.object({
    start: Joi.string().required(),
    start_file: Joi.string().optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/overview - Graph-Atlas Top-Down-Einstieg (Treemap + Meta-Graph)
  // Achse A (segment_by) × Achse B (view). level steuert den Treemap-Trichter.
  // parent_* = Drill-Kontext (Ebene 1/2). Schema-kanonisch composite (uuid::file).
  graphOverview: Joi.object({
    view: Joi.string().lowercase().valid('composition', 'topology').default('composition'),
    level: Joi.string().lowercase().valid('root', 'segment', 'leaf').default('root'),
    segment_by: Joi.string().lowercase().valid('community', 'file', 'type', 'hubs').default('community'),
    parent_community: Joi.number().integer().optional(),
    parent_file: Joi.string().optional(),
    parent_type: Joi.string().optional(),
    weight: Joi.string().lowercase().valid('domain', 'logical').default('domain'),
    include_builtins: Joi.boolean().default(false),
    // Objekttyp-Filterleiste (Exclusion-Semantik wie die Explorer-Type-Chips):
    // CSV der auszublendenden Object_Type. Greift VOR der Aggregation → ändert
    // Segment-Gewichte/-Counts und blendet Blätter aus.
    exclude_types: Joi.string().optional(),
    // Top-K/„Rest"-Faltung der Aggregat-Ebenen abschalten (Rest-Kachel „auffalten"):
    // false → alle Segmente, keine Rest-Kachel.
    fold: Joi.boolean().default(true),
    limit: Joi.number().integer().min(1).max(environment.api.maxLimit).default(50),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // POST /api/codegen/lint — Script-Entwurf parsen + linten (Editor-Diagnostics).
  // Body-Validierung; text = Script-Textform (fmgen-Notation).
  codegenLint: Joi.object({
    text: Joi.string().min(1).max(500000).required(),
  }),

  // POST /api/codegen/compile — volle fmgen-Pipeline (parse→resolve→emit→gate).
  // file = FM-Zieldatei im Katalog (Referenz-Auflösung ist datei-skopiert).
  codegenCompile: Joi.object({
    text: Joi.string().min(1).max(500000).required(),
    file: Joi.string().min(1).required(),
  }),

  // POST /api/codegen/decompile — fmxmlsnippet-XML → kanonische Textform.
  // file optional (nur für die Layout→TO-Anreicherung aus dem Katalog).
  codegenDecompile: Joi.object({
    xml: Joi.string().min(1).max(2000000).required(),
    file: Joi.string().min(1).optional(),
  }),

  // PUT /api/annotations/community - Community-Name/Notiz (User-Annotation)
  // Body-Validierung. Leere Strings sind erlaubt (= Feld löschen); der Service
  // normalisiert sie zu NULL. engine+community identifizieren die Community in der
  // aktiven Partition (Live-Overlay-Key).
  annotationCommunity: Joi.object({
    engine: Joi.string().min(1).required(),
    community: Joi.number().integer().required(),
    user_name: Joi.string().allow('', null).max(200).optional(),
    user_notes: Joi.string().allow('', null).max(4000).optional(),
  }),

  // PUT /api/annotations/node/visibility - Node als sichtbar/ausgeblendet markieren
  annotationNodeVisibility: Joi.object({
    uuid: Joi.string().min(1).required(),
    file: Joi.string().allow('', null).optional(),
    visible: Joi.boolean().required(),
  }),

  // GET /api/graph/community-stats - Community-Namen-Status + Cluster-Verfügbarkeit
  // (keine fachlichen Params; nur die Standard-Ausgabesteuerung).
  graphCommunityStats: Joi.object({
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET /api/graph/search - Fokus-Autocomplete über ObjectCatalog
  graphSearch: Joi.object({
    q: Joi.string().min(1).required(),
    type: Joi.string().optional(),
    file: Joi.string().optional(),
    limit: Joi.number().integer().min(1).max(100).default(20),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('json'),
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
  }),

  // GET/POST /api/report - Execute report template
  report: Joi.object({
    template: Joi.string().required(),
    params: Joi.alternatives().try(
      Joi.object().unknown(true), // Object with any properties
      Joi.string() // JSON string (for GET requests)
    ).optional(),
    format: Joi.string().lowercase().valid(...Object.values(OUTPUT_FORMATS)).default('html'), // Default to HTML for reports
    meta: Joi.boolean().default(false),
    debug: Joi.boolean().default(false),
    // Mermaid-specific parameters
    theme: Joi.string().valid('default', 'dark', 'forest', 'neutral').optional(),
    direction: Joi.string().valid('TD', 'LR', 'BT', 'RL').optional(),
    title: Joi.string().max(200).optional(),
  }).unknown(true), // Allow additional parameters for template variables
};

/**
 * Validate request query parameters or body
 * @param {string} schemaName - Name of the schema to use
 * @param {string} source - 'query' or 'body' or 'both' (default: 'query')
 * @returns {Function} Express middleware
 */
function validate(schemaName, source = 'query') {
  return (req, res, next) => {
    const schema = schemas[schemaName];

    if (!schema) {
      return next(createError('INTERNAL_ERROR', `Unknown validation schema: ${schemaName}`));
    }

    // Determine what to validate
    let dataToValidate;
    if (source === 'both') {
      // Merge query and body (body takes precedence)
      dataToValidate = { ...req.query, ...req.body };
    } else if (source === 'body') {
      dataToValidate = req.body;
    } else {
      dataToValidate = req.query;
    }

    const { error, value } = schema.validate(dataToValidate, {
      abortEarly: false,
      stripUnknown: true,
      presence: 'optional', // Allow defaults to be applied for missing fields
      convert: true, // Enable type coercion and transformations (like .lowercase())
    });

    if (error) {
      const details = error.details.map((detail) => ({
        field: detail.path.join('.'),
        message: detail.message,
      }));

      return next(createError('VALIDATION_ERROR', 'Request validation failed', { errors: details }));
    }

    // Replace query or body with validated and defaulted values
    if (source === 'both' || source === 'query') {
      Object.defineProperty(req, 'query', {
        value: value,
        writable: true,
        enumerable: true,
        configurable: true
      });
    }
    if (source === 'both' || source === 'body') {
      Object.defineProperty(req, 'body', {
        value: value,
        writable: true,
        enumerable: true,
        configurable: true
      });
    }
    next();
  };
}

module.exports = {
  validate,
  schemas,
};
