-- @template_type: report
-- @description: E-Mail-Versand — je Zeile ein Send-Mail-Step (Step_ID 63), klassifiziert nach Versandweg (SMTP-Server vs. E-Mail-Client) mit extrahiertem SMTP-Host und Flag für hartkodierte Zugangsdaten. Plus MBS SendMail-Aufrufe. Klick öffnet den Träger.
-- @params: file (optional), mode (optional), limit (optional, default 400)

WITH native AS (
    SELECT
        s.File_Name                                         AS file,
        CASE
            WHEN ddr.Step_Text LIKE '%Send via SMTP Server%'  THEN 'SMTP'
            WHEN ddr.Step_Text LIKE '%Send via E-mail Client%' THEN 'Client'
            ELSE 'unknown'
        END                                                 AS mode,
        'Send Mail'                                          AS mechanism,
        s.Script_Name                                        AS carrier,
        regexp_extract(COALESCE(ddr.Step_Text, ''), 'SMTP Server:\s*"([^"]+)"', 1) AS smtp_host,
        (COALESCE(ddr.Step_Text, '') LIKE '%Password:%')     AS hardcoded_auth,
        s.Step_Index + 1                                         AS step_index,
        s.Script_UUID                                        AS nav_uuid,
        'Script'                                             AS nav_type,
        s.Step_UUID                                          AS step_uuid
    FROM StepsForScripts s
    LEFT JOIN DDR_ScriptSteps ddr ON s.Step_UUID = ddr.Step_UUID AND ddr.File_Name = s.File_Name
    WHERE s.Step_ID = 63
),
mbs AS (
    -- Per-usage aus PluginFunctionUsages (step-granular: Source_Subkey =
    -- Step_Index bei Source_Type='Script') statt der deduplizierten
    -- Script→PluginFunction-Links, damit MBS-Zeilen Step-Anchor + Script-Zeile tragen.
    SELECT
        p.File_Name                                          AS file,
        'MBS'                                                AS mode,
        'MBS ' || regexp_extract(p.Plugin_Function_Name, '(?i)MBS:([A-Za-z]+\.[A-Za-z0-9]+)', 1) AS mechanism,
        COALESCE(s.Script_Name, oc.Object_Name)              AS carrier,
        CAST(NULL AS VARCHAR)                                AS smtp_host,
        FALSE                                                AS hardcoded_auth,
        s.Step_Index + 1                                         AS step_index,
        p.Source_UUID                                        AS nav_uuid,
        p.Source_Type                                        AS nav_type,
        s.Step_UUID                                          AS step_uuid
    FROM PluginFunctionUsages p
    LEFT JOIN StepsForScripts s
      ON p.Source_Type = 'Script'
     AND s.Script_UUID = p.Source_UUID
     AND s.File_Name = p.File_Name
     AND s.Step_Index = TRY_CAST(p.Source_Subkey AS INTEGER)
    LEFT JOIN ObjectCatalog oc ON oc.Object_UUID = p.Source_UUID AND oc.File_Name = p.File_Name
    WHERE regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(SendMail|EmailParser)\.')
),
all_hits AS (SELECT * FROM native UNION ALL SELECT * FROM mbs),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        *,
           mode AS _ord_1,
           file AS _ord_2,
           carrier AS _ord_3,
           step_index AS _ord_4
    FROM all_hits
    WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
      AND (getvariable('mode') IS NULL OR getvariable('mode') IN ('', 'All', 'Alle')
           OR mode = getvariable('mode'))
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
