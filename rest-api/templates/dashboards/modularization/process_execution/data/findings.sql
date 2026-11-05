-- @template_type: report
-- @description: Prozess-/Shell-Ausführung — je Zeile ein Grenzübertritt in einen externen Prozess: Send Event, Perform AppleScript (Step_ID-gated) oder ein MBS Shell/RunTask/Process-Aufruf. Klick auf eine Zeile öffnet den Träger am konkreten Step.
-- @params: file (optional), mechanism (optional), limit (optional, default 400)
--
-- Die MBS-Seite liest aus PluginFunctionUsages (step-granular: Source_Subkey =
-- Step_Index bei Source_Type='Script') statt aus den Script→PluginFunction-Links,
-- damit der Step-Anchor (step_uuid) und die Script-Zeile (#) verfügbar sind.

WITH native AS (
    SELECT
        s.File_Name                                     AS file,
        CASE WHEN s.Step_ID = 57 THEN 'Send Event' ELSE 'AppleScript' END AS mechanism,
        'Native Step'                                   AS ref_type,
        s.Script_Name                                   AS carrier,
        s.Step_Name                                     AS detail,
        s.Step_Index + 1                                    AS step_index,
        s.Script_UUID                                   AS nav_uuid,
        'Script'                                        AS nav_type,
        s.Step_UUID                                     AS step_uuid
    FROM StepsForScripts s
    WHERE s.Step_ID IN (57, 67)
),
mbs AS (
    SELECT
        p.File_Name                                     AS file,
        'MBS ' || regexp_extract(p.Plugin_Function_Name, '(?i)MBS:([A-Za-z]+)\.', 1) AS mechanism,
        'MBS ' || p.Source_Type                         AS ref_type,
        COALESCE(s.Script_Name, oc.Object_Name)         AS carrier,
        regexp_extract(p.Plugin_Function_Name, '(?i)MBS:(.+)$', 1) AS detail,
        s.Step_Index + 1                                    AS step_index,
        p.Source_UUID                                   AS nav_uuid,
        p.Source_Type                                   AS nav_type,
        s.Step_UUID                                     AS step_uuid
    FROM PluginFunctionUsages p
    LEFT JOIN StepsForScripts s
      ON p.Source_Type = 'Script'
     AND s.Script_UUID = p.Source_UUID
     AND s.File_Name = p.File_Name
     AND s.Step_Index = TRY_CAST(p.Source_Subkey AS INTEGER)
    LEFT JOIN ObjectCatalog oc ON oc.Object_UUID = p.Source_UUID AND oc.File_Name = p.File_Name
    WHERE regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Shell|RunTask|Process)\.')
),
all_hits AS (
    SELECT * FROM native
    UNION ALL
    SELECT * FROM mbs
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT *,
           mechanism AS _ord_1,
           file AS _ord_2,
           carrier AS _ord_3,
           step_index AS _ord_4
    FROM all_hits
    WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
      AND (getvariable('mechanism') IS NULL OR getvariable('mechanism') IN ('', 'All', 'Alle')
           OR mechanism = getvariable('mechanism'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 400), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
