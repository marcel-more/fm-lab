-- @template_type: report
-- @description: Detailed view of a Privilege Set — standard privileges plus Custom Record/Field/Object access (incl. record-access calc formulas)
-- @params: uuid (required)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: privilegeset, security, custom-record-privileges, calculations
-- @note: Structured flat rows with a `section` discriminator (meta|record|field|object).
--        Record rows carry calculation_text + ddr_hash so the frontend can render the
--        formula (clickable tokens via /api/get-calc?hash=<ddr_hash>). PRD prd_record_privileges_calc_rendering.md §4.
--        `order_hint` drives a single stable sort across all sections.

WITH ps AS (
  SELECT *
  FROM PrivilegeSetsCatalog
  -- Clone-Scoping: Identität ist (UUID, File_Name); ohne file-Var graceful downgrade
  WHERE PrivilegeSet_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  LIMIT 1
)

SELECT * FROM (
  -- ── META: standard privilege summary (always present, so non-custom sets aren't empty) ──
  SELECT 'meta' AS section, 0 AS sort_key, '001' AS order_hint,
         'Description' AS label, NULLIF(ps.Description, '') AS sub_label,
         NULL AS access_mode, NULL AS calculation_text, NULL AS context_to, NULL AS ddr_hash,
         NULL AS item_type, NULL AS fields_access, NULL AS records_access, NULL AS target_uuid
  FROM ps WHERE NULLIF(ps.Description, '') IS NOT NULL
  UNION ALL
  SELECT 'meta', 0, '002', 'Default Access', ps.Is_Default_Access,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps
  UNION ALL
  SELECT 'meta', 0, '003', 'Records',
         'Create=' || ps.Records_Create || '  Edit=' || ps.Records_Edit ||
         '  Delete=' || ps.Records_Delete || '  View=' || ps.Records_View,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps
  UNION ALL
  SELECT 'meta', 0, '004', 'Layouts',
         'Create=' || ps.Layouts_Create || '  Edit=' || ps.Layouts_Edit ||
         '  Delete=' || ps.Layouts_Delete || '  View=' || ps.Layouts_View,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps
  UNION ALL
  SELECT 'meta', 0, '005', 'Value Lists',
         'Create=' || ps.ValueLists_Create || '  Edit=' || ps.ValueLists_Edit ||
         '  Delete=' || ps.ValueLists_Delete || '  View=' || ps.ValueLists_View,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps
  UNION ALL
  SELECT 'meta', 0, '006', 'Scripts',
         'Create=' || ps.Scripts_Create || '  Edit=' || ps.Scripts_Edit ||
         '  Delete=' || ps.Scripts_Delete || '  View=' || ps.Scripts_View,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps
  UNION ALL
  SELECT 'meta', 0, '007', 'Management',
         'Database=' || ps.Manage_Database || '  Accounts=' || ps.Manage_Accounts ||
         '  ExtPrivs=' || ps.Manage_Ext_Privs || '  Menus=' || ps.Manage_Custom_Menus,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM ps

  UNION ALL

  -- ── RECORD: Custom Record Privileges (table level) — the calc-bearing rows ──
  -- order_hint = '<table>#<operation-rank>' → groups operations under each table.
  SELECT 'record' AS section, 1 AS sort_key,
         COALESCE(ra.BaseTable_Name, '~') || '#' ||
           CASE ra.Operation WHEN 'View' THEN '0' WHEN 'Edit' THEN '1'
                             WHEN 'Create' THEN '2' WHEN 'Delete' THEN '3' ELSE '4' END AS order_hint,
         COALESCE(ra.BaseTable_Name, '‹New tables (default)›') AS label,
         ra.Operation AS sub_label,
         ra.Access_Mode AS access_mode,
         NULLIF(ra.Calculation_Text, '') AS calculation_text,
         ra.Context_TO_Name AS context_to,
         NULLIF(ra.DDR_Hash, '') AS ddr_hash,
         ra.Table_Type AS item_type,
         ra.Fields_Access AS fields_access,
         NULL AS records_access,
         ra.BaseTable_UUID AS target_uuid
  FROM PrivilegeSetRecordAccess ra
  WHERE ra.PrivilegeSet_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR ra.File_Name = getvariable('file'))

  UNION ALL

  -- ── FIELD: Custom Record Privileges (field level) — only tables with Fields access=Custom ──
  SELECT 'field' AS section, 2 AS sort_key,
         COALESCE(fa.BaseTable_Name, '~') || '#' || COALESCE(fa.Field_Name, '') AS order_hint,
         fa.Field_Name AS label,
         fa.BaseTable_Name AS sub_label,
         fa.Access_Mode AS access_mode,
         NULL, NULL, NULL,
         fa.Field_Type AS item_type,
         NULL, NULL,
         fa.Field_UUID AS target_uuid
  FROM PrivilegeSetFieldAccess fa
  WHERE fa.PrivilegeSet_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR fa.File_Name = getvariable('file'))

  UNION ALL

  -- ── OBJECT: Custom Privileges for Layouts / ValueLists / Scripts ──
  SELECT 'object' AS section, 3 AS sort_key,
         CASE oa.Object_Class WHEN 'Layout' THEN '0' WHEN 'ValueList' THEN '1'
                              WHEN 'Script' THEN '2' ELSE '3' END || '#' ||
           COALESCE(oa.Object_Name, '') AS order_hint,
         oa.Object_Name AS label,
         oa.Object_Class AS sub_label,
         oa.Access_Mode AS access_mode,
         NULL, NULL, NULL,
         oa.Item_Type AS item_type,
         NULL,
         oa.Records_Access AS records_access,
         oa.Object_UUID AS target_uuid
  FROM PrivilegeSetObjectAccess oa
  WHERE oa.PrivilegeSet_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR oa.File_Name = getvariable('file'))
)
ORDER BY sort_key, order_hint;
