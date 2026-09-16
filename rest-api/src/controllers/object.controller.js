const objectService = require('../services/object.service');
const templateService = require('../services/template.service');
const formatters = require('../formatters');
const { sendFormatted, buildSuccess } = require('../utils/response-builder');
const { createError } = require('../middleware/error-handler');
const referenceService = require('../services/reference.service');

// UUID-Erkennung: Standard-UUID v1–v5 mit Bindestrichen ODER 32 Hex-Chars ohne
// Bindestriche (Pseudo-Type-UUIDs aus md5() wie ScriptStepType, BuiltinFunction,
// PluginFunction, PluginComponent).
const UUID_REGEX = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32})$/i;

// Synthetische Katalog-Object_UUIDs für Sub-Knoten ohne native FM-UUID:
// `trig_<id>_<owner>_<file>` (ScriptTrigger), `part_…` (LayoutPart), `rel_…`
// (Relationship), `paste_…` (PasteIndexObject), `step_…` (ScriptStep). Gültige
// Navigations-/Highlight-Ziele — nur das Format weicht ab.
const SYNTHETIC_ID_RE = /^(trig|part|rel|paste|step)_/;
const isCatalogUuid = (s) => UUID_REGEX.test(s) || SYNTHETIC_ID_RE.test(s);

/**
 * Object Controller
 * Handles requests for object-related endpoints
 */

// Mapping API-Type → interne Source_Table für FolderHierarchy/list_with_folders.sql
const SUBTYPE_FOR_TYPE = {
  script:         'ScriptCatalog',
  layout:         'Layouts',
  customfunction: 'CustomFunctionsCatalog',
};

// Ergebnistyp → Merge-Syntax-Präfix einer typisierten Layoutformel — exakte
// Umkehrung der Converter-Ableitung (P4 Display-Anreicherung, Schema 1.27.0).
// Unbekannte Präfixe speichert der Converter roh als '%<X>' und laufen hier
// unverändert durch.
const DISPLAY_RESULT_TYPE_PREFIX = { Text: '', Number: '%N:', Date: '%D:', Time: '%I:', Timestamp: '%M:' };

/**
 * Rekonstruiert den Layout-Textanker einer display_calculation-Instanz aus den
 * gespeicherten Teilen: '<<ƒ:' + Ergebnistyp-Präfix + Formula_Text + '>>'.
 * NULL für jede andere Rolle und für Instanzen ohne Formula_Text (dann gibt es
 * nichts Verlässliches zu rekonstruieren).
 */
function buildLayoutFormula(role, resultType, formulaText) {
  if (role !== 'display_calculation' || formulaText == null || formulaText === '') return null;
  let prefix = '';
  if (resultType != null && resultType !== '') {
    if (Object.prototype.hasOwnProperty.call(DISPLAY_RESULT_TYPE_PREFIX, resultType)) {
      prefix = DISPLAY_RESULT_TYPE_PREFIX[resultType];
    } else if (String(resultType).startsWith('%')) {
      prefix = `${resultType}:`;
    }
  }
  return `<<ƒ:${prefix}${formulaText}>>`;
}

/**
 * Synthetische Tokenisierung einer GERETTETEN display_calculation-Instanz
 * (leere DDR-ChunkList): lädt die slot-skopierten, converter-geborgenen
 * Referenzen (XMLCalcReferences: Felder/CustomFunctions/Variablen je
 * Owner × Subrole) und lokalisiert sie im geretteten Formeltext
 * (tokens.formatter.synthesizeRecoveredCalcTokens). NULL für andere Rollen,
 * ohne Formula_Text oder wenn keine Referenz matcht — der Aufrufer bleibt
 * dann beim Klartext-Fallback.
 */
async function recoveredDisplayTokens(ctx, inst) {
  if (!inst || inst.Calc_Role !== 'display_calculation') return null;
  const formula = inst.Formula_Text;
  if (formula == null || formula === '') return null;
  const db = require('../config/database');
  const tokensFormatter = require('../formatters/tokens.formatter');
  const refRes = await db.executeQuery(
    ctx,
    `SELECT DISTINCT Ref_Type, Ref_Name, Ref_UUID, TO_Name
     FROM XMLCalcReferences
     WHERE Source_UUID = ? AND File_Name = ? AND Subrole = ?
       AND Ref_Type IN ('field', 'customfunction', 'variable')`,
    [inst.Owner_UUID, inst.File_Name, inst.Calc_Kind_Raw]
  );
  const refs = refRes.rows.map(r => ({
    type: r.Ref_Type === 'field' ? 'field'
        : r.Ref_Type === 'customfunction' ? 'customFunction'
        : 'variable',
    name: String(r.Ref_Name),
    uuid: r.Ref_UUID != null ? String(r.Ref_UUID) : null,
    toName: r.TO_Name != null ? String(r.TO_Name) : null,
  }));
  return tokensFormatter.synthesizeRecoveredCalcTokens(formula, refs);
}

/**
 * GET /api/get - Get object by UUID
 */
async function get(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { uuid, file, format = 'json', meta, debug, lang } = req.query;

    const result = await objectService.getByUUID(ctx, uuid, file);

    // ?lang=<code> — lokalisierte Fassung des Namens NEBEN dem kanonischen.
    // Betrifft BuiltinFunction, dessen Katalogname seit Schema 1.32.0
    // sprachunabhängig kanonisch ist; alle anderen Typen bleiben unberührt.
    if (lang) await referenceService.enrichBuiltinLocalizedNames(ctx, [result.data], lang);

    const formattedData = formatters.format([result.data], format);

    sendFormatted(
      res,
      format === 'json' ? formattedData[0] : formattedData,
      format,
      meta ? result.meta : null,
      debug ? `SELECT * FROM ObjectCatalog WHERE Object_UUID = '${uuid}'` : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/list - List objects by type
 *
 * Neue Pseudo-Token-Parameter
 * (?withUsage, ?withCategory, ?category, ?sort) durchgereicht an den Service.
 */
async function list(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const {
      type, file, limit,
      with_usage, with_category, category, sort,
      format = 'json', meta, debug, lang,
    } = req.query;

    const result = await objectService.listObjects(ctx, {
      type, file, limit,
      withUsage: with_usage, withCategory: with_category, category, sort,
    });

    // Lokalisierte Namen der Built-ins mitliefern (s. /api/get) — damit
    // Objektliste und Detailseite denselben Namen zeigen.
    if (lang) await referenceService.enrichBuiltinLocalizedNames(ctx, result.data, lang);

    const formattedData = formatters.format(result.data, format);

    // Debug-SQL nur für den einfachen (nicht aggregierten) Pfad sinnvoll.
    const debugQuery = debug
      ? `list type=${type} with_usage=${!!with_usage} with_category=${!!with_category} category=${category || ''} sort=${sort || '(default)'} file=${file || ''} limit=${limit}`
      : null;

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debugQuery
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/list/categories - Pseudo-Token-Filter-Pillen Datenbasis
 * { category, token_count, total_usage } pro Category.
 */
async function listCategories(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { type, file, format = 'json', meta, debug } = req.query;

    const result = await objectService.listCategorySummary(ctx, { type, file });

    const formattedData = formatters.format(result.data, format);

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debug ? `list-categories type=${type} file=${file || ''}` : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/list-with-folders - Hierarchisch annotierte Liste eines Subtyps (Scripts/Layouts/CFs).
 * Liefert Items + Folder + Separators in sequenzieller Reihenfolge mit nesting_level.
 * Wrappt das Custom-Template list_with_folders.sql.
 */
async function listWithFolders(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { type, file, format = 'json', meta, debug } = req.query;
    const subtype = SUBTYPE_FOR_TYPE[type];

    const result = await templateService.executeTemplate(
      ctx,
      'list_with_folders',
      { subtype, file },
      'query'
    );

    const formattedData = formatters.format(result.data, format);

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debug ? result.sql : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/count - Count objects
 */
async function count(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { type, file, group_by, format = 'json', meta, debug } = req.query;

    const result = await objectService.countObjects(ctx, { type, file, group_by });

    const formattedData = formatters.format(result.data, format);

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debug ? 'COUNT query (SQL not shown for brevity)' : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/search - Search objects by name
 */
async function search(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { name, type, file, limit, offset, format = 'json', meta, debug, lang } = req.query;

    const result = await objectService.searchObjects(ctx, { name, type, file, limit, offset });

    // Lokalisierte Namen in der Trefferliste (s. /api/get). Ergänzt den
    // Such-Zweig, der Built-ins auch unter ihrer lokalisierten Schreibweise
    // FINDET (Matched_Spelling) — Finden und Anzeigen gehören zusammen.
    if (lang) await referenceService.enrichBuiltinLocalizedNames(ctx, result.data, lang);

    const formattedData = formatters.format(result.data, format);

    const debugQuery = debug
      ? `SELECT * FROM ObjectCatalog WHERE Object_Name LIKE '${name}'${type ? ` AND Object_Type = '${type}'` : ''}${file ? ` AND File_Name = '${file}'` : ''} ORDER BY Object_Name LIMIT ${limit} OFFSET ${offset}`
      : null;

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debugQuery
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/search/count - Count search results by name pattern
 */
async function searchCount(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { name, type, file, format = 'json', meta, debug } = req.query;

    const result = await objectService.countSearchResults(ctx, { name, type, file });

    const formattedData = formatters.format(result.data, format);

    const debugQuery = debug
      ? `SELECT COUNT(*) as count FROM ObjectCatalog WHERE Object_Name ILIKE '${name}'${type ? ` AND Object_Type = '${type}'` : ''}${file ? ` AND File_Name = '${file}'` : ''}`
      : null;

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debugQuery
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/references - Get object references
 */
async function references(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { uuid, file, origin, direction, link_type, limit, format = 'json', meta, debug } = req.query;

    const result = await objectService.getReferences(ctx, { uuid, direction, link_type, limit, file, origin });

    const formattedData = formatters.format(result.data, format);

    sendFormatted(
      res,
      formattedData,
      format,
      meta ? result.meta : null,
      debug ? `References query for ${direction} direction (SQL not shown for brevity)` : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/get-details - Get object details by UUID (type-specific template dispatch)
 */
async function getDetails(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { uuid, file, format = 'json', meta, debug, lang } = req.query;

    // format=tokens has its own dispatch path with type-specific templates and
    // dedicated post-processing. Use a per-type look-up plus the tokens formatter
    // instead of running the generic detail template through the format pipeline.
    if (format === 'tokens') {
      return await respondWithTokens(req, res, { uuid, file, meta, debug, enrich: req.query.enrich });
    }

    // ?lang=<code> — aktive UI-Sprache für Detail-Templates, die eine
    // lokalisierte Schreibweise neben dem (kanonischen) Katalognamen zeigen.
    const result = await objectService.getDetails(ctx, uuid, file, lang);

    // Content templates auto-override to content formatter (except JSON)
    let effectiveFormat = format;
    if (result.meta.template_type === 'content' && format !== 'json') {
      effectiveFormat = 'content';
    }

    const formattedData = formatters.format(result.data, effectiveFormat);

    sendFormatted(
      res,
      formattedData,
      effectiveFormat,
      meta ? result.meta : null,
      debug ? result.sql : null
    );
  } catch (error) {
    next(error);
  }
}

/**
 * ?enrich=<lang> für step-basierte Token-Payloads (Script/ScriptStep/LayoutObject-
 * Step): pro Step-Line Display-Name/Beschreibung/Help-URL aus der Reference-DB
 * ergänzen (Lookup über Step-ID, sprach-unabhängig vom lokalisierten Step_Name) und
 * Function-Refs (type='function') aus Step-Calcs anreichern. Mutiert payload.lines
 * in-place. Gibt das Meta-Fragment zurück ({ enrich } bzw. Soft-Fail
 * { enrich:null, enrich_error }); wirft bei ungültiger Sprache.
 */
async function enrichStepLines(ctx, payload, enrich) {
  try {
    const enrichLang = referenceService.resolveStepLang(enrich);
    const stepMeta = await referenceService.getStepMetaMap(ctx, enrichLang);

    const fnRefs = [];
    for (const line of payload.lines) {
      if (line.stepId != null) {
        const m = stepMeta.get(line.stepId);
        if (m) {
          line.stepDisplayName = m.displayName;
          line.stepDescription = m.description;
          line.stepHelpUrl     = m.helpUrl;
          line.stepLocalHelpUrl = m.localHelpUrl;
          line.stepCategoryId  = m.categoryId;
        }
      }
      if (Array.isArray(line.refs)) {
        for (const r of line.refs) {
          if (r.type === 'function') fnRefs.push(r);
        }
      }
    }
    if (fnRefs.length > 0) {
      const adapted = fnRefs.map((r) => ({ type: 'function', content: r.name, __ref: r }));
      await referenceService.enrichFunctionTokens(ctx, adapted, enrichLang);
      for (const a of adapted) {
        if (typeof a.functionId === 'number') {
          const r = a.__ref;
          r.functionId          = a.functionId;
          r.functionCanonical   = a.functionCanonical;
          if (a.functionSubParameter) r.functionSubParameter = a.functionSubParameter;
          r.functionDisplayName = a.functionDisplayName;
          r.functionSignature   = a.functionSignature;
          r.functionPurpose     = a.functionPurpose;
          r.functionReturnType  = a.functionReturnType;
          r.functionHelpUrl     = a.functionHelpUrl;
          r.functionLocalHelpUrl = a.functionLocalHelpUrl;
        }
      }
    }
    return { enrich: enrichLang };
  } catch (e) {
    if (e.code === 'REF_LANG_INVALID') {
      throw createError('VALIDATION_ERROR', e.message, e.details || {});
    }
    if (e.code === 'REF_NOT_ATTACHED') {
      return { enrich: null, enrich_error: e.code };
    }
    throw e;
  }
}

/**
 * format=tokens dispatcher for /api/get-details.
 *
 * Looks up the object type from ObjectCatalog, then runs the token-specific
 * SQL template(s) for that type and feeds the rows through the tokens formatter.
 * Currently supported: Script, ScriptStep, LayoutObject (button-embedded step),
 * CustomFunction, Field, CustomMenu, CustomMenuItem. Other types return 400.
 */
async function respondWithTokens(req, res, { uuid, file, meta, debug, enrich }) {
  const ctx = req.solutionContext;
  // 1. Look up object metadata so we know which token template to run.
  const lookup = await objectService.getByUUID(ctx, uuid, file);
  const objectType = lookup.data.Object_Type;
  const baseObject = {
    uuid,
    name: lookup.data.Object_Name,
    file: lookup.data.File_Name,
  };
  // Klon-Disambiguierung: die aufgelöste Datei (getByUUID hat sie eindeutig
  // bestimmt bzw. 409 geworfen) an ALLE Token-Templates weiterreichen, sonst
  // joinen sie eine geteilte Klon-UUID gegen alle Dateien → Schritte/Tokens
  // erscheinen mehrfach.
  const resolvedFile = lookup.data.File_Name;

  let payload;
  let metaInfo = {
    object_type: objectType,
    object_name: lookup.data.Object_Name,
    file_name: lookup.data.File_Name,
  };
  let debugSql = null;

  if (objectType === 'Script') {
    const stepsResult = await templateService.executeTemplate(
      ctx,
      'object_details_script_tokens',
      { uuid, file: resolvedFile },
      'report'
    );
    const refsResult = await templateService.executeTemplate(
      ctx,
      'object_references_script',
      { uuid, file: resolvedFile },
      'report'
    );

    payload = formatters.format(stepsResult.data, 'tokens', {
      kind: 'script',
      object: baseObject,
      refs: refsResult.data,
    });

    // ?enrich=<lang> — pro Step-Line Display-Name/Beschreibung/Help-URL aus
    // der Reference-DB ergänzen. Ohne `enrich` bleibt der Payload byte-identisch
    // zum bisherigen Verhalten (Akzeptanzkriterium "byte-identisch").
    if (enrich) {
      try {
        const enrichLang = referenceService.resolveStepLang(enrich);
        const stepMeta = await referenceService.getStepMetaMap(ctx, enrichLang);

        // Funktion-Refs (type='function') aus Calcs sammeln — diese werden
        // pro Line in den refs[] geliefert (SQL-Block 6 in object_references_script.sql).
        // Wir sammeln alle eindeutigen Tokens für einen Bulk-Lookup.
        const fnRefs = [];
        for (const line of payload.lines) {
          if (line.stepId != null) {
            const m = stepMeta.get(line.stepId);
            if (m) {
              line.stepDisplayName = m.displayName;
              line.stepDescription = m.description;
              line.stepHelpUrl = m.helpUrl;
              line.stepLocalHelpUrl = m.localHelpUrl;
              line.stepCategoryId = m.categoryId;
            }
          }
          if (Array.isArray(line.refs)) {
            for (const r of line.refs) {
              if (r.type === 'function') {
                // enrichFunctionTokens iteriert über Items mit `content`-Feld
                // (analog zum Calc-Token-Format). Wir wrappen ScriptRefs in
                // ein Adapter-Objekt, das auf `name` als `content` zeigt.
                fnRefs.push(r);
              }
            }
          }
        }
        if (fnRefs.length > 0) {
          // Adapter: enrichFunctionTokens erwartet `t.content` — wir aliasen
          // auf `name`, lassen das Ergebnis dann durch.
          const adapted = fnRefs.map((r) => ({
            type: 'function',
            content: r.name,
            __ref: r,
          }));
          await referenceService.enrichFunctionTokens(ctx, adapted, enrichLang);
          for (const a of adapted) {
            if (typeof a.functionId === 'number') {
              const r = a.__ref;
              r.functionId          = a.functionId;
              r.functionCanonical   = a.functionCanonical;
              if (a.functionSubParameter) r.functionSubParameter = a.functionSubParameter;
              r.functionDisplayName = a.functionDisplayName;
              r.functionSignature   = a.functionSignature;
              r.functionPurpose     = a.functionPurpose;
              r.functionReturnType  = a.functionReturnType;
              r.functionHelpUrl     = a.functionHelpUrl;
              r.functionLocalHelpUrl = a.functionLocalHelpUrl;
            }
          }
        }
        metaInfo = { ...metaInfo, enrich: enrichLang };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          // soft-fail: enrich liefert nichts, Antwort sonst unverändert
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: 'object_details_script_tokens',
      references_template: 'object_references_script',
    };
    debugSql = debug ? `${stepsResult.sql}\n\n-- references:\n${refsResult.sql}` : null;
  } else if (objectType === 'ScriptStep') {
    // ScriptStep-Detail: 1-Zeilen-Variante des Script-Tokens-Payloads. Der
    // Step wird über Step_UUID aufgelöst und der Parent-Script-Kontext in
    // object.parentScript abgelegt, damit das Frontend einen Sprung-Link
    // zum Skript und die Step-Position anzeigen kann.
    const stepResult = await templateService.executeTemplate(
      ctx,
      'object_details_scriptstep_tokens',
      { uuid, file: resolvedFile },
      'report'
    );

    if (!stepResult.data || stepResult.data.length === 0) {
      throw createError('OBJECT_NOT_FOUND', `ScriptStep with UUID '${uuid}' not found`, { uuid });
    }

    const stepRow = stepResult.data[0];
    const parentScriptUuid = stepRow.parent_script_uuid;
    const parentStepIndex  = Number(stepRow.parent_step_index);

    // Refs des Parent-Scripts holen, dann auf den einen Step filtern und
    // line_index auf 0 mappen (im 1-Zeilen-Payload liegt unsere Zeile bei 0).
    // Das vermeidet eine Duplikation des 265-Zeilen-Refs-Templates.
    const refsResult = await templateService.executeTemplate(
      ctx,
      'object_references_script',
      { uuid: parentScriptUuid, file: resolvedFile },
      'report'
    );
    const filteredRefs = (refsResult.data || [])
      .filter(r => Number(r.line_index) === parentStepIndex)
      .map(r => ({ ...r, line_index: 0 }));

    const enrichedObject = {
      ...baseObject,
      parentScript: {
        uuid: parentScriptUuid,
        name: stepRow.parent_script_name,
        file: stepRow.parent_file_name,
      },
      stepIndex: parentStepIndex,
    };

    payload = formatters.format(stepResult.data, 'tokens', {
      kind: 'script',
      object: enrichedObject,
      refs: filteredRefs,
    });

    // Enrich-Pipeline: identisch zum Script-Case (Step-Meta + Function-Refs).
    if (enrich) {
      try {
        const enrichLang = referenceService.resolveStepLang(enrich);
        const stepMeta = await referenceService.getStepMetaMap(ctx, enrichLang);

        const fnRefs = [];
        for (const line of payload.lines) {
          if (line.stepId != null) {
            const m = stepMeta.get(line.stepId);
            if (m) {
              line.stepDisplayName = m.displayName;
              line.stepDescription = m.description;
              line.stepHelpUrl     = m.helpUrl;
              line.stepLocalHelpUrl = m.localHelpUrl;
              line.stepCategoryId  = m.categoryId;
            }
          }
          if (Array.isArray(line.refs)) {
            for (const r of line.refs) {
              if (r.type === 'function') fnRefs.push(r);
            }
          }
        }
        if (fnRefs.length > 0) {
          const adapted = fnRefs.map((r) => ({ type: 'function', content: r.name, __ref: r }));
          await referenceService.enrichFunctionTokens(ctx, adapted, enrichLang);
          for (const a of adapted) {
            if (typeof a.functionId === 'number') {
              const r = a.__ref;
              r.functionId          = a.functionId;
              r.functionCanonical   = a.functionCanonical;
              if (a.functionSubParameter) r.functionSubParameter = a.functionSubParameter;
              r.functionDisplayName = a.functionDisplayName;
              r.functionSignature   = a.functionSignature;
              r.functionPurpose     = a.functionPurpose;
              r.functionReturnType  = a.functionReturnType;
              r.functionHelpUrl     = a.functionHelpUrl;
              r.functionLocalHelpUrl = a.functionLocalHelpUrl;
            }
          }
        }
        metaInfo = { ...metaInfo, enrich: enrichLang };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: 'object_details_scriptstep_tokens',
      references_template: 'object_references_script',
    };
    debugSql = debug ? `${stepResult.sql}\n\n-- references:\n${refsResult.sql}` : null;
  } else if (objectType === 'CustomFunction') {
    const cfResult = await templateService.executeTemplate(
      ctx,
      'object_details_customfunction_tokens',
      { uuid, file: resolvedFile },
      'report'
    );

    payload = formatters.format(cfResult.data, 'tokens', {
      kind: 'customfunction',
      object: baseObject,
    });

    // ?enrich=<lang> — Calc-Tokens vom Type 'function' aus der Reference-DB
    // anreichern (function_name_lookup → functions / functions_lang). Soft-Fail
    // wenn die Reference-DB nicht attached ist; Validation-Fehler werden
    // hochgereicht.
    if (enrich) {
      try {
        await referenceService.enrichFunctionTokens(ctx, payload.tokens, enrich);
        metaInfo = { ...metaInfo, enrich };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: 'object_details_customfunction_tokens',
    };
    debugSql = debug ? cfResult.sql : null;
  } else if (objectType === 'Field') {
    const fldResult = await templateService.executeTemplate(
      ctx,
      'object_details_field_tokens',
      { uuid, file: resolvedFile },
      'report'
    );

    payload = formatters.format(fldResult.data, 'tokens', {
      kind: 'field',
      object: baseObject,
    });

    // ?enrich=<lang> — Calc-Tokens vom Type 'function' aus der Reference-DB
    // anreichern. Identische Semantik wie bei CustomFunction.
    if (enrich) {
      try {
        await referenceService.enrichFunctionTokens(ctx, payload.tokens, enrich);
        metaInfo = { ...metaInfo, enrich };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: 'object_details_field_tokens',
    };
    debugSql = debug ? fldResult.sql : null;
  } else if (objectType === 'CustomMenu' || objectType === 'CustomMenuItem') {
    const cmTemplate = objectType === 'CustomMenuItem'
      ? 'object_details_custommenuitem_tokens'
      : 'object_details_custommenu_tokens';
    const cmResult = await templateService.executeTemplate(
      ctx,
      cmTemplate,
      { uuid, file: resolvedFile },
      'report'
    );

    payload = formatters.format(cmResult.data, 'tokens', {
      kind: 'custommenu',
      object: baseObject,
    });

    // ?enrich=<lang> — Calc-Tokens vom Type 'function' anreichern. Die Tokens
    // liegen pro Calc-Block; für die Anreicherung über alle Blöcke flach sammeln
    // (enrichFunctionTokens mutiert in-place, die Referenzen bleiben erhalten).
    if (enrich) {
      try {
        const allTokens = (payload.calcs || []).flatMap(c => c.tokens || []);
        await referenceService.enrichFunctionTokens(ctx, allTokens, enrich);
        metaInfo = { ...metaInfo, enrich };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: cmTemplate,
    };
    debugSql = debug ? cmResult.sql : null;
  } else if (objectType === 'LayoutObject') {
    // Button-eingebetteter Einzel-Step (Grouped Button / Button): als 1-Zeilen-
    // Tokens-Payload rendern, damit das Frontend den Klartext-Step mit Step-Namen-
    // Tooltip (enrich) und verlinkten Parametern zeigt (wie im Script-Detail).
    // Objekte ohne eingebetteten Step liefern 0 Zeilen → das Frontend rendert
    // keine Step-Sektion.
    const stepResult = await templateService.executeTemplate(
      ctx,
      'object_details_layoutobject_step_tokens',
      { uuid, file: resolvedFile },
      'report'
    );
    const refsResult = await templateService.executeTemplate(
      ctx,
      'object_references_layoutobject_step',
      { uuid, file: resolvedFile },
      'report'
    );

    payload = formatters.format(stepResult.data, 'tokens', {
      kind: 'script',
      object: baseObject,
      refs: refsResult.data,
    });

    if (enrich) {
      metaInfo = { ...metaInfo, ...(await enrichStepLines(ctx, payload, enrich)) };
    }

    // Calc-Slot-Instanzen des Objekts (hide, tooltip, conditional_format 1..n,
    // portal_filter, web_viewer_url, trigger-Parameter, …) aus dem
    // CalculationsCatalog — das Frontend rendert jeden Slot tokenisiert via
    // get-calc?uuid. Katalog vor Schema 1.22.0: graceful ohne Slots.
    try {
      const db = require('../config/database');
      const slotRes = await db.executeQuery(
        ctx,
        `SELECT Calculation_UUID, Calc_Role, Calc_Index, Source_Path, Is_Static,
                (DDR_Calc_UUID IS NOT NULL) AS Has_Tokens,
                Formula_Text, Result_Type,
                COALESCE(Formula_Text, Display_Text) AS Plain_Text
         FROM CalculationsCatalog
         WHERE Owner_UUID = ? AND File_Name = ?
         ORDER BY CASE Calc_Role
             WHEN 'hide' THEN 0 WHEN 'tooltip' THEN 1 WHEN 'placeholder' THEN 2
             WHEN 'button_label' THEN 3 WHEN 'panel_title' THEN 4 WHEN 'popover_title' THEN 5
             WHEN 'web_viewer_url' THEN 6 WHEN 'portal_filter' THEN 7
             WHEN 'conditional_format' THEN 8 WHEN 'script_trigger_parameter' THEN 9
             ELSE 10 END, Calc_Index`,
        [uuid, resolvedFile]
      );
      payload.calcSlots = slotRes.rows.map(r => ({
        uuid: String(r.Calculation_UUID),
        role: r.Calc_Role,
        index: Number(r.Calc_Index),
        sourcePath: r.Source_Path ?? null,
        isStatic: r.Is_Static === true || r.Is_Static === 'True',
        hasTokens: r.Has_Tokens === true || r.Has_Tokens === 'True',
        plainText: r.Plain_Text ?? null,
        // Display-Calculations (Schema 1.27.0): Ergebnistyp + rekonstruierter
        // Layout-Textanker (zweigeteilte Slot-Darstellung); NULL für andere Rollen.
        resultType: r.Result_Type ?? null,
        layoutFormula: buildLayoutFormula(r.Calc_Role, r.Result_Type, r.Formula_Text),
      }));
    } catch (e) {
      payload.calcSlots = [];
    }

    // LayoutObject-Kontext: konkreter Objekt-Typ + Eltern-Layout (Rücksprung
    // „Im Layout anzeigen" der Ziel-Leiste) + Struktur-Eigenschaften für das
    // Eigenschaften-Panel (Part, Bounds, Nesting, klickbarer Parent — der
    // Parent-Link ist zugleich die Gegenrichtung der Kind-Sektion unten).
    // Fehlender Datensatz → null.
    let layoutContextTO = null;
    try {
      const db = require('../config/database');
      const ctxRes = await db.executeQuery(
        ctx,
        `SELECT lo.Object_Type, lo.Object_ID, lo.Part_Type, lo.Nesting_Level,
                lo.Bounds_Top, lo.Bounds_Left, lo.Bounds_Bottom, lo.Bounds_Right,
                lo.Text_Content,
                l.L_UUID AS Layout_UUID, l.L_Name AS Layout_Name,
                l.L_TO_Name AS Layout_TO_Name,
                po.Object_UUID AS Parent_UUID, po.Object_Type AS Parent_Type,
                po.Object_Name AS Parent_Name
         FROM LayoutObjects lo
         JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
         LEFT JOIN LayoutObjects po
           ON po.Object_ID = lo.Parent_Object_ID
          AND po.Layout_ID = lo.Layout_ID
          AND po.File_Name = lo.File_Name
         WHERE lo.Object_UUID = ? AND lo.File_Name = ?
         LIMIT 1`,
        [uuid, resolvedFile]
      );
      const row = ctxRes.rows[0];
      layoutContextTO = row?.Layout_TO_Name ?? null;
      payload.layoutObject = row
        ? {
            type: row.Object_Type,
            layoutUuid: row.Layout_UUID ? String(row.Layout_UUID) : null,
            layoutName: row.Layout_Name ?? null,
            objectId: row.Object_ID != null ? Number(row.Object_ID) : null,
            partType: row.Part_Type ?? null,
            nestingLevel: row.Nesting_Level != null ? Number(row.Nesting_Level) : null,
            // Original-Textblock des Objekts (Layout-Wahrheit inkl. aller
            // Merge-Anker und Fließtext) — Sektion „Textinhalt" im Frontend.
            textContent: row.Text_Content ?? null,
            bounds:
              row.Bounds_Top != null
                ? {
                    top: Number(row.Bounds_Top),
                    left: Number(row.Bounds_Left),
                    bottom: Number(row.Bounds_Bottom),
                    right: Number(row.Bounds_Right),
                  }
                : null,
            parent: row.Parent_UUID
              ? {
                  uuid: String(row.Parent_UUID),
                  type: row.Parent_Type ?? null,
                  name: row.Parent_Name || null,
                }
              : null,
          }
        : null;
    } catch (e) {
      payload.layoutObject = null;
    }

    // Aufgelöste Merge-Text-Zeile (mergeText): reine Merge-Anker (<<Feld>>,
    // <<$$var>>, {{Symbol}}) haben modellbedingt KEINE Calculation-Instanz —
    // ihre Auflösung lebt in den Kanten (displays_field/displays_variable)
    // und im Symbol-Inventar. Hier wird daraus eine typisierte Token-Zeile
    // synthetisiert (tokens.formatter.synthesizeMergeTextTokens); ƒ-Anker
    // bleiben Pass-through, ihre Formeln zeigen die calcSlots. Nur Text-
    // Objekte (displays_field existiert auch an Feld-Platzierungen!), DDR-
    // unabhängig, Best-Effort: Fehler → Feld fehlt. Symbol-Gültigkeit prüft
    // die Standard-Referenz über den GESAMTEN Get-Parameter-Namensraum, ohne
    // match_source-Filter: FileMaker akzeptiert und rendert auch den
    // lokalisierten Parameternamen ({{Seitennummer}}), und ein Export kann
    // beide Formen tragen — ein canonical_en-Filter erklärte gültige Symbole
    // fälschlich für literal. Dieselbe Vergleichsmenge nutzen die Regel
    // layout_invalid_symbol und der Konverter (GetParameterNames).
    // Ohne ATTACH bleiben Symbole literal — LayoutObjectSymbols inventarisiert
    // auch ungültige, unvalidiert wäre Get(…) eine falsche Aussage.
    try {
      const lo = payload.layoutObject;
      if (lo && lo.type === 'Text' && lo.textContent) {
        const db = require('../config/database');
        const tokensFormatter = require('../formatters/tokens.formatter');

        const edgeRes = await db.executeQuery(
          ctx,
          `SELECT ol.Link_Role, ol.Target_UUID,
                  oc.Object_Name AS Target_Name,
                  ff.Field_Name, ff.Table_Name
           FROM ObjectLinks ol
           LEFT JOIN ObjectCatalog oc
             ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
           LEFT JOIN FieldsForTables ff
             ON ol.Link_Role = 'displays_field'
            AND ff.Field_UUID = ol.Target_UUID AND ff.File_Name = ol.Target_File
           WHERE ol.Source_UUID = ? AND ol.Source_Type = 'LayoutObject'
             AND ol.Source_File = ?
             AND ol.Link_Role IN ('displays_field', 'displays_variable')`,
          [uuid, resolvedFile]
        );
        const fields = [];
        const variables = [];
        for (const r of edgeRes.rows) {
          if (r.Link_Role === 'displays_field') {
            fields.push({
              name: r.Field_Name != null ? String(r.Field_Name) : null,
              baseTable: r.Table_Name != null ? String(r.Table_Name) : null,
              uuid: r.Target_UUID != null ? String(r.Target_UUID) : null,
            });
          } else {
            variables.push({
              name: r.Target_Name != null ? String(r.Target_Name) : null,
              uuid: r.Target_UUID != null ? String(r.Target_UUID) : null,
            });
          }
        }

        const symRes = await db.executeQuery(
          ctx,
          `SELECT Symbol_Text, Symbol_Norm
           FROM LayoutObjectSymbols
           WHERE Object_UUID = ? AND File_Name = ?`,
          [uuid, resolvedFile]
        );
        let symbols = symRes.rows.map(r => ({
          text: r.Symbol_Text != null ? String(r.Symbol_Text) : null,
          norm: r.Symbol_Norm != null ? String(r.Symbol_Norm) : null,
          valid: false,
        }));
        if (symbols.length > 0 && db.isReferenceAttached()) {
          try {
            const norms = symbols.map(s => s.norm).filter(Boolean);
            const placeholders = norms.map(() => '?').join(',');
            const valRes = await db.executeQuery(
              ctx,
              `SELECT DISTINCT lower(lookup_name) AS norm
               FROM ref.function_name_lookup
               WHERE chunk_role = 'getparameter'
                 AND lower(lookup_name) IN (${placeholders})`,
              norms
            );
            const validNorms = new Set(valRes.rows.map(r => String(r.norm)));
            symbols = symbols.map(s => ({ ...s, valid: s.norm != null && validNorms.has(s.norm) }));
          } catch (e) {
            // Soft-Fail: ohne Referenz-Urteil bleiben Symbole literal.
          }
        }

        const toBaseTable = {};
        if (/<</.test(lo.textContent)) {
          const toRes = await db.executeQuery(
            ctx,
            `SELECT TO_Name, BT_Name FROM TableOccurrenceCatalog WHERE File_Name = ?`,
            [resolvedFile]
          );
          for (const r of toRes.rows) {
            if (r.TO_Name != null && r.BT_Name != null) {
              toBaseTable[String(r.TO_Name).toLowerCase()] = String(r.BT_Name);
            }
          }
        }

        const merge = tokensFormatter.synthesizeMergeTextTokens(lo.textContent, {
          fields, variables, symbols, toBaseTable, layoutTOName: layoutContextTO,
        });
        if (merge) {
          payload.mergeText = {
            tokens: merge.tokens,
            anchors: { total: merge.anchorsTotal, resolved: merge.anchorsResolved },
          };
          // Get-Token-Gruppen der Symbole an der bestehenden Function-Token-
          // Anreicherung teilnehmen lassen (Mouseover-Parität zu Formeln).
          if (enrich) {
            try {
              const fnToks = merge.tokens.filter(t => t.type === 'function');
              if (fnToks.length > 0) {
                const enrichLang = referenceService.resolveStepLang(enrich);
                await referenceService.enrichFunctionTokens(ctx, fnToks, enrichLang);
              }
            } catch (e) {
              // Soft-Fail analog enrichStepLines — Tokens bleiben unangereichert.
            }
          }
        }
      }
    } catch (e) {
      // Best-Effort — der Detailview bleibt ohne mergeText voll funktionsfähig.
    }

    // Direkte Kind-Objekte (Button-Bar-Segmente, Tab-Panels, Group-/Popover-/
    // Portal-Inhalte) für die Kind-Objekt-Sektion — nur die direkte Ebene,
    // sortiert nach Z_Order (= Segment-Reihenfolge, gegen die Bounds
    // verifiziert; Object_ID als Tiebreak). Pro Kind das gehoistete Ziel nach
    // der v2-Auflösungsregel (displays_field → portal_context →
    // triggers_script[button_action] → navigates_to_layout): Event-Trigger
    // scheiden aus der Objekt-Auflösung aus und speisen ausschließlich die
    // Trigger-Liste (owner-genau aus ScriptTriggers, nicht aus der Kanten-
    // Subrole — die attribuiert nur als Multiset je Gruppe). NULL-Subrole
    // (Importe < Converter 2.14.0) nimmt als Fallback am button_action-Rang
    // teil. Die Button-Aktion wird zusätzlich separat geliefert, wenn sie
    // nicht selbst das gehoistete Ziel ist (Feld-Control, das zugleich Button
    // ist). Label-Calculation wie gehabt (button_label bei Segmenten,
    // panel_title/popover_title bei Panels — pro Kind höchstens eine Rolle).
    try {
      const db = require('../config/database');
      const childRes = await db.executeQuery(
        ctx,
        `WITH me AS (
           SELECT Object_ID, Layout_ID, File_Name
           FROM LayoutObjects
           WHERE Object_UUID = ? AND File_Name = ?
           LIMIT 1
         ),
         kids AS (
           SELECT lo.Object_UUID, lo.Object_ID, lo.Z_Order, lo.Object_Type,
                  lo.Object_Name, lo.Text_Content, lo.Label_Calculation_Text
           FROM LayoutObjects lo
           JOIN me ON lo.Parent_Object_ID = me.Object_ID
                  AND lo.Layout_ID = me.Layout_ID
                  AND lo.File_Name = me.File_Name
         ),
         edges AS (
           SELECT ol.Source_UUID, ol.Link_Role, ol.Link_Subrole, ol.Target_UUID,
                  ol.Target_Type, ol.Target_File, oc.Object_Name AS Target_Name
           FROM ObjectLinks ol
           LEFT JOIN ObjectCatalog oc
             ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
           WHERE ol.Source_UUID IN (SELECT Object_UUID FROM kids)
             AND ol.Source_Type = 'LayoutObject'
             AND ol.Source_File = (SELECT File_Name FROM me)
             AND ol.Link_Role IN ('triggers_script', 'navigates_to_layout',
                                  'displays_field', 'portal_context')
         ),
         tgt AS (
           SELECT * FROM (
             SELECT e.*,
                    ROW_NUMBER() OVER (
                      PARTITION BY e.Source_UUID
                      ORDER BY CASE e.Link_Role
                          WHEN 'displays_field' THEN 0
                          WHEN 'portal_context' THEN 1
                          WHEN 'triggers_script' THEN 2
                          WHEN 'navigates_to_layout' THEN 3 END,
                        e.Target_Name
                    ) AS rn
             FROM edges e
             WHERE e.Link_Role <> 'triggers_script'
                OR e.Link_Subrole = 'button_action'
                OR e.Link_Subrole IS NULL
           ) WHERE rn = 1
         ),
         btn AS (
           SELECT * FROM (
             SELECT e.Source_UUID, e.Target_UUID, e.Target_Type, e.Target_File,
                    e.Target_Name,
                    ROW_NUMBER() OVER (
                      PARTITION BY e.Source_UUID ORDER BY e.Target_Name
                    ) AS rn
             FROM edges e
             WHERE e.Link_Role = 'triggers_script'
               AND e.Link_Subrole = 'button_action'
           ) WHERE rn = 1
         ),
         trg AS (
           SELECT st.Owner_UUID,
                  list(struct_pack(action := st.Trigger_Action,
                                   script_uuid := st.Script_UUID,
                                   script_name := st.Script_Name,
                                   trigger_uuid := 'trig_' || st.Trigger_ID || '_' || st.Owner_UUID || '_' || st.File_Name)
                       ORDER BY st.Trigger_ID) AS Trigger_List
           FROM ScriptTriggers st
           WHERE st.Owner_UUID IN (SELECT Object_UUID FROM kids)
             AND st.Owner_Type = 'LayoutObject'
             AND st.File_Name = (SELECT File_Name FROM me)
           GROUP BY st.Owner_UUID
         ),
         lbl AS (
           SELECT cc.Owner_UUID,
                  arg_min(cc.Calculation_UUID, cc.Calc_Index) AS Calc_UUID,
                  arg_min(cc.DDR_Calc_UUID IS NOT NULL, cc.Calc_Index) AS Has_Tokens,
                  arg_min(COALESCE(cc.Formula_Text, cc.Display_Text), cc.Calc_Index) AS Label_Text
           FROM CalculationsCatalog cc
           WHERE cc.Owner_UUID IN (SELECT Object_UUID FROM kids)
             AND cc.File_Name = (SELECT File_Name FROM me)
             AND cc.Calc_Role IN ('button_label', 'panel_title', 'popover_title')
           GROUP BY cc.Owner_UUID
         )
         SELECT k.Object_UUID, k.Object_ID, k.Object_Type, k.Object_Name, k.Text_Content,
                l.Calc_UUID AS Label_Calc_UUID, l.Has_Tokens AS Label_Has_Tokens,
                COALESCE(l.Label_Text, k.Label_Calculation_Text) AS Label_Text,
                t.Link_Role AS Target_Role, t.Target_UUID, t.Target_Type,
                t.Target_Name, t.Target_File,
                b.Target_UUID AS Btn_UUID, b.Target_Type AS Btn_Type,
                b.Target_Name AS Btn_Name, b.Target_File AS Btn_File,
                tr.Trigger_List
         FROM kids k
         LEFT JOIN lbl l ON l.Owner_UUID = k.Object_UUID
         LEFT JOIN tgt t ON t.Source_UUID = k.Object_UUID
         LEFT JOIN btn b ON b.Source_UUID = k.Object_UUID
         LEFT JOIN trg tr ON tr.Owner_UUID = k.Object_UUID
         ORDER BY k.Z_Order, k.Object_ID`,
        [uuid, resolvedFile]
      );
      payload.children = childRes.rows.map(r => ({
        uuid: String(r.Object_UUID),
        objectId: Number(r.Object_ID),
        type: r.Object_Type,
        name: r.Object_Name || null,
        textContent: r.Text_Content ?? null,
        labelCalcUuid: r.Label_Calc_UUID ? String(r.Label_Calc_UUID) : null,
        labelHasTokens: r.Label_Has_Tokens === true || r.Label_Has_Tokens === 'True',
        labelText: r.Label_Text ?? null,
        target: r.Target_UUID
          ? {
              uuid: String(r.Target_UUID),
              type: r.Target_Type ?? null,
              name: r.Target_Name ?? null,
              file: r.Target_File ?? null,
              linkRole: r.Target_Role,
            }
          : null,
        triggers: Array.isArray(r.Trigger_List)
          ? r.Trigger_List.map(tg => ({
              action: tg.action ?? null,
              scriptUuid: tg.script_uuid ? String(tg.script_uuid) : null,
              scriptName: tg.script_name ?? null,
              triggerUuid: tg.trigger_uuid ? String(tg.trigger_uuid) : null,
            }))
          : [],
        // Button-Aktion nur separat, wenn nicht selbst als Ziel gehoistet
        // (Target_Role 'triggers_script' deckt auch den NULL-Subrole-Fallback).
        buttonAction:
          r.Btn_UUID && r.Target_Role !== 'triggers_script'
            ? {
                uuid: String(r.Btn_UUID),
                type: r.Btn_Type ?? null,
                name: r.Btn_Name ?? null,
                file: r.Btn_File ?? null,
              }
            : null,
      }));
    } catch (e) {
      payload.children = [];
    }

    // Script-Trigger des Objekts als strukturierte Tabelle (Event, Modi,
    // Script, Parameter-Calculation). Die Parameter-Zuordnung läuft über den
    // Edge_Subrole-Join ('ScriptTrigger_<id>' → Trigger_ID) — bewusst NICHT
    // über ObjectLinks/Link_Subrole (die triggers_script-Subrole trägt seit
    // Converter 2.14.0 das Event bzw. 'button_action' als Multiset je Gruppe,
    // keine Trigger_ID; ScriptTriggers bleibt hier die owner-genaue Quelle).
    try {
      const db = require('../config/database');
      const trgRes = await db.executeQuery(
        ctx,
        `SELECT st.Trigger_ID, st.Trigger_Action,
                st.Trigger_BrowseMode, st.Trigger_FindMode, st.Trigger_PreviewMode,
                st.Script_Name, st.Script_UUID,
                'trig_' || st.Trigger_ID || '_' || st.Owner_UUID || '_' || st.File_Name AS Trigger_UUID,
                cc.Calculation_UUID AS Param_Calc_UUID,
                (cc.DDR_Calc_UUID IS NOT NULL) AS Param_Has_Tokens,
                COALESCE(cc.Formula_Text, cc.Display_Text) AS Param_Text
         FROM ScriptTriggers st
         LEFT JOIN CalculationsCatalog cc
           ON cc.Owner_UUID = st.Owner_UUID
          AND cc.File_Name = st.File_Name
          AND cc.Calc_Role = 'script_trigger_parameter'
          AND cc.Edge_Subrole = 'ScriptTrigger_' || st.Trigger_ID
         WHERE st.Owner_UUID = ? AND st.Owner_Type = 'LayoutObject' AND st.File_Name = ?
         ORDER BY st.Trigger_ID`,
        [uuid, resolvedFile]
      );
      const asBool = v => v === true || v === 'True';
      payload.triggers = trgRes.rows.map(r => ({
        triggerId: Number(r.Trigger_ID),
        action: r.Trigger_Action,
        browseMode: asBool(r.Trigger_BrowseMode),
        findMode: asBool(r.Trigger_FindMode),
        previewMode: asBool(r.Trigger_PreviewMode),
        scriptUuid: r.Script_UUID ? String(r.Script_UUID) : null,
        scriptName: r.Script_Name ?? null,
        triggerUuid: r.Trigger_UUID ? String(r.Trigger_UUID) : null,
        paramCalcUuid: r.Param_Calc_UUID ? String(r.Param_Calc_UUID) : null,
        paramHasTokens: r.Param_Has_Tokens === true || r.Param_Has_Tokens === 'True',
        paramText: r.Param_Text ?? null,
      }));
    } catch (e) {
      payload.triggers = [];
    }

    // Ziel-Links für die Ziel-Leiste (displays_field, displays_variable,
    // portal_context, navigates_to_layout, uses_valuelist). triggers_script
    // bleibt bewusst draußen: Trigger-Ziele leben in der Trigger-Tabelle, das
    // Button-Action-Ziel kommt aus den Refs des eingebetteten Steps (die
    // Kanten-Subrole attribuiert nur als Multiset je Gruppe, nicht kanten-genau).
    try {
      const db = require('../config/database');
      const tgtRes = await db.executeQuery(
        ctx,
        `SELECT ol.Link_Role, ol.Target_UUID, ol.Target_Type, ol.Target_File,
                ol.Is_Cross_File, oc.Object_Name AS Target_Name
         FROM ObjectLinks ol
         LEFT JOIN ObjectCatalog oc
           ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
         WHERE ol.Source_UUID = ? AND ol.Source_Type = 'LayoutObject'
           AND ol.Source_File = ?
           AND ol.Link_Role IN ('displays_field', 'displays_variable', 'portal_context', 'navigates_to_layout', 'uses_valuelist')
         ORDER BY CASE ol.Link_Role
             WHEN 'displays_field' THEN 0 WHEN 'displays_variable' THEN 1
             WHEN 'portal_context' THEN 2
             WHEN 'navigates_to_layout' THEN 3 WHEN 'uses_valuelist' THEN 4
             ELSE 5 END, oc.Object_Name`,
        [uuid, resolvedFile]
      );
      payload.targets = tgtRes.rows.map(r => ({
        linkRole: r.Link_Role,
        uuid: String(r.Target_UUID),
        type: r.Target_Type ?? null,
        name: r.Target_Name ?? null,
        file: r.Target_File ?? null,
        crossFile: r.Is_Cross_File === true || r.Is_Cross_File === 'True',
      }));
    } catch (e) {
      payload.targets = [];
    }

    // Conditional-Formatting-Regeln aus LayoutObjectConditions (Schema 1.25.0,
    // regel-genau & selbstverankert — auch rein wertbasierte Bedingungen),
    // inkl. geparstem Format (C3-CSS-Parser) — gleiche Datenquelle wie der
    // Standalone-Endpoint /api/conditional-formatting. Katalog ohne Tabelle/
    // Import: graceful leer, die conditional_format-Slots der generischen
    // Liste bleiben dann als Fallback stehen (siehe unten).
    try {
      const cfService = require('../services/conditional-formatting.service');
      const cf = await cfService.getRulesForObject(ctx, uuid, resolvedFile);
      payload.conditions = cf.rules;
    } catch (e) {
      payload.conditions = [];
    }

    // Slot-Konsolidierung: Trigger-Parameter leben vollständig in der Trigger-
    // Tabelle, CF-Formeln in der Regel-Tabelle — die generische Slot-Liste
    // zeigt beide nicht mehr doppelt. Nur konsolidieren, was die Tabellen
    // tatsächlich abdecken (alter Import ohne Trigger-/Conditions-Daten
    // behält seine Slots).
    if (Array.isArray(payload.calcSlots)) {
      const coveredParams = new Set(
        (payload.triggers || []).map(t => t.paramCalcUuid).filter(Boolean)
      );
      const hasConditions = (payload.conditions || []).length > 0;
      payload.calcSlots = payload.calcSlots.filter(s => {
        if (s.role === 'script_trigger_parameter') return !coveredParams.has(s.uuid);
        if (s.role === 'conditional_format') return !hasConditions;
        return true;
      });
    }

    metaInfo = {
      ...metaInfo,
      template_used: 'object_details_layoutobject_step_tokens',
      references_template: 'object_references_layoutobject_step',
    };
    debugSql = debug ? `${stepResult.sql}\n\n-- references:\n${refsResult.sql}` : null;
  } else if (objectType === 'Calculation') {
    // Calculation-Instanz (Schema 1.22.0): Katalog-Datensatz + Tokens + Ziel-Links.
    // Der DDR-los-Fallback wird am Katalog-DATENSATZ entschieden (DDR_Calc_UUID),
    // nicht über den Fehlerpfad des Token-Templates.
    const db = require('../config/database');
    const instRes = await db.executeQuery(
      ctx,
      `SELECT Calculation_UUID, Owner_UUID, Owner_Type, Owner_Name, Calc_Role,
              Calc_Kind_Raw, Calc_Index, Source_Path, Is_Static, Formula_Hash,
              DDR_Calc_UUID, Context_TO_Name, Chunk_Count, Ref_Count,
              Formula_Text, Result_Type,
              COALESCE(Formula_Text, Display_Text) AS Plain_Text, File_Name
       FROM CalculationsCatalog
       WHERE Calculation_UUID = ? AND File_Name = ?
       LIMIT 1`,
      [uuid, resolvedFile]
    );
    if (!instRes.rows || instRes.rows.length === 0) {
      throw createError('OBJECT_NOT_FOUND', `Calculation '${uuid}' not found`, { uuid });
    }
    const inst = instRes.rows[0];
    const hasTokens = inst.DDR_Calc_UUID != null;

    if (hasTokens) {
      const calcResult = await templateService.executeTemplate(
        ctx,
        'object_details_calculation_tokens',
        { uuid, file: resolvedFile },
        'report'
      );
      payload = formatters.format(calcResult.data, 'tokens', {
        kind: 'calculation',
        object: { uuid },
      });
      debugSql = debug ? calcResult.sql : null;
    } else {
      // DDR-lose Instanz: kein Token-Fetch — struktureller Klartext als Fallback.
      payload = {
        kind: 'calculation',
        object: { uuid },
        tokens: [],
        plainText: inst.Plain_Text ?? '',
      };
      // Display-Calculations: synthetische Tokenisierung aus der
      // geretteten Formel + den slot-skopierten Referenzen — Tooltips und
      // Cross-Navigation trotz leerer DDR-ChunkList; Builtins bleiben Text.
      try {
        const recovered = await recoveredDisplayTokens(ctx, inst);
        if (recovered) {
          payload.tokens = recovered;
          payload.tokensRecovered = true;
        }
      } catch (e) {
        // Rettung ist Best-Effort — Klartext-Fallback bleibt der Vertrag.
      }
    }
    payload.object = { ...payload.object, name: baseObject.name, file: inst.File_Name };
    payload.calc = {
      role: inst.Calc_Role,
      kindRaw: inst.Calc_Kind_Raw ?? null,
      index: Number(inst.Calc_Index),
      sourcePath: inst.Source_Path ?? null,
      isStatic: inst.Is_Static === true || inst.Is_Static === 'True',
      hasTokens,
      hash: inst.Formula_Hash ?? null,
      contextTo: inst.Context_TO_Name ?? null,
      // Display-Calculations (Schema 1.27.0): Ergebnistyp aus dem %X:-Präfix
      // + rekonstruierter Layout-Textanker für die zweigeteilte Darstellung
      // (Rohschicht „Layoutformel" über dem kanonischen Token-Körper).
      resultType: inst.Result_Type ?? null,
      layoutFormula: buildLayoutFormula(inst.Calc_Role, inst.Result_Type, inst.Formula_Text),
      owner: {
        uuid: String(inst.Owner_UUID),
        type: inst.Owner_Type,
        name: inst.Owner_Name ?? null,
        file: inst.File_Name,
      },
    };
    if (!payload.plainText && inst.Plain_Text) payload.plainText = inst.Plain_Text;

    // Ziel-Links der Instanz (abgeleitet aus den owner-projizierten Kanten).
    try {
      const tgtRes = await db.executeQuery(
        ctx,
        `SELECT vl.Link_Role, vl.Target_UUID, vl.Target_Type, vl.Target_File, vl.Is_Cross_File,
                COALESCE(oc.Object_Name, vl.Target_UUID) AS Target_Name
         FROM v_calculation_links vl
         LEFT JOIN ObjectCatalog oc ON oc.Object_UUID = vl.Target_UUID
           AND (oc.File_Name = vl.Target_File OR (oc.File_Name IS NULL AND vl.Target_File IS NULL))
         WHERE vl.Calculation_UUID = ?
         ORDER BY vl.Link_Role, Target_Name, vl.Target_UUID`,
        [uuid]
      );
      payload.targets = tgtRes.rows.map(r => ({
        linkRole: r.Link_Role,
        uuid: r.Target_UUID != null ? String(r.Target_UUID) : null,
        type: r.Target_Type ?? null,
        name: r.Target_Name != null ? String(r.Target_Name) : null,
        file: r.Target_File ?? null,
        crossFile: r.Is_Cross_File === true || r.Is_Cross_File === 'True',
      }));

      // Display-Calculations: Variablen-Ziele ergänzen —
      // Variablen-Kanten tragen keine Link_Subrole (Modell-Eigenschaft von
      // Block 28), v_calculation_links kann sie daher nicht slot-zuordnen.
      // Die slot-skopierten XMLCalcReferences-Zeilen (chunk-basiert bzw.
      // A.6.10b-Rettung) liefern die Zuordnung; die Variable-Objekt-UUID folgt
      // der Block-28-Formel md5(Scope::Anchor::Name) via VariablesCatalog.
      if (inst.Calc_Role === 'display_calculation') {
        try {
          const varRes = await db.executeQuery(
            ctx,
            `SELECT DISTINCT
                    md5(vc.Variable_Scope || '::' || vc.Scope_Anchor || '::' || vc.Variable_Name) AS Var_UUID,
                    vc.Variable_Name
             FROM XMLCalcReferences x
             JOIN VariablesCatalog vc
               ON vc.Variable_Name  = x.Ref_Name
              AND vc.Variable_Scope = x.Variable_Scope
             WHERE x.Source_UUID = ? AND x.File_Name = ? AND x.Subrole = ?
               AND x.Ref_Type = 'variable'
             ORDER BY vc.Variable_Name`,
            [inst.Owner_UUID, inst.File_Name, inst.Calc_Kind_Raw]
          );
          for (const r of varRes.rows) {
            payload.targets.push({
              linkRole: 'reads_variable',
              uuid: String(r.Var_UUID),
              type: 'Variable',
              name: String(r.Variable_Name),
              file: inst.File_Name,
              crossFile: false,
            });
          }
        } catch (e) {
          // Best-Effort — targets bleiben ohne Variablen-Zeilen.
        }
      }
    } catch (e) {
      payload.targets = [];
    }

    if (enrich && payload.tokens && payload.tokens.length > 0) {
      try {
        await referenceService.enrichFunctionTokens(ctx, payload.tokens, enrich);
        metaInfo = { ...metaInfo, enrich };
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          metaInfo = { ...metaInfo, enrich: null, enrich_error: e.code };
        } else {
          throw e;
        }
      }
    }

    metaInfo = {
      ...metaInfo,
      template_used: hasTokens ? 'object_details_calculation_tokens' : null,
    };
  } else if (objectType === 'ScriptTrigger') {
    // ScriptTrigger-Detail: die ScriptTriggers-Zeile ist die Attribut-Quelle
    // (Event, Modi, Script, Parameter). Zuordnung über die UUID-Rekonstruktion
    // 'trig_<id>_<OwnerUUID>_<File>' — Trigger_ID allein ist NICHT eindeutig
    // (die Slot-Räume 1–8/101+/201+ wiederholen sich je Owner). Script-Datei
    // kommt von der importzeitlich aufgelösten trigger_script-Kante (nicht aus
    // einem Catalog-Join über die bloße Script_UUID — Klon-Fan-out). Owner-
    // Kette: LayoutObject-Owner bekommen ihr Eltern-Layout über parent_layout
    // mitgeliefert (Breadcrumb Datei › Layout › Objekt).
    const db = require('../config/database');
    const trgRes = await db.executeQuery(
      ctx,
      `SELECT st.Trigger_ID, st.Trigger_Action,
              st.Trigger_BrowseMode, st.Trigger_FindMode, st.Trigger_PreviewMode,
              st.Script_UUID, st.Script_Name, tsl.Target_File AS Script_File,
              st.Owner_UUID, st.Owner_Type, st.File_Name,
              ownc.Object_Name AS Owner_Name,
              il.Object_UUID AS Layout_UUID, il.Object_Name AS Layout_Name,
              st.Trigger_ScriptParameter_FieldName,
              cc.Calculation_UUID AS Param_Calc_UUID,
              (cc.DDR_Calc_UUID IS NOT NULL) AS Param_Has_Tokens,
              COALESCE(cc.Formula_Text, cc.Display_Text) AS Param_Text
       FROM ScriptTriggers st
       LEFT JOIN ObjectCatalog ownc
         ON ownc.Object_UUID = st.Owner_UUID AND ownc.File_Name = st.File_Name
       LEFT JOIN ObjectLinks olp
         ON st.Owner_Type = 'LayoutObject'
        AND olp.Source_UUID = st.Owner_UUID AND olp.Source_File = st.File_Name
        AND olp.Link_Role = 'parent_layout'
       LEFT JOIN ObjectCatalog il
         ON olp.Target_UUID = il.Object_UUID AND olp.Target_File = il.File_Name
       LEFT JOIN ObjectLinks tsl
         ON tsl.Source_UUID = ? AND tsl.Source_File = st.File_Name
        AND tsl.Link_Role = 'trigger_script'
       LEFT JOIN CalculationsCatalog cc
         ON cc.Owner_UUID = st.Owner_UUID
        AND cc.File_Name = st.File_Name
        AND cc.Calc_Role = 'script_trigger_parameter'
        AND cc.Edge_Subrole = 'ScriptTrigger_' || st.Trigger_ID
       WHERE 'trig_' || st.Trigger_ID || '_' || st.Owner_UUID || '_' || st.File_Name = ?
         AND st.File_Name = ?
       LIMIT 1`,
      [uuid, uuid, resolvedFile]
    );
    if (!trgRes.rows || trgRes.rows.length === 0) {
      throw createError('OBJECT_NOT_FOUND', `ScriptTrigger '${uuid}' not found`, { uuid });
    }
    const trg = trgRes.rows[0];
    const asBool = v => v === true || v === 'True';

    // Namens-Kandidaten des Transaktions-Parameterfelds (OnWindowTransaction):
    // eine Kante je gleichnamigem Feld der eigenen Datei; Tabellen-Zuordnung
    // über FieldsForTables (nie über den Catalog-Namen).
    let fieldCandidates = [];
    try {
      const candRes = await db.executeQuery(
        ctx,
        `SELECT ol.Target_UUID, oc.Object_Name, oc.File_Name, fft.Table_Name
         FROM ObjectLinks ol
         JOIN ObjectCatalog oc
           ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
         LEFT JOIN FieldsForTables fft
           ON fft.Field_UUID = ol.Target_UUID AND fft.File_Name = oc.File_Name
         WHERE ol.Source_UUID = ? AND ol.Source_File = ?
           AND ol.Link_Role = 'reads_field'
           AND ol.Link_Subrole = 'transaction_parameter_field'
         ORDER BY fft.Table_Name, oc.Object_Name`,
        [uuid, resolvedFile]
      );
      fieldCandidates = candRes.rows.map(r => ({
        uuid: String(r.Target_UUID),
        name: r.Object_Name ?? null,
        file: r.File_Name ?? null,
        tableName: r.Table_Name ?? null,
      }));
    } catch (e) {
      fieldCandidates = [];
    }

    payload = {
      kind: 'scripttrigger',
      object: { ...baseObject, type: 'ScriptTrigger' },
      trigger: {
        triggerId: Number(trg.Trigger_ID),
        action: trg.Trigger_Action ?? null,
        browseMode: asBool(trg.Trigger_BrowseMode),
        findMode: asBool(trg.Trigger_FindMode),
        previewMode: asBool(trg.Trigger_PreviewMode),
        scriptUuid: trg.Script_UUID ? String(trg.Script_UUID) : null,
        scriptName: trg.Script_Name ?? null,
        scriptFile: trg.Script_File ?? trg.File_Name ?? null,
        paramCalcUuid: trg.Param_Calc_UUID ? String(trg.Param_Calc_UUID) : null,
        paramHasTokens: asBool(trg.Param_Has_Tokens),
        paramText: trg.Param_Text ?? null,
        scriptParameterFieldName: trg.Trigger_ScriptParameter_FieldName ?? null,
      },
      owner: {
        uuid: String(trg.Owner_UUID),
        type: trg.Owner_Type,
        name: trg.Owner_Name ?? null,
        file: trg.File_Name,
        layoutUuid: trg.Layout_UUID ? String(trg.Layout_UUID) : null,
        layoutName: trg.Layout_Name ?? null,
      },
      fieldCandidates,
    };
    metaInfo = { ...metaInfo, template_used: null };
  } else {
    throw createError(
      'VALIDATION_ERROR',
      `format=tokens is not supported for object type '${objectType}'`,
      { uuid, objectType, supported: ['Script', 'ScriptStep', 'LayoutObject', 'CustomFunction', 'Field', 'CustomMenu', 'CustomMenuItem', 'Calculation', 'ScriptTrigger'] }
    );
  }

  // Cross-Nav-Links der BuiltinFunction-Tokens gegen den Katalog auflösen
  // (betrifft alle Token-Views: Script/ScriptStep/LayoutObject/CF/Field/
  // CustomMenu/Calculation).
  await resolveBuiltinLinks(ctx, payload);

  return sendFormatted(res, payload, 'tokens', meta ? metaInfo : null, debugSql);
}

/**
 * Setzt die Cross-Navigation-UUID der BuiltinFunction-Tokens — per NACHSCHLAGEN
 * im Katalog, nicht per Rechnen aus dem Namen.
 *
 * Vorgeschichte: der Tokenizer (tokens.formatter.js) mintete für jedes
 * `function`-Token `md5('BuiltinFunction::' + name)` und war damit eine dritte
 * Kopie der Identitätsregel des Imports. Das ging nur auf, solange Katalog-
 * Identität und Formel-Token derselbe Text waren — bei einer lokalisierten
 * Autorensprache erzeugte es eine UUID, die es nicht gibt, und diese Funktion
 * musste sie hinterher wieder wegräumen. Seit Katalog-Schema 1.32.0 normalisiert
 * der Import die Built-ins auf den kanonischen englischen Namen der Referenz und
 * schreibt die Identität mit (BuiltinFunctionIdentity) — die Auflösung ist
 * seither ein Lookup gegen die dafür gebaute Katalog-Fläche
 * `v_builtin_token_lookup`: Token-Name (in JEDER Referenzsprache, beide
 * Namensräume, plus die Rohnamen der Namens-Fallback-Knoten) → Knoten. Die
 * Vorrangregel steckt in der View, nicht hier — der Consumer schlägt nur nach.
 *
 * Ein Token ohne Treffer bleibt uuidlos (kein Link statt 404) — die frühere
 * Tot-Link-Bereinigung ist damit strukturell erledigt statt nachgelagert.
 * Ausnahme wie bisher: die Boolean-Operatoren `and/or/not/xor` bleiben bewusst
 * unverlinkt, auch wenn der Import sie als Knoten führt (ob Operatoren und
 * Konstanten überhaupt BuiltinFunction-Objekte sein sollten, ist eine eigene
 * Frage — hier wird die bisherige Darstellung nicht verändert).
 *
 * Erfasst die Tokens REKURSIV über den ganzen Payload, nicht über eine Liste
 * bekannter Pfade. Grund ist eine real getroffene Falle: die Token-Container
 * liegen je Objekttyp anders (`payload.tokens` bei CF/Field, `payload.calcs[]
 * .tokens` bei CustomMenu, `payload.mergeText.tokens` bei den aufgelösten
 * Platzhaltern eines LayoutObjects) — eine Pfadliste vergisst genau den, der
 * später dazukommt, und das Symptom ist ein still unverlinktes Token.
 *
 * Nur Tokens mit `content` werden angefasst. Die Script-Referenzliste
 * (`payload.lines[].refs`) trägt `name` statt `content` und ihre UUID kommt
 * bereits aus dem SQL-Template (object_references_script.sql, Lookup gegen
 * v_builtin_token_lookup) — sie muss hier unberührt bleiben, sonst würde die
 * Bereinigung unten eine korrekte UUID wieder wegräumen.
 */
const BUILTIN_LINK_EXCLUDED = new Set(['and', 'or', 'not', 'xor']);

/** Sammelt jedes `function`-Token MIT `content` rekursiv aus dem Payload. */
function collectFunctionTokens(node, out = [], depth = 0) {
  if (!node || depth > 12) return out;
  if (Array.isArray(node)) {
    for (const v of node) collectFunctionTokens(v, out, depth + 1);
    return out;
  }
  if (typeof node !== 'object') return out;
  if (node.type === 'function' && typeof node.content === 'string') out.push(node);
  for (const v of Object.values(node)) collectFunctionTokens(v, out, depth + 1);
  return out;
}

async function resolveBuiltinLinks(ctx, payload) {
  if (!payload) return;
  const tokens = collectFunctionTokens(payload);
  if (tokens.length === 0) return;

  const names = new Set();
  for (const t of tokens) {
    if (t.content.length > 0 && !BUILTIN_LINK_EXCLUDED.has(t.content)) names.add(t.content);
  }
  if (names.size === 0) return;

  // Bulk-Lookup über den Vergleichsschlüssel der View (lower(<Name>)) — eine
  // IN-Liste wie in reference.service.enrichFunctionTokens, nicht eine
  // VALUES-Zeile: `VALUES (?,?)` wäre EINE Zeile mit zwei Spalten und würde
  // alle Namen bis auf den ersten still verschlucken.
  const normList = Array.from(new Set(Array.from(names, n => n.toLowerCase())));
  const placeholders = normList.map(() => '?').join(',');
  const database = require('../config/database');
  let rows = [];
  try {
    const r = await database.executeQuery(
      ctx,
      `SELECT l.Name_Norm, l.Object_UUID
       FROM v_builtin_token_lookup l
       WHERE l.Name_Norm IN (${placeholders})`,
      normList
    );
    rows = r.rows;
  } catch (e) {
    // Katalog vor Schema 1.32.0 (keine v_builtin_token_lookup): lieber alle
    // Built-in-Tokens unverlinkt ausliefern als geratene 404-Links. Der
    // zentrale Drift-Erkenner meldet den Re-Import-Bedarf ohnehin am nächsten
    // Template-Aufruf; ein Token ohne Link bleibt lesbar.
    rows = [];
  }

  const byNorm = new Map(rows.map(row => [String(row.Name_Norm), String(row.Object_UUID)]));
  for (const t of tokens) {
    const uuid = byNorm.get(t.content.toLowerCase());
    if (uuid) t.uuid = uuid;
    else if (t.uuid) delete t.uuid;
  }
}

/**
 * GET /api/get-calc - Standalone calculation (token format only).
 * Primary path (schema 1.22.0): ?uuid=<Calculation_UUID> — instance-exact via
 * CalculationsCatalog. ?hash= stays as alias (dedup pick); with ?meta the
 * response lists the instances sharing the hash (ambiguity made visible).
 */
async function getCalc(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { uuid, hash, file, format = 'tokens', meta, debug, enrich } = req.query;

    const result = await templateService.executeTemplate(
      ctx,
      'object_details_calculation_tokens',
      { uuid, hash, file },
      'report'
    );

    let payload;
    if (!result.data || result.data.length === 0) {
      // Display-Calculations mit LEERER DDR-ChunkList: statt 404 die
      // synthetische Tokenisierung aus der geretteten Formel + den
      // slot-skopierten Referenzen versuchen (uuid-Pfad; der Hash-Alias hat
      // keinen Instanz-Kontext und bleibt beim Not-Found-Vertrag).
      let recovered = null;
      let recInst = null;
      if (uuid) {
        try {
          const db = require('../config/database');
          const instRes = await db.executeQuery(
            ctx,
            `SELECT Calculation_UUID, Owner_UUID, Calc_Role, Calc_Kind_Raw,
                    Formula_Text, File_Name
             FROM CalculationsCatalog
             WHERE Calculation_UUID = ?${file ? ' AND File_Name = ?' : ''}
             LIMIT 1`,
            file ? [uuid, file] : [uuid]
          );
          recInst = instRes.rows[0] || null;
          recovered = await recoveredDisplayTokens(ctx, recInst);
        } catch (e) {
          recovered = null;
        }
      }
      if (recovered && recInst) {
        payload = {
          kind: 'calculation',
          object: { uuid },
          tokens: recovered,
          plainText: recInst.Formula_Text ?? '',
          tokensRecovered: true,
        };
      } else {
        throw createError(
          'OBJECT_NOT_FOUND',
          uuid
            ? `Calculation '${uuid}' not found (or without DDR chunk data)`
            : `Calculation with hash '${hash}' not found`,
          { uuid, hash }
        );
      }
    } else {
      payload = formatters.format(result.data, 'tokens', {
        kind: 'calculation',
        object: uuid ? { uuid } : { hash },
      });
    }

    const metaInfo = meta ? {
      template_used: 'object_details_calculation_tokens',
      ...(uuid ? { uuid } : { hash }),
    } : null;

    // Hash-Pfad + meta: Instanzliste (ein Hash ↔ n Verwendungsorte) sichtbar machen
    if (metaInfo && !uuid && hash) {
      try {
        const db = require('../config/database');
        const inst = await db.executeQuery(
          ctx,
          `SELECT Calculation_UUID, Owner_Type, Owner_Name, Calc_Role, File_Name
           FROM CalculationsCatalog WHERE Formula_Hash = ? ORDER BY File_Name, Owner_Name LIMIT 20`,
          [hash]
        );
        metaInfo.instance_count = inst.rows.length;
        metaInfo.instances = inst.rows;
      } catch (e) {
        // CalculationsCatalog fehlt (Katalog vor Schema 1.22.0) → graceful ohne Instanzliste
        metaInfo.instances_unavailable = true;
      }
    }

    // Built-in-Cross-Nav-Links auflösen — wie im zentralen Token-Pfad. Vorher
    // fehlte dieser Schritt hier, weil der Formatter die UUID selbst mintete;
    // seit der Katalog die Identität trägt, braucht auch dieser Endpunkt den
    // Lookup (und liefert dadurch nebenbei keine toten Links mehr).
    await resolveBuiltinLinks(ctx, payload);

    // ?enrich=<lang> — Calc-Token-Anreicherung via function_name_lookup
    if (enrich) {
      try {
        await referenceService.enrichFunctionTokens(ctx, payload.tokens, enrich);
        if (metaInfo) metaInfo.enrich = enrich;
      } catch (e) {
        if (e.code === 'REF_LANG_INVALID') {
          throw createError('VALIDATION_ERROR', e.message, e.details || {});
        }
        if (e.code === 'REF_NOT_ATTACHED') {
          if (metaInfo) metaInfo.enrich_error = e.code;
        } else {
          throw e;
        }
      }
    }

    return sendFormatted(res, payload, format, metaInfo, debug ? result.sql : null);
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/conditional-formatting - Conditional-formatting rules of one
 * layout object, rule-exact from LayoutObjectConditions with the parsed
 * format (C3 CSS parser: bit-gated colours/font/size, presence-based style
 * toggles, ready-to-use preview CSS + raw LocalCSS).
 *
 * Flat query-param route (?uuid=&file=) consistent with the rest of the API;
 * clone disambiguation follows the get-details path (getByUUID resolves the
 * file or throws AMBIGUOUS_UUID). Non-LayoutObject targets simply yield zero
 * rules; a catalog imported before schema 1.25.0 reports `unavailable`.
 */
async function conditionalFormatting(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { uuid, file, format = 'json', meta, debug } = req.query;

    const lookup = await objectService.getByUUID(ctx, uuid, file);
    const resolvedFile = lookup.data.File_Name;

    const cfService = require('../services/conditional-formatting.service');
    const result = await cfService.getRulesForObject(ctx, uuid, resolvedFile);

    const payload = {
      object: {
        uuid,
        name: lookup.data.Object_Name,
        type: lookup.data.Object_Type,
        file: resolvedFile,
      },
      rules: result.rules,
    };
    if (result.unavailable) payload.unavailable = true;

    const metaInfo = meta
      ? {
          rule_count: result.rules.length,
          source_table: 'LayoutObjectConditions',
          object_type: lookup.data.Object_Type,
        }
      : null;

    sendFormatted(res, payload, format, metaInfo,
      debug ? `SELECT … FROM LayoutObjectConditions WHERE Object_UUID = '${uuid}' AND File_Name = '${resolvedFile}' ORDER BY Rule_Index` : null);
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/back-references
 *
 * Liefert alle Objekt-UUIDs, die innerhalb eines Destination-Containers
 * (Layout / Script / CustomFunction) auf das Origin-Objekt verweisen.
 * Wird vom Frontend genutzt, um Cross-Reference-Highlights im Ziel-View
 * (z.B. LayoutCanvas matchUuids) vorzubelegen.
 *
 * Parameter:
 *   destination — Pflicht, UUID des aktuell geöffneten Objekts (Ziel-Container)
 *   origin      — Pflicht, UUID (oder Name) des auslösenden Objekts
 *   mode        — optional 'uuid' | 'name' | 'auto' (Default: auto)
 */
async function backReferences(req, res, next) {
  try {
    const ctx = req.solutionContext;
    const { destination, origin, dest_file, origin_file, mode = 'auto', format = 'json', meta, debug } = req.query;

    const destUuid = String(destination || '').trim();
    let originRaw = String(origin || '').trim();

    if (!destUuid || !originRaw) {
      throw createError('VALIDATION_ERROR',
        'Parameter `destination` und `origin` sind beide erforderlich.',
        { destination: destUuid, origin: originRaw });
    }

    // Destination muss eine (echte oder synthetische Katalog-) UUID sein und
    // existieren. Sub-Knoten wie ScriptTrigger/LayoutPart/Relationship tragen
    // synthetische Object_UUIDs (`trig_…`, `part_…`, `rel_…`, `paste_…`, `step_…`),
    // die dennoch gültige Navigations-/Highlight-Ziele sind — Existenz prüft getByUUID.
    if (!isCatalogUuid(destUuid)) {
      throw createError('VALIDATION_ERROR',
        '`destination` muss eine UUID sein.', { destination: destUuid });
    }
    const destObj = await objectService.getByUUID(ctx, destUuid, dest_file);

    // Origin: (echte/synthetische) UUID ODER Name-Lookup.
    const looksLikeUuid = isCatalogUuid(originRaw);
    const useUuid = mode === 'uuid' || (mode === 'auto' && looksLikeUuid);
    const useName = mode === 'name' || (mode === 'auto' && !looksLikeUuid);

    let originObj = null;
    let matchStrategy = 'uuid';

    if (useUuid) {
      try {
        const o = await objectService.getByUUID(ctx, originRaw, origin_file);
        originObj = o.data;
        matchStrategy = 'uuid';
      } catch (e) {
        if (e.code !== 'OBJECT_NOT_FOUND') throw e;
        // Fallback auf Name, falls UUID nicht im ObjectCatalog existiert.
        if (mode === 'auto') {
          originObj = await lookupOriginByName(ctx, originRaw);
          matchStrategy = originObj ? 'name-fallback' : 'unresolved';
        }
      }
    } else if (useName) {
      originObj = await lookupOriginByName(ctx, originRaw);
      matchStrategy = originObj ? 'name' : 'unresolved';
    }

    // Origin nicht aufgelöst → Antwort mit leerer Match-Liste; Frontend zeigt
    // Pill mit Hinweis "Origin nicht gefunden".
    if (!originObj) {
      return res.json(buildSuccess({
        destination: {
          uuid: destObj.data.Object_UUID,
          type: destObj.data.Object_Type,
          name: destObj.data.Object_Name,
        },
        origin: null,
        matches: [],
        match_strategy: 'unresolved',
      }, meta ? { destination: destUuid, origin: originRaw, mode } : null));
    }

    const result = await templateService.executeTemplate(
      ctx,
      'back_references',
      { destination: destUuid, origin: originObj.Object_UUID },
      'report',
    );

    const payload = {
      destination: {
        uuid: destObj.data.Object_UUID,
        type: destObj.data.Object_Type,
        name: destObj.data.Object_Name,
      },
      origin: {
        uuid: originObj.Object_UUID,
        type: originObj.Object_Type,
        name: originObj.Object_Name,
        file: originObj.File_Name,
      },
      matches: result.data,
      match_strategy: matchStrategy,
    };

    const metaInfo = meta ? {
      destination: destUuid,
      origin: originRaw,
      mode,
      match_count: result.data.length,
      template_used: 'back_references',
    } : null;

    return sendFormatted(res, payload, format, metaInfo, debug ? result.sql : null);
  } catch (error) {
    next(error);
  }
}

/**
 * Origin-Name-Fallback: exakter Match bevorzugt, sonst kürzester Teiltreffer.
 * Bei Mehrdeutigkeit gewinnt der kürzeste Name (heuristisch der spezifischste).
 */
async function lookupOriginByName(ctx, name) {
  const sql = `
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Name = ?
       OR Object_Name ILIKE ?
    ORDER BY (Object_Name = ?) DESC, length(Object_Name) ASC
    LIMIT 1
  `;
  const db = require('../config/database');
  const r = await db.executeQuery(ctx, sql, [name, `%${name}%`, name]);
  return r.rows[0] || null;
}

module.exports = {
  get,
  getDetails,
  getCalc,
  conditionalFormatting,
  list,
  listCategories,
  listWithFolders,
  count,
  search,
  searchCount,
  references,
  backReferences,
};
