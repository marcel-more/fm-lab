-- @template_type: content
-- @description: Theme detail view - display name (localized) plus internal FileMaker name and references
-- @params: uuid (required), file (optional)
-- @output_format: content
-- @author: Marcel
-- @version: 1.0
-- @tags: theme, design, details
-- @note: Object_Name im Katalog ist der lokalisierte Anzeigename (z.B. „Apex Blau");
-- @note: der interne name (com.filemaker.theme.*) kommt zusätzlich aus ThemeCatalog.

WITH object_info AS (
  SELECT oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name, oc.Source_Table, oc.Object_ID,
         tc.Theme_Name AS Internal_Name
  FROM ObjectCatalog oc
  LEFT JOIN ThemeCatalog tc
    ON tc.Theme_UUID = oc.Object_UUID AND tc.File_Name = oc.File_Name
  WHERE oc.Object_UUID = getvariable('uuid')
    -- Clone-Scoping: Object_UUID ist nur je File eindeutig
    AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
  LIMIT 1
),
child_refs AS (
  SELECT
    oc.Object_Type as Target_Type,
    oc.Object_Name as Target_Name,
    oc.File_Name as Target_File,
    ol.Link_Role,
    ol.Is_Cross_File
  FROM ObjectLinks ol
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND oc.File_Name = ol.Target_File
  WHERE ol.Source_UUID = getvariable('uuid')
    AND ol.Link_Type = 'operational'
    AND (getvariable('file') IS NULL OR ol.Source_File = getvariable('file'))
  ORDER BY oc.Object_Type, oc.Object_Name
),
parent_refs AS (
  SELECT
    oc.Object_Type as Source_Type,
    oc.Object_Name as Source_Name,
    oc.File_Name as Source_File,
    ol.Link_Role,
    ol.Is_Cross_File
  FROM ObjectLinks ol
  JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID AND oc.File_Name = ol.Source_File
  WHERE ol.Target_UUID = getvariable('uuid')
    AND ol.Link_Type = 'operational'
    AND (getvariable('file') IS NULL OR ol.Target_File = getvariable('file'))
  ORDER BY oc.Object_Type, oc.Object_Name
)

SELECT content FROM (
  SELECT 1 as sort_key, 0 as sub_key,
    '=== ' || oi.Object_Type || ' Details ===' as content
  FROM object_info oi

  UNION ALL
  SELECT 2, 0, '' FROM object_info

  -- Anzeigename (lokalisiert) + interner FileMaker-Name
  UNION ALL
  SELECT 3, 1, 'Name:          ' || oi.Object_Name FROM object_info oi
  UNION ALL
  SELECT 3, 2, 'Internal name: ' || oi.Internal_Name FROM object_info oi
    WHERE oi.Internal_Name IS NOT NULL AND oi.Internal_Name <> oi.Object_Name
  UNION ALL
  SELECT 3, 3, 'Type:          ' || oi.Object_Type FROM object_info oi
  UNION ALL
  SELECT 3, 4, 'File:          ' || oi.File_Name FROM object_info oi
  UNION ALL
  SELECT 3, 5, 'UUID:          ' || oi.Object_UUID FROM object_info oi

  -- Child references
  UNION ALL
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM child_refs) > 0
  UNION ALL
  SELECT 5, 1,
    '--- References (uses) --- (' || CAST((SELECT COUNT(*) FROM child_refs) AS VARCHAR) || ')'
  WHERE (SELECT COUNT(*) FROM child_refs) > 0
  UNION ALL
  SELECT 6, ROW_NUMBER() OVER (ORDER BY Target_Type, Target_Name),
    '  -> ' || Target_Type || ': ' || Target_Name
    || CASE WHEN Is_Cross_File THEN ' [' || Target_File || ']' ELSE '' END
    || ' (' || Link_Role || ')'
  FROM child_refs

  -- Parent references (Layouts, die dieses Design verwenden)
  UNION ALL
  SELECT 8, 0, '' WHERE (SELECT COUNT(*) FROM parent_refs) > 0
  UNION ALL
  SELECT 8, 1,
    '--- Referenced by (used in) --- (' || CAST((SELECT COUNT(*) FROM parent_refs) AS VARCHAR) || ')'
  WHERE (SELECT COUNT(*) FROM parent_refs) > 0
  UNION ALL
  SELECT 9, ROW_NUMBER() OVER (ORDER BY Source_Type, Source_Name),
    '  <- ' || Source_Type || ': ' || Source_Name
    || CASE WHEN Is_Cross_File THEN ' [' || Source_File || ']' ELSE '' END
    || ' (' || Link_Role || ')'
  FROM parent_refs
) details
ORDER BY sort_key, sub_key;
