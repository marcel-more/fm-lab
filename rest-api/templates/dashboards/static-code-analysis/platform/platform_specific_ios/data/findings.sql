-- Platform-binding inventory (axis b): scripts built FOR FileMaker Go (iOS).
-- Neutral by design: findings are properties, not defects — severity is always
-- 'info', the result state stays neutral and never colours a traffic light.
-- Two evidence sources, one row per occurrence:
--   step     — iOS-exclusive script steps, derived from ref.step_compat with a
--              strict exclusivity predicate (go = true AND every other runtime
--              column strictly false; NULL = Partial elsewhere disqualifies).
--              No hard-coded step-id list: the predicate follows future
--              fm_spec versions automatically.
--   function — iOS-dedicated builtin functions (curated affinity list):
--              callable everywhere, meaningful results only on iOS — called
--              directly OR transitively through custom functions (a CF that
--              wraps GetSensor makes its calling scripts iOS-dedicated too;
--              the feature text names the CF the script actually calls).
-- Script-level `binding` = strongest evidence class: exclusive > dedicated.
WITH RECURSIVE affinity AS (
    -- v5.1: curated affinity lives in fm_spec (function_platform_affinity,
    -- reference ≥ 1.12.0; provenance + evidence note per row). This replaced
    -- the v5 seed CTE — the curated list is maintained in the fm-spec build
    -- (grammar/function_platform_affinity.tsv + CURATION_LOG), not here.
    SELECT function_id, affinity
    FROM ref.function_platform_affinity
    WHERE platform = 'go'
),
step_evidence AS (
    SELECT s.File_Name AS file_name, s.Script_UUID AS nav_uuid,
           s.Script_Name AS script_name,
           'step' AS evidence_kind, 'exclusive' AS signal,
           COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
           s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
           st.url_slug AS doc_slug, 1 AS usage_count
    FROM StepsForScripts s
    JOIN ref.step_compat c ON c.step_id = s.Step_ID
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    WHERE s.Is_Enabled
      AND c.go = true AND c.pro = false AND c.server = false
      AND c.webdirect = false AND c.cloud = false AND c.dataapi = false
      AND c.cwp = false
),
-- Locale-tolerant function resolution: catalog BuiltinFunction names are
-- localized (GetSensor / HoleSensor / Get(NetworkType) / Hole ( Netzwerktyp )).
-- function_name_lookup carries all variants; comparison is space-insensitive
-- and additionally tries the inner text of a trailing "(…)" (Get forms).
seed_functions AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    JOIN affinity a ON a.function_id = fl.function_id
    WHERE fn.Object_Type = 'BuiltinFunction'
    GROUP BY fn.Object_UUID
),
function_evidence AS (
    SELECT src.File_Name AS file_name, src.Object_UUID AS nav_uuid,
           src.Object_Name AS script_name,
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           CAST(NULL AS INTEGER) AS step_no, CAST(NULL AS VARCHAR) AS step_uuid,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    JOIN affinity a ON a.function_id = sf.function_id
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, a.affinity,
             f.canonical_name, sf.function_id, f.url_slug
),
-- Transitive closure: custom functions that reach a seed function — directly
-- (calls_function CF→BuiltinFunction) or through other CFs (calls_customfunction
-- CF→CF). Path array guards cycles; DISTINCT collapses multi-path reaches.
cf_closure(cf_uuid, function_id, path) AS (
    SELECT ol.Source_UUID, sf.function_id, [ol.Source_UUID]
    FROM ObjectLinks ol
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    WHERE ol.Link_Role = 'calls_function' AND ol.Source_Type = 'CustomFunction'
    UNION ALL
    SELECT ol.Source_UUID, c.function_id, list_append(c.path, ol.Source_UUID)
    FROM cf_closure c
    JOIN ObjectLinks ol ON ol.Target_UUID = c.cf_uuid
    WHERE ol.Link_Role = 'calls_customfunction' AND ol.Source_Type = 'CustomFunction'
      AND NOT list_contains(c.path, ol.Source_UUID)
),
cf_evidence AS (
    SELECT src.File_Name AS file_name, src.Object_UUID AS nav_uuid,
           src.Object_Name AS script_name,
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || cc.function_id)
             || ' (via CF ' || cf.Object_Name || ')' AS feature,
           CAST(NULL AS INTEGER) AS step_no, CAST(NULL AS VARCHAR) AS step_uuid,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM cf_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog cf ON cc.cf_uuid = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN affinity a ON a.function_id = cc.function_id
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, a.affinity,
             f.canonical_name, cc.function_id, cf.Object_Name, f.url_slug
),
evidence AS (
    SELECT * FROM step_evidence
    UNION ALL
    SELECT * FROM function_evidence
    UNION ALL
    SELECT * FROM cf_evidence
),
ranked AS (
    SELECT e.*,
           MIN(CASE e.signal WHEN 'exclusive' THEN 1 WHEN 'dedicated' THEN 2 ELSE 3 END)
               OVER (PARTITION BY e.nav_uuid) AS binding_rank
    FROM evidence e
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'platform-specific-ios' AS rule_id,
        'info' AS severity,
        file_name, nav_uuid, script_name,
        CASE binding_rank WHEN 1 THEN 'exclusive' WHEN 2 THEN 'dedicated'
             ELSE 'contextual' END AS binding,
        evidence_kind, signal, feature, step_no, step_uuid, usage_count,
        CASE evidence_kind
             WHEN 'step'
             THEN feature || ' runs ONLY on FileMaker Go (iOS) — exclusive step, fails on every other runtime'
             ELSE feature || ' is iOS-dedicated — callable everywhere, meaningful results only on FileMaker Go (iOS); used ' || usage_count || '× in this script'
        END AS message,
        doc_slug,
           binding_rank AS _ord_1
    FROM ranked
    WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u.file_name, u.script_name, u.evidence_kind, u.step_no NULLS LAST, u.feature, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
