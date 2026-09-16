const { LRUCache } = require('lru-cache');
const db = require('../config/database');
const docsManifest = require('./docs-manifest');
const { sqlPluginSubName } = require('../utils/plugin-name');

/**
 * Docs References Service
 *
 * Aggregiert "Anzahl Code-Referenzen pro Function/Category" für die
 * Counter-Pills im Frontend.
 *
 * Gating über catalog[].references:
 *   - references: true  → Aggregations-Queries werden ausgeführt
 *   - references: false → API liefert null, Frontend rendert keine Pill
 *
 * Aktuell implementiert:
 *   - MBS    → PluginFunction Object_Name = 'MBS:<Sub>::<Sub>' (fachliche fn_id =
 *              SubName hinter dem letzten '::', vgl. utils/plugin-name.js) →
 *              ObjectLinks(calls_pluginfunction)
 *   - Claris → BuiltinFunction + ScriptStepType → Reference-DB Name-Lookup
 *
 * Für Claris:
 *   • Functions: BuiltinFunction-Objects (Object_Name lokalisiert; Solution kann
 *     in beliebiger Sprache sein) werden gegen `ref.function_name_lookup`
 *     gejoint, das pro function_id alle bekannten Namen-Varianten kennt
 *     (canonical_en, display_de, fmstrs_eid …). Aggregation per function_id
 *     via SUM, weil mehrere Object-Namen auf denselben Funktion-Eintrag
 *     mappen können (z.B. "ZeitStempel" + "Timestamp" wenn beide auftauchen).
 *   • Script-Steps: Aggregate aus `StepsForScripts.Step_Name` (nicht aus
 *     ObjectLinks — es gibt heute keine Step→Type-Edge), gejoined gegen
 *     `ref.script_step_name_lookup`.
 *   • Categories: pro fn: / ss: Category aus den enthaltenen Function-/Step-
 *     Counts aggregiert.
 *
 * Cache: 60 Sekunden TTL pro Lösung+Set-ID (`<ctx.solution>:<setId>`);
 * Invalidation per `clearCache()` (via
 * /api/admin/reload nach jedem convert-xml-Lauf).
 */

const TTL_MS = 60 * 1000;

const fnCache = new LRUCache({ max: 50, ttl: TTL_MS });
const catCache = new LRUCache({ max: 50, ttl: TTL_MS });

function clearCache() {
  fnCache.clear();
  catCache.clear();
}

async function referencesPerFunctionMbs(ctx) {
  // fn_id = fachlicher SubName (deckt sich mit der Docset-Function-ID). Der
  // Katalog-Object_Name ist `MBS:<Sub>::<Sub>`; SubName = Teil hinter dem
  // letzten `::` (format-tolerant, vgl. utils/plugin-name.js).
  const subExpr = sqlPluginSubName('oc.Object_Name');
  const sql = `
    SELECT
      ${subExpr} AS fn_id,
      COUNT(*) AS ref_count
    FROM ObjectCatalog oc
    JOIN ObjectLinks ol ON oc.Object_UUID = ol.Target_UUID
    WHERE oc.Object_Type = 'PluginFunction'
      AND ol.Link_Role = 'calls_pluginfunction'
    GROUP BY fn_id
  `;
  const result = await db.executeQuery(ctx, sql);
  const map = new Map();
  for (const row of result.rows) {
    map.set(row.fn_id, Number(row.ref_count));
  }
  return map;
}

async function referencesPerCategoryMbs(ctx) {
  // MBS-Kategorie = Component-Präfix. Wir aggregieren über alle PluginFunction-Calls
  // und schneiden den SubName am ersten Punkt ab (`MBS:List.AddValue::List.AddValue`
  // → SubName `List.AddValue` → `List`; format-tolerant, vgl. utils/plugin-name.js).
  const sql = `
    SELECT
      split_part(${sqlPluginSubName('oc.Object_Name')}, '.', 1) AS category,
      COUNT(*) AS ref_count
    FROM ObjectCatalog oc
    JOIN ObjectLinks ol ON oc.Object_UUID = ol.Target_UUID
    WHERE oc.Object_Type = 'PluginFunction'
      AND ol.Link_Role = 'calls_pluginfunction'
    GROUP BY category
  `;
  const result = await db.executeQuery(ctx, sql);
  const map = new Map();
  for (const row of result.rows) {
    if (row.category) map.set(row.category, Number(row.ref_count));
  }
  return map;
}

/**
 * Claris-Funktionen (BuiltinFunction): pro `function_id` aus der Reference-DB
 * die Anzahl aufrufender ObjectLinks im FM-Catalog.
 *
 * Match-Logik: der Import schreibt die Referenz-Identität jedes aufgelösten
 * Built-in-Knotens mit (`BuiltinFunctionIdentity`, Katalog-Schema 1.32.0) — hier
 * wird sie NACHGESCHLAGEN, nicht aus dem Namen zurückgerechnet. Ein Knoten ohne
 * Identitätszeile ist bewusst nicht zählbar (Token, den die Referenz nicht
 * kennt: `Get`, die Keyword-/JSON-Konstanten, Funktionen neuer als die
 * Referenz).
 *
 * Vorher lief der Join namensbasiert über `ref.function_name_lookup` und hatte
 * zwei Fehler, die beide hier verschwinden:
 *   • Lokalisierte Autorensprachen zählten 0 — ein deutsches
 *     `HoleAlsZeitstempel` traf keinen `is_primary`-Namen. Der Import
 *     normalisiert die Knoten jetzt auf den kanonischen englischen Namen.
 *   • Get-Parameter zählten DOPPELT: die Referenz führt die gewickelte Form
 *     `Get(LayoutName)` (chunk_role 'getfunction') UND den nackten Parameter
 *     `LayoutName` ('getparameter') je mit is_primary = 1, und der Katalog trug
 *     für denselben Aufruf beide Knoten. Ein Knoten je Parameter plus ein
 *     Identitäts-Join zählt jetzt pro echter Aufrufstelle.
 * Damit fällt auch die `is_primary`-Krücke weg.
 *
 * Gezählt werden BEIDE Verwendungsklassen eines Built-ins:
 *   • `calls_function`  — Aufruf in einer Formel
 *   • `displays_symbol` — ein Layout-Symbol {{X}}, laut Claris-Doku der Wert von
 *                         Get(X) zur Anzeigezeit, also eine echte Verwendung
 *                         DIESES Get-Parameters (sie zählt auch im Where-used)
 * Beide sind Verwendungsnachweise derselben Funktion und der Zähler beantwortet
 * „wie oft kommt diese Funktion in der Lösung vor" — eine Klasse davon
 * wegzulassen hat einen Get-Parameter, den eine Lösung nur als Merge-Symbol
 * benutzt, mit 0 geführt (gemessen: Get(PageNumber) mit 10 Aufrufen und
 * 324 Symbolen wurde als 10 gezählt). Doppelzählung gibt es dabei nicht: ein
 * Layoutobjekt, das {{PageNumber}} zeigt UND in seiner Ausblendungsformel
 * Get(PageNumber) rechnet, sind zwei verschiedene Verwendungsstellen.
 */
async function referencesPerFunctionClarisFunctions(ctx) {
  const sql = `
    SELECT 'fn:' || bfi.Function_ID AS fn_id,
           COUNT(*)                 AS ref_count
    FROM ObjectLinks ol
    JOIN BuiltinFunctionIdentity bfi ON bfi.Object_UUID = ol.Target_UUID
    WHERE ol.Link_Role IN ('calls_function', 'displays_symbol')
    GROUP BY bfi.Function_ID
  `;
  const result = await db.executeQuery(ctx, sql);
  return result.rows;
}

/**
 * Claris-Script-Steps: Aggregate aus `StepsForScripts.Step_Name`. Step→Type-
 * Edges existieren heute nicht in ObjectLinks, daher direkte Aggregation auf
 * der Step-Tabelle.
 */
async function referencesPerFunctionClarisSteps(ctx) {
  const sql = `
    WITH usage AS (
      SELECT Step_Name AS name, COUNT(*) AS use_count
      FROM StepsForScripts
      GROUP BY Step_Name
    )
    SELECT 'ss:' || lk.step_id AS fn_id,
           SUM(usage.use_count) AS ref_count
    FROM usage
    JOIN ref.script_step_name_lookup lk ON lk.lookup_name = usage.name
    WHERE lk.is_primary = 1
    GROUP BY lk.step_id
  `;
  const result = await db.executeQuery(ctx, sql);
  return result.rows;
}

async function referencesPerFunctionClaris(ctx) {
  const [fns, sts] = await Promise.all([
    referencesPerFunctionClarisFunctions(ctx),
    referencesPerFunctionClarisSteps(ctx),
  ]);
  const map = new Map();
  for (const row of [...fns, ...sts]) {
    map.set(row.fn_id, Number(row.ref_count));
  }
  return map;
}

/**
 * Claris-Categories: aggregiere je Category die Counts ihrer enthaltenen
 * Funktionen + Script-Steps. Liefert IDs im selben Schema wie
 * `listDocsetCategories` (fn:<n> / ss:<n>).
 */
async function referencesPerCategoryClaris(ctx, fnMap) {
  if (!fnMap || fnMap.size === 0) return new Map();
  // Funktion-IDs ohne Prefix für SQL IN-Listen extrahieren.
  const fnIds = [];
  const ssIds = [];
  for (const [key, count] of fnMap) {
    if (count <= 0) continue;
    if (key.startsWith('fn:')) fnIds.push([parseInt(key.slice(3), 10), count]);
    else if (key.startsWith('ss:')) ssIds.push([parseInt(key.slice(3), 10), count]);
  }
  if (fnIds.length === 0 && ssIds.length === 0) return new Map();

  // VALUES-Liste mit Mappings function_id → count, dann GROUP BY category.
  // Wir bauen das als inline SQL (alle Werte sind Integers aus eigenem Code,
  // keine Injection-Vektoren).
  const map = new Map();

  if (fnIds.length > 0) {
    const valuesSql = fnIds.map(([id, c]) => `(${id}, ${c})`).join(',');
    const sql = `
      WITH cnt(function_id, ref_count) AS (VALUES ${valuesSql})
      SELECT 'fn:' || f.category_id AS cat_id, SUM(cnt.ref_count) AS total
      FROM cnt
      JOIN ref.functions f ON f.function_id = cnt.function_id
      GROUP BY f.category_id
    `;
    const result = await db.executeQuery(ctx, sql);
    for (const row of result.rows) map.set(row.cat_id, Number(row.total));
  }

  if (ssIds.length > 0) {
    const valuesSql = ssIds.map(([id, c]) => `(${id}, ${c})`).join(',');
    const sql = `
      WITH cnt(step_id, ref_count) AS (VALUES ${valuesSql})
      SELECT 'ss:' || s.category_id AS cat_id, SUM(cnt.ref_count) AS total
      FROM cnt
      JOIN ref.script_steps s ON s.step_id = cnt.step_id
      GROUP BY s.category_id
    `;
    const result = await db.executeQuery(ctx, sql);
    for (const row of result.rows) map.set(row.cat_id, Number(row.total));
  }
  return map;
}

/**
 * Liefert Map<functionId, count> oder null, wenn das Set nicht referenz-fähig ist.
 */
async function referencesPerFunction(ctx, setId) {
  const catalog = docsManifest.getCatalogEntry(setId);
  if (!catalog || !catalog.references) return null;
  const cacheKey = `${ctx?.solution ?? ''}:${setId}`;
  if (fnCache.has(cacheKey)) return fnCache.get(cacheKey);

  let map = null;
  try {
    if (setId === 'mbs') {
      map = await referencesPerFunctionMbs(ctx);
    } else if (setId === 'claris-help') {
      map = await referencesPerFunctionClaris(ctx);
    }
  } catch (err) {
    console.warn(`[docs-references] referencesPerFunction(${setId}) failed: ${err.message}`);
  }
  fnCache.set(cacheKey, map);
  return map;
}

async function referencesPerCategory(ctx, setId) {
  const catalog = docsManifest.getCatalogEntry(setId);
  if (!catalog || !catalog.references) return null;
  const cacheKey = `${ctx?.solution ?? ''}:${setId}`;
  if (catCache.has(cacheKey)) return catCache.get(cacheKey);

  let map = null;
  try {
    if (setId === 'mbs') {
      map = await referencesPerCategoryMbs(ctx);
    } else if (setId === 'claris-help') {
      // Reuse the function-level map so wir nicht zweimal über ObjectLinks
      // aggregieren müssen. referencesPerFunction setzt den Cache mit, daher
      // ist der zweite Call hier billig.
      const fnMap = await referencesPerFunction(ctx, setId);
      if (fnMap) map = await referencesPerCategoryClaris(ctx, fnMap);
    }
  } catch (err) {
    console.warn(`[docs-references] referencesPerCategory(${setId}) failed: ${err.message}`);
  }
  catCache.set(cacheKey, map);
  return map;
}

/**
 * Annotiert eine Categories-Liste mit code_ref_count (oder null, wenn Set
 * nicht referenz-fähig ist oder die Kategorie keine Referenzen hat).
 */
async function annotateCategoriesWithCounts(ctx, setId, categories) {
  const map = await referencesPerCategory(ctx, setId);
  return categories.map(c => ({
    ...c,
    code_ref_count: map ? (map.get(c.id) ?? 0) : null,
  }));
}

/**
 * Annotiert eine Functions-Liste mit code_ref_count.
 */
async function annotateFunctionsWithCounts(ctx, setId, functions) {
  const map = await referencesPerFunction(ctx, setId);
  return functions.map(f => ({
    ...f,
    code_ref_count: map ? (map.get(f.id) ?? 0) : null,
  }));
}

module.exports = {
  clearCache,
  referencesPerFunction,
  referencesPerCategory,
  annotateCategoriesWithCounts,
  annotateFunctionsWithCounts,
};
