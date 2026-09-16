const db = require('../config/database');
const { createError } = require('../middleware/error-handler');
const { buildWhereClause, buildGroupByClause } = require('../utils/query-builder');
const environment = require('../config/environment');
const { OBJECT_TYPE_MAP, DETAIL_TEMPLATE_MAP, FOLDER_PSEUDO_TYPES, PSEUDO_TOKEN_TYPES } = require('../config/constants');
const aggregations = require('./aggregations');

/**
 * Resolve a possibly-pseudo Object_Type into a SQL filter fragment + params.
 * For Folder-Pseudo-Types ('ScriptFolder', 'LayoutFolder') the filter constrains
 * Object_Type='Folder' AND Source_Table=<mapped>. For all other types it's a plain
 * Object_Type=? filter.
 */
function buildTypeFilter(dbType) {
  if (FOLDER_PSEUDO_TYPES[dbType]) {
    return {
      sql: 'oc.Object_Type = ? AND oc.Source_Table = ?',
      sqlNoAlias: 'Object_Type = ? AND Source_Table = ?',
      params: ['Folder', FOLDER_PSEUDO_TYPES[dbType]],
    };
  }
  return {
    sql: 'oc.Object_Type = ?',
    sqlNoAlias: 'Object_Type = ?',
    params: [dbType],
  };
}
const templateService = require('./template.service');

/**
 * Object Service
 * Handles queries to ObjectCatalog table
 */

/**
 * Convert BigInt values in object to Numbers for JSON serialization
 */
function convertBigInts(obj) {
  if (Array.isArray(obj)) {
    return obj.map(convertBigInts);
  } else if (obj !== null && typeof obj === 'object') {
    const converted = {};
    for (const [key, value] of Object.entries(obj)) {
      converted[key] = typeof value === 'bigint' ? Number(value) : convertBigInts(value);
    }
    return converted;
  }
  return obj;
}

/**
 * Clone-aware object resolution against ObjectCatalog.
 *
 * Geklonte/modulare FileMaker-Dateien teilen interne Objekt-UUIDs:
 * eine UUID ist nicht mehr global eindeutig. Vertrag (Graceful Downgrade):
 *   - file gesetzt         → WHERE Object_UUID=? AND File_Name=?  (eindeutig pro Datei)
 *   - file leer, 1 Treffer → Treffer (bare UUID bleibt gültig, solange eindeutig)
 *   - file leer, >1 Treffer → AMBIGUOUS_UUID (409) + matched_files, statt stillem rows[0]
 *   - 0 Treffer            → OBJECT_NOT_FOUND (404)
 *
 * `columns` MUSS File_Name enthalten (für die matched_files-Liste). Liefert das
 * rohe Query-Result; rows[0] ist garantiert eindeutig aufgelöst.
 *
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {string} uuid
 * @param {string} [file] - optionaler File_Name zur Disambiguierung
 * @param {string} [columns='*'] - SELECT-Spaltenliste (muss File_Name enthalten)
 * @returns {Promise<{rows: Array, meta: Object}>}
 */
async function resolveByUUID(ctx, uuid, file, columns = '*') {
  const where = file ? 'Object_UUID = ? AND File_Name = ?' : 'Object_UUID = ?';
  const params = file ? [uuid, file] : [uuid];
  const result = await db.executeQuery(ctx, `SELECT ${columns} FROM ObjectCatalog WHERE ${where}`, params);

  if (result.rows.length === 0) {
    throw createError(
      'OBJECT_NOT_FOUND',
      file
        ? `Object with UUID '${uuid}' not found in file '${file}'`
        : `Object with UUID '${uuid}' not found`,
      file ? { uuid, file } : { uuid }
    );
  }

  if (!file && result.rows.length > 1) {
    const matched_files = [...new Set(result.rows.map((r) => r.File_Name))].sort();
    throw createError(
      'AMBIGUOUS_UUID',
      `UUID '${uuid}' exists in ${matched_files.length} files (cloned/modular solution); ` +
        `add ?file=<File_Name> to disambiguate`,
      { uuid, matched_files }
    );
  }

  return result;
}

/**
 * Synthetic replacement UUIDs from duplicate healing (schema 1.19.0) are
 * md5 hex — 32 chars WITHOUT dashes — and thus formally distinguishable
 * from native 8-4-4-4-12 UUIDs.
 */
const SYNTHETIC_UUID_RE = /^[0-9a-fA-F]{32}$/;

/**
 * Resolve healing metadata for a synthetic (healed) UUID.
 *
 * Looks up the original UUID in DuplicateAbsorptionDetails (the twin with the
 * smallest internal ID kept the original; further twins got a synthetic
 * replacement). Older catalogs may not have the table — then the object is
 * still flagged as synthetic, but without a resolvable original.
 *
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {string} uuid - synthetic Object_UUID (Healed_UUID in the mapping)
 * @param {string} fileName - File_Name of the object
 * @returns {Promise<Object>} healing info { is_synthetic, original_uuid, discriminator }
 */
async function getHealingInfo(ctx, uuid, fileName) {
  try {
    const result = await db.executeQuery(
      ctx,
      `SELECT Object_UUID, Discriminator
       FROM DuplicateAbsorptionDetails
       WHERE Healed_UUID = ? AND File_Name = ?
       LIMIT 1`,
      [uuid, fileName]
    );
    const row = result.rows[0];
    return {
      is_synthetic: true,
      original_uuid: row ? row.Object_UUID : null,
      discriminator: row ? row.Discriminator : null,
    };
  } catch {
    // Pre-1.19.0 catalogs have no DuplicateAbsorptionDetails table.
    return { is_synthetic: true, original_uuid: null, discriminator: null };
  }
}

/**
 * Get object by UUID (clone-aware, see resolveByUUID).
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {string} uuid - Object UUID
 * @param {string} [file] - optional File_Name to disambiguate clone duplicates
 * @returns {Promise<Object>} Object data
 */
async function getByUUID(ctx, uuid, file) {
  try {
    const result = await resolveByUUID(ctx, uuid, file);
    const data = convertBigInts(result.rows[0]);

    // Duplicate healing: synthetic replacement UUIDs get a `healing` field
    // pointing back to the (ambiguous) original UUID. Native UUIDs stay
    // untouched — no extra field, no extra query.
    if (SYNTHETIC_UUID_RE.test(data.Object_UUID)) {
      data.healing = await getHealingInfo(ctx, data.Object_UUID, data.File_Name);
    }

    return {
      data,
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, file ? { uuid, file } : { uuid });
  }
}

/**
 * List objects by type with optional filters
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {Object} filters - Filter options
 * @param {string} filters.type
 * @param {string} [filters.file]
 * @param {number} [filters.limit]
 * @param {boolean} [filters.withUsage]   - Pseudo-Token-Erweiterung: usage_count Spalte
 * @param {boolean} [filters.withCategory] - Pseudo-Token-Erweiterung: category/category_id Spalten
 * @param {string|string[]} [filters.category] - Category-Filter (kommasepariert oder Array)
 * @param {string} [filters.sort]         - 'usage' | 'name' | 'category'
 * @returns {Promise<Object>} List of objects with metadata
 */
async function listObjects(ctx, filters) {
  try {
    const {
      type,
      file,
      limit = environment.api.defaultLimit,
      withUsage = false,
      withCategory = false,
      category,
      sort,
    } = filters;

    // Normalize type to PascalCase for database
    const dbType = OBJECT_TYPE_MAP[type] || type;

    // Categories als Array normalisieren (akzeptiert "A,B,C" oder Array).
    const categories = normalizeCategories(category);

    // Wenn der Typ eine Aggregations-Erweiterung verlangt, gehen wir über den
    // Aggregations-Builder. Sonst klassischer Pfad mit Reference_Count.
    const wantsAggregation =
      withUsage || withCategory || categories.length > 0 || (sort && PSEUDO_TOKEN_TYPES.includes(dbType));

    const supportsAggregation = aggregations.USAGE_TYPES.includes(dbType);

    if (wantsAggregation && supportsAggregation) {
      // Validierung: PluginComponent kennt keine Category-Schicht über sich.
      if (dbType === 'PluginComponent') {
        if (withCategory || categories.length > 0) {
          throw createError(
            'VALIDATION_ERROR',
            "PluginComponent has no parent category — '?withCategory' / '?category' are not supported.",
            { type, withCategory, category }
          );
        }
      }
      const { sql, params } = aggregations.buildListQuery(dbType, {
        file,
        withUsage,
        withCategory,
        categories,
        sort,
        limit,
        refAttached: db.isReferenceAttached(),
      });
      const result = await db.executeQuery(ctx, sql, params);
      return {
        data: convertBigInts(result.rows),
        meta: result.meta,
      };
    }

    // Standardpfad — bestehend, mit Reference_Count.
    const typeFilter = buildTypeFilter(dbType);

    let sql = `
      SELECT
        oc.*,
        COUNT(ol.Target_UUID) as Reference_Count
      FROM ObjectCatalog oc
      LEFT JOIN ObjectLinks ol ON oc.Object_UUID = ol.Source_UUID
        AND ol.Link_Type = 'operational'
      WHERE ${typeFilter.sql}
    `;

    const params = [...typeFilter.params];

    if (file) {
      sql += ' AND oc.File_Name = ?';
      params.push(file);
    }

    sql += `
      GROUP BY oc.Object_UUID, oc.Object_Type, oc.Object_Name,
               oc.File_Name, oc.Source_Table, oc.Object_ID
      ORDER BY oc.Object_Name
    `;

    if (limit > 0) {
      sql += ' LIMIT ?';
      params.push(limit);
    }

    const result = await db.executeQuery(ctx, sql, params);

    return {
      data: convertBigInts(result.rows),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, filters);
  }
}

/**
 * Normalisiert den Category-Parameter zu einem String-Array.
 * Akzeptiert: undefined/null → []; String "A,B,C" → ['A','B','C']; Array → unverändert.
 */
function normalizeCategories(category) {
  if (!category) return [];
  if (Array.isArray(category)) return category.filter(Boolean);
  if (typeof category === 'string') {
    return category.split(',').map(s => s.trim()).filter(Boolean);
  }
  return [];
}

/**
 * GET /api/list/categories — Filter-Pillen-Datenbasis.
 * Liefert pro Category eines
 * Pseudo-Token-Typs { category, token_count, total_usage }, sortiert nach
 * total_usage desc.
 */
async function listCategorySummary(ctx, { type, file }) {
  try {
    const dbType = OBJECT_TYPE_MAP[type] || type;
    if (!PSEUDO_TOKEN_TYPES.includes(dbType)) {
      throw createError(
        'VALIDATION_ERROR',
        `Type '${dbType}' has no category schema (only PSEUDO_TOKEN_TYPES are supported).`,
        { type, supported: PSEUDO_TOKEN_TYPES }
      );
    }
    const { sql, params } = aggregations.buildCategorySummaryQuery(
      dbType,
      db.isReferenceAttached(),
      file
    );
    const result = await db.executeQuery(ctx, sql, params);
    return {
      data: convertBigInts(result.rows),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, { type, file });
  }
}

/**
 * Count objects with optional grouping
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {Object} options - Count options {type, file, group_by}
 * @returns {Promise<Object>} Count results with metadata
 */
async function countObjects(ctx, options) {
  try {
    const { type, file, group_by } = options;

    // Normalize type to PascalCase for database
    const dbType = type ? (OBJECT_TYPE_MAP[type] || type) : null;

    const { clause: groupByClause, columns } = buildGroupByClause(group_by);

    let sql;
    const params = [];

    if (columns.length > 0) {
      // Grouped count
      sql = `
        SELECT ${columns.join(', ')}, COUNT(*) as count
        FROM ObjectCatalog
      `;

      const conditions = [];
      // Exclude DDR-specific object types from count
      conditions.push("Object_Type NOT IN ('DDR_ScriptStep', 'DDR_Calculation')");

      if (dbType) {
        const typeFilter = buildTypeFilter(dbType);
        conditions.push(typeFilter.sqlNoAlias);
        params.push(...typeFilter.params);
      }
      if (file) {
        conditions.push('File_Name = ?');
        params.push(file);
      }

      if (conditions.length > 0) {
        sql += ' WHERE ' + conditions.join(' AND ');
      }

      sql += ` ${groupByClause} ORDER BY ${columns.join(', ')}`;
    } else {
      // Simple count
      sql = 'SELECT COUNT(*) as count FROM ObjectCatalog';

      const conditions = [];
      // Exclude DDR-specific object types from count
      conditions.push("Object_Type NOT IN ('DDR_ScriptStep', 'DDR_Calculation')");

      if (dbType) {
        const typeFilter = buildTypeFilter(dbType);
        conditions.push(typeFilter.sqlNoAlias);
        params.push(...typeFilter.params);
      }
      if (file) {
        conditions.push('File_Name = ?');
        params.push(file);
      }

      if (conditions.length > 0) {
        sql += ' WHERE ' + conditions.join(' AND ');
      }
    }

    const result = await db.executeQuery(ctx, sql, params);

    return {
      data: convertBigInts(result.rows),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, options);
  }
}

/**
 * COALESCE-Ausdruck für den vollständigen Step_Text einer ScriptStep-Reihe.
 * Wird sowohl in SELECT (Anzeige) als auch in WHERE (Volltextsuche) verwendet.
 * Quellen-Priorität: DDR_ScriptSteps.Step_Text → Comment aus Parameters_XML
 * → generischer Step_Name. Identisch zu SCRIPTSTEP_SEARCH_CTE (siehe unten).
 */
const STEP_TEXT_EXPR = `
  COALESCE(
    ddr.Step_Text,
    CASE WHEN s.Step_Name = '# (comment)'
         THEN NULLIF('# ' || regexp_extract(s.Parameters_XML, '<Comment value="([^"]*)"', 1), '# ')
         ELSE NULL
    END,
    s.Step_Name
  )
`;

/**
 * ValueList-Volltext-Branch: findet Wertelisten, deren NAME **oder** deren
 * hinterlegte Custom-Values auf das Suchmuster passen. Bei einem Wert-Treffer
 * werden die passenden Werte (max. 20) in `Matched_Values` aggregiert, damit
 * das Frontend unter dem Werteliste-Namen anzeigen kann, WELCHER Wert getroffen
 * hat (analog zum Step_Text-Breadcrumb bei ScriptSteps).
 *
 * Custom_Values liegt im Export als EIN newline-verbundenes Array-Element →
 * pro Zeile via string_split(chr(10)) entpacken; trailing \r (CRLF) strippen.
 *
 * Zwei `?`-Parameter in Textreihenfolge:
 *   1. Wert-Match (im LATERAL-Aggregat)
 *   2. Name-Match (Object_Name ILIKE)
 * Der Aufrufer hängt bei Bedarf `AND oc.File_Name = ?` an.
 */
const VALUELIST_SEARCH_BRANCH = `
  SELECT
    oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name,
    oc.Source_Table, oc.Object_ID,
    CAST(NULL AS VARCHAR) AS Step_Text,
    CAST(NULL AS VARCHAR) AS Script_Name,
    CAST(NULL AS INTEGER) AS Step_Index,
    m.Matched_Values
  FROM ObjectCatalog oc
  LEFT JOIN LATERAL (
    SELECT string_agg(mv.val, ', ') AS Matched_Values
    FROM (
      SELECT rtrim(t.val, chr(13)) AS val
      FROM OptionsForValueLists ovl,
           LATERAL unnest(
             flatten(list_transform(ovl.Custom_Values, lambda x: string_split(x, chr(10))))
           ) AS t(val)
      WHERE ovl.VL_UUID = oc.Object_UUID
        AND ovl.File_Name = oc.File_Name
        AND ovl.Custom_Values IS NOT NULL
        AND rtrim(t.val, chr(13)) ILIKE ?
      LIMIT 20
    ) mv
  ) m ON TRUE
  WHERE oc.Object_Type = 'ValueList'
    AND (oc.Object_Name ILIKE ? OR m.Matched_Values IS NOT NULL)
`;

/**
 * Baut den Standard-Such-SQL und die Parameter-Liste.
 *
 * Vier Pfade je nach Filter-Konstellation:
 *  - dbType === 'ValueList': dedizierter Wert-Branch (Name **oder** Custom-Value
 *    matcht, mit Matched_Values in der Response).
 *  - dbType sonst gesetzt (≠ ScriptStep): plain ObjectCatalog-Match auf Object_Name.
 *  - dbType nicht gesetzt, name selektiv: UNION ALL (non-ScriptStep/ValueList via
 *    Object_Name) + (ValueList via Name/Wert) + (ScriptStep via Step_Text).
 *    Alle Branches schließen DDR-Internals aus.
 *  - dbType nicht gesetzt, name = '%'-only: nur non-ScriptStep (inkl. ValueList
 *    per Name) — Initial-Load, keine 196k Steps / Wert-Scans in der Default-Liste.
 *
 * Alle Branches liefern dieselbe Spaltenmenge (…, Step_Text, Script_Name,
 * Step_Index, Matched_Values), damit die UNION-Zweige typkompatibel sind.
 *
 * @param {Object} opts - {name, dbType, file, limit, offset, countOnly?}
 * @returns {{sql: string, params: Array}}
 */
/**
 * BuiltinFunction-Branch über die LOKALISIERTEN Schreibweisen.
 *
 * Warum es ihn braucht: seit Katalog-Schema 1.32.0 trägt ein Built-in nur noch
 * seinen kanonischen englischen Namen (`Get(PageNumber)`), weil das seine
 * Identität ist. Eine Suche nach `Seitennummer` fand ihn damit nicht mehr —
 * und das ist für eine deutschsprachige Lösung der Normalfall, nicht der
 * Randfall (gemessen: 126 von 140 Get-Parameter-Schreibweisen dort lokalisiert).
 * Verwendungen in Script-Steps blieben über den Step_Text-Branch auffindbar,
 * alle anderen (Feld, CustomFunction, Menü, Layoutobjekt) hatten den
 * Funktionsknoten als einzigen Einstieg — genau den.
 *
 * `v_builtin_token_lookup` ist die beim Import gebaute Abbildung
 * Schreibweise → Knoten (alle Referenzsprachen, beide Namensräume). Gesucht
 * wird in `Name_Decoded`; die entity-kodierte Achse derselben View liefert
 * dieselbe dekodierte Schreibweise und fällt per DISTINCT zusammen.
 *
 * `Matched_Values` trägt die Schreibweise(n), die getroffen haben — dasselbe
 * Muster wie der Werteliste-Branch: der Treffer erklärt sich selbst, statt dass
 * ein englischer Name ohne ersichtlichen Grund in der Liste steht.
 *
 * Dedup: der Namens-Branch findet Built-ins schon per `Object_Name ILIKE`.
 * Dieser Branch schließt solche Zeilen aus, sonst käme der Knoten doppelt.
 *
 * Drei `?`-Parameter in Textreihenfolge: 1. Schreibweisen-Match,
 * 2. Namens-Match (Ausschluss), 3./optional File-Filter beim Aufrufer.
 */
const BUILTIN_LOCALIZED_SEARCH_BRANCH = `
  SELECT
    oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name,
    oc.Source_Table, oc.Object_ID,
    CAST(NULL AS VARCHAR) AS Step_Text,
    CAST(NULL AS VARCHAR) AS Script_Name,
    CAST(NULL AS INTEGER) AS Step_Index,
    m.Matched_Values
  FROM ObjectCatalog oc
  JOIN LATERAL (
    SELECT string_agg(DISTINCT l.Name_Decoded, ', ') AS Matched_Values
    FROM v_builtin_token_lookup l
    WHERE l.Object_UUID = oc.Object_UUID
      AND l.Name_Decoded ILIKE ?
  ) m ON m.Matched_Values IS NOT NULL
  WHERE oc.Object_Type = 'BuiltinFunction'
    AND NOT (oc.Object_Name ILIKE ?)
`;

// Verfügbarkeit von v_builtin_token_lookup je Lösung (Katalog < Schema 1.32.0
// hat sie nicht). Einmal pro Lösung geprüft statt per Suche — und beim
// Reload geleert, weil ein Re-Import das Schema hebt.
const builtinLookupAvailable = new Map();

function clearObjectServiceCaches() {
  builtinLookupAvailable.clear();
}

/**
 * Prüft (und cached), ob die Lösung die Nachschlage-View trägt. Bewusst
 * explizit statt „SQL versuchen, bei Fehler ohne Branch wiederholen": so bleibt
 * ein echter Fehler im Branch sichtbar, statt still zu einer Suche ohne
 * lokalisierte Treffer zu degradieren.
 */
async function hasBuiltinTokenLookup(ctx) {
  const key = ctx?.solution ?? '';
  if (builtinLookupAvailable.has(key)) return builtinLookupAvailable.get(key);
  let ok = false;
  try {
    const r = await db.executeQuery(
      ctx,
      "SELECT 1 AS ok FROM duckdb_views() WHERE view_name = 'v_builtin_token_lookup' LIMIT 1"
    );
    ok = r.rows.length > 0;
  } catch {
    ok = false;
  }
  builtinLookupAvailable.set(key, ok);
  return ok;
}

function buildSearchSql({ name, dbType, file, limit, offset, countOnly = false, builtinLocalized = false }) {
  const params = [];

  // Pfad A0: expliziter ValueList-Filter → Wert-Branch (Name ODER Custom-Value).
  if (dbType === 'ValueList') {
    let inner = VALUELIST_SEARCH_BRANCH;
    params.push(name, name); // 1. Wert-Match, 2. Name-Match
    if (file) {
      inner += ' AND oc.File_Name = ?';
      params.push(file);
    }
    if (countOnly) {
      return { sql: `SELECT COUNT(*) AS count FROM (${inner}) c`, params };
    }
    let sql = `SELECT * FROM (${inner}) c ORDER BY Object_Name`;
    if (limit > 0) {
      sql += ' LIMIT ? OFFSET ?';
      params.push(limit, offset);
    }
    return { sql, params };
  }

  // Pfad A: expliziter Type-Filter (nicht ScriptStep/ValueList — oben abgefangen)
  if (dbType) {
    const typeFilter = buildTypeFilter(dbType);
    let inner = `
      SELECT Object_UUID, Object_Type, Object_Name, File_Name, Source_Table, Object_ID,
             CAST(NULL AS VARCHAR) AS Step_Text,
             CAST(NULL AS VARCHAR) AS Script_Name,
             CAST(NULL AS INTEGER) AS Step_Index,
             CAST(NULL AS VARCHAR) AS Matched_Values
      FROM ObjectCatalog
      WHERE Object_Name ILIKE ?
        AND Object_Type NOT IN ('DDR_ScriptStep', 'DDR_Calculation')
        AND ${typeFilter.sqlNoAlias}
    `;
    params.push(name, ...typeFilter.params);
    if (file) {
      inner += ' AND File_Name = ?';
      params.push(file);
    }
    // Typ-Filter BuiltinFunction: die lokalisierten Schreibweisen mitsuchen,
    // sonst findet gerade der explizit auf Built-ins eingeschränkte Blick die
    // deutsche Schreibweise nicht. Built-ins sind lösungsunabhängig
    // (File_Name IS NULL), der File-Filter trifft sie ohnehin nie — dann bleibt
    // der Branch weg, statt einen Filter zu unterlaufen.
    if (builtinLocalized && dbType === 'BuiltinFunction' && !file) {
      inner = `(${inner}) UNION ALL (${BUILTIN_LOCALIZED_SEARCH_BRANCH})`;
      params.push(name, name);
    }
    if (countOnly) {
      return { sql: `SELECT COUNT(*) AS count FROM (${inner}) c`, params };
    }
    let sql = `SELECT * FROM (${inner}) c ORDER BY Object_Name`;
    if (limit > 0) {
      sql += ' LIMIT ? OFFSET ?';
      params.push(limit, offset);
    }
    return { sql, params };
  }

  // Pfad B/C: kein Type-Filter
  // Non-ScriptStep-Branch (Object_Name-Match). ScriptSteps immer ausgeschlossen;
  // ValueLists nur im Volltext-Modus (dort übernimmt sie der Wert-Branch unten,
  // sonst käme jede Werteliste doppelt) — im Wildcard-Modus bleiben sie hier.
  // Calculation (Schema 1.22.0) wie ScriptStep: High-Cardinality-Typ mit
  // GENERIERTEN Namen ('<Owner> › <Rolle>') — jede Owner-Namenssuche träfe sonst
  // zusätzlich alle Calc-Zeilen des Owners (Dubletten-Flut). Per explizitem
  // Typ-Filter (Pfad A) bleibt der Typ voll such-/listbar (bewusster Entscheid).
  const isWildcardOnly = !name.replace(/%/g, '').trim();
  const nonStepExcluded = isWildcardOnly
    ? "'DDR_ScriptStep', 'DDR_Calculation', 'ScriptStep', 'Calculation'"
    : "'DDR_ScriptStep', 'DDR_Calculation', 'ScriptStep', 'Calculation', 'ValueList'";
  let nonStepInner = `
    SELECT Object_UUID, Object_Type, Object_Name, File_Name, Source_Table, Object_ID,
           CAST(NULL AS VARCHAR) AS Step_Text,
           CAST(NULL AS VARCHAR) AS Script_Name,
           CAST(NULL AS INTEGER) AS Step_Index,
           CAST(NULL AS VARCHAR) AS Matched_Values
    FROM ObjectCatalog
    WHERE Object_Name ILIKE ?
      AND Object_Type NOT IN (${nonStepExcluded})
  `;
  params.push(name);
  if (file) {
    nonStepInner += ' AND File_Name = ?';
    params.push(file);
  }

  // Wildcard-only ('%' bzw. nur Wildcards): ScriptStep- und ValueList-Wert-Branch
  // weglassen, sonst landen 196k Steps bzw. teure Wert-Scans in der Default-Liste.
  if (isWildcardOnly) {
    if (countOnly) {
      return { sql: `SELECT COUNT(*) AS count FROM (${nonStepInner}) c`, params };
    }
    let sql = `${nonStepInner} ORDER BY Object_Name`;
    if (limit > 0) {
      sql += ' LIMIT ? OFFSET ?';
      params.push(limit, offset);
    }
    return { sql, params };
  }

  // ValueList-Wert-Branch (Name ODER Custom-Value, mit Matched_Values)
  let vlInner = VALUELIST_SEARCH_BRANCH;
  params.push(name, name); // 1. Wert-Match, 2. Name-Match
  if (file) {
    vlInner += ' AND oc.File_Name = ?';
    params.push(file);
  }

  // ScriptStep-Branch (Step_Text-Match, mit Anreicherung der Step-Spalten)
  let stepInner = `
    SELECT
      oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name,
      oc.Source_Table, oc.Object_ID,
      ${STEP_TEXT_EXPR} AS Step_Text,
      s.Script_Name,
      s.Step_Index,
      CAST(NULL AS VARCHAR) AS Matched_Values
    FROM ObjectCatalog oc
    LEFT JOIN StepsForScripts s ON s.Step_UUID = oc.Object_UUID
    LEFT JOIN DDR_ScriptSteps ddr ON ddr.Step_UUID = oc.Object_UUID
    WHERE oc.Object_Type = 'ScriptStep'
      AND ${STEP_TEXT_EXPR} ILIKE ?
  `;
  params.push(name);
  if (file) {
    stepInner += ' AND oc.File_Name = ?';
    params.push(file);
  }

  // Built-in-Branch über die lokalisierten Schreibweisen (s. Konstante). Nur im
  // Volltext-Pfad: der Wildcard-only-Initial-Load ist oben schon zurück und
  // schließt teure Zweige bewusst aus.
  let combined = `(${nonStepInner}) UNION ALL (${vlInner}) UNION ALL (${stepInner})`;
  if (builtinLocalized) {
    combined += ` UNION ALL (${BUILTIN_LOCALIZED_SEARCH_BRANCH})`;
    params.push(name, name);
  }
  if (countOnly) {
    return { sql: `SELECT COUNT(*) AS count FROM (${combined}) c`, params };
  }
  let sql = `SELECT * FROM (${combined}) c ORDER BY Object_Name`;
  if (limit > 0) {
    sql += ' LIMIT ? OFFSET ?';
    params.push(limit, offset);
  }
  return { sql, params };
}

/**
 * Search objects by name pattern
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {Object} searchOptions - Search options {name, type, file, limit, offset}
 * @returns {Promise<Object>} Search results with metadata
 */
async function searchObjects(ctx, searchOptions) {
  try {
    const { name, type, file, limit = environment.api.defaultLimit, offset = 0 } = searchOptions;

    // Normalize type to PascalCase for database
    const dbType = type ? (OBJECT_TYPE_MAP[type] || type) : null;

    // ScriptStep-Spezialpfad: Volltextsuche im DDR_Step_Text + Comment-Inhalt
    // aus Parameters_XML, mit Script_Name/Step_Index/Step_Text in der Response.
    if (dbType === 'ScriptStep') {
      return await searchScriptSteps(ctx, { name, file, limit, offset });
    }

    // Suchstrategie (ScriptStep-Filtering):
    //   1. dbType === 'ScriptStep'  → searchScriptSteps (oben abgefangen).
    //   2. dbType ist ein anderer Typ → ObjectCatalog mit Type-Filter; ScriptSteps
    //      kommen hier nicht vor.
    //   3. dbType === 'ValueList'    → buildSearchSql Wert-Branch (Name ODER
    //      Custom-Value, mit Matched_Values in der Response).
    //   4. Kein dbType-Filter        → UNION ALL:
    //        a) Non-ScriptStep/ValueList mit Object_Name-Match.
    //        b) ValueList mit Name- ODER Custom-Value-Match (Matched_Values).
    //        c) ScriptStep mit Step_Text-Match (Skriptname-Treffer würden
    //           sonst die Trefferliste überschwemmen — der Script-Treffer
    //           selbst erscheint ja schon in (a)).
    //      Wildcard-only-Suche ('%') überspringt (b)+(c), weil dann sonst 196k
    //      Steps bzw. teure Wert-Scans in die Initial-Liste flössen (ValueLists
    //      erscheinen im Wildcard-Modus per Name über (a)).
    // Lokalisierte Built-in-Schreibweisen mitsuchen, wenn der Katalog die
    // Nachschlage-View trägt (Schema 1.32.0+). Wildcard-only-Suchen brauchen
    // den Zweig nicht — buildSearchSql lässt ihn dort weg.
    const builtinLocalized = await hasBuiltinTokenLookup(ctx);
    const { sql, params } = buildSearchSql({ name, dbType, file, limit, offset, builtinLocalized });

    const result = await db.executeQuery(ctx, sql, params);

    return {
      data: convertBigInts(result.rows),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, searchOptions);
  }
}

/**
 * ScriptStep-Spezial-CTE: löst den vollen Klartext einer Skriptzeile auf.
 * Priorität:
 *   1. DDR_ScriptSteps.Step_Text  (FileMaker 21+ DDR_INFO — fertig gerendert
 *      mit Parametern/Formeln/Referenzen)
 *   2. "# " + Comment-value aus StepsForScripts.Parameters_XML  (Fallback für
 *      Comment-Steps ohne DDR-Text)
 *   3. StepsForScripts.Step_Name  (generischer Step-Typ als Last-Resort)
 *
 * Liefert außerdem Script_Name und Step_Index, damit das Frontend einen
 * "Datei ▸ Skript ▸ Step N"-Breadcrumb unter dem Step-Text anzeigen kann.
 */
const SCRIPTSTEP_SEARCH_CTE = `
  WITH script_steps AS (
    SELECT
      oc.Object_UUID,
      oc.Object_Type,
      oc.Object_Name,
      oc.File_Name,
      oc.Source_Table,
      oc.Object_ID,
      COALESCE(
        ddr.Step_Text,
        CASE WHEN s.Step_Name = '# (comment)'
             THEN NULLIF('# ' || regexp_extract(s.Parameters_XML, '<Comment value="([^"]*)"', 1), '# ')
             ELSE NULL
        END,
        s.Step_Name
      ) AS Step_Text,
      s.Script_Name,
      s.Step_Index
    FROM ObjectCatalog oc
    LEFT JOIN StepsForScripts s ON s.Step_UUID = oc.Object_UUID
    LEFT JOIN DDR_ScriptSteps ddr ON ddr.Step_UUID = oc.Object_UUID
    WHERE oc.Object_Type = 'ScriptStep'
  )
`;

async function searchScriptSteps(ctx, { name, file, limit, offset }) {
  // Filter NUR auf Step_Text. Object_Name enthält bei ScriptSteps auch den
  // Skriptnamen ("<Script> [<Index>] <StepType>") — wenn wir den mitdurch-
  // suchen würden, käme jeder Skriptnamen-Treffer als rauschende Step-Liste
  // zurück. Skriptnamen-Suche gehört in den Typ=Script-Filter, nicht hier.
  let sql = `${SCRIPTSTEP_SEARCH_CTE}
    SELECT *
    FROM script_steps
    WHERE Step_Text ILIKE ?`;
  const params = [name];

  if (file) {
    sql += ' AND File_Name = ?';
    params.push(file);
  }

  sql += ' ORDER BY File_Name, Script_Name, Step_Index';

  if (limit > 0) {
    sql += ' LIMIT ? OFFSET ?';
    params.push(limit, offset);
  }

  const result = await db.executeQuery(ctx, sql, params);
  return {
    data: convertBigInts(result.rows),
    meta: result.meta,
  };
}

async function countScriptSteps(ctx, { name, file }) {
  let sql = `${SCRIPTSTEP_SEARCH_CTE}
    SELECT COUNT(*) AS count
    FROM script_steps
    WHERE Step_Text ILIKE ?`;
  const params = [name];

  if (file) {
    sql += ' AND File_Name = ?';
    params.push(file);
  }

  const result = await db.executeQuery(ctx, sql, params);
  return {
    data: convertBigInts(result.rows),
    meta: result.meta,
  };
}

/**
 * Count search results by name pattern
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {Object} searchOptions - Search options {name, type, file}
 * @returns {Promise<Object>} Count result with metadata
 */
async function countSearchResults(ctx, searchOptions) {
  try {
    const { name, type, file } = searchOptions;

    // Normalize type to PascalCase for database
    const dbType = type ? (OBJECT_TYPE_MAP[type] || type) : null;

    // ScriptStep-Spezialpfad: muss denselben WHERE-Filter wie searchScriptSteps
    // verwenden, sonst weicht der Total-Count von der gepaginierten Liste ab.
    if (dbType === 'ScriptStep') {
      return await countScriptSteps(ctx, { name, file });
    }

    // Identische Filterlogik wie searchObjects (UNION ALL bei Volltextsuche
    // ohne Type-Filter). Gemeinsamer Builder, damit Count == List-Total —
    // einschliesslich des Built-in-Branches über die lokalisierten
    // Schreibweisen: ohne dasselbe Flag zählte der Count weniger als die Liste
    // zeigt.
    const builtinLocalized = await hasBuiltinTokenLookup(ctx);
    const { sql, params } = buildSearchSql({ name, dbType, file, countOnly: true, builtinLocalized });

    const result = await db.executeQuery(ctx, sql, params);

    return {
      data: convertBigInts(result.rows),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, searchOptions);
  }
}

/**
 * Subrole-Normalisierung für Referenzlisten.
 *
 * Mappt die Kanten-Subrole (DDRREF-Anker-Suffix, siehe convert_xml_02_resolve.sql)
 * auf einen locale-unabhängigen Klassen-Key im calc_kind-Vokabular der
 * CalculationsCatalog — kein zweites Vokabular. Drei Fälle:
 *   - benannte Slots → calc_kind-Klasse. `Condition_N` kollabiert bewusst zur
 *     Klasse (ein LayoutObject mit demselben Feld in Regel 1+2 bleibt EINE
 *     Aggregat-Zeile); die Regelnummern transportiert `Subrole_Detail`.
 *   - positionelle Slots → NULL: Script-Kanten tragen den numerischen
 *     Calc-Slot-Index des Steps (plus XML/XSL bei Import/Export-XSLT). Ohne
 *     Unterdrückung zerfiele die ×N-Aggregation der Script-Zeilen in
 *     bedeutungslose Slot-Zeilen.
 *   - alles andere (primary/left/Total/Part-Typen/Trigger-Events/calc_kinds/…)
 *     → Durchreichung roh. Die Anzeige-Labels im Frontend sind Politur,
 *     kein Gatekeeper — Unbekanntes wird nie verschluckt. Dazu zählt
 *     `field_entry`: die Kanten der Feld-Eingabeformel tragen seit Konverter
 *     2.30.0 den calc_kind selbst (P4 retaggt den kollidierenden DDR-Schlüssel
 *     'Hide'); `Hide` bleibt allein der Ausblendungsformel.
 * `PopoverPanel` → `popover_title` (NICHT panel_title): das Suffix hängt am
 * Popover-Titel-Calc (CalculationsCatalog: Calc_Kind_Raw='PopoverPanel' →
 * Calc_Role='popover_title'); Tab-Panel-Titel haben das eigene Raw-Kind
 * 'TabPanel' und treten als Kanten-Subrole nicht auf.
 *
 * @param {string} col - SQL-Spaltenreferenz auf die rohe Subrole (z.B. 'ol.Link_Subrole')
 * @returns {string} CASE-Ausdruck, der den Klassen-Key (oder NULL) liefert
 */
function subroleClassSql(col) {
  return `CASE
    WHEN ${col} IS NULL THEN NULL
    WHEN ${col} = 'Hide' THEN 'hide'
    WHEN starts_with(${col}, 'Condition_') THEN 'conditional_format'
    WHEN ${col} = 'Tooltip' THEN 'tooltip'
    WHEN ${col} = 'action' THEN 'button_action'
    WHEN ${col} = 'Portal' THEN 'portal_filter'
    WHEN ${col} = 'WebViewer' THEN 'web_viewer_url'
    WHEN ${col} = 'Placeholder' THEN 'placeholder'
    WHEN ${col} = 'PopoverPanel' THEN 'popover_title'
    WHEN starts_with(${col}, 'ScriptTrigger_') THEN 'script_trigger_parameter'
    WHEN ${col} = 'MBS:FM.RunScript' THEN 'mbs_runscript'
    WHEN ${col} = 'Install' THEN 'menu_install'
    WHEN regexp_full_match(${col}, '[0-9]+') OR ${col} IN ('XML', 'XSL') THEN NULL
    ELSE ${col}
  END`;
}

/**
 * Trigger-Event-Auflösung für Referenzlisten (additives Feld `Subrole_Event`).
 *
 * Zeilen, deren Roh-Subrole(s) `ScriptTrigger_<id>`-Slots tragen (Klasse
 * `script_trigger_parameter`; child/parent: einzelner Roh-Wert, all: DISTINCT-
 * aggregierte Liste in `Subrole_Detail`), bekommen die Slot-Nummern über die
 * kuratierte fm_spec-Tabelle `script_triggers` (Referenz ≥ 1.18.0) zu
 * kanonischen Event-Namen aufgelöst — als DISTINCT-Liste in Detail-Reihenfolge
 * (`'OnObjectValidate'` bzw. `'OnPanelSwitch, OnObjectValidate'`).
 *
 * Graceful-Vertrag: ohne attachte Referenz-DB oder ohne Tabelle (Consumer-DB
 * < 1.18.0) bleibt das Feld weg — exakt heutiges Verhalten, kein Fehlerpfad.
 * Teil-unauflösbare Slot-Listen lassen das Feld ebenfalls weg (lieber kein
 * Event als ein irreführend verkürztes). Die Chip-Identität (Klassenebene)
 * und alle übrigen Spalten bleiben unberührt.
 */
async function enrichSubroleEvents(ctx, rows) {
  if (!Array.isArray(rows)) return rows;
  const candidates = rows.filter((r) => r
    && r.Subrole_Class === 'script_trigger_parameter'
    && typeof r.Subrole_Detail === 'string');
  if (candidates.length === 0) return rows;

  let eventMap;
  try {
    // Lazy require + eigener try/catch: die Referenz-DB ist optional und darf
    // den Referenzen-Pfad nie brechen (REF_NOT_ATTACHED & Co. → unverändert).
    const referenceService = require('./reference.service');
    eventMap = await referenceService.getScriptTriggerEventMap(ctx);
  } catch {
    return rows;
  }
  if (!eventMap || eventMap.size === 0) return rows;

  for (const r of candidates) {
    const slots = [...r.Subrole_Detail.matchAll(/ScriptTrigger_(\d+)/g)]
      .map((m) => Number(m[1]));
    if (slots.length === 0) continue;
    const events = [];
    let complete = true;
    for (const slot of slots) {
      const event = eventMap.get(slot);
      if (!event) { complete = false; break; }
      if (!events.includes(event)) events.push(event);
    }
    if (complete && events.length > 0) r.Subrole_Event = events.join(', ');
  }
  return rows;
}

/**
 * Pseudo-Type Reference-Resolver.
 *
 * ScriptStepType + PluginComponent haben keine vollständigen ObjectLinks-
 * Spiegelungen. Damit der
 * Referenzen-Tab im Frontend trotzdem die aufrufenden Scripts/Container
 * anzeigen kann, aggregieren wir die "parent"-Liste live aus den Basis-
 * Tabellen:
 *   - ScriptStepType  → StepsForScripts (alle Scripts mit Step_Name = Object_Name)
 *   - PluginComponent → ObjectLinks via groups_into → calls_pluginfunction
 *                       (Aufrufer-Container)
 *
 * Liefert ein {data, meta}-Objekt (kompatibel zum Standard-References-Pfad)
 * oder NULL, wenn das Objekt kein Pseudo-Typ ist.
 */
async function getPseudoTypeReferences(ctx, uuid, direction, link_type, limit, origin = null) {
  // Object-Type lookup
  const typeLookup = await db.executeQuery(
    ctx,
    'SELECT Object_Type, Object_Name FROM ObjectCatalog WHERE Object_UUID = ?',
    [uuid]
  );
  if (typeLookup.rows.length === 0) return null;
  const objType = typeLookup.rows[0].Object_Type;

  // Pseudo-Type-Gate: dieser Resolver ist NUR für Aggregate (ScriptStepType,
  // PluginComponent) zuständig. Für alle anderen Typen sofort durchreichen
  // an den Standard-References-Pfad — sonst würde der frühe structural-Filter
  // unten z.B. parent_script-Links für ScriptStep verschlucken.
  if (objType !== 'ScriptStepType' && objType !== 'PluginComponent') {
    return null;
  }

  // 'child'-direction macht für Aggregate keinen Sinn — sie haben keine
  // Downstream-Abhängigkeiten. 'parent' und 'all' liefern die Aufrufer-Liste.
  if (direction === 'child' || direction === 'recursive') return null;

  // Pseudo-Typen haben nur "operational"-Equivalente; auf structural-Anfragen
  // liefern wir explizit ein leeres Result, damit der Frontend-Hook nicht
  // versehentlich Aufrufer doppelt sieht.
  if (link_type === 'structural') {
    return { data: [], meta: { source: 'pseudo_type_resolver', object_type: objType } };
  }

  if (objType === 'ScriptStepType') {
    // ── (A) Aufrufer (parent) = Scripts UND Buttons mit Step_Name = Object_Name ──
    // Zwei Träger, ein Step-Typ: Script-Steps (StepsForScripts) und
    // button-eingebettete Steps (LayoutObjectSteps). Ohne den zweiten Zweig bliebe
    // der Referenzen-Tab eines Button-only-Step-Typs leer.
    // `Origin_Hit` markiert den Herkunfts-Knoten, aus dem der User auf den
    // Token-Knoten gesprungen ist (?ref=<script|button>) — die Frontend-Liste hebt
    // ihn hervor. Der Button-Zweig prüft dafür gegen die LayoutObject-UUID, weil
    // ein Button-Step genau von dort verlinkt.
    // Container = besitzendes Layout (parent_layout), analog zum
    // PluginComponent-Zweig: "Button @ (17,4)" ist ohne sein Layout nicht lesbar.
    const scriptSql = `
      SELECT * FROM (
        SELECT
          'parent' as direction,
          s.Script_UUID as uuid,
          'Script' as Object_Type,
          s.Script_Name as Object_Name,
          s.File_Name as File_Name,
          'uses_step_type' as Link_Role,
          NULL as Subrole_Class,
          NULL as Subrole_Detail,
          FALSE as Is_Cross_File,
          NULL as Container_UUID,
          NULL as Container_Type,
          TRUE as navigable,
          COUNT(*) as Call_Count,
          BOOL_OR(s.Script_UUID = ?) as Origin_Hit
        FROM StepsForScripts s
        JOIN ObjectCatalog oc ON oc.Object_UUID = ?
        WHERE s.Step_Name = oc.Object_Name
        GROUP BY s.Script_UUID, s.Script_Name, s.File_Name

        UNION ALL

        SELECT
          'parent' as direction,
          los.Object_UUID as uuid,
          'LayoutObject' as Object_Type,
          COALESCE(boc.Object_Name, 'Button') as Object_Name,
          los.File_Name as File_Name,
          'uses_step_type' as Link_Role,
          NULL as Subrole_Class,
          NULL as Subrole_Detail,
          FALSE as Is_Cross_File,
          pl.Target_UUID as Container_UUID,
          pc_container.Object_Type as Container_Type,
          TRUE as navigable,
          COUNT(*) as Call_Count,
          BOOL_OR(los.Object_UUID = ?) as Origin_Hit
        FROM LayoutObjectSteps los
        JOIN ObjectCatalog oc ON oc.Object_UUID = ?
        LEFT JOIN ObjectCatalog boc ON boc.Object_UUID = los.Object_UUID
                                   AND boc.File_Name = los.File_Name
        LEFT JOIN ObjectLinks pl ON pl.Source_UUID = los.Object_UUID
                                AND pl.Source_File = los.File_Name
                                AND pl.Link_Role = 'parent_layout'
        LEFT JOIN ObjectCatalog pc_container ON pc_container.Object_UUID = pl.Target_UUID
                                            AND pc_container.File_Name = pl.Target_File
        WHERE los.Step_Name = oc.Object_Name
        GROUP BY los.Object_UUID, boc.Object_Name, los.File_Name,
                 pl.Target_UUID, pc_container.Object_Type
      )
      ORDER BY Call_Count DESC, Object_Name ASC
      ${limit > 0 ? 'LIMIT ?' : ''}
    `;
    const scriptParams = limit > 0
      ? [origin, uuid, origin, uuid, limit]
      : [origin, uuid, origin, uuid];

    // ── (B) Ziel-/Downstream-Objekte (child) eines Step-Typs ─────────────────
    // ScriptStepTypes spiegeln keine ObjectLinks; die step-eigenen Bezüge leben
    // step-granular in XMLStepReferences (das Graph-Hoisting hängt sie ans
    // Eltern-Script). Hier aggregieren wir sie pro Typ zu Distinct-Zielen —
    // für "Replace Field Contents"/"Set Field" sind das die geschriebenen
    // Felder, allgemein auch TO/Layout/Script-Bezüge anderer Step-Typen.
    // REINER LESEPFAD: ObjectLinks/Graph werden NICHT angefasst, das Hoisting
    // bleibt erhalten (kein ScriptStepType→Field-Mega-Hub im Where-used/Cluster).
    // Rollen-Mapping spiegelt STEP_REF_ROLE (getReferences) / Block 16 in
    // convert_xml_04_catalog.sql. Call_Count = Anzahl Steps dieses Typs, die das
    // Ziel referenzieren. Origin_Hit = Ziel wird im Herkunfts-Script getroffen.
    const targetSql = `
      SELECT
        'child' as direction,
        uuid,
        Object_Type,
        Object_Name,
        File_Name,
        Link_Role,
        NULL as Subrole_Class,
        NULL as Subrole_Detail,
        BOOL_OR(Is_Cross_File) as Is_Cross_File,
        NULL as Container_UUID,
        NULL as Container_Type,
        BOOL_OR(navigable) as navigable,
        COUNT(*) as Call_Count,
        BOOL_OR(is_origin) as Origin_Hit
      FROM (
        SELECT
          xsr.Ref_UUID as uuid,
          COALESCE(tc.Object_Type, CASE xsr.Ref_Type
            WHEN 'field' THEN 'Field'
            WHEN 'tableOccurrence' THEN 'TableOccurrence'
            WHEN 'layout' THEN 'Layout'
            WHEN 'script' THEN 'Script'
            ELSE xsr.Ref_Type END) as Object_Type,
          COALESCE(tc.Object_Name, xsr.Ref_Name) as Object_Name,
          COALESCE(tc.File_Name, xsr.File_Name) as File_Name,
          CASE
            WHEN xsr.Ref_Type = 'tableOccurrence' THEN 'navigates_to_to'
            WHEN xsr.Ref_Type = 'layout' THEN 'navigates_to_layout'
            WHEN xsr.Ref_Type = 'script' THEN 'calls_script'
            WHEN xsr.Ref_Type = 'field' THEN CASE xsr.Step_Name
              WHEN 'Set Field' THEN 'sets_field'
              WHEN 'Replace Field Contents' THEN 'sets_field'
              WHEN 'Insert Calculated Result' THEN 'sets_field'
              WHEN 'Insert Text' THEN 'sets_field'
              WHEN 'Insert File' THEN 'sets_field'
              WHEN 'Insert from URL' THEN 'sets_field'
              WHEN 'Paste' THEN 'sets_field'
              WHEN 'Clear' THEN 'sets_field'
              WHEN 'Set Selection' THEN 'sets_field'
              WHEN 'Set Next Serial Value' THEN 'sets_field'
              WHEN 'Relookup Field Contents' THEN 'sets_field'
              WHEN 'Copy' THEN 'reads_field'
              WHEN 'Export Field Contents' THEN 'reads_field'
              WHEN 'Go to Field' THEN 'navigates_to_field'
              WHEN 'Go to Related Record' THEN 'navigates_to_field'
              WHEN 'Perform Find' THEN 'finds_in_field'
              WHEN 'Constrain Found Set' THEN 'finds_in_field'
              WHEN 'Extend Found Set' THEN 'finds_in_field'
              WHEN 'Enter Find Mode' THEN 'finds_in_field'
              WHEN 'Sort Records' THEN 'sorts_by_field'
              WHEN 'Import Records' THEN 'imports_to_field'
              WHEN 'Export Records' THEN 'exports_from_field'
              WHEN 'Show Custom Dialog' THEN 'inputs_to_field'
              ELSE 'references_field'
            END
            ELSE xsr.Ref_Type
          END as Link_Role,
          (xsr.File_Name <> COALESCE(tc.File_Name, xsr.File_Name)) as Is_Cross_File,
          (tc.Object_UUID IS NOT NULL) as navigable,
          COALESCE(xsr.Script_UUID = ?, FALSE) as is_origin
        FROM XMLStepReferences xsr
        JOIN ObjectCatalog oc ON oc.Object_UUID = ?
        LEFT JOIN ObjectCatalog tc ON tc.Object_UUID = xsr.Ref_UUID
        WHERE xsr.Step_Name = oc.Object_Name
          AND xsr.Ref_UUID IS NOT NULL
      )
      GROUP BY uuid, Object_Type, Object_Name, File_Name, Link_Role
      ORDER BY Origin_Hit DESC, Call_Count DESC, Object_Name ASC
      ${limit > 0 ? 'LIMIT ?' : ''}
    `;
    const targetParams = limit > 0 ? [origin, uuid, limit] : [origin, uuid];

    // ── (C) Ziel-Variablen (child) eines Step-Typs ───────────────────────────
    // Steps, die ihr Ergebnis in eine Variable schreiben (Set Variable, Insert
    // Text/from URL, Show Custom Dialog, Execute FileMaker Data API, Open/Write/
    // Get Data File, …), tragen kein <FieldReference> und stehen daher NICHT in
    // XMLStepReferences (Variablen-Refs dort haben Ref_UUID=NULL). Die geschriebene
    // Variable lebt aber in VariableUsages (Usage_Type='set', Source u.a.
    // 'target_variable_step'/'set_variable_step'). Wir mappen sie per
    // (Script_UUID, Step_Index) → StepsForScripts.Step_Name auf den Step-Typ und
    // lösen die Variable über ihre kanonische UUID md5(scope::anchor::name) in
    // ObjectCatalog auf (= identische Bildung wie convert_xml_04_catalog.sql Block
    // 24, daher mit dem `sets_variable`-Graph konsistent). REINER LESEPFAD.
    const variableSql = `
      SELECT
        'child' as direction,
        uuid,
        Object_Type,
        Object_Name,
        File_Name,
        'sets_variable' as Link_Role,
        NULL as Subrole_Class,
        NULL as Subrole_Detail,
        FALSE as Is_Cross_File,
        NULL as Container_UUID,
        NULL as Container_Type,
        TRUE as navigable,
        COUNT(*) as Call_Count,
        BOOL_OR(is_origin) as Origin_Hit
      FROM (
        SELECT
          vc.Object_UUID as uuid,
          vc.Object_Type as Object_Type,
          vc.Object_Name as Object_Name,
          vc.File_Name as File_Name,
          COALESCE(vu.Script_UUID = ?, FALSE) as is_origin
        FROM VariableUsages vu
        JOIN ObjectCatalog oc ON oc.Object_UUID = ?
        JOIN StepsForScripts s
          ON s.Script_UUID = vu.Script_UUID
         AND s.Step_Index = vu.Step_Index
         AND s.Step_Name = oc.Object_Name
        JOIN ObjectCatalog vc
          ON vc.Object_UUID = md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name)
         AND vc.Object_Type LIKE '%Variable%'
        WHERE vu.Usage_Type = 'set'
          AND vu.Context_Type = 'script_step'
          AND vu.Script_UUID IS NOT NULL
          AND vu.Step_Index IS NOT NULL
      )
      GROUP BY uuid, Object_Type, Object_Name, File_Name
      ORDER BY Origin_Hit DESC, Call_Count DESC, Object_Name ASC
      ${limit > 0 ? 'LIMIT ?' : ''}
    `;
    const variableParams = limit > 0 ? [origin, uuid, limit] : [origin, uuid];

    const [scriptResult, targetResult, variableResult] = await Promise.all([
      db.executeQuery(ctx, scriptSql, scriptParams),
      db.executeQuery(ctx, targetSql, targetParams),
      db.executeQuery(ctx, variableSql, variableParams),
    ]);
    return {
      data: convertBigInts([
        ...scriptResult.rows,
        ...targetResult.rows,
        ...variableResult.rows,
      ]),
      meta: {
        ...scriptResult.meta,
        source: 'pseudo_type_resolver',
        object_type: objType,
        parent_count: scriptResult.rows.length,
        child_count: targetResult.rows.length + variableResult.rows.length,
      },
    };
  }

  if (objType === 'PluginComponent') {
    // Zwei-Stufen-Aggregation: groups_into → calls_pluginfunction
    // Aufrufer-Containers (Script/CustomFunction) der Funktionen dieser Component.
    const sql = `
      WITH funcs AS (
        SELECT pf.Object_UUID
        FROM ObjectCatalog pc
        JOIN ObjectLinks gi ON gi.Target_UUID = pc.Object_UUID
                           AND gi.Link_Role = 'groups_into'
        JOIN ObjectCatalog pf ON pf.Object_UUID = gi.Source_UUID
                             AND pf.Object_Type = 'PluginFunction'
        WHERE pc.Object_UUID = ?
      )
      SELECT
        'parent' as direction,
        oc.Object_UUID as uuid,
        oc.Object_Type as Object_Type,
        oc.Object_Name as Object_Name,
        oc.File_Name as File_Name,
        'calls_component' as Link_Role,
        NULL as Subrole_Class,
        NULL as Subrole_Detail,
        FALSE as Is_Cross_File,
        pl.Target_UUID as Container_UUID,
        pc_container.Object_Type as Container_Type,
        COUNT(*) as Call_Count
      FROM funcs f
      JOIN ObjectLinks call ON call.Target_UUID = f.Object_UUID
                           AND call.Link_Role = 'calls_pluginfunction'
      JOIN ObjectCatalog oc ON oc.Object_UUID = call.Source_UUID
      LEFT JOIN ObjectLinks pl ON pl.Source_UUID = oc.Object_UUID
                              AND pl.Link_Role IN ('parent_layout', 'parent_script')
      LEFT JOIN ObjectCatalog pc_container ON pc_container.Object_UUID = pl.Target_UUID
      GROUP BY oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name,
               pl.Target_UUID, pc_container.Object_Type
      ORDER BY Call_Count DESC, oc.Object_Name ASC
      ${limit > 0 ? 'LIMIT ?' : ''}
    `;
    const params = limit > 0 ? [uuid, limit] : [uuid];
    const result = await db.executeQuery(ctx, sql, params);
    return {
      data: convertBigInts(result.rows),
      meta: { ...result.meta, source: 'pseudo_type_resolver', object_type: objType },
    };
  }

  return null;
}

/**
 * Get object references (dependencies)
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {Object} refOptions - Reference options {uuid, direction, link_type, limit}
 * @returns {Promise<Object>} References with metadata
 */
async function getReferences(ctx, refOptions) {
  try {
    const {
      uuid,
      direction = 'all',
      link_type = 'operational',
      limit = environment.api.defaultLimit,
      file,
      origin = null,
    } = refOptions;

    // Clone-Scoping: bei geteilter UUID (Klon) liefern die ObjectLinks-Joins sonst
    // die Kanten BEIDER Klone gemischt. Mit `file` wird die Fokus-Seite der Kante
    // auf die richtige Datei eingegrenzt (Source_File bei child, Target_File bei
    // parent). Ohne `file` unverändertes Verhalten (Graceful Downgrade).
    const focusFile = file || null;

    // Pseudo-Type-Sonderfall: ScriptStepType + PluginComponent haben keine
    // (vollständigen) ObjectLinks-Spiegelungen. Die "Verwendet in"-
    // Liste muss daher live aus den Basis-Tabellen aggregiert werden.
    const pseudoRefs = await getPseudoTypeReferences(ctx, uuid, direction, link_type, limit, origin);
    if (pseudoRefs !== null) return pseudoRefs;

    let sql;
    let params;

    // Container-Resolution für Sub-Knoten:
    // LayoutObject und ScriptStep haben keinen sinnvollen Standalone-Detail-View —
    // ihr Wert liegt im Container-Kontext. Die zusätzlichen LEFT JOINs liefern
    // den Container-UUID/Type über `parent_layout`/`parent_script`-Links mit.
    // Für andere Object-Types bleibt Container_UUID = NULL, und das Frontend
    // navigiert wie gewohnt direkt auf das Objekt.
    // Klon-Disambiguierung: die Container-Joins (Sub-Knoten → Container) MÜSSEN
    // datei-gleich ausgerichtet werden. Sonst matcht eine geteilte Klon-UUID die
    // ObjectCatalog-/ObjectLinks-Zeilen ALLER Klon-Dateien → kartesisches Produkt
    // (z.B. parent_script eines geklonten Scripts explodierte auf ~10000 Zeilen).
    // ScriptTrigger → Container: ein Trigger hängt via `trigger_owner` an
    // einem Layout oder der Datei (direkter Container) ODER an einem
    // LayoutObject (Objekt-Ebene) → dann einen Hop weiter über `parent_layout`
    // zum Layout. Der Owner-Typ wird DURCHGEREICHT statt hartkodiert
    // (Owner_Kind: 'Layout' bzw. 'File' direkt, nach dem Hop il.Object_Type =
    // 'Layout') — File-Trigger trugen sonst Container None/None.
    // Liefert je ScriptTrigger genau eine Zeile (1:1-Kanten, keine Fächerung).
    const TRIGGER_LAYOUT_JOIN = `
      LEFT JOIN (
        SELECT
          trg.Object_UUID AS st_uuid,
          trg.File_Name   AS st_file,
          CASE WHEN ownc.Object_Type = 'LayoutObject' THEN il.Object_UUID ELSE ownc.Object_UUID END AS Layout_UUID,
          CASE WHEN ownc.Object_Type = 'LayoutObject' THEN il.Object_Name ELSE ownc.Object_Name END AS Layout_Name,
          CASE WHEN ownc.Object_Type = 'LayoutObject' THEN il.File_Name   ELSE ownc.File_Name   END AS Layout_File,
          CASE WHEN ownc.Object_Type = 'LayoutObject' THEN il.Object_Type ELSE ownc.Object_Type END AS Owner_Kind
        FROM ObjectCatalog trg
        JOIN ObjectLinks own ON own.Source_UUID = trg.Object_UUID AND own.Source_File = trg.File_Name
                            AND own.Link_Role = 'trigger_owner'
        JOIN ObjectCatalog ownc ON own.Target_UUID = ownc.Object_UUID AND own.Target_File = ownc.File_Name
        LEFT JOIN ObjectLinks olp ON ownc.Object_Type = 'LayoutObject'
                                 AND olp.Source_UUID = ownc.Object_UUID AND olp.Source_File = ownc.File_Name
                                 AND olp.Link_Role = 'parent_layout'
        LEFT JOIN ObjectCatalog il ON olp.Target_UUID = il.Object_UUID AND olp.Target_File = il.File_Name
        WHERE trg.Object_Type = 'ScriptTrigger'
      ) tl ON tl.st_uuid = oc.Object_UUID AND tl.st_file = oc.File_Name
    `;
    const CONTAINER_JOIN = `
      LEFT JOIN ObjectLinks pl ON pl.Source_UUID = oc.Object_UUID
        AND pl.Source_File = oc.File_Name
        AND pl.Link_Role IN ('parent_layout', 'parent_script')
      LEFT JOIN ObjectCatalog pc ON pl.Target_UUID = pc.Object_UUID
        AND pl.Target_File = pc.File_Name
      ${TRIGGER_LAYOUT_JOIN}
    `;
    // Container-Spalten (UUID/Type/Name/File): parent_layout/parent_script-Container
    // (LayoutObject/ScriptStep) ODER — für ScriptTrigger — Layout bzw. Datei
    // (Owner_Kind aus dem Trigger-Join statt hartkodiertem 'Layout').
    const CONTAINER_SELECT = `
          COALESCE(pl.Target_UUID, tl.Layout_UUID) as Container_UUID,
          COALESCE(pc.Object_Type, tl.Owner_Kind) as Container_Type,
          COALESCE(pc.Object_Name, tl.Layout_Name) as Container_Name,
          COALESCE(pc.File_Name, tl.Layout_File) as Container_File`;

    // ── Step-Ebenen-Referenzen (NUR Anzeige) ──────────────────────────────
    // XMLStepReferences behält die Step-Granularität, die ObjectLinks durch das
    // Hoisting-auf-Script verliert (die TO-/Layout-/Feld-/Script-Bezüge eines
    // Steps hängen im Graph am Eltern-Script). Für eine ScriptStep-Detailseite
    // zeigen wir hier die step-eigenen ausgehenden Bezüge — REINER LESEPFAD:
    // ObjectLinks/der Graph werden NICHT angefasst, das Hoisting bleibt erhalten.
    // Der WHERE-Filter auf Step_UUID grenzt den Branch automatisch korrekt ein —
    // nur ScriptStep-UUIDs treffen eine Step_UUID, für alle anderen Objekttypen
    // ist er leer (keine Typ-Verzweigung im Code nötig).
    // Variablen (Ref_UUID NULL) bleiben vorerst außen vor (Phase 2 — Auflösung
    // per Name statt UUID). `navigable` markiert datei-extern nicht auflösbare
    // Ziele, die das Frontend als nicht-klickbaren Text rendert statt sie zu
    // verschlucken. Feld-Rollen spiegeln convert_xml_04_catalog.sql Block 16.
    const STEP_REF_ROLE = `CASE
        WHEN xsr.Ref_Type = 'tableOccurrence' THEN 'navigates_to_to'
        WHEN xsr.Ref_Type = 'layout' THEN 'navigates_to_layout'
        WHEN xsr.Ref_Type = 'script' THEN 'calls_script'
        WHEN xsr.Ref_Type = 'field' THEN CASE xsr.Step_Name
          WHEN 'Set Field' THEN 'sets_field'
          WHEN 'Replace Field Contents' THEN 'sets_field'
          WHEN 'Insert Calculated Result' THEN 'sets_field'
          WHEN 'Insert Text' THEN 'sets_field'
          WHEN 'Insert File' THEN 'sets_field'
          WHEN 'Insert from URL' THEN 'sets_field'
          WHEN 'Paste' THEN 'sets_field'
          WHEN 'Clear' THEN 'sets_field'
          WHEN 'Set Selection' THEN 'sets_field'
          WHEN 'Set Next Serial Value' THEN 'sets_field'
          WHEN 'Relookup Field Contents' THEN 'sets_field'
          WHEN 'Copy' THEN 'reads_field'
          WHEN 'Export Field Contents' THEN 'reads_field'
          WHEN 'Go to Field' THEN 'navigates_to_field'
          WHEN 'Go to Related Record' THEN 'navigates_to_field'
          WHEN 'Perform Find' THEN 'finds_in_field'
          WHEN 'Constrain Found Set' THEN 'finds_in_field'
          WHEN 'Extend Found Set' THEN 'finds_in_field'
          WHEN 'Enter Find Mode' THEN 'finds_in_field'
          WHEN 'Sort Records' THEN 'sorts_by_field'
          WHEN 'Import Records' THEN 'imports_to_field'
          WHEN 'Export Records' THEN 'exports_from_field'
          WHEN 'Show Custom Dialog' THEN 'inputs_to_field'
          ELSE 'references_field'
        END
        ELSE xsr.Ref_Type
      END`;
    // Anzeige-Typ auch für nicht-auflösbare Ziele (oc.* NULL) aus Ref_Type ableiten.
    const STEP_REF_TYPE = `COALESCE(oc.Object_Type, CASE xsr.Ref_Type
        WHEN 'tableOccurrence' THEN 'TableOccurrence'
        WHEN 'layout' THEN 'Layout'
        WHEN 'script' THEN 'Script'
        WHEN 'field' THEN 'Field'
        ELSE xsr.Ref_Type END)`;
    // Spaltenform passend zum direction='all'-Zweig (baseChild/baseParent).
    const STEP_REFS_ALL = `
      SELECT 'child' as direction,
        xsr.Ref_UUID as uuid,
        ${STEP_REF_TYPE} as Object_Type,
        COALESCE(oc.Object_Name, xsr.Ref_Name) as Object_Name,
        COALESCE(oc.File_Name, xsr.File_Name) as File_Name,
        ${STEP_REF_ROLE} as Link_Role,
        NULL as Subrole_Class,
        NULL as Subrole_Raw,
        (xsr.File_Name <> COALESCE(oc.File_Name, xsr.File_Name)) as Is_Cross_File,
        NULL as Container_UUID, NULL as Container_Type, NULL as Container_Name, NULL as Container_File,
        NULL as Trigger_UUID,
        (oc.Object_UUID IS NOT NULL) as navigable
      FROM XMLStepReferences xsr
      LEFT JOIN ObjectCatalog oc ON xsr.Ref_UUID = oc.Object_UUID
      WHERE xsr.Step_UUID = ? AND xsr.Ref_UUID IS NOT NULL
    `;
    // Spaltenform passend zum direction='child'-Zweig (Target_*).
    const STEP_REFS_CHILD = `
      SELECT
        xsr.Ref_UUID as Target_UUID,
        ${STEP_REF_TYPE} as Target_Type,
        COALESCE(oc.Object_Name, xsr.Ref_Name) as Target_Name,
        COALESCE(oc.File_Name, xsr.File_Name) as Target_File,
        ${STEP_REF_ROLE} as Link_Role,
        NULL as Subrole_Class,
        NULL as Subrole_Detail,
        (xsr.File_Name <> COALESCE(oc.File_Name, xsr.File_Name)) as Is_Cross_File,
        NULL as Container_UUID, NULL as Container_Type, NULL as Container_Name, NULL as Container_File,
        NULL as Trigger_UUID,
        (oc.Object_UUID IS NOT NULL) as navigable
      FROM XMLStepReferences xsr
      LEFT JOIN ObjectCatalog oc ON xsr.Ref_UUID = oc.Object_UUID
      WHERE xsr.Step_UUID = ? AND xsr.Ref_UUID IS NOT NULL
    `;

    // ── Anzeige-Konsolidierung der Trigger-Doppelrepräsentation ───────────
    // Trigger erscheinen in der Aufrufer-Richtung doppelt: als granulare
    // trigger_script-Kante des ScriptTrigger-Sub-Knotens UND als deren
    // 1:1-Spiegel triggers_script·<Event> vom Owner (Objekt-Ebene seit
    // Converter 2.14.0, alle drei Owner-Ebenen — LayoutObject/Layout/File —
    // seit 2.17.0; aus derselben ScriptTriggers-Zeile erzeugt). Die granulare
    // Zeile wird NUR unterdrückt, wenn ihr Spiegel in der Liste sichtbar wäre:
    //   - die trigger_owner-Kante muss existieren — fehlt sie (Parser-Lücke
    //     PopoverPanel-Owner), fällt der Spiegel im Katalog-JOIN der Liste
    //     weg und die granulare Zeile bleibt die einzige Repräsentation,
    //   - der Spiegel muss eine Event-Subrole tragen — Alt-Kataloge
    //     (< 2.14.0, Subrole NULL) zeigen das Event nur am Trigger-Knoten
    //     und behalten deshalb das ungefilterte Bild bis zum Re-Import.
    //     Alt-Kataloge 2.14.0–2.16.x (Spiegel nur auf Objekt-Ebene) bleiben
    //     ebenfalls graceful: Layout-/File-Trigger haben dort keinen Spiegel,
    //     der EXISTS greift nicht, die granulare Zeile bleibt stehen.
    // Reine Anzeige-Ebene: ObjectLinks, Graph, LinkRoleRegistry und die
    // Where-used-Flags bleiben unberührt. (Where-used zählt seit 2.17.0
    // ohnehin nur die Spiegel — trigger_script ist demotiert.)
    const TRIGGER_MIRROR_FILTER = `AND NOT (
          ol.Link_Role = 'trigger_script'
          AND EXISTS (
            SELECT 1
            FROM ObjectLinks owner_edge
            JOIN ObjectLinks mirror
              ON mirror.Source_UUID = owner_edge.Target_UUID
             AND mirror.Source_File = owner_edge.Target_File
             AND mirror.Link_Role = 'triggers_script'
             AND mirror.Link_Subrole IS NOT NULL
             AND mirror.Link_Subrole <> 'button_action'
             AND mirror.Target_UUID = ol.Target_UUID
             AND mirror.Target_File IS NOT DISTINCT FROM ol.Target_File
            WHERE owner_edge.Source_UUID = ol.Source_UUID
              AND owner_edge.Source_File = ol.Source_File
              AND owner_edge.Link_Role = 'trigger_owner'
          )
        )`;

    // ── Trigger-Absprung auf konsolidierten Spiegel-Zeilen ────────────────
    // Objekt-Level-Spiegelkanten (triggers_script·<Event>) tragen die UUID
    // ihres ScriptTrigger-Sub-Knotens als Zusatzspalte, damit das Frontend
    // vom konsolidierten Owner-Eintrag zur Trigger-Detailseite springen kann —
    // die granulare trigger_script-Zeile ist in der Liste ja gerade
    // unterdrückt (TRIGGER_MIRROR_FILTER). Auflösung rein über ObjectLinks
    // (trigger_owner + trigger_script): die Subroles beider Kanten stammen
    // aus demselben Trigger_Action-Passthrough, der Join ist damit
    // locale-konsistent; (Owner, Event) ist je Owner eindeutig (FileMaker:
    // ein Script pro Event-Slot), LIMIT 1 ist defensiv. button_action-Zeilen
    // und alle anderen Rollen liefern NULL ohne Subquery-Evaluation.
    const TRIGGER_UUID_SELECT = `CASE
          WHEN ol.Link_Role = 'triggers_script'
           AND ol.Link_Subrole IS NOT NULL
           AND ol.Link_Subrole <> 'button_action'
          THEN (
            SELECT own.Source_UUID
            FROM ObjectLinks own
            JOIN ObjectLinks ts
              ON ts.Source_UUID = own.Source_UUID
             AND ts.Source_File = own.Source_File
             AND ts.Link_Role = 'trigger_script'
            WHERE own.Link_Role = 'trigger_owner'
              AND own.Target_UUID = ol.Source_UUID
              AND own.Target_File = ol.Source_File
              AND own.Link_Subrole = ol.Link_Subrole
              AND ts.Target_UUID = ol.Target_UUID
            LIMIT 1
          )
          ELSE NULL
        END`;

    if (direction === 'child') {
      // Downstream dependencies (what this object references)
      sql = `
        SELECT
          ol.Target_UUID,
          oc.Object_Type as Target_Type,
          oc.Object_Name as Target_Name,
          oc.File_Name as Target_File,
          ol.Link_Role,
          ${subroleClassSql('ol.Link_Subrole')} as Subrole_Class,
          ol.Link_Subrole as Subrole_Detail,
          ol.Is_Cross_File,
${CONTAINER_SELECT},
          ${TRIGGER_UUID_SELECT} as Trigger_UUID,
          TRUE as navigable
        FROM ObjectLinks ol
        JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
        ${CONTAINER_JOIN}
        WHERE ol.Source_UUID = ?
      `;
      params = [uuid];

      if (focusFile) { sql += ' AND ol.Source_File = ?'; params.push(focusFile); }
      if (link_type !== 'all') {
        sql += ' AND ol.Link_Type = ?';
        params.push(link_type);
      }
      // Step-eigene ausgehende Bezüge (operational) anhängen — leer für Nicht-Steps.
      if (link_type !== 'structural') {
        sql += ` UNION ALL ${STEP_REFS_CHILD}`;
        params.push(uuid);
      }
    } else if (direction === 'parent') {
      // Upstream dependencies (what references this object)
      sql = `
        SELECT
          ol.Source_UUID,
          oc.Object_Type as Source_Type,
          oc.Object_Name as Source_Name,
          oc.File_Name as Source_File,
          ol.Link_Role,
          ${subroleClassSql('ol.Link_Subrole')} as Subrole_Class,
          ol.Link_Subrole as Subrole_Detail,
          ol.Is_Cross_File,
${CONTAINER_SELECT},
          ${TRIGGER_UUID_SELECT} as Trigger_UUID
        FROM ObjectLinks ol
        JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID AND ol.Source_File = oc.File_Name
        ${CONTAINER_JOIN}
        WHERE ol.Target_UUID = ?
        ${TRIGGER_MIRROR_FILTER}
      `;
      params = [uuid];

      if (focusFile) { sql += ' AND ol.Target_File = ?'; params.push(focusFile); }
      if (link_type !== 'all') {
        sql += ' AND ol.Link_Type = ?';
        params.push(link_type);
      }
    } else if (direction === 'recursive') {
      // Recursive dependencies.
      // Klon-Robustheit: die Traversierung folgt der Kante DATEI-GENAU — der nächste Hop
      // beginnt in genau der Datei, in der der vorige endete (ol.Source_File = dt.Target_File).
      // Sonst matcht eine geklonte Target_UUID die ObjectLinks ALLER Klon-Dateien und der Lauf
      // fächert über Geschwister-Klone (focus_file skopierte bisher nur die Saat, nicht den Lauf:
      // focus_file=GM vs LKU lieferten identisch). NULL-Ziel-Knoten (Builtin-/PluginFunction:
      // Target_File IS NULL) sind operationale Blätter → `=` terminiert dort natürlich. Die finale
      // Katalog-Auflösung ist (UUID, File)-genau; IS NOT DISTINCT FROM matcht die synthetischen
      // NULL-File-Objekte korrekt mit.
      sql = `
        WITH RECURSIVE dependency_tree AS (
          SELECT Source_UUID, Source_File, Target_UUID, Target_File, Link_Role, 1 as depth
          FROM ObjectLinks
          WHERE Source_UUID = ? AND Link_Type = 'operational'
            ${focusFile ? 'AND Source_File = ?' : ''}

          UNION ALL

          SELECT ol.Source_UUID, ol.Source_File, ol.Target_UUID, ol.Target_File, ol.Link_Role, dt.depth + 1
          FROM ObjectLinks ol
          JOIN dependency_tree dt
            ON ol.Source_UUID = dt.Target_UUID
           AND ol.Source_File = dt.Target_File
          WHERE dt.depth < 10 AND ol.Link_Type = 'operational'
        )
        SELECT DISTINCT
          dt.Target_UUID,
          dt.Link_Role,
          dt.depth,
          oc.Object_Type,
          oc.Object_Name,
          oc.File_Name
        FROM dependency_tree dt
        JOIN ObjectCatalog oc
          ON dt.Target_UUID = oc.Object_UUID
         AND oc.File_Name IS NOT DISTINCT FROM dt.Target_File
        ORDER BY depth, Object_Name
      `;
      params = focusFile ? [uuid, focusFile] : [uuid];
    } else {
      // All (both parent and child) — beide Hälften mit Container-Resolution.
      const baseChild = `
        SELECT 'child' as direction,
          ol.Target_UUID as uuid,
          oc.Object_Type, oc.Object_Name, oc.File_Name,
          ol.Link_Role,
          ${subroleClassSql('ol.Link_Subrole')} as Subrole_Class,
          ol.Link_Subrole as Subrole_Raw,
          ol.Is_Cross_File,
${CONTAINER_SELECT},
          ${TRIGGER_UUID_SELECT} as Trigger_UUID,
          TRUE as navigable
        FROM ObjectLinks ol
        JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
        ${CONTAINER_JOIN}
        WHERE ol.Source_UUID = ?
        ${focusFile ? 'AND ol.Source_File = ?' : ''}
      `;
      const baseParent = `
        SELECT 'parent' as direction,
          ol.Source_UUID as uuid,
          oc.Object_Type, oc.Object_Name, oc.File_Name,
          ol.Link_Role,
          ${subroleClassSql('ol.Link_Subrole')} as Subrole_Class,
          ol.Link_Subrole as Subrole_Raw,
          ol.Is_Cross_File,
${CONTAINER_SELECT},
          ${TRIGGER_UUID_SELECT} as Trigger_UUID,
          TRUE as navigable
        FROM ObjectLinks ol
        JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID AND ol.Source_File = oc.File_Name
        ${CONTAINER_JOIN}
        WHERE ol.Target_UUID = ?
        ${TRIGGER_MIRROR_FILTER}
        ${focusFile ? 'AND ol.Target_File = ?' : ''}
      `;
      // Param-Reihenfolge je UNION-Hälfte: uuid [, focusFile] [, link_type].
      const childParams = focusFile ? [uuid, focusFile] : [uuid];
      const parentParams = focusFile ? [uuid, focusFile] : [uuid];
      if (link_type !== 'all') {
        sql = `${baseChild} AND ol.Link_Type = ? UNION ALL ${baseParent} AND ol.Link_Type = ?`;
        params = [...childParams, link_type, ...parentParams, link_type];
      } else {
        sql = `${baseChild} UNION ALL ${baseParent}`;
        params = [...childParams, ...parentParams];
      }
      // Step-eigene ausgehende Bezüge (operational, child-Richtung) anhängen.
      // Bei link_type='structural' weggelassen (Step-Bezüge sind operational).
      if (link_type !== 'structural') {
        sql += ` UNION ALL ${STEP_REFS_ALL}`;
        params.push(uuid);
      }
      // Identische Mehrfachkanten zu EINER Referenz je (Richtung · Ziel · Rolle ·
      // Subrole-Klasse · Container) zusammenfassen. ObjectLinks hält bewusst eine
      // Kante pro Vorkommen (z.B. ruft ein Script dasselbe Ziel-Script in 4
      // Perform-Script-Schritten → 4 calls_script-Zeilen); in der Referenzliste
      // zeigt jedes dieselbe Zielzeile, was nur Lärm ist. Call_Count = Anzahl der
      // Vorkommen (Frontend rendert ×N) — gleiche Aggregation wie der Pseudo-
      // Type-Resolver. Die Subrole-Klasse splittet Zeilen NUR, wo Slots wirklich
      // differieren (Hide vs. CF); Script-Zeilen bleiben durch die Numerik-
      // Unterdrückung (Klasse NULL) unverändert aggregiert. Subrole_Detail trägt
      // die Roh-Werte der Gruppe (z.B. 'Condition_1, Condition_2') für den
      // Tooltip — nur bei echter Klasse, sonst wäre es Slot-Index-Lärm.
      // Trigger_UUID ist gruppen-konstant: befüllt nur auf Spiegel-Zeilen
      // (triggers_script·<Event>), und Event-Subroles sind ihre EIGENE
      // Subrole-Klasse (ELSE-Durchreichung) — je (Owner, Event) existiert
      // genau ein Trigger. Die Spalte im GROUP BY splittet daher keine
      // bestehende Aggregat-Zeile.
      sql = `
        SELECT direction, uuid, Object_Type, Object_Name, File_Name, Link_Role,
               Subrole_Class,
               CASE WHEN Subrole_Class IS NOT NULL
                    THEN string_agg(DISTINCT Subrole_Raw, ', ' ORDER BY Subrole_Raw)
               END AS Subrole_Detail,
               BOOL_OR(Is_Cross_File) AS Is_Cross_File,
               Container_UUID, Container_Type, Container_Name, Container_File,
               Trigger_UUID,
               BOOL_OR(navigable) AS navigable,
               COUNT(*) AS Call_Count
        FROM (${sql}) ref_union
        GROUP BY direction, uuid, Object_Type, Object_Name, File_Name, Link_Role,
                 Subrole_Class,
                 Container_UUID, Container_Type, Container_Name, Container_File,
                 Trigger_UUID
      `;
    }

    if (limit > 0 && direction !== 'recursive') {
      sql += ' LIMIT ?';
      params.push(limit);
    }

    const result = await db.executeQuery(ctx, sql, params);

    return {
      data: await enrichSubroleEvents(ctx, convertBigInts(result.rows)),
      meta: result.meta,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, refOptions);
  }
}

/**
 * Get object details using type-specific SQL template
 * Dispatches to object_details_<type>.sql based on Object_Type
 * Falls back to object_details_generic.sql for types without dedicated template
 * @param {Object} ctx - Request-Kontext (Solution-Scope)
 * @param {string} uuid - Object UUID
 * @returns {Promise<Object>} Detail data with metadata
 */
async function getDetails(ctx, uuid, file, lang) {
  try {
    // 1. Look up object type from ObjectCatalog (clone-aware, see resolveByUUID)
    const lookupResult = await resolveByUUID(
      ctx,
      uuid,
      file,
      'Object_Type, Object_Name, File_Name, Source_Table, Object_ID'
    );

    const objectInfo = lookupResult.rows[0];
    const objectType = objectInfo.Object_Type;
    // Klon-Robustheit: die kanonisch aufgelöste Datei (resolveByUUID hat bei
    // mehrdeutiger UUID ohne `file` bereits 409 geworfen) wird an das Detail-Template
    // durchgereicht. Sonst matcht ein bare-`getvariable('uuid')`-WHERE die Klon-Zeilen
    // ALLER Dateien → Inhalt mischt sich (z.B. Field-Klon BEL/BELA). Templates skopieren
    // via `(getvariable('file') IS NULL OR <tbl>.File_Name = getvariable('file'))`.
    const resolvedFile = objectInfo.File_Name;

    // 2. Determine template name from explicit map
    const templateName = DETAIL_TEMPLATE_MAP[objectType] || 'object_details_generic';
    const hasDedicatedTemplate = objectType in DETAIL_TEMPLATE_MAP;

    // 3. Execute the detail template (templates/sql/ = 'report' source)
    // `lang` = aktive UI-Sprache. Detail-Templates, die eine lokalisierte
    // Schreibweise NEBEN dem Katalognamen zeigen (BuiltinFunction seit
    // Katalog-Schema 1.32.0, wo der Katalogname sprachunabhängig kanonisch ist),
    // lesen sie per getvariable('lang'); alle anderen ignorieren den Parameter.
    const result = await templateService.executeTemplate(
      ctx, templateName, { uuid, file: resolvedFile, lang: lang ?? null }, 'report');

    return {
      data: result.data,
      meta: {
        ...result.meta,
        object_type: objectType,
        object_name: objectInfo.Object_Name,
        file_name: objectInfo.File_Name,
        template_used: templateName,
        has_dedicated_template: hasDedicatedTemplate,
      },
      sql: result.sql,
    };
  } catch (error) {
    if (error.code) throw error;
    throw createError('DATABASE_ERROR', error.message, { uuid });
  }
}

module.exports = {
  clearObjectServiceCaches,
  resolveByUUID,
  getByUUID,
  getDetails,
  listObjects,
  listCategorySummary,
  countObjects,
  searchObjects,
  countSearchResults,
  getReferences,
  enrichSubroleEvents,
  // Für Unit-Tests exportiert — Konsumenten nutzen getReferences.
  subroleClassSql,
};
