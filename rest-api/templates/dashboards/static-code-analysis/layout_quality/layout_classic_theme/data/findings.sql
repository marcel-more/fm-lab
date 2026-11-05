-- Layouts whose theme resolves to the deprecated Classic theme (internal name
-- com.filemaker.theme.classic — locale-independent, unlike the display name).
-- Translated from fmCheckMate ReportObjectsWithClassicStyle.
--
-- Classic detection runs as an OR chain over the RAW columns on purpose — it is
-- correct on every catalog version, including those imported before the resolved
-- theme columns existed (schema 1.21.0). Referencing L_Theme_Resolved_Name here
-- would turn an old catalog into a hard binder error instead of a result:
--   1. L_Theme_Base  — Classic named as the base theme (explicit exports)
--   2. L_Theme_Name  — Classic referenced by name
--   3. L_Theme_ID IS NULL — the SaXML case: FileMaker writes Classic as an EMPTY
--      <LayoutThemeReference/> with no id/name/UUID/Base at all, so every Classic
--      layout carries NULL and the literal string appears in no layout row. This
--      branch is what actually fires on SaXML exports; without it a solution that
--      is entirely Classic reports zero findings.
-- Folders (isFolder 'True'/'Marker') and separators never carry a theme and would
-- otherwise all match branch 3 — excluded with the same predicate P4 uses.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-classic-theme' AS rule_id, 'warning' AS severity,
        ly.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        NULL AS object_uuid,
        COALESCE(ly.L_Theme_Name, 'com.filemaker.theme.classic') AS theme_name,
        'Layout uses the deprecated Classic theme' AS message,
           ly.File_Name AS _ord_1,
           ly.L_Name AS _ord_2
    FROM Layouts ly
    WHERE (ly.Folder_Type IS NULL OR ly.Folder_Type = 'False')
      AND NOT COALESCE(ly.Is_Separator, FALSE)
      AND (ly.L_Theme_Base = 'com.filemaker.theme.classic'
           OR ly.L_Theme_Name = 'com.filemaker.theme.classic'
           OR ly.L_Theme_ID IS NULL)
      AND (getvariable('file') IS NULL OR ly.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u) AS row_key
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
