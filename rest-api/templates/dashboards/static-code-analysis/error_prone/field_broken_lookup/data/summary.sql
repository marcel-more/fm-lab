-- Hand-maintained wrapper around the rule core (field_broken_lookup).
-- `unverifiable` counts the lookups whose target file is not part of the
-- export, or whose data source does not resolve to a file at all — those are
-- deliberately not findings.
WITH lookups AS (
    SELECT f.File_Name, f.Field_UUID, f.Lookup_Field_Name,
           t.BT_Name, t.DS_UUID, t.TO_UUID
    FROM FieldsForTables f
    LEFT JOIN TableOccurrenceCatalog t ON f.Lookup_TO_UUID = t.TO_UUID
    WHERE f.AutoEnter_Type = 'Looked_up'
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
resolved AS (
    SELECT l.*,
           COALESCE(m.Resolved_File, l.File_Name) AS target_file,
           m.Resolved_File IS NULL AND l.DS_UUID IS NOT NULL AS ds_unresolved
    FROM lookups l
    LEFT JOIN DataSourceFileMap m ON m.File_Name = l.File_Name AND m.DS_UUID = l.DS_UUID
),
checked AS (
    SELECT r.*,
           r.target_file IN (SELECT File_Name FROM FilesCatalog) AS target_in_corpus,
           EXISTS (SELECT 1 FROM BaseTableCatalog b
                    WHERE b.File_Name = r.target_file AND b.BT_Name = r.BT_Name) AS bt_found,
           EXISTS (SELECT 1 FROM FieldsForTables ff
                     JOIN BaseTableCatalog b ON ff.Table_UUID = b.BT_UUID
                    WHERE b.File_Name = r.target_file AND b.BT_Name = r.BT_Name
                      AND ff.Field_Name = r.Lookup_Field_Name) AS field_found
    FROM resolved r
)
SELECT COUNT(*) FILTER (WHERE TO_UUID IS NULL
                          OR (target_in_corpus AND NOT ds_unresolved AND NOT field_found)) AS finding_count,
       COUNT(*) AS lookups_total,
       COUNT(*) FILTER (WHERE TO_UUID IS NOT NULL
                          AND (NOT target_in_corpus OR ds_unresolved)) AS unverifiable,
       COUNT(DISTINCT File_Name) FILTER (WHERE TO_UUID IS NULL
                          OR (target_in_corpus AND NOT ds_unresolved AND NOT field_found)) AS affected_files
FROM checked;
