-- @template_type: content
-- @description: Detailed view of a FileMaker LayoutObject - type, position, nesting
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 3.0
-- @tags: layoutobjects, details
-- @note: Shows LayoutObject structural properties only. The attached calculations
--        (hide, tooltip, conditional formatting, portal filter, web-viewer URL, …)
--        are NOT part of this content block — the frontend renders them tokenized
--        from the CalculationsCatalog instances (calcSlots via format=tokens +
--        get-calc?uuid). Since v3 the reference lines are gone as well: every
--        operational edge (incl. subrole classes) is served by /api/references —
--        the canonical edge view — so this block no longer duplicates it.

WITH object_match AS (
  SELECT
    lo.Object_UUID, lo.Object_Type, lo.Object_Name, lo.Object_ID,
    lo.Layout_ID, lo.Part_Type, lo.Object_Kind,
    lo.Bounds_Top, lo.Bounds_Left, lo.Bounds_Bottom, lo.Bounds_Right,
    lo.Parent_Object_ID, lo.Nesting_Level,
    lo.File_Name
  FROM LayoutObjects lo
  -- Clone-Scoping: Object_UUID ist über Modul-Dateien hinweg geklont → auf die aufgelöste Datei einschränken
  WHERE lo.Object_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  LIMIT 1
),
layout_info AS (
  SELECT L_ID, L_Name, L_UUID
  FROM Layouts
  WHERE L_ID = (SELECT Layout_ID FROM object_match)
    AND File_Name = (SELECT File_Name FROM object_match)
  LIMIT 1
),
parent_object AS (
  SELECT Object_UUID, Object_Type, Object_Name
  FROM LayoutObjects
  WHERE Object_ID = (SELECT Parent_Object_ID FROM object_match)
    AND Layout_ID = (SELECT Layout_ID FROM object_match)
    AND File_Name = (SELECT File_Name FROM object_match)
  LIMIT 1
)

SELECT content FROM (
  -- Header
  SELECT 1 as sort_key, 0 as sub_key,
    '=== LayoutObject Details ===' as content
  FROM object_match

  UNION ALL

  SELECT 2, 0, '' FROM object_match

  UNION ALL

  -- Object properties
  SELECT 3, 1, 'Type:         ' || om.Object_Type FROM object_match om
  UNION ALL
  SELECT 3, 2, 'Name:         ' || COALESCE(NULLIF(om.Object_Name, ''), '(unnamed)') FROM object_match om
  UNION ALL
  SELECT 3, 3, 'Layout:       ' || COALESCE(li.L_Name, '?') || ' (ID: ' || CAST(om.Layout_ID AS VARCHAR) || ')'
  FROM object_match om LEFT JOIN layout_info li ON true
  UNION ALL
  SELECT 3, 4, 'Part:         ' || om.Part_Type FROM object_match om
  UNION ALL
  SELECT 3, 5, 'Position:     Top=' || om.Bounds_Top || ' Left=' || om.Bounds_Left
    || ' Bottom=' || om.Bounds_Bottom || ' Right=' || om.Bounds_Right
    || ' (' || (om.Bounds_Right - om.Bounds_Left) || 'x' || (om.Bounds_Bottom - om.Bounds_Top) || ')'
  FROM object_match om
  UNION ALL
  SELECT 3, 6, 'Nesting:      Level ' || om.Nesting_Level
    || CASE WHEN po.Object_Type IS NOT NULL
       THEN ' (in ' || po.Object_Type || COALESCE(': ' || NULLIF(po.Object_Name, ''), '') || ')'
       ELSE '' END
  FROM object_match om LEFT JOIN parent_object po ON true
  UNION ALL
  SELECT 3, 7, 'File:         ' || om.File_Name FROM object_match om
  UNION ALL
  SELECT 3, 8, 'UUID:         ' || om.Object_UUID FROM object_match om
) details
ORDER BY sort_key, sub_key;
