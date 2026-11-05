-- Files exported without DDR info — "Include details for analysis tools" was
-- off when the XML was saved (root attribute Has_DDR_INFO="False", stored as
-- FilesCatalog.Has_DDR_INFO by P1). Such a file imports without error and looks
-- complete: scripts, fields, layouts and even every formula TEXT are there. But
-- the DDR chunk stream is the ONLY source of formula references — no field
-- reads/writes from calculations, no calls_function, no calls_customfunction,
-- no calls_pluginfunction for anything defined in that file. Where-used, the
-- plug-in inventory and the object graph are silently blind for it.
--
-- One finding per file. nav_uuid = the catalog's File object (same UUID as
-- FilesCatalog.File_UUID) — opens the file detail. Impact columns count the
-- formulas whose references are lost; plugin_text_formulas uses the same text
-- vocabulary as plugin_call_without_reference (the MBS literal plus every
-- plug-in prefix the catalog itself knows) — a lower bound, not a census of
-- every plug-in on the market.
--
-- No fix inside fm-lab: the information is absent from the export. Re-export
-- with the option and import again.
WITH prefixes AS (
    SELECT 'MBS' AS p
    UNION
    SELECT DISTINCT split_part(Plugin_Function_Name, ':', 1)
    FROM PluginFunctionUsages
    WHERE Plugin_Function_Name IS NOT NULL AND Plugin_Function_Name <> ''
),
impact AS (
    SELECT c.File_Name,
           COUNT(*) AS formulas_total,
           -- comments stripped (/* … */ and // …) — same vocabulary and same
           -- exclusion as plugin_call_without_reference / plugin_reference_census
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM prefixes p
               WHERE regexp_matches(
                   regexp_replace(regexp_replace(c.Formula_Text, '(?s)/\*.*?\*/', '', 'g'), '//[^\n]*', '', 'g'),
                   '\b' || p.p || '\s*\('))) AS plugin_text_formulas
    FROM CalculationsCatalog c
    GROUP BY c.File_Name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'export-ddr-missing' AS rule_id,
        'warning' AS severity,
        o.Object_UUID AS nav_uuid,
        'File' AS type,
        f.File_Name AS name,
        f.File_Name AS file,
        f.FileMaker_Version AS filemaker_version,
        f.SaXML_Profile AS saxml_profile,
        COALESCE(i.formulas_total, 0) AS formulas_total,
        COALESCE(i.plugin_text_formulas, 0) AS plugin_text_formulas,
        'File exported without DDR info — the references of its ' || COALESCE(i.formulas_total, 0)
          || ' formulas (' || COALESCE(i.plugin_text_formulas, 0)
          || ' with plug-in calls) are invisible; re-export with "Include details for analysis tools"' AS message,
           f.File_Name AS _ord_1
    FROM FilesCatalog f
    LEFT JOIN ObjectCatalog o ON o.Object_Type = 'File' AND o.File_Name = f.File_Name
    LEFT JOIN impact i ON i.File_Name = f.File_Name
    WHERE NOT COALESCE(f.Has_DDR_INFO, FALSE)
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR o.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u) AS row_key
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
