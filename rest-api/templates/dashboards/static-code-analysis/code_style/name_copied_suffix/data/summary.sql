-- Hand-maintained wrapper around the rule core (name_copied_suffix).
-- finding_count follows the selected suffix class (default: copy suffixes only)
-- so the rule's headline number is the one the findings table shows; the chip
-- badges read the per-class totals next to it. The object-type select narrows
-- everything here (it is a scoping filter, not a class chip).
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL
      AND (getvariable('object_type') IS NULL OR Object_Type = getvariable('object_type'))
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
classified AS (
    SELECT *,
           CASE WHEN Object_Name LIKE '% Copy' OR Object_Name LIKE '% copy' OR Object_Name LIKE '% Kopie'
                THEN 'copy'
                WHEN regexp_matches(Object_Name, ' [0-9]{1,4}$') THEN 'numeric'
           END AS suffix_class
    FROM named
)
SELECT COUNT(*) FILTER (WHERE suffix_class IS NOT NULL
                          AND (COALESCE(getvariable('suffix_kind'), 'copy') = 'all'
                               OR suffix_class = COALESCE(getvariable('suffix_kind'), 'copy'))) AS finding_count,
       COUNT(*) FILTER (WHERE suffix_class = 'copy')    AS copy_count,
       COUNT(*) FILTER (WHERE suffix_class = 'numeric') AS numeric_count,
       COUNT(*) FILTER (WHERE suffix_class IS NOT NULL) AS total_count,
       COUNT(DISTINCT File_Name) FILTER (WHERE suffix_class IS NOT NULL) AS affected_files
FROM classified;
