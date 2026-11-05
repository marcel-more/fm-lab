-- Platform-binding inventory (axis b), trigger evidence: scripts attached to
-- an event that exists ONLY in FileMaker Go (iOS). Exclusivity is derived from
-- ref.trigger_compat (fm_spec >= 2.8.0) with the same strict predicate as the
-- step evidence of platform_specific_ios: go = true AND every other runtime
-- column strictly false (NULL = Partial elsewhere disqualifies) - no slot-id
-- literals, the predicate follows future reference versions. Neutral by
-- design: severity 'info', findings are properties, never defects.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'platform-ios-specific-triggers' AS rule_id, 'info' AS severity,
        t.File_Name AS file_name, t.Script_UUID AS nav_uuid, t.Script_Name AS script_name,
        st.event_name AS trigger_event, t.Owner_Type AS owner_type,
        CASE t.Owner_Type
             WHEN 'Layout'       THEN COALESCE(l.L_Name, t.Owner_UUID)
             WHEN 'LayoutObject' THEN COALESCE(NULLIF(trim(lo.Object_Name), ''), COALESCE(lo.Object_Type, 'object') || ' (unnamed)')
             ELSE t.File_Name END AS owner_name,
        COALESCE(l.L_Name, lol.L_Name) AS layout_name,
        'trig_' || t.Trigger_ID || '_' || t.Owner_UUID || '_' || t.File_Name AS trigger_uuid,
        lower(st.event_name) AS doc_slug,
        st.event_name || ' fires only in FileMaker Go (iOS) - the script is bound to the iOS runtime' AS message
    FROM ScriptTriggers t
    JOIN ref.trigger_compat c ON c.trigger_id = t.Trigger_ID
    JOIN ref.script_triggers st ON st.trigger_id = t.Trigger_ID
    LEFT JOIN Layouts l ON t.Owner_Type = 'Layout' AND l.L_UUID = t.Owner_UUID AND l.File_Name = t.File_Name
    LEFT JOIN (
        SELECT Object_UUID, Layout_ID, File_Name, Object_Type, Object_Name,
               ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
        FROM LayoutObjects
    ) lo ON t.Owner_Type = 'LayoutObject' AND lo.Object_UUID = t.Owner_UUID AND lo.File_Name = t.File_Name AND lo.rn = 1
    LEFT JOIN Layouts lol ON lo.Layout_ID = lol.L_ID AND lol.File_Name = lo.File_Name
    WHERE t.Script_UUID IS NOT NULL
      -- strict exclusivity from the table: Go yes, EVERY other runtime strictly No
      -- (NULL = Partial elsewhere disqualifies); no hard-coded slot ids
      AND c.go = true AND c.pro = false AND c.server = false AND c.webdirect = false
      AND c.cloud = false AND c.dataapi = false AND c.cwp = false
      AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR t.Owner_UUID  IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR COALESCE(l.L_UUID, lol.L_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.script_name, u.trigger_event, u) AS row_key
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
