-- Hand-maintained COUNT wrapper for rule (unstored_calc_network_function).
-- Keep filters (file filter + scope block) in sync with data/findings.sql.
WITH hot_fields AS (
    SELECT f.File_Name, f.Field_UUID
    FROM FieldsForTables f
    WHERE f.Field_Type = 'Calculated'
      AND COALESCE(f.Storage_StoreCalcResults, FALSE) = FALSE
      AND regexp_matches(lower(f.Calculation_Text), 'currenthosttimestamp|systemuhrzeitstempelhost')
),
placed AS (
    SELECT h.File_Name, h.Field_UUID, count(*) AS placement_count
    FROM hot_fields h
    JOIN ObjectLinks ol ON ol.Target_UUID = h.Field_UUID AND ol.Link_Role = 'displays_field'
    GROUP BY 1, 2
)
SELECT
    COUNT(*) AS finding_count,
    'warning' AS severity,
    CAST(COALESCE(SUM(placement_count), 0) AS INTEGER) AS placement_count,
    COUNT(DISTINCT File_Name) AS affected_files
FROM placed
WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
