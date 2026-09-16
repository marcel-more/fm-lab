const { LRUCache } = require('lru-cache');
const db = require('../config/database');
const environment = require('../config/environment');
const {
  REFERENCE_STEP_LANGUAGES,
  REFERENCE_FUNCTION_LANGUAGES,
  REFERENCE_LANG_TO_MIRROR_DIR,
} = require('../config/constants');

/**
 * Reference-Service
 *
 * Kapselt alle Zugriffe auf die per ATTACH eingebundene fm_spec.duckdb
 * (Alias `ref`). Bietet:
 *   - Sprach-Validierung pro Domain (Steps: 11, Functions: 9)
 *   - Bulk-Lookups (Steps/Functions/Categories) mit Pro-Sprache-LRU-Cache
 *   - Einzel-Lookups (Step/Function-Detail inkl. Parameter)
 *   - Universal-Lookup (Token → Step/Function via Reverse-Lookup-Tabellen)
 *   - DDR-Token-Anreicherung für Script-Step- und Funktions-Tokens
 *
 * HTML-Cache und Manifest-Status liegen im `help.service.js`.
 */

const metaCache = new LRUCache({
  max: 1000,
  ttl: environment.reference.cacheTtlMs,
});

// Vorgeladene Step-Map pro Sprache: stepMetaByLang.get('de').get(141) → {…}
const stepMetaByLang = new Map();

function clearCaches() {
  metaCache.clear();
  stepMetaByLang.clear();
  refTableExistsCache.clear();
  refColumnExistsCache.clear();
  stepCompatMapCache = null;
  functionAffinityMapCache = null;
  scriptTriggerEventMapCache = null;
  scriptTriggerEventLabelsCache.clear();
  triggerCompatMapCache = null;
}

function isStepLang(lang) {
  return REFERENCE_STEP_LANGUAGES.includes(lang);
}

function isFunctionLang(lang) {
  return REFERENCE_FUNCTION_LANGUAGES.includes(lang);
}

/**
 * Normalisiert eine (evtl. regions-qualifizierte) Locale-Kennung auf einen der
 * unterstützten Domänen-Codes und fällt sonst sanft auf die Default-Sprache
 * zurück — statt hart zu werfen.
 *
 * Auflösungsreihenfolge:
 *   1. Exakt-Treffer (case-insensitiv) → kanonische Schreibweise aus `valid`
 *   2. Regions-Tag (en-US, de-DE, pt-BR, zh-Hant, …) → Match auf dem Primär-Subtag
 *   3. sonst Default (`en`)
 *
 * Beispiele: en-US → en · de_DE → de · zh-CN → zh-Hans (Steps) · xx → en
 */
function normalizeRefLang(lang, valid) {
  const raw = String(lang || environment.reference.defaultLang).trim();
  const lower = raw.toLowerCase();

  const exact = valid.find((c) => c.toLowerCase() === lower);
  if (exact) return exact;

  const primary = lower.split(/[-_]/)[0];
  const byPrimary = valid.find((c) => c.toLowerCase().split('-')[0] === primary);
  if (byPrimary) return byPrimary;

  return environment.reference.defaultLang;
}

function resolveStepLang(lang) {
  return normalizeRefLang(lang, REFERENCE_STEP_LANGUAGES);
}

function resolveFunctionLang(lang) {
  return normalizeRefLang(lang, REFERENCE_FUNCTION_LANGUAGES);
}

function assertAttached() {
  if (!db.isReferenceAttached()) {
    const err = new Error('Reference-DB not attached. Set REFERENCE_DUCKDB_PATH or copy fm_spec.duckdb into reference/.');
    err.code = 'REF_NOT_ATTACHED';
    throw err;
  }
}

/**
 * BigInt → Number normalisieren (für JSON-Serialisierung).
 */
function normalizeRow(row) {
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    out[k] = typeof v === 'bigint' ? Number(v) : v;
  }
  return out;
}

function mirrorLangDir(lang) {
  return REFERENCE_LANG_TO_MIRROR_DIR[lang] || lang;
}

/**
 * Prüft, ob eine Tabelle im attachten `ref`-Katalog existiert. Wird genutzt,
 * um die generativen Tabellen (Referenz ≥ 1.2.0) gegen ältere Referenzen
 * abzusichern (Konsumenten-Schutz). Ergebnis wird pro Prozess
 * gecacht (Schema ändert sich nicht zur Laufzeit).
 */
const refTableExistsCache = new Map();
async function refTableExists(ctx, name) {
  if (refTableExistsCache.has(name)) return refTableExistsCache.get(name);
  const r = await db.executeQuery(ctx,
    `SELECT 1 FROM information_schema.tables
     WHERE table_catalog = 'ref' AND table_name = ? LIMIT 1`,
    [String(name)]
  );
  const exists = r.rows.length > 0;
  refTableExistsCache.set(name, exists);
  return exists;
}

/**
 * Prüft, ob eine Spalte im attachten `ref`-Katalog existiert — gleiche
 * Absicherung wie refTableExists, für spaltenweise Schema-Erweiterungen
 * (z. B. script_steps.xml_name seit Referenz 1.10.0).
 */
const refColumnExistsCache = new Map();
async function refColumnExists(ctx, table, column) {
  const key = `${table}.${column}`;
  if (refColumnExistsCache.has(key)) return refColumnExistsCache.get(key);
  const r = await db.executeQuery(ctx,
    `SELECT 1 FROM information_schema.columns
     WHERE table_catalog = 'ref' AND table_name = ? AND column_name = ? LIMIT 1`,
    [String(table), String(column)]
  );
  const exists = r.rows.length > 0;
  refColumnExistsCache.set(key, exists);
  return exists;
}

/**
 * Namensvertrag (Referenz ≥ 1.10.0): Aliase pro Step aus dem Reverse-Lookup —
 * `xml_emission` (Namen, wie FileMaker sie im XML tatsächlich emittiert,
 * inkl. beobachteter Sprachvarianten) und `legacy` (Alt-Namen von
 * Rename-Fällen, z. B. Get Directory → 181). Sprachneutral, ein Query,
 * gecacht; ältere Referenzen ohne diese match_sources liefern leere Listen.
 * Lookup-Zeilen auf Legacy-IDs (außerhalb script_steps) bleiben im Map-Bau
 * harmlos — kein Step der Liste trägt ihre step_id.
 */
async function getStepAliasMap(ctx) {
  const cacheKey = 'steps-alias-map';
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);
  const r = await db.executeQuery(ctx, `
    SELECT step_id, lookup_name, match_source
    FROM ref.script_step_name_lookup
    WHERE match_source IN ('xml_emission', 'legacy')
    ORDER BY match_source, lookup_name
  `);
  const map = new Map();
  for (const row of r.rows) {
    const id = Number(row.step_id);
    if (!map.has(id)) map.set(id, []);
    map.get(id).push({ name: row.lookup_name, source: row.match_source });
  }
  metaCache.set(cacheKey, map);
  return map;
}

/**
 * ============================================================================
 * Kategorien
 * ============================================================================
 */

async function getStepCategories(ctx, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  const cacheKey = `step-cat:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);

  const r = await db.executeQuery(ctx, `
    SELECT c.category_id, c.url_slug, cl.name, cl.url
    FROM ref.script_steps_categories c
    JOIN ref.script_steps_categories_lang cl USING (category_id)
    WHERE cl.language = ?
    ORDER BY c.category_id
  `, [language]);

  const data = r.rows.map((row) => ({
    id: Number(row.category_id),
    slug: row.url_slug,
    name: row.name,
    url: row.url,
  }));
  metaCache.set(cacheKey, data);
  return data;
}

async function getFunctionCategories(ctx, lang) {
  assertAttached();
  const language = resolveFunctionLang(lang);
  const cacheKey = `fn-cat:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);

  const r = await db.executeQuery(ctx, `
    SELECT c.category_id, c.url_slug, cl.name, cl.url
    FROM ref.function_categories c
    JOIN ref.function_categories_lang cl USING (category_id)
    WHERE cl.language = ?
    ORDER BY c.category_id
  `, [language]);

  const data = r.rows.map((row) => ({
    id: Number(row.category_id),
    slug: row.url_slug,
    name: row.name,
    url: row.url,
  }));
  metaCache.set(cacheKey, data);
  return data;
}

/**
 * ============================================================================
 * Steps — Bulk + Detail
 * ============================================================================
 */

/**
 * Step-Kompatibilitätsmap (stepId → 7 tri-state Flags) aus `step_compat`.
 * Tri-State-Semantik der Claris-Quelle: true = Yes, false = No,
 * **NULL = Partial (bedingt unterstützt)** — nie "undokumentiert". Sprach-
 * neutral, ein Query, prozessweit gecacht; ältere Referenzen ohne Tabelle
 * liefern eine leere Map (Konsumenten degradieren auf "keine Angabe").
 */
const STEP_COMPAT_PLATFORMS = ['pro', 'server', 'go', 'webdirect', 'cloud', 'dataapi', 'cwp'];
let stepCompatMapCache = null;
async function getStepCompatMap(ctx) {
  if (stepCompatMapCache) return stepCompatMapCache;
  const map = new Map();
  if (await refTableExists(ctx, 'step_compat')) {
    const r = await db.executeQuery(ctx, `
      SELECT step_id, pro, server, go, webdirect, cloud, dataapi, cwp
      FROM ref.step_compat
    `);
    for (const row of r.rows) {
      const compat = {};
      for (const p of STEP_COMPAT_PLATFORMS) {
        compat[p] = row[p] === null || row[p] === undefined ? null : Boolean(row[p]);
      }
      map.set(Number(row.step_id), compat);
    }
  }
  stepCompatMapCache = map;
  return map;
}

/**
 * OS-Affinität (Referenz ≥ 1.13.0): kuratierte, spärliche OS-Aussagen aus der
 * Claris-Hilfe-Prosa — Vokabular strikt macos|windows|linux|ios ('ios' = das
 * Betriebssystem, hostet Go UND iOS-SDK; nie ein Runtime-Begriff). Klassen:
 * exclusive / unsupported (quellentreu invers) / variant / os_probe (nur
 * Funktionen; Guard-Idiom, os=null). Leere Liste bei älteren Referenzen.
 */
async function getOsAffinity(ctx, table, idColumn, id) {
  if (!(await refTableExists(ctx, table))) return [];
  const r = await db.executeQuery(ctx, `
    SELECT os, affinity, provenance, note
    FROM ref.${table}
    WHERE ${idColumn} = ?
    ORDER BY affinity, os NULLS LAST
  `, [id]);
  return r.rows.map((a) => ({
    os:         a.os || null,
    affinity:   a.affinity,
    provenance: a.provenance,
    note:       a.note || null,
  }));
}

/**
 * Slot→Event-Map (trigger_id → event_name) aus `script_triggers`
 * (Referenz ≥ 1.18.0) — die kuratierte, locale-feste Auflösung der SaXML-
 * ScriptTrigger-Slot-IDs auf kanonische Event-Namen (der Action-Name im
 * Quell-XML ist ein lokalisierbarer Passthrough und taugt nicht als Quelle).
 * Sprachneutral, ein Query, prozessweit gecacht. Graceful: ohne attachte
 * Referenz-DB oder bei älterem Stand liefert sie eine leere Map — Konsumenten
 * lassen das Event-Feld dann einfach weg, kein Fehlerpfad.
 */
let scriptTriggerEventMapCache = null;
async function getScriptTriggerEventMap(ctx) {
  if (scriptTriggerEventMapCache) return scriptTriggerEventMapCache;
  const map = new Map();
  if (db.isReferenceAttached() && (await refTableExists(ctx, 'script_triggers'))) {
    const r = await db.executeQuery(ctx, `
      SELECT trigger_id, event_name FROM ref.script_triggers
    `);
    for (const row of r.rows) map.set(Number(row.trigger_id), row.event_name);
  }
  scriptTriggerEventMapCache = map;
  return map;
}

/**
 * Lokalisierte Event-Beschriftungen (event_name → event_label) aus
 * `script_triggers` × `script_triggers_lang` (Referenz ≥ 1.18.0) für EINE
 * Sprache — die Anzeige-Namen des FileMaker-Trigger-Dialogs (z.B.
 * OnRecordLoad → „BeiDatensatzLaden"). Sprach-Normalisierung über die
 * Step-Domäne (identisches 11-Sprachen-Set). Pro Sprache gecacht; graceful:
 * ohne attachte Referenz-DB oder älteren Stand ein leeres Objekt — die
 * Konsumenten fallen dann auf den kanonischen Namen zurück.
 */
const scriptTriggerEventLabelsCache = new Map();
async function getScriptTriggerEventLabels(ctx, lang) {
  const refLang = resolveStepLang(lang);
  if (scriptTriggerEventLabelsCache.has(refLang)) {
    return { lang: refLang, labels: scriptTriggerEventLabelsCache.get(refLang) };
  }
  const labels = {};
  if (db.isReferenceAttached()
      && (await refTableExists(ctx, 'script_triggers'))
      && (await refTableExists(ctx, 'script_triggers_lang'))) {
    const r = await db.executeQuery(ctx, `
      SELECT s.event_name, l.event_label
      FROM ref.script_triggers s
      JOIN ref.script_triggers_lang l USING (trigger_id)
      WHERE l.language = '${refLang}'
    `);
    for (const row of r.rows) {
      if (row.event_label) labels[row.event_name] = row.event_label;
    }
  }
  scriptTriggerEventLabelsCache.set(refLang, labels);
  return { lang: refLang, labels };
}

/**
 * Funktions-Affinitätsmap (functionId → [{platform, affinity}]) aus
 * `function_platform_affinity` (Referenz ≥ 1.12.0) — Bindung, nie
 * Kompatibilität. Leere Map bei älteren Referenzen.
 */
let functionAffinityMapCache = null;
async function getFunctionAffinityMap(ctx) {
  if (functionAffinityMapCache) return functionAffinityMapCache;
  const map = new Map();
  if (await refTableExists(ctx, 'function_platform_affinity')) {
    const r = await db.executeQuery(ctx, `
      SELECT function_id, platform, affinity
      FROM ref.function_platform_affinity
      ORDER BY function_id, platform
    `);
    for (const row of r.rows) {
      const id = Number(row.function_id);
      if (!map.has(id)) map.set(id, []);
      map.get(id).push({ platform: row.platform, affinity: row.affinity });
    }
  }
  functionAffinityMapCache = map;
  return map;
}

async function listSteps(ctx, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  const cacheKey = `steps-list:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);

  // hasGrammar: EXISTS-Prüfung auf step_xml_map — nur wenn die generative
  // Tabelle vorhanden ist (Referenz ≥ 1.2.0). Bei älterer Referenz degradiert
  // das Feld auf `false`, ohne die Liste zu brechen.
  const grammarTable = await refTableExists(ctx, 'step_xml_map');
  const grammarSelect = grammarTable
    ? `EXISTS (SELECT 1 FROM ref.step_xml_map m WHERE m.step_id = s.step_id)`
    : `FALSE`;

  // xmlName: EN-Emissions-Name (Referenz ≥ 1.10.0); NULL = keine Evidenz.
  const xmlNameSelect = (await refColumnExists(ctx, 'script_steps', 'xml_name'))
    ? `s.xml_name` : `NULL AS xml_name`;

  const r = await db.executeQuery(ctx, `
    SELECT s.step_id, s.url_slug, s.canonical_name, s.category_id,
           s.origin_version,
           ${grammarSelect} AS has_grammar,
           ${xmlNameSelect},
           sl.display_name, sl.description, sl.url
    FROM ref.script_steps s
    LEFT JOIN ref.script_steps_lang sl
      ON sl.step_id = s.step_id AND sl.language = ?
    ORDER BY s.step_id
  `, [language]);

  const aliasMap = await getStepAliasMap(ctx);
  const compatMap = await getStepCompatMap(ctx);

  const steps = r.rows.map((row) => ({
    stepId:      Number(row.step_id),
    name:        row.canonical_name,
    urlSlug:     row.url_slug,
    displayName: row.display_name || row.canonical_name,
    description: row.description,
    categoryId:  Number(row.category_id),
    originVersion: row.origin_version || null,
    hasGrammar:  Boolean(row.has_grammar),
    xmlName:     row.xml_name || null,
    aliases:     aliasMap.get(Number(row.step_id)) || [],
    compat:      compatMap.get(Number(row.step_id)) || null,
    helpUrl:     row.url,
    localHelpUrl: buildLocalHelpUrl('steps', language, row.url_slug),
  }));
  metaCache.set(cacheKey, steps);
  return steps;
}

/**
 * Vorgeladene Step-Map (stepId → meta) für eine Sprache. Wird vom
 * Token-Anreicherer in get-details verwendet, um nicht pro Line eine
 * DB-Query zu fahren.
 */
async function getStepMetaMap(ctx, lang) {
  const language = resolveStepLang(lang);
  if (stepMetaByLang.has(language)) return stepMetaByLang.get(language);
  const steps = await listSteps(ctx, language);
  const map = new Map(steps.map((s) => [s.stepId, s]));
  stepMetaByLang.set(language, map);
  return map;
}

async function findStepBySlugOrId(ctx, idOrSlug) {
  assertAttached();
  const xmlNameSelect = (await refColumnExists(ctx, 'script_steps', 'xml_name'))
    ? `xml_name` : `NULL AS xml_name`;
  const isNumeric = /^\d+$/.test(String(idOrSlug));
  let row;
  if (isNumeric) {
    const r = await db.executeQuery(ctx,
      `SELECT step_id, url_slug, canonical_name, category_id, origin_version, ${xmlNameSelect} FROM ref.script_steps WHERE step_id = ?`,
      [parseInt(idOrSlug, 10)]
    );
    row = r.rows[0];
  } else {
    const r = await db.executeQuery(ctx,
      `SELECT step_id, url_slug, canonical_name, category_id, origin_version, ${xmlNameSelect} FROM ref.script_steps WHERE url_slug = ? OR canonical_name = ?`,
      [String(idOrSlug), String(idOrSlug)]
    );
    row = r.rows[0];
  }
  return row ? normalizeRow(row) : null;
}

async function getStepDetail(ctx, idOrSlug, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  const base = await findStepBySlugOrId(ctx, idOrSlug);
  if (!base) return null;

  const r = await db.executeQuery(ctx, `
    SELECT sl.display_name, sl.description, sl.parameter, sl.url
    FROM ref.script_steps_lang sl
    WHERE sl.step_id = ? AND sl.language = ?
  `, [base.step_id, language]);
  const lang_row = r.rows[0] || {};

  const catRows = await db.executeQuery(ctx, `
    SELECT c.category_id, c.url_slug, c.category_name_en,
           cl.name AS lang_name
    FROM ref.script_steps_categories c
    LEFT JOIN ref.script_steps_categories_lang cl
      ON cl.category_id = c.category_id AND cl.language = ?
    WHERE c.category_id = ?
  `, [language, base.category_id]);
  const catRow = catRows.rows[0] || {};

  const paramsRes = await db.executeQuery(ctx, `
    SELECT param_index, name, description
    FROM ref.script_step_parameters_lang
    WHERE step_id = ? AND language = ?
    ORDER BY param_index
  `, [base.step_id, language]);

  const parameters = paramsRes.rows.map((p) => ({
    index: Number(p.param_index),
    name: p.name,
    description: p.description,
  }));

  const aliasMap = await getStepAliasMap(ctx);
  const compatMap = await getStepCompatMap(ctx);
  const osAffinity = await getOsAffinity(ctx, 'step_os_affinity', 'step_id', base.step_id);

  return {
    stepId:      base.step_id,
    name:        base.canonical_name,
    urlSlug:     base.url_slug,
    canonicalName: base.canonical_name,
    xmlName:     base.xml_name || null,
    aliases:     aliasMap.get(Number(base.step_id)) || [],
    compat:      compatMap.get(Number(base.step_id)) || null,
    osAffinity,
    displayName: lang_row.display_name || base.canonical_name,
    description: lang_row.description || null,
    parameterText: lang_row.parameter || null,
    parameters,
    categoryId:  base.category_id,
    category: catRow.category_id != null ? {
      id:     Number(catRow.category_id),
      slug:   catRow.url_slug,
      nameEn: catRow.category_name_en,
      name:   catRow.lang_name || catRow.category_name_en,
    } : null,
    helpUrl:      lang_row.url || null,
    localHelpUrl: buildLocalHelpUrl('steps', language, base.url_slug),
    docsEntry:    buildDocsEntryRef('step', base.category_id, base.step_id, base.url_slug),
  };
}

/**
 * ============================================================================
 * Functions — Bulk + Detail
 * ============================================================================
 */

async function listFunctions(ctx, lang) {
  assertAttached();
  const language = resolveFunctionLang(lang);
  const cacheKey = `functions-list:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);

  // retirement column (fm_spec >= 2.2.0); NULL on older builds
  const removedSel = (await refColumnExists(ctx, 'functions', 'removed_in_version'))
    ? 'f.removed_in_version' : 'NULL AS removed_in_version';
  const r = await db.executeQuery(ctx, `
    SELECT f.function_id, f.opcode, f.canonical_name, f.return_type,
           f.origin_version, ${removedSel}, f.is_get_function, f.url_slug, f.category_id,
           fl.display_name, fl.signature, fl.purpose, fl.url
    FROM ref.functions f
    LEFT JOIN ref.functions_lang fl
      ON fl.function_id = f.function_id AND fl.language = ?
    ORDER BY f.function_id
  `, [language]);

  const affinityMap = await getFunctionAffinityMap(ctx);

  const fns = r.rows.map((row) => ({
    functionId:    Number(row.function_id),
    name:          row.canonical_name,
    opcode:        row.opcode,
    returnType:    row.return_type,
    originVersion: row.origin_version,
    removedInVersion: row.removed_in_version ?? null,
    isGetFunction: Number(row.is_get_function) === 1,
    urlSlug:       row.url_slug,
    displayName:   row.display_name || row.canonical_name,
    signature:     row.signature,
    purpose:       row.purpose,
    categoryId:    Number(row.category_id),
    platformAffinity: affinityMap.get(Number(row.function_id)) || [],
    helpUrl:       row.url,
    localHelpUrl:  buildLocalHelpUrl('functions', language, row.url_slug),
  }));
  metaCache.set(cacheKey, fns);
  return fns;
}

async function findFunctionByNameOrId(ctx, nameOrId) {
  assertAttached();
  const isNumeric = /^\d+$/.test(String(nameOrId));
  const removedSel = (await refColumnExists(ctx, 'functions', 'removed_in_version'))
    ? 'removed_in_version' : 'NULL AS removed_in_version';
  let row;
  if (isNumeric) {
    const r = await db.executeQuery(ctx,
      `SELECT function_id, canonical_name, opcode, category_id, return_type, origin_version, ${removedSel}, is_get_function, url_slug
       FROM ref.functions WHERE function_id = ?`,
      [parseInt(nameOrId, 10)]
    );
    row = r.rows[0];
  } else {
    const r = await db.executeQuery(ctx,
      `SELECT function_id, canonical_name, opcode, category_id, return_type, origin_version, ${removedSel}, is_get_function, url_slug
       FROM ref.functions
       WHERE canonical_name = ? OR url_slug = ?`,
      [String(nameOrId), String(nameOrId)]
    );
    row = r.rows[0];
  }
  return row ? normalizeRow(row) : null;
}

async function getFunctionDetail(ctx, nameOrId, lang) {
  assertAttached();
  const language = resolveFunctionLang(lang);
  const base = await findFunctionByNameOrId(ctx, nameOrId);
  if (!base) return null;

  const r = await db.executeQuery(ctx, `
    SELECT display_name, signature, description, purpose, notes,
           example_1, return_type_display, url
    FROM ref.functions_lang
    WHERE function_id = ? AND language = ?
  `, [base.function_id, language]);
  const lang_row = r.rows[0] || {};

  const catRes = await db.executeQuery(ctx, `
    SELECT c.category_id, c.url_slug, c.category_name,
           cl.name AS lang_name
    FROM ref.function_categories c
    LEFT JOIN ref.function_categories_lang cl
      ON cl.category_id = c.category_id AND cl.language = ?
    WHERE c.category_id = ?
  `, [language, base.category_id]);
  const catRow = catRes.rows[0] || {};

  const paramsRes = await db.executeQuery(ctx, `
    SELECT p.position, p.is_optional, p.is_variadic, pl.name, pl.description
    FROM ref.function_parameters p
    LEFT JOIN ref.function_parameters_lang pl
      ON pl.function_id = p.function_id AND pl.position = p.position AND pl.language = ?
    WHERE p.function_id = ?
    ORDER BY p.position
  `, [language, base.function_id]);

  const parameters = paramsRes.rows.map((p) => ({
    position:    Number(p.position),
    name:        p.name,
    description: p.description,
    optional:    Number(p.is_optional) === 1,
    variadic:    Number(p.is_variadic) === 1,
  }));

  // Curated platform binding (reference ≥ 1.12.0) — AFFINITY, not
  // compatibility: "meaningful results only on X", never "does not run on X"
  // (Claris publishes no function compatibility table). Older references
  // yield an empty list.
  let platformAffinity = [];
  if (await refTableExists(ctx, 'function_platform_affinity')) {
    const affRes = await db.executeQuery(ctx, `
      SELECT platform, affinity, provenance, note
      FROM ref.function_platform_affinity
      WHERE function_id = ?
      ORDER BY platform
    `, [base.function_id]);
    platformAffinity = affRes.rows.map((a) => ({
      platform:   a.platform,
      affinity:   a.affinity,
      provenance: a.provenance,
      note:       a.note || null,
    }));
  }

  return {
    functionId:    base.function_id,
    name:          base.canonical_name,
    canonicalName: base.canonical_name,
    opcode:        base.opcode,
    returnType:    base.return_type,
    returnTypeDisplay: lang_row.return_type_display || null,
    originVersion: base.origin_version,
    removedInVersion: base.removed_in_version ?? null,
    isGetFunction: Number(base.is_get_function) === 1,
    urlSlug:       base.url_slug,
    displayName:   lang_row.display_name || base.canonical_name,
    signature:     lang_row.signature || null,
    description:   lang_row.description || null,
    purpose:       lang_row.purpose || null,
    notes:         lang_row.notes || null,
    example1:      lang_row.example_1 || null,
    categoryId:    base.category_id,
    category: catRow.category_id != null ? {
      id:     Number(catRow.category_id),
      slug:   catRow.url_slug,
      nameEn: catRow.category_name,
      name:   catRow.lang_name || catRow.category_name,
    } : null,
    parameters,
    platformAffinity,
    osAffinity: await getOsAffinity(ctx, 'function_os_affinity', 'function_id', base.function_id),
    helpUrl:      lang_row.url || null,
    localHelpUrl: buildLocalHelpUrl('functions', language, base.url_slug),
    docsEntry:    buildDocsEntryRef('function', base.category_id, base.function_id, base.url_slug),
  };
}

/**
 * ============================================================================
 * Universal Reverse-Lookup (Token → Step/Function)
 * ============================================================================
 */

async function lookupToken(ctx, token, lang, { all = false } = {}) {
  assertAttached();

  // Sprach-Filterung pro Domain — Function-Sprachen sind eine Untermenge der
  // Step-Sprachen; wir liefern für ungültige Function-Sprachen nur Steps.
  const stepLang = isStepLang(lang) ? lang : null;
  const fnLang   = isFunctionLang(lang) ? lang : (lang ? null : environment.reference.defaultLang);

  const primaryFilter = all ? '' : 'AND l.is_primary = 1';

  const stepRes = await db.executeQuery(ctx, `
    SELECT l.step_id, l.match_source, l.is_primary,
           s.canonical_name, s.url_slug,
           sl.display_name, sl.url
    FROM ref.script_step_name_lookup l
    JOIN ref.script_steps s USING (step_id)
    LEFT JOIN ref.script_steps_lang sl
      ON sl.step_id = l.step_id AND sl.language = ?
    WHERE l.lookup_name = ? ${primaryFilter}
    ORDER BY l.is_primary DESC, l.step_id
  `, [stepLang || environment.reference.defaultLang, token]);

  const fnRes = await db.executeQuery(ctx, `
    SELECT l.function_id, l.match_source, l.chunk_role, l.is_primary,
           f.canonical_name, f.url_slug, f.is_get_function,
           fl.display_name, fl.url, fl.purpose, fl.signature
    FROM ref.function_name_lookup l
    JOIN ref.functions f USING (function_id)
    LEFT JOIN ref.functions_lang fl
      ON fl.function_id = l.function_id AND fl.language = ?
    WHERE l.lookup_name = ? ${primaryFilter}
    ORDER BY l.is_primary DESC, l.function_id
  `, [fnLang || environment.reference.defaultLang, token]);

  const matches = [];
  for (const r of stepRes.rows) {
    matches.push({
      kind: 'script_step',
      stepId: Number(r.step_id),
      canonical: r.canonical_name,
      urlSlug: r.url_slug,
      matchSource: r.match_source,
      isPrimary: Number(r.is_primary) === 1,
      displayName: r.display_name || r.canonical_name,
      helpUrl: r.url || null,
      localHelpUrl: buildLocalHelpUrl('steps', stepLang || environment.reference.defaultLang, r.url_slug),
    });
  }
  for (const r of fnRes.rows) {
    // chunk_role='getparameter' → in canonical='Get' + subParameter aufspalten.
    // In der Reference-DB ist canonical_name bereits der reine Parameter-Name
    // (z.B. `FileName`, `AccountName`) — kein "Get"-Präfix. Bei Get-Funktionen
    // bilden wir das vollständige Token `Get(canonical_name)` für die UI ab.
    let canonical = r.canonical_name;
    let subParameter = null;
    if (r.chunk_role === 'getparameter' && Number(r.is_get_function) === 1) {
      subParameter = canonical;
      canonical = 'Get';
    }
    matches.push({
      kind: 'function',
      functionId: Number(r.function_id),
      canonical,
      subParameter,
      chunkRole: r.chunk_role,
      matchSource: r.match_source,
      isPrimary: Number(r.is_primary) === 1,
      urlSlug: r.url_slug,
      displayName: r.display_name || r.canonical_name,
      signature: r.signature || null,
      purpose: r.purpose || null,
      helpUrl: r.url || null,
      localHelpUrl: buildLocalHelpUrl('functions', fnLang || environment.reference.defaultLang, r.url_slug),
    });
  }
  return matches;
}

/**
 * ============================================================================
 * Calc-Token-Anreicherung (function_name_lookup)
 * ============================================================================
 *
 * Reichert Tokens vom Type `function` (aus tokens.formatter.js) in-place an —
 * Bulk-Lookup pro eindeutigen Token-Content über `function_name_lookup`. Get-
 * Funktionen mit chunkRole='getparameter' werden auf {canonical='Get',
 * subParameter=<param>} aufgespalten — analog `lookupToken`.
 *
 * Für die Sprache `en` existiert kein `functions_lang`-Eintrag; wir liefern
 * dann `displayName = canonical_name` und purpose/signature `null`.
 */
async function enrichFunctionTokens(ctx, tokens, lang) {
  if (!Array.isArray(tokens) || tokens.length === 0) return tokens;
  assertAttached();

  // Sprache mit Soft-Fallback: für ungültige Function-Sprache (z.B. 'en' oder
  // 'zh-Hans') laden wir die DB ohne functions_lang JOIN und liefern canonical
  // als Display.
  const requestedLang = lang || environment.reference.defaultLang;
  const useLang = isFunctionLang(requestedLang) ? requestedLang : null;

  // Eindeutige Token-Contents sammeln
  const names = new Set();
  for (const t of tokens) {
    if (t && t.type === 'function' && typeof t.content === 'string' && t.content.length > 0) {
      names.add(t.content);
    }
  }
  if (names.size === 0) return tokens;

  const nameList = Array.from(names);
  const placeholders = nameList.map(() => '?').join(',');

  // Pro Bulk-Query holen wir alle is_primary=1-Matches in einem Rutsch.
  // Hinweis: in `lookup_name IN (…)` können prinzipiell mehrere Treffer pro
  // Name landen (z.B. canonical_en + display_de). Wir nehmen den ersten via
  // arg_max-artiger Reduktion clientseitig — primärer Treffer gewinnt.
  //
  // Bridge-JOIN für Get-Sub-Parameter: Einige Get-Funktionen sind in der
  // Reference-DB als "Waisen" angelegt (z.B. function_id=369 für
  // "HostAnwendungVersion" — kein url_slug, keine URL). Über die signature
  // (z.B. "Hole ( HostAnwendungVersion )") finden wir oft die "reiche"
  // Geschwister-function_id mit gefülltem url_slug. Greift nur bei
  // is_get_function=1 AND url_slug IS NULL.
  const sql = `
    SELECT l.lookup_name,
           l.function_id,
           l.match_source,
           l.chunk_role,
           l.is_primary,
           f.canonical_name,
           f.url_slug,
           f.is_get_function,
           f.return_type,
           ${useLang
             ? `fl.display_name, fl.signature, fl.purpose, fl.description, fl.url,
                bridge_f.url_slug AS bridge_url_slug,
                bridge_fl.url AS bridge_url,
                bridge_fl.purpose AS bridge_purpose,
                bridge_fl.description AS bridge_description`
             : `NULL AS display_name, NULL AS signature, NULL AS purpose, NULL AS description, NULL AS url,
                NULL AS bridge_url_slug, NULL AS bridge_url,
                NULL AS bridge_purpose, NULL AS bridge_description`}
    FROM ref.function_name_lookup l
    JOIN ref.functions f USING (function_id)
    ${useLang
      ? `LEFT JOIN ref.functions_lang fl ON fl.function_id = l.function_id AND fl.language = ?
         LEFT JOIN ref.function_name_lookup bridge_l
           ON f.is_get_function = 1
           AND f.url_slug IS NULL
           AND fl.signature IS NOT NULL
           AND bridge_l.lookup_name = fl.signature
           AND bridge_l.chunk_role = 'getfunction'
           AND bridge_l.function_id != l.function_id
         LEFT JOIN ref.functions bridge_f
           ON bridge_f.function_id = bridge_l.function_id
           AND bridge_f.url_slug IS NOT NULL
         LEFT JOIN ref.functions_lang bridge_fl
           ON bridge_fl.function_id = bridge_l.function_id
           AND bridge_fl.language = ?`
      : ''}
    WHERE l.lookup_name IN (${placeholders})
      AND l.is_primary = 1
  `;
  const params = useLang ? [useLang, useLang, ...nameList] : nameList;
  const r = await db.executeQuery(ctx, sql, params);

  const mirrorLang = useLang ? mirrorLangDir(useLang) : null;

  // Pro Token-Content den ersten Treffer behalten (Sortierung ist stabil genug,
  // weil is_primary=1 in der Quelle ohnehin eindeutig pro (lookup_name, function_id))
  const matchByName = new Map();
  for (const row of r.rows) {
    if (matchByName.has(row.lookup_name)) continue;
    matchByName.set(row.lookup_name, row);
  }

  for (const t of tokens) {
    if (!t || t.type !== 'function') continue;
    const row = matchByName.get(t.content);
    if (!row) continue;

    let canonical = row.canonical_name;
    let subParameter = null;
    if (row.chunk_role === 'getparameter' && Number(row.is_get_function) === 1) {
      subParameter = canonical;
      canonical = 'Get';
    }

    t.functionId       = Number(row.function_id);
    t.functionCanonical = canonical;
    if (subParameter)  t.functionSubParameter = subParameter;
    // Der UNGETEILTE kanonische Name — für einen Get-Parameter also
    // `Get(PageNumber)`, nicht das nackte `Get` aus der Aufspaltung oben.
    // Genau dieser Name ist die Katalog-Identität des Built-ins (ObjectCatalog
    // .Object_Name seit Schema 1.32.0), und nur er ist als „kanonisch: …"-Angabe
    // brauchbar: `Get` allein benennt keine Funktion und war für den Leser
    // schlicht falsch.
    t.functionCanonicalFull = subParameter ? `Get(${subParameter})` : canonical;
    t.functionDisplayName = row.display_name || row.canonical_name;
    t.functionSignature   = row.signature || null;
    // Purpose-Kaskade: bei Get-Waisen ist `purpose` oft NULL und der Kurztext
    // steckt unter `description`; ggf. liefert die Bridge-Funktion (function_id
    // mit gefülltem url_slug) den schöner formulierten purpose. Reihenfolge:
    //   1. eigener purpose  (normalfall)
    //   2. bridge purpose   (Waisen mit Geschwister-Eintrag)
    //   3. eigene description (Waisen ohne Bridge — Kurztext steht hier)
    //   4. bridge description
    t.functionPurpose     = row.purpose
      || row.bridge_purpose
      || row.description
      || row.bridge_description
      || null;
    t.functionReturnType  = row.return_type || null;
    t.functionChunkRole   = row.chunk_role;
    t.functionMatchSource = row.match_source;

    // Help-URL-Auflösung mit dreistufiger Kaskade für Get-Funktionen, die
    // wegen DB-Waisen (function_id ohne url_slug) sonst keinen Link bekämen:
    //   1. Direkter url_slug der gematchten function_id  → spezifische Sub-Hilfe
    //   2. Bridge-url_slug (über fl.signature aufgelöst) → spezifische Sub-Hilfe
    //   3. Fallback get-functions                        → Übersichts-Seite
    // Nur Stufe 1+2 setzen functionUrlSlug; Stufe 3 setzt nur die URLs (sonst
    // täuscht functionUrlSlug eine spezifische Funktion vor, die es nicht gibt).
    let resolvedSlug = row.url_slug || null;
    let resolvedUrl  = row.url || null;
    let usedBridge = false;
    let usedFallback = false;

    if (!resolvedSlug && row.bridge_url_slug) {
      resolvedSlug = row.bridge_url_slug;
      resolvedUrl  = row.bridge_url || resolvedUrl;
      usedBridge = true;
    }

    t.functionUrlSlug = resolvedSlug;
    t.functionHelpUrl = resolvedUrl;

    if (resolvedSlug && mirrorLang) {
      const helpService = require('./help.service');
      if (helpService.hasMirrorForLang(mirrorLang)) {
        t.functionLocalHelpUrl = `/api/reference/help/${encodeURIComponent(useLang)}/${encodeURIComponent(resolvedSlug)}`;
      }
    }

    // Stufe 3: Fallback auf get-functions Übersichtsseite, wenn weder eigene
    // noch Bridge-Slug existiert UND es eine Get-Funktion ist. Damit zumindest
    // ein Link sichtbar wird (Funktionsliste mit Anker pro Sub-Parameter).
    if (!resolvedSlug && Number(row.is_get_function) === 1) {
      const helpService = require('./help.service');
      const fallbackSlug = 'get-functions';
      if (mirrorLang && helpService.hasMirrorForLang(mirrorLang)) {
        const inv = helpService.getSlugInventory(mirrorLang);
        if (inv && inv.has(fallbackSlug)) {
          t.functionLocalHelpUrl = `/api/reference/help/${encodeURIComponent(useLang)}/${encodeURIComponent(fallbackSlug)}`;
          usedFallback = true;
        }
      }
      if (useLang) {
        t.functionHelpUrl = `https://help.claris.com/${encodeURIComponent(useLang)}/pro-help/content/${fallbackSlug}.html`;
        usedFallback = true;
      }
    }

    if (usedBridge)   t.functionHelpResolution = 'bridge';
    if (usedFallback) t.functionHelpResolution = 'fallback-get-functions';
  }
  return tokens;
}

/**
 * ============================================================================
 * Levenshtein-Distanz für 404-Suggestions
 * ============================================================================
 */

function levenshtein(a, b) {
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  const m = a.length, n = b.length;
  const dp = new Array(n + 1);
  for (let j = 0; j <= n; j++) dp[j] = j;
  for (let i = 1; i <= m; i++) {
    let prev = dp[0];
    dp[0] = i;
    for (let j = 1; j <= n; j++) {
      const tmp = dp[j];
      dp[j] = a[i - 1] === b[j - 1]
        ? prev
        : 1 + Math.min(prev, dp[j], dp[j - 1]);
      prev = tmp;
    }
  }
  return dp[n];
}

async function suggestStepSlugs(ctx, needle, limit = 5) {
  assertAttached();
  const r = await db.executeQuery(ctx, `SELECT url_slug, canonical_name FROM ref.script_steps`);
  return rankSuggestions(needle, r.rows.flatMap((x) => [x.url_slug, x.canonical_name]), limit);
}

async function suggestFunctionNames(ctx, needle, limit = 5) {
  assertAttached();
  const r = await db.executeQuery(ctx, `SELECT canonical_name, url_slug FROM ref.functions`);
  return rankSuggestions(needle, r.rows.flatMap((x) => [x.canonical_name, x.url_slug].filter(Boolean)), limit);
}

function rankSuggestions(needle, candidates, limit) {
  const lower = String(needle || '').toLowerCase();
  const scored = candidates
    .filter((s) => s && s.length > 0)
    .map((s) => ({ s, d: levenshtein(lower, s.toLowerCase()) }))
    .sort((a, b) => a.d - b.d);
  const out = [];
  const seen = new Set();
  for (const x of scored) {
    if (seen.has(x.s)) continue;
    seen.add(x.s);
    out.push(x.s);
    if (out.length >= limit) break;
  }
  return out;
}

/**
 * ============================================================================
 * Local-Help-URL-Builder
 * ============================================================================
 *
 * Liefert /api/reference/help/<lang>/<slug>, wenn der lokale Mirror für diese
 * Sprache verfügbar ist. Sonst null. Status liegt im help.service.
 */
function buildLocalHelpUrl(domain, lang, slug) {
  if (!slug) return null;
  const helpService = require('./help.service');
  const mirrorDir = mirrorLangDir(lang);
  if (!helpService.hasMirrorForLang(mirrorDir)) return null;
  return `/api/reference/help/${encodeURIComponent(lang)}/${encodeURIComponent(slug)}`;
}

/**
 * Cross-navigation target into the Claris docs page of a step/function
 * (`/docs/claris-help/<category>/<entry>` in the SPA). Language-independent:
 * the docs page resolves the display language itself. Returns null unless the
 * counterpart really exists — the `claris-help` doc-set is installed AND the
 * help mirror holds the slug in at least one language (an installed doc-set
 * with a missing page would render an empty docs view).
 *
 * `kind` = 'step' | 'function'; the id prefixes mirror the claris-duckdb docs
 * adapter (`ss:` / `fn:`).
 */
const CLARIS_DOCSET_ID = 'claris-help';
function buildDocsEntryRef(kind, categoryId, id, slug) {
  if (!slug || categoryId == null || id == null) return null;
  const helpService = require('./help.service');
  const docsManifest = require('./docs-manifest');
  if (!docsManifest.isInstalled(CLARIS_DOCSET_ID)) return null;
  if (!helpService.hasAnyHtml(slug)) return null;
  const prefix = kind === 'step' ? 'ss' : 'fn';
  return {
    set: CLARIS_DOCSET_ID,
    category: `${prefix}:${Number(categoryId)}`,
    entry: `${prefix}:${Number(id)}`,
  };
}

/**
 * ============================================================================
 * Build-Metadaten (für Response-Header / -Envelope)
 * ============================================================================
 */
async function getBuildMeta(ctx) {
  assertAttached();
  if (metaCache.has('build-meta')) return metaCache.get('build-meta');
  // Quelle für Versions-Info: functions.source_version (FileMaker v21)
  const r = await db.executeQuery(ctx, `SELECT DISTINCT source_version FROM ref.functions LIMIT 1`);
  const meta = {
    sourceVersion: r.rows[0]?.source_version || null,
  };
  metaCache.set('build-meta', meta);
  return meta;
}

/**
 * ============================================================================
 * fm-spec Schema-Viewer
 * ============================================================================
 */

/**
 * Kopfbereich in einem Call: reference_meta + Zähler + Locale-Matrix.
 * Degradiert definiert, wenn generative Tabellen fehlen (grammarSteps = 0).
 */
async function getReferenceMeta(ctx) {
  assertAttached();
  const cacheKey = 'fmspec-meta';
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);

  // reference_meta ist eine key/value-Tabelle → zu einem Objekt pivotieren.
  const metaRows = await db.executeQuery(ctx, `SELECT key, value FROM ref.reference_meta`);
  const referenceMeta = {};
  for (const row of metaRows.rows) referenceMeta[row.key] = row.value;

  const grammarTable = await refTableExists(ctx, 'step_xml_map');
  // runtime & diagnostics tables (fm_spec >= 2.8.0) — counted only where present
  const countIf = async (table) => (await refTableExists(ctx, table))
    ? Number((await db.executeQuery(ctx, `SELECT COUNT(*) AS n FROM ref.${table}`)).rows[0].n)
    : 0;

  const [stepCount, fnCount, stepLoc, fnLoc, grammar, triggers, errorCodes, featureVersions, constants] = await Promise.all([
    db.executeQuery(ctx, `SELECT COUNT(*) AS n FROM ref.script_steps`),
    db.executeQuery(ctx, `SELECT COUNT(*) AS n FROM ref.functions`),
    db.executeQuery(ctx, `SELECT COUNT(DISTINCT language) AS n FROM ref.script_steps_lang`),
    db.executeQuery(ctx, `SELECT COUNT(DISTINCT language) AS n FROM ref.functions_lang`),
    grammarTable
      ? db.executeQuery(ctx, `SELECT COUNT(*) AS n FROM ref.step_xml_map`)
      : Promise.resolve({ rows: [{ n: 0 }] }),
    countIf('script_triggers'),
    countIf('error_codes'),
    countIf('feature_versions'),
    countIf('language_constants'),
  ]);

  // Locale-Matrix (deckt Tab 4.3 mit ab). Pro Sprache: Step-/Functions-/
  // Parameter-Abdeckung. Union der Sprachen aus beiden Domänen.
  const [stepsByLang, fnsByLang, paramsByLang] = await Promise.all([
    db.executeQuery(ctx, `SELECT language, COUNT(*) AS n FROM ref.script_steps_lang GROUP BY language`),
    db.executeQuery(ctx, `SELECT language, COUNT(*) AS n FROM ref.functions_lang GROUP BY language`),
    db.executeQuery(ctx, `SELECT language, COUNT(*) AS n FROM ref.script_step_parameters_lang GROUP BY language`),
  ]);

  const localeMap = new Map();
  const ensure = (code) => {
    if (!localeMap.has(code)) {
      localeMap.set(code, { code, steps: 0, functions: 0, stepParameters: 0 });
    }
    return localeMap.get(code);
  };
  for (const row of stepsByLang.rows) ensure(row.language).steps = Number(row.n);
  for (const row of fnsByLang.rows) ensure(row.language).functions = Number(row.n);
  for (const row of paramsByLang.rows) ensure(row.language).stepParameters = Number(row.n);
  const locales = Array.from(localeMap.values()).sort((a, b) => a.code.localeCompare(b.code));

  const data = {
    referenceMeta: {
      schema_version:    referenceMeta.schema_version || null,
      filemaker_coverage: referenceMeta.filemaker_coverage || null,
      doc_coverage:      referenceMeta.doc_coverage || null,      // documentation layer (since fm_spec 1.19.0)
      doc_help_build:    referenceMeta.doc_help_build || null,
      doc_source:        referenceMeta.doc_source || null,
      built_at:          referenceMeta.built_at || null,
      shape_coverages:   referenceMeta.shape_coverages || null, // fm_spec >= 2.0.0
      source_commit:     referenceMeta.source_commit || null,
    },
    coverages: await getShapeCoverages(ctx),
    counts: {
      scriptSteps:     Number(stepCount.rows[0].n),
      functions:       Number(fnCount.rows[0].n),
      stepLocales:     Number(stepLoc.rows[0].n),
      functionLocales: Number(fnLoc.rows[0].n),
      grammarSteps:    Number(grammar.rows[0].n),
      triggers,                 // fm_spec >= 1.18.0 (0 on older builds)
      errorCodes,               // fm_spec >= 2.8.0
      featureVersions,          // fm_spec >= 2.8.0
      constants,                // language_constants rows (52 since 2.8.0)
    },
    locales,
    grammarAvailable: grammarTable,
    diagnosticsAvailable: errorCodes > 0, // error_codes/feature_versions/trigger_compat shipped (fm_spec >= 2.8.0)
  };
  metaCache.set(cacheKey, data);
  return data;
}

/**
 * Lokalisierte Step-Daten + Parameter über ALLE Sprachen
 * in einem Call (vermeidet n Requests je Sprache).
 */
async function getStepAllLangs(ctx, idOrSlug) {
  assertAttached();
  const base = await findStepBySlugOrId(ctx, idOrSlug);
  if (!base) return null;

  const [langRes, paramRes] = await Promise.all([
    db.executeQuery(ctx, `
      SELECT language, display_name, description, parameter, url
      FROM ref.script_steps_lang
      WHERE step_id = ?
      ORDER BY language
    `, [base.step_id]),
    db.executeQuery(ctx, `
      SELECT language, param_index, name, description
      FROM ref.script_step_parameters_lang
      WHERE step_id = ?
      ORDER BY language, param_index
    `, [base.step_id]),
  ]);

  const paramsByLang = new Map();
  for (const p of paramRes.rows) {
    if (!paramsByLang.has(p.language)) paramsByLang.set(p.language, []);
    paramsByLang.get(p.language).push({
      index: Number(p.param_index),
      name: p.name,
      description: p.description,
    });
  }

  const langs = langRes.rows.map((row) => ({
    language:     row.language,
    displayName:  row.display_name || base.canonical_name,
    description:  row.description || null,
    parameterText: row.parameter || null,
    helpUrl:      row.url || null,
    localHelpUrl: buildLocalHelpUrl('steps', row.language, base.url_slug),
    parameters:   paramsByLang.get(row.language) || [],
  }));

  const compatMap = await getStepCompatMap(ctx);

  return {
    stepId:        base.step_id,
    canonicalName: base.canonical_name,
    urlSlug:       base.url_slug,
    categoryId:    base.category_id,
    originVersion: base.origin_version || null,
    compat:        compatMap.get(Number(base.step_id)) || null,
    osAffinity:    await getOsAffinity(ctx, 'step_os_affinity', 'step_id', base.step_id),
    docsEntry:     buildDocsEntryRef('step', base.category_id, base.step_id, base.url_slug),
    langs,
  };
}

// ---------------------------------------------------------------------------
// Shape coverages (fm_spec >= 2.0.0)
//
// The seven shape tables (step_xml_map, step_options, step_option_values,
// step_repeat_groups, step_skeleton_elements, step_option_element_bindings,
// step_mirror_elements since 2.6.0) carry a `coverage` column: '*' = standard row, '<NN>' = override/addition
// of ONE FileMaker coverage (26 today). The vocabulary lives in `coverages`
// (base flag, paired version, SaXML version). A reader resolves against one
// TARGET coverage: rows of the target override the '*' row of the same key,
// no target row = the standard row — the same rule fmgen applies
// (fmgen_lib/db.py Reference._resolve). Older references have neither the
// column nor the table: a single, unversioned shape.
// ---------------------------------------------------------------------------

/**
 * Shape coverages of the attached reference, base first:
 * [{ coverage, pairedVersion, saxmlVersion, isBase }]. Empty on builds
 * without the `coverages` vocabulary (fm_spec < 2.0.0).
 */
async function getShapeCoverages(ctx) {
  const cacheKey = 'fmspec-coverages';
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);
  let out = [];
  if (await refTableExists(ctx, 'coverages')) {
    const r = await db.executeQuery(ctx, `
      SELECT coverage, paired_version, saxml_version, is_base
      FROM ref.coverages
      ORDER BY is_base DESC, coverage
    `);
    out = r.rows.map((c) => ({
      coverage:      String(c.coverage),
      pairedVersion: c.paired_version ?? null,
      saxmlVersion:  c.saxml_version ?? null,
      isBase:        Boolean(c.is_base),
    }));
  }
  metaCache.set(cacheKey, out);
  return out;
}

/**
 * Resolve the requested shape coverage. Empty/undefined = the base coverage
 * of the reference; any other value must be one of its coverages, otherwise
 * REF_COVERAGE_INVALID (400). Returns { coverage, source } with source
 * 'query' | 'base' | 'none' (reference without shape coverages).
 */
async function resolveShapeCoverage(ctx, requested) {
  const list = await getShapeCoverages(ctx);
  const wanted = requested == null ? '' : String(requested).trim();
  if (list.length === 0) {
    if (wanted) {
      const err = new Error('This reference build carries no shape coverages (fm_spec < 2.0.0) — omit the coverage parameter.');
      err.code = 'REF_COVERAGE_INVALID';
      throw err;
    }
    return { coverage: null, source: 'none' };
  }
  const base = list.find((c) => c.isBase) || list[0];
  if (!wanted) return { coverage: base.coverage, source: 'base' };
  const hit = list.find((c) => c.coverage === wanted);
  if (!hit) {
    const err = new Error(`Unknown shape coverage '${wanted}'. Known: ${list.map((c) => c.coverage).join(', ')}.`);
    err.code = 'REF_COVERAGE_INVALID';
    err.details = { known: list.map((c) => c.coverage) };
    throw err;
  }
  return { coverage: hit.coverage, source: 'query' };
}

/**
 * Resolution rule over a union of '*' rows and target-coverage rows: target
 * rows win over '*' rows with the same key; target rows keep their relative
 * order and come first, then the surviving '*' rows. `coverage` stays on the
 * row so the viewer can mark overrides. No target = rows as they are.
 */
function resolveCoverageRows(rows, keyFn, target) {
  if (target == null) return rows;
  const own = rows.filter((r) => String(r.coverage) === target);
  const ownKeys = new Set(own.map(keyFn));
  const std = rows.filter((r) => String(r.coverage) !== target && !ownKeys.has(keyFn(r)));
  return own.concat(std);
}

/** Coverages (other than '*') that carry any shape row for one step. */
async function getStepOverrideCoverages(ctx, stepId, hasCoverage) {
  if (!hasCoverage) return [];
  const parts = [];
  for (const t of ['step_xml_map', 'step_options', 'step_option_values',
                   'step_repeat_groups', 'step_skeleton_elements', 'step_option_element_bindings',
                   'step_mirror_elements']) {
    if (await refTableExists(ctx, t) && await refColumnExists(ctx, t, 'coverage')) {
      parts.push(`SELECT coverage FROM ref.${t} WHERE step_id = ${Number(stepId)}`);
    }
  }
  if (parts.length === 0) return [];
  const r = await db.executeQuery(ctx, `
    SELECT DISTINCT coverage FROM (${parts.join(' UNION ALL ')}) u
    WHERE coverage <> '*' ORDER BY coverage
  `);
  return r.rows.map((x) => String(x.coverage));
}

/**
 * Grammatik-Details (Abschnitte 3+4 des Detail-Views).
 * 404-frei bezüglich Grammatik: existiert keine step_xml_map-Zeile (oder fehlt
 * die Tabelle bei Referenz < 1.2.0) → `{ available:false, xmlMap:null, … }`.
 * Ein unbekannter Step wirft dagegen REF_STEP_NOT_FOUND (Controller → 404).
 */
async function getStepGrammar(ctx, idOrSlug, requestedCoverage) {
  assertAttached();
  const base = await findStepBySlugOrId(ctx, idOrSlug);
  if (!base) {
    const err = new Error(`No step with id/slug '${idOrSlug}'.`);
    err.code = 'REF_STEP_NOT_FOUND';
    throw err;
  }

  const empty = {
    stepId: base.step_id,
    canonicalName: base.canonical_name,
    available: false,
    coverage: null,
    coverageSource: 'none',
    coverages: [],
    overrideCoverages: [],
    xmlMap: null,
    options: [],
    constraints: [],
    repeatGroups: [],
    skeletonElements: [],
    elementBindings: [],
    optionImplications: [],
    mirrorElements: [],
  };

  if (!(await refTableExists(ctx, 'step_xml_map'))) return empty;

  // Shape coverages (fm_spec >= 2.0.0): read the standard rows plus the rows
  // of the TARGET coverage and resolve per table (override rule above).
  // No column = pre-2.0 reference, single shape, coverage null.
  const hasCoverage = await refColumnExists(ctx, 'step_xml_map', 'coverage');
  const { coverage, source: coverageSource } = hasCoverage
    ? await resolveShapeCoverage(ctx, requestedCoverage)
    : { coverage: null, source: 'none' };
  const cov = hasCoverage
    ? (coverage != null ? ` AND coverage IN ('*', ?)` : ` AND coverage = '*'`)
    : '';
  const covParams = hasCoverage && coverage != null ? [coverage] : [];
  const rowCov = (r) => (r.coverage != null ? String(r.coverage) : null);
  // step_constraints.coverage (fm_spec >= 2.7.0): '*' = every coverage, a
  // coverage id scopes the row (saxml_omission). Every row is listed — the
  // scope is shown, not filtered — so a 22-only export gap stays visible
  // when the grammar is viewed for 26 and vice versa.
  const conCov = (await refColumnExists(ctx, 'step_constraints', 'coverage')) ? ', coverage' : '';

  // SELECT * — the deployed consumer variant strips curation columns (notes)
  // and adds payload columns (saxml_example); tolerate both shapes.
  const mapRes = await db.executeQuery(ctx, `
    SELECT * FROM ref.step_xml_map WHERE step_id = ?${cov}
  `, [base.step_id, ...covParams]);
  const mapRows = resolveCoverageRows(mapRes.rows, (r) => String(r.step_id), coverage);
  if (mapRows.length === 0) return { ...empty, coverage, coverageSource, coverages: await getShapeCoverages(ctx) };
  const m = mapRows[0];

  const [optRes, valRes, conRes] = await Promise.all([
    // SELECT * keeps the reads tolerant across reference schema versions
    // (slot_kind / xml_true / xml_false since 2.2.0, coverage since 2.0.0)
    db.executeQuery(ctx, `
      SELECT *
      FROM ref.step_options
      WHERE step_id = ?${cov}
      ORDER BY sort_order, option_key
    `, [base.step_id, ...covParams]),
    db.executeQuery(ctx, `
      SELECT *
      FROM ref.step_option_values
      WHERE step_id = ?${cov}
      ORDER BY option_key, xml_value
    `, [base.step_id, ...covParams]),
    db.executeQuery(ctx, `
      SELECT constraint_kind, detail, evidence, verified_version${conCov}
      FROM ref.step_constraints
      WHERE step_id = ?
      ORDER BY constraint_kind${conCov}
    `, [base.step_id]),
  ]);

  // enum values: target rows come FIRST so a display text shared by two xml
  // values resolves to the coverage-specific value (226 RAGPromptRequest)
  const valueRows = resolveCoverageRows(
    valRes.rows, (r) => `${r.option_key}\u0000${r.xml_value}`, coverage);
  const valuesByKey = new Map();
  for (const v of valueRows) {
    if (!valuesByKey.has(v.option_key)) valuesByKey.set(v.option_key, []);
    valuesByKey.get(v.option_key).push({
      xmlValue: v.xml_value,
      displayTextEn: v.display_text_en,
      evidence: v.evidence ?? null,
      coverage: rowCov(v),
    });
  }

  const optionRows = resolveCoverageRows(optRes.rows, (r) => r.option_key, coverage)
    .sort((a, b) => (Number(a.sort_order ?? 999) - Number(b.sort_order ?? 999))
      || String(a.option_key).localeCompare(String(b.option_key)));
  const options = optionRows.map((o) => ({
    optionKey:      o.option_key,
    optionType:     o.option_type,
    required:       Boolean(o.required),
    displayLocation: o.display_location,
    displayLabelEn: o.display_label_en,
    trueText:       o.true_text,
    falseText:      o.false_text,
    omitWhenFalse:  Boolean(o.omit_when_false),
    invertedLabel:  Boolean(o.inverted_label),
    xmlPath:        o.xml_path,
    sortOrder:      o.sort_order != null ? Number(o.sort_order) : null,
    evidence:       o.evidence,
    verifiedVersion: o.verified_version,
    // value form of a target slot (fm_spec >= 2.2.0); null = not curated
    slotKind:       o.slot_kind ?? null,
    // XML value domain of a boolean attribute (fm_spec >= 2.2.0); null = True/False
    xmlTrue:        o.xml_true ?? null,
    xmlFalse:       o.xml_false ?? null,
    // discarded by FileMaker on paste whatever its value (fm_spec >= 2.6.0);
    // false on older references (column absent)
    pasteDropped:   o.paste_dropped != null ? Boolean(o.paste_dropped) : false,
    coverage:       rowCov(o),
    values:         valuesByKey.get(o.option_key) || [],
  }));

  // Constraint-kind registry (fm_spec >= 1.17.0): consumer-facing lead text
  // per kind (bug-registry kinds only); tolerant on older references.
  let kindNotes = new Map();
  if (await refTableExists(ctx, 'constraint_kinds')) {
    const kRes = await db.executeQuery(ctx, `
      SELECT constraint_kind, consumer_note
      FROM ref.constraint_kinds
      WHERE consumer_note IS NOT NULL
    `);
    kindNotes = new Map(kRes.rows.map((k) => [k.constraint_kind, k.consumer_note]));
  }

  const constraints = conRes.rows.map((c) => ({
    constraintKind:  c.constraint_kind,
    detail:          c.detail,
    evidence:        c.evidence,
    verifiedVersion: c.verified_version,
    consumerNote:    kindNotes.get(c.constraint_kind) ?? null,
    coverage:        c.coverage != null ? String(c.coverage) : null,
  }));

  // Repeat groups (fm_spec >= 1.15.0; fixed-slot columns >= 1.16.0).
  // SELECT * keeps this tolerant across reference schema versions.
  let repeatGroups = [];
  if (await refTableExists(ctx, 'step_repeat_groups')) {
    const grpRes = await db.executeQuery(ctx, `
      SELECT * FROM ref.step_repeat_groups
      WHERE step_id = ?${cov}
      ORDER BY (parent_group IS NOT NULL), group_key
    `, [base.step_id, ...covParams]);
    const grpRows = resolveCoverageRows(grpRes.rows, (r) => r.group_key, coverage)
      .sort((a, b) => Number(a.parent_group != null) - Number(b.parent_group != null)
        || String(a.group_key).localeCompare(String(b.group_key)));
    repeatGroups = grpRows.map((g) => ({
      coverage:       rowCov(g),
      groupKey:       g.group_key,
      groupLabel:     g.group_label,
      parentGroup:    g.parent_group ?? null,
      containerPath:  g.container_path,
      countAttr:      g.count_attr ?? null,
      itemForm:       g.item_form,
      maxItems:       g.max_items != null ? Number(g.max_items) : null,
      slotPositional: g.slot_positional != null ? Boolean(g.slot_positional) : null,
      padMode:        g.pad_mode ?? null,
      evidence:       g.evidence ?? null,
      verifiedVersion: g.verified_version ?? null,
    }));
  }

  // Hint-inventory tables (fm_spec >= 1.17.0): skeleton hulls, option-bound
  // elements and notation implications per step. SELECT * keeps the reads
  // tolerant across reference schema versions; empty on older references.
  let skeletonElements = [];
  let elementBindings = [];
  let optionImplications = [];
  if (await refTableExists(ctx, 'step_skeleton_elements')) {
    const skRes = await db.executeQuery(ctx, `
      SELECT * FROM ref.step_skeleton_elements
      WHERE step_id = ?${cov}
      ORDER BY (parent_tag <> 'Step'), child_tag
    `, [base.step_id, ...covParams]);
    const skRows = resolveCoverageRows(
      skRes.rows,
      (r) => [r.parent_tag, r.child_tag, r.condition_option ?? '', r.condition_value ?? ''].join('\u0000'),
      coverage,
    ).sort((a, b) => Number(a.parent_tag !== 'Step') - Number(b.parent_tag !== 'Step')
      || String(a.child_tag).localeCompare(String(b.child_tag)));
    skeletonElements = skRows.map((s) => ({
      coverage:        rowCov(s),
      parentTag:       s.parent_tag,
      childTag:        s.child_tag,
      conditionOption: s.condition_option ?? null,
      conditionValue:  s.condition_value ?? null,
      keepMode:        s.keep_mode,
      evidence:        s.evidence ?? null,
      verifiedVersion: s.verified_version ?? null,
    }));
  }
  if (await refTableExists(ctx, 'step_option_element_bindings')) {
    const bdRes = await db.executeQuery(ctx, `
      SELECT * FROM ref.step_option_element_bindings
      WHERE step_id = ?${cov}
      ORDER BY element_path, binding, option_key, option_value
    `, [base.step_id, ...covParams]);
    const bdRows = resolveCoverageRows(
      bdRes.rows,
      (r) => [r.option_key ?? '', r.option_value ?? '', r.element_path, r.binding].join('\u0000'),
      coverage,
    ).sort((a, b) => String(a.element_path).localeCompare(String(b.element_path))
      || String(a.binding).localeCompare(String(b.binding))
      || String(a.option_key ?? '').localeCompare(String(b.option_key ?? ''))
      || String(a.option_value ?? '').localeCompare(String(b.option_value ?? '')));
    elementBindings = bdRows.map((b) => ({
      coverage:        rowCov(b),
      optionKey:       b.option_key ?? null,
      optionValue:     b.option_value ?? null,
      elementPath:     b.element_path,
      binding:         b.binding,
      evidence:        b.evidence ?? null,
      verifiedVersion: b.verified_version ?? null,
    }));
  }
  if (await refTableExists(ctx, 'step_option_implications')) {
    const imRes = await db.executeQuery(ctx, `
      SELECT * FROM ref.step_option_implications
      WHERE step_id = ?
      ORDER BY trigger_kind, trigger
    `, [base.step_id]);
    optionImplications = imRes.rows.map((i) => ({
      triggerKind:     i.trigger_kind,
      trigger:         i.trigger,
      impliedOption:   i.implied_option,
      impliedValue:    i.implied_value ?? null,
      isDefault:       i.is_default != null ? Boolean(i.is_default) : null,
      direction:       i.direction,
      evidence:        i.evidence ?? null,
      verifiedVersion: i.verified_version ?? null,
    }));
  }

  // Mirror elements (fm_spec >= 2.6.0): values FileMaker writes twice and
  // keeps in sync on paste (144 title -> Step-level Calculation); empty on
  // older references.
  let mirrorElements = [];
  if (await refTableExists(ctx, 'step_mirror_elements')) {
    const mrRes = await db.executeQuery(ctx, `
      SELECT * FROM ref.step_mirror_elements
      WHERE step_id = ?${cov}
      ORDER BY source_option, target_path
    `, [base.step_id, ...covParams]);
    const mrRows = resolveCoverageRows(
      mrRes.rows,
      (r) => [r.source_option, r.target_path].join('\u0000'),
      coverage,
    ).sort((a, b) => String(a.source_option).localeCompare(String(b.source_option))
      || String(a.target_path).localeCompare(String(b.target_path)));
    mirrorElements = mrRows.map((m) => ({
      coverage:        rowCov(m),
      sourceOption:    m.source_option,
      targetPath:      m.target_path,
      trigger:         m.trigger,
      evidence:        m.evidence ?? null,
      verifiedVersion: m.verified_version ?? null,
    }));
  }

  return {
    stepId: base.step_id,
    canonicalName: base.canonical_name,
    available: true,
    // resolved shape coverage (fm_spec >= 2.0.0): the coverage the rows below
    // are resolved for, how it was chosen, the reference's coverages and the
    // coverages that carry override rows for THIS step
    coverage,
    coverageSource,
    coverages: await getShapeCoverages(ctx),
    overrideCoverages: await getStepOverrideCoverages(ctx, base.step_id, hasCoverage),
    xmlMap: {
      coverage:         rowCov(m),
      // step-level value form of the target slot(s) (fm_spec >= 1.17.0)
      targetSlotKind:   m.target_slot_kind ?? null,
      snippetTemplate:  m.snippet_template,
      saxmlParamTypes:  m.saxml_param_types,
      saxmlExample:     m.saxml_example ?? null,
      elementOrder:     m.element_order,
      // structural variable-target marker (fm_spec >= 1.17.0); null = column
      // absent on this reference build
      variableTargetMarker: m.variable_target_marker != null
        ? Boolean(m.variable_target_marker) : null,
      evidence:         m.evidence,
      verifiedVersion:  m.verified_version,
      notes:            m.notes ?? null,
    },
    options,
    constraints,
    repeatGroups,
    skeletonElements,
    elementBindings,
    optionImplications,
    mirrorElements,
  };
}

/**
 * ============================================================================
 * Lokalisierte Anzeigenamen für BuiltinFunction-Objekte
 * ============================================================================
 *
 * Seit Katalog-Schema 1.32.0 ist `ObjectCatalog.Object_Name` eines Built-ins der
 * KANONISCHE englische Referenzname — die Identität des Knotens, bewusst
 * sprachunabhängig. Für einen Entwickler, der seine Formeln deutsch schreibt,
 * heißt das: die Objektseite, die Objektliste und die Trefferliste zeigen
 * `Get(PageNumber)`, obwohl in seiner Lösung `Hole ( Seitennummer )` steht.
 * Diese Funktion liefert die lokalisierte Fassung NEBEN dem kanonischen Namen
 * nach — sie ersetzt ihn nie, weil sonst die Identität aus der Anzeige
 * verschwindet (und Suche/Joins/Deep-Links auf dem kanonischen Namen stehen).
 *
 * Ein Bulk-Lookup pro Antwort, Muster wie enrichFunctionTokens: Zeilen mit
 * Object_Type='BuiltinFunction' sammeln, EINE Abfrage, in-place anreichern.
 * Gesetzt wird `Localized_Name` nur, wenn es sich vom kanonischen Namen
 * unterscheidet — sonst wäre die Zusatzangabe reines Rauschen (englische UI,
 * oder eine Funktion, deren Name in der Zielsprache gleich lautet).
 *
 * Weich in jeder Richtung: ohne Sprache, ohne angehängte Referenz-DB, ohne
 * Identitätszeile (Namens-Fallback-Knoten) oder auf einem Katalog vor Schema
 * 1.32.0 passiert schlicht nichts — der kanonische Name allein ist immer eine
 * korrekte Anzeige.
 *
 * @param {Object} ctx   - Request-Kontext (Solution-Scope)
 * @param {Array}  rows  - Zeilen mit Object_UUID/Object_Type/Object_Name
 * @param {string} lang  - aktive UI-Sprache
 * @returns {Array} dieselben Zeilen (in-place angereichert)
 */
async function enrichBuiltinLocalizedNames(ctx, rows, lang) {
  if (!Array.isArray(rows) || rows.length === 0 || !lang) return rows;
  if (!isFunctionLang(lang)) return rows;

  const byUuid = new Map();
  for (const r of rows) {
    if (r && r.Object_Type === 'BuiltinFunction' && r.Object_UUID) {
      const key = String(r.Object_UUID);
      if (!byUuid.has(key)) byUuid.set(key, []);
      byUuid.get(key).push(r);
    }
  }
  if (byUuid.size === 0) return rows;

  const ids = Array.from(byUuid.keys());
  const placeholders = ids.map(() => '?').join(',');
  let resultRows = [];
  try {
    const r = await db.executeQuery(
      ctx,
      `SELECT b.Object_UUID, fl.display_name
       FROM BuiltinFunctionIdentity b
       JOIN ref.functions_lang fl
         ON fl.function_id = b.Function_ID
        AND fl.language = ?
       WHERE b.Object_UUID IN (${placeholders})
         AND NULLIF(trim(fl.display_name), '') IS NOT NULL`,
      [lang, ...ids]
    );
    resultRows = r.rows;
  } catch (e) {
    return rows;
  }

  const norm = (v) => String(v).replace(/\s+/g, '').toLowerCase();
  for (const row of resultRows) {
    const targets = byUuid.get(String(row.Object_UUID));
    if (!targets) continue;
    const localized = String(row.display_name).trim();
    for (const t of targets) {
      if (localized && norm(localized) !== norm(t.Object_Name ?? '')) {
        t.Localized_Name = localized;
      }
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Runtime & diagnostics (fm_spec >= 2.8.0): trigger_compat, error_codes(_lang),
// feature_versions(_lang) and the extended language_constants. Every reader
// degrades on older references — compat null, lists empty — never a 500.
// ---------------------------------------------------------------------------

/**
 * Tri-state platform cell → API value: true = Yes, false = No, null = Partial
 * (conditionally supported — read the Claris page). NULL never means
 * "undocumented": a MISSING row is that case, and the callers express it by
 * `compat: null` on the whole object.
 */
function compatFromRow(row) {
  const compat = {};
  for (const p of STEP_COMPAT_PLATFORMS) {
    compat[p] = row[p] === null || row[p] === undefined ? null : Boolean(row[p]);
  }
  return compat;
}

/**
 * Trigger compatibility map (triggerId → compat) from `trigger_compat`
 * (fm_spec >= 2.8.0; same vocabulary and tri-state rule as step_compat).
 * Empty map on older references → consumers show no platform line.
 */
let triggerCompatMapCache = null;
async function getTriggerCompatMap(ctx) {
  if (triggerCompatMapCache) return triggerCompatMapCache;
  const map = new Map();
  if (db.isReferenceAttached() && (await refTableExists(ctx, 'trigger_compat'))) {
    const r = await db.executeQuery(ctx, `
      SELECT trigger_id, pro, server, go, webdirect, cloud, dataapi, cwp
      FROM ref.trigger_compat
    `);
    for (const row of r.rows) map.set(Number(row.trigger_id), compatFromRow(row));
  }
  triggerCompatMapCache = map;
  return map;
}

/** Claris help slug of a trigger page = the lower-cased event name (verified for all 26). */
function triggerSlug(eventName) {
  return String(eventName || '').toLowerCase();
}

function mapTriggerRow(row, compatMap, language) {
  const id = Number(row.trigger_id);
  const slug = triggerSlug(row.event_name);
  return {
    triggerId:             id,
    eventName:             row.event_name,
    level:                 row.level,
    label:                 row.event_label || row.event_name,
    parameterCapable:      Boolean(row.parameter_capable),
    hasParameterFieldAttr: Boolean(row.has_parameter_field_attr),
    sinceVersion:          row.since_version || null,
    sinceVersionNum:       row.since_version_num == null ? null : Number(row.since_version_num),
    compat:                compatMap.get(id) || null,
    urlSlug:               slug,
    helpUrl:               `https://help.claris.com/${mirrorLangDir(language)}/pro-help/content/${slug}.html`,
    localHelpUrl:          buildLocalHelpUrl('triggers', language, slug),
  };
}

/**
 * All 26 script triggers with the label of ONE language, since-version and
 * platform compatibility. Empty list on references without script_triggers.
 */
async function listTriggers(ctx, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  const cacheKey = `triggers-list:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);
  if (!(await refTableExists(ctx, 'script_triggers'))) {
    metaCache.set(cacheKey, []);
    return [];
  }
  const hasLang = await refTableExists(ctx, 'script_triggers_lang');
  const r = await db.executeQuery(ctx, `
    SELECT t.trigger_id, t.level, t.event_name, t.parameter_capable, t.has_parameter_field_attr,
           t.since_version, t.since_version_num,
           ${hasLang ? 'l.event_label' : 'NULL AS event_label'}
    FROM ref.script_triggers t
    ${hasLang ? 'LEFT JOIN ref.script_triggers_lang l ON l.trigger_id = t.trigger_id AND l.language = ?' : ''}
    ORDER BY t.trigger_id
  `, hasLang ? [language] : []);
  const compatMap = await getTriggerCompatMap(ctx);
  const triggers = r.rows.map((row) => mapTriggerRow(row, compatMap, language));
  metaCache.set(cacheKey, triggers);
  return triggers;
}

/**
 * One trigger by slot id or event name (case-insensitive), with the labels of
 * ALL languages. null when unknown or on references without script_triggers.
 */
async function getTriggerDetail(ctx, idOrName, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  if (!(await refTableExists(ctx, 'script_triggers'))) return null;
  const needle = String(idOrName || '').trim();
  const byId = /^\d+$/.test(needle);
  const r = await db.executeQuery(ctx, `
    SELECT trigger_id, level, event_name, parameter_capable, has_parameter_field_attr,
           since_version, since_version_num
    FROM ref.script_triggers
    WHERE ${byId ? 'trigger_id = ?' : 'lower(event_name) = lower(?)'}
    LIMIT 1
  `, [byId ? Number(needle) : needle]);
  if (r.rows.length === 0) return null;
  const base = r.rows[0];
  let labels = [];
  if (await refTableExists(ctx, 'script_triggers_lang')) {
    const l = await db.executeQuery(ctx, `
      SELECT language, event_label FROM ref.script_triggers_lang
      WHERE trigger_id = ? ORDER BY language
    `, [Number(base.trigger_id)]);
    labels = l.rows.map((row) => ({ language: row.language, label: row.event_label }));
  }
  const compatMap = await getTriggerCompatMap(ctx);
  const own = labels.find((x) => x.language === language);
  return {
    ...mapTriggerRow({ ...base, event_label: own ? own.label : null }, compatMap, language),
    labels,
  };
}

/**
 * Error codes with the message of ONE language (EN text as fallback and
 * always as `messageEn`). Cached per language; the optional `q` filters the
 * cached list: an integer matches the span (`BETWEEN code_from AND code_to`),
 * any other text matches message / code text case-insensitively.
 * Empty list on references without error_codes (fm_spec < 2.8.0).
 */
async function listErrorCodes(ctx, lang, q) {
  assertAttached();
  const language = resolveStepLang(lang);
  const cacheKey = `error-codes:${language}`;
  let rows = metaCache.get(cacheKey);
  if (!rows) {
    rows = [];
    if (await refTableExists(ctx, 'error_codes')) {
      const hasLang = await refTableExists(ctx, 'error_codes_lang');
      const r = await db.executeQuery(ctx, `
        SELECT e.code_from, e.code_to, e.code_text, e.scope, e.message_en,
               ${hasLang ? 'l.message' : 'NULL AS message'}
        FROM ref.error_codes e
        ${hasLang ? 'LEFT JOIN ref.error_codes_lang l ON l.code_from = e.code_from AND l.language = ?' : ''}
        ORDER BY e.code_from
      `, hasLang ? [language] : []);
      rows = r.rows.map((row) => ({
        codeFrom:  Number(row.code_from),
        codeTo:    Number(row.code_to),
        codeText:  row.code_text,
        scope:     row.scope,
        message:   row.message || row.message_en,
        messageEn: row.message_en,
      }));
    }
    metaCache.set(cacheKey, rows);
  }
  return filterErrorCodes(rows, q);
}

/** Pure filter over a mapped error-code list (unit-tested; see listErrorCodes). */
function filterErrorCodes(rows, q) {
  const needle = q == null ? '' : String(q).trim();
  if (!needle) return rows;
  if (/^-?\d+$/.test(needle)) {
    const n = Number(needle);
    return rows.filter((e) => n >= e.codeFrom && n <= e.codeTo);
  }
  const lc = needle.toLowerCase();
  return rows.filter((e) => e.codeText.includes(needle)
    || (e.message || '').toLowerCase().includes(lc)
    || (e.messageEn || '').toLowerCase().includes(lc));
}

/** Pure span lookup (unit-tested): the row whose span contains `code`, else null. */
function findErrorCode(rows, code) {
  const n = Number(code);
  if (!Number.isInteger(n)) return null;
  return rows.find((e) => n >= e.codeFrom && n <= e.codeTo) || null;
}

/** One error code by number: exact code or the range it falls into (5123 → 5000-5499). */
async function getErrorCode(ctx, code, lang) {
  const rows = await listErrorCodes(ctx, lang, null);
  return findErrorCode(rows, code);
}

/**
 * Features with their introduction version (feature_versions, fm_spec >= 2.8.0),
 * localized label of ONE language with EN fallback. Empty list on older builds.
 */
async function listFeatureVersions(ctx, lang) {
  assertAttached();
  const language = resolveStepLang(lang);
  const cacheKey = `feature-versions:${language}`;
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);
  let rows = [];
  if (await refTableExists(ctx, 'feature_versions')) {
    const hasLang = await refTableExists(ctx, 'feature_versions_lang');
    const r = await db.executeQuery(ctx, `
      SELECT f.feature_id, f.feature_en, f.version_introduced, f.version_num, f.feature_key,
             ${hasLang ? 'l.feature_label' : 'NULL AS feature_label'}
      FROM ref.feature_versions f
      ${hasLang ? 'LEFT JOIN ref.feature_versions_lang l ON l.feature_id = f.feature_id AND l.language = ?' : ''}
      ORDER BY f.feature_id
    `, hasLang ? [language] : []);
    rows = r.rows.map((row) => ({
      featureId:         Number(row.feature_id),
      feature:           row.feature_label || row.feature_en,
      featureEn:         row.feature_en,
      versionIntroduced: row.version_introduced,
      versionNum:        Number(row.version_num),
      featureKey:        row.feature_key || null,
    }));
  }
  metaCache.set(cacheKey, rows);
  return rows;
}

/**
 * language_constants (+ used_with/source since fm_spec 2.8.0). `usedWith` is
 * the list of canonical function names the constant is a parameter value of
 * (Get functions by their canonical name, e.g. RecordID) — the only safe way
 * to classify a free token: Lower/Higher are lookup constants AND Lower is a
 * function. Older references deliver the three base columns only.
 */
async function listLanguageConstants(ctx) {
  assertAttached();
  const cacheKey = 'language-constants';
  if (metaCache.has(cacheKey)) return metaCache.get(cacheKey);
  let rows = [];
  if (await refTableExists(ctx, 'language_constants')) {
    const hasUsedWith = await refColumnExists(ctx, 'language_constants', 'used_with');
    const r = await db.executeQuery(ctx, `
      SELECT name, constant_type, canonical_name,
             ${hasUsedWith ? 'used_with, source' : 'NULL AS used_with, NULL AS source'}
      FROM ref.language_constants
      ORDER BY constant_type, name
    `);
    rows = r.rows.map((row) => ({
      name:          row.name,
      constantType:  row.constant_type,
      canonicalName: row.canonical_name,
      usedWith:      row.used_with ? String(row.used_with).split(',').map((x) => x.trim()).filter(Boolean) : [],
      source:        row.source || null,
    }));
  }
  metaCache.set(cacheKey, rows);
  return rows;
}

module.exports = {
  clearCaches,
  // Sprachen
  resolveStepLang,
  resolveFunctionLang,
  isStepLang,
  isFunctionLang,
  // Kategorien
  getStepCategories,
  getFunctionCategories,
  // Steps
  listSteps,
  getStepDetail,
  getStepMetaMap,
  findStepBySlugOrId,
  suggestStepSlugs,
  // Functions
  listFunctions,
  getFunctionDetail,
  findFunctionByNameOrId,
  suggestFunctionNames,
  // Reverse-Lookup
  lookupToken,
  enrichFunctionTokens,
  enrichBuiltinLocalizedNames,
  // Script-Trigger-Referenz
  getScriptTriggerEventMap,
  getScriptTriggerEventLabels,
  // Runtime & diagnostics (fm_spec >= 2.8.0)
  getTriggerCompatMap,
  listTriggers,
  getTriggerDetail,
  listErrorCodes,
  getErrorCode,
  listFeatureVersions,
  listLanguageConstants,
  compatFromRow,
  filterErrorCodes,
  findErrorCode,
  // Help-URL
  buildLocalHelpUrl,
  mirrorLangDir,
  buildDocsEntryRef,
  // Build-Info
  getBuildMeta,
  // fm-spec Schema-Viewer
  getReferenceMeta,
  getStepAllLangs,
  getStepGrammar,
  getShapeCoverages,
  resolveShapeCoverage,
};
