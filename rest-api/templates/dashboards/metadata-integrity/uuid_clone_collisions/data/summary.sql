-- @template_type: report
-- @description: One-row KPI summary for the clone-collision dashboard (distinct duplicated UUIDs, affected catalog rows, affected files).
-- @params: file (optional), scope_uuids (optional)
-- keep in sync with data/findings.sql (shared dup CTE + outer filters)
-- Params are normalised ONCE here ('' and NULL both mean "no filter"); each
-- getvariable appears exactly once so the M5a copy-sync check stays green.
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter,
           NULLIF(CAST(getvariable('scope_uuids') AS VARCHAR), '') AS scope_csv
),
dup AS (
    SELECT Object_UUID,
           COUNT(*) AS occurrences,
           COUNT(DISTINCT File_Name) AS file_count,
           COUNT(DISTINCT Object_Type) AS type_count
    FROM ObjectCatalog
    WHERE Object_UUID IS NOT NULL
      AND File_Name IS NOT NULL
      -- Native FileMaker UUIDs only (8-4-4-4-12), relationships included. FM-Lab's
      -- synthetic identities (md5 variables/builtins/plugin components, part_/trig_/
      -- paste_ prefixes, rel_ fallback keys of relationships without <UUID>) are
      -- tool-internal and partly global by design - not solution metadata defects.
      AND regexp_matches(Object_UUID, '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
    GROUP BY Object_UUID
    HAVING COUNT(DISTINCT File_Name) > 1
)
SELECT
    COUNT(DISTINCT oc.Object_UUID) AS finding_count,
    COUNT(*) AS affected_objects,
    COUNT(DISTINCT oc.File_Name) AS affected_files,
    COUNT(DISTINCT oc.Object_UUID) FILTER (WHERE d.type_count > 1) AS type_conflicts,
    'warning' AS severity
FROM ObjectCatalog oc
JOIN dup d USING (Object_UUID)
CROSS JOIN params p
WHERE (p.file_filter IS NULL OR oc.File_Name = p.file_filter)
  AND (p.scope_csv IS NULL
       OR oc.Object_UUID IN (SELECT unnest(string_split(p.scope_csv, ','))));
