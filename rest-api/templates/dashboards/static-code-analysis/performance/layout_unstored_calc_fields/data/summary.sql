-- @template_type: report
-- @description: KPI summary for the layout_unstored_calc_fields rule — how many layouts
--   carry at least one unstored calculation field, split by Default_View (Form/List/Table),
--   across how many files, and the worst single-layout count. The per-view counts back the
--   clickable Form/List/Table KPIs and ignore the 'view' filter so they always show totals.
-- @params: file (optional)
--   Scope: file filter + S-Block on the layout UUID — keep in sync with data/findings.sql.
WITH unstored AS (
    SELECT Field_UUID, File_Name
    FROM FieldsForTables
    WHERE Field_Type = 'Calculated' AND Storage_StoreCalcResults = FALSE
),
per_layout AS (
    SELECT l.File_Name AS file_name, l.L_UUID AS l_uuid, l.Default_View AS default_view,
           COUNT(DISTINCT ol.Target_UUID || '|' || COALESCE(ol.Target_File, '')) AS n
    FROM ObjectLinks ol
    JOIN unstored u ON u.Field_UUID = ol.Target_UUID AND u.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN Layouts l  ON l.L_UUID = ol.Source_UUID AND l.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'displays_field'
      AND (getvariable('file') IS NULL OR l.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY l.File_Name, l.L_UUID, l.Default_View
    HAVING COUNT(DISTINCT ol.Target_UUID || '|' || COALESCE(ol.Target_File, '')) > 0
)
SELECT
    COUNT(*)                                        AS affected_layouts,
    'warning'                                          AS severity,
    COUNT(*) FILTER (WHERE default_view = 'Form')   AS view_form,
    COUNT(*) FILTER (WHERE default_view = 'List')   AS view_list,
    COUNT(*) FILTER (WHERE default_view = 'Table')  AS view_table,
    COUNT(DISTINCT file_name)                       AS affected_files,
    COALESCE(MAX(n), 0)                             AS max_per_layout
FROM per_layout;
