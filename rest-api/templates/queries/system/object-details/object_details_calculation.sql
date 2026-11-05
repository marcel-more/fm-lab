-- @template_type: content
-- @description: Detailed view of a Calculation instance - owner, role/slot, formula, resolved target links
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.0
-- @tags: calculation, details, calculations
-- @note: Calculation = one calculation INSTANCE (owner × role × index, CalculationsCatalog,
--        schema 1.22.0). Target links come from v_calculation_links (derived from the
--        canonical owner-projected edges — variant A, no physical duplicate edges).

WITH calc_match AS (
  SELECT c.Calculation_UUID, c.Owner_UUID, c.Owner_Type, c.Owner_Name,
    c.Calc_Role, c.Calc_Kind_Raw, c.Calc_Index, c.Formula_Text, c.Formula_Hash,
    c.DDR_Calc_UUID, c.Context_TO_UUID, c.Context_TO_Name, c.Is_Static,
    c.Chunk_Count, c.Ref_Count, c.Display_Text, c.Source_Path, c.File_Name,
    oc.Object_Name AS Display_Name
  FROM CalculationsCatalog c
  LEFT JOIN ObjectCatalog oc
    ON oc.Object_UUID = c.Calculation_UUID AND oc.File_Name = c.File_Name
  WHERE c.Calculation_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  LIMIT 1
),
formula_lines AS (
  SELECT string_split(replace(COALESCE(cm.Formula_Text, cm.Display_Text, ''), chr(13), chr(10)), chr(10)) AS arr
  FROM calc_match cm
  WHERE COALESCE(cm.Formula_Text, cm.Display_Text) IS NOT NULL
),
target_links AS (
  SELECT vl.Link_Role,
    COALESCE(oc.Object_Name, vl.Target_UUID) AS Target_Name,
    vl.Target_Type, vl.Target_File, vl.Is_Cross_File,
    ROW_NUMBER() OVER (ORDER BY vl.Link_Role, oc.Object_Name, vl.Target_UUID) AS ord
  FROM v_calculation_links vl
  LEFT JOIN ObjectCatalog oc
    ON oc.Object_UUID = vl.Target_UUID
   AND (oc.File_Name = vl.Target_File OR (oc.File_Name IS NULL AND vl.Target_File IS NULL))
  WHERE vl.Calculation_UUID = getvariable('uuid')
)

SELECT content FROM (
  SELECT 1 as sort_key, 0 as sub_key, '=== Calculation Details ===' as content FROM calc_match
  UNION ALL
  SELECT 2, 0, '' FROM calc_match
  UNION ALL
  SELECT 3, 0, 'Name:         ' || COALESCE(cm.Display_Name, cm.Calc_Role) FROM calc_match cm
  UNION ALL
  SELECT 3, 1, 'Owner:        ' || COALESCE(cm.Owner_Name, '(unresolved)')
    || '  [' || cm.Owner_Type || ']' FROM calc_match cm
  UNION ALL
  SELECT 3, 2, 'Role:         ' || cm.Calc_Role
    || CASE WHEN cm.Calc_Index > 1 THEN ' #' || cm.Calc_Index ELSE '' END
  FROM calc_match cm
  UNION ALL
  SELECT 3, 3, 'Slot:         ' || cm.Source_Path FROM calc_match cm
  WHERE cm.Source_Path IS NOT NULL
  UNION ALL
  SELECT 3, 4, 'Kind:         ' || CASE WHEN cm.Is_Static THEN 'static value' ELSE 'formula' END
    || CASE WHEN cm.Ref_Count IS NOT NULL
            THEN '  (' || COALESCE(cm.Ref_Count, 0) || ' reference(s), ' || COALESCE(cm.Chunk_Count, 0) || ' chunk(s))'
            ELSE '' END
  FROM calc_match cm
  WHERE cm.Is_Static IS NOT NULL
  UNION ALL
  SELECT 3, 5, 'Context:      ' || cm.Context_TO_Name FROM calc_match cm
  WHERE cm.Context_TO_Name IS NOT NULL
  UNION ALL
  SELECT 3, 6, 'Hash:         ' || cm.Formula_Hash FROM calc_match cm
  WHERE cm.Formula_Hash IS NOT NULL
  UNION ALL
  SELECT 3, 7, 'DDR data:     ' || CASE WHEN cm.DDR_Calc_UUID IS NOT NULL
    THEN 'available (' || cm.DDR_Calc_UUID || ')'
    ELSE 'not available (structural slot; instance exists without DDR info)' END
  FROM calc_match cm
  UNION ALL
  SELECT 3, 8, 'File:         ' || cm.File_Name FROM calc_match cm
  UNION ALL
  SELECT 3, 9, 'UUID:         ' || cm.Calculation_UUID FROM calc_match cm

  UNION ALL

  -- Formula block
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM formula_lines) > 0
  UNION ALL
  SELECT 5, 1, '--- Formula ---' WHERE (SELECT COUNT(*) FROM formula_lines) > 0
  UNION ALL
  SELECT 5, 1 + line_no, '  ' || line
  FROM (
    SELECT unnest(arr) AS line,
           generate_subscripts(arr, 1) AS line_no
    FROM formula_lines
  )

  UNION ALL

  -- Resolved target links (derived, variant A)
  SELECT 7, 0, '' WHERE (SELECT COUNT(*) FROM target_links) > 0
  UNION ALL
  SELECT 7, 1, '--- Uses (' || CAST((SELECT COUNT(*) FROM target_links) AS VARCHAR) || ') ---'
  WHERE (SELECT COUNT(*) FROM target_links) > 0
  UNION ALL
  SELECT 7, 1 + tl.ord,
    '  [' || tl.Link_Role || '] ' || tl.Target_Name
    || '  (' || tl.Target_Type
    || CASE WHEN tl.Is_Cross_File THEN ' @ ' || COALESCE(tl.Target_File, '?') ELSE '' END || ')'
  FROM target_links tl

  UNION ALL
  SELECT 99, 0, '' FROM calc_match
  UNION ALL
  SELECT 99, 1, 'Hint: where-used and dead-code semantics live on the OWNER edges (variant A) - '
    || 'this instance is contained via has_calculation and never counts as a usage itself.'
  FROM calc_match
) ORDER BY sort_key, sub_key;
