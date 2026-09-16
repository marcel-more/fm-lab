-- @template_type: content
-- @description: Detailed view of a FileMaker field - properties, table context, and calculation formula
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.4
-- @tags: fields, details, ddr, calculations
-- @note: Shows field properties and calculation formula (primary: Text CDATA, fallback: DDR chunks reconstruction)

WITH field_match AS (
  SELECT f.Field_UUID, f.Field_Name, f.Table_Name, f.Table_UUID,
         f.Field_Type, f.Data_Type, f.Field_Comment, f.Field_Annotation,
         f.Is_Global, f.Max_Repetitions, f.DDR_Hash, f.File_Name,
         f.Field_ID, f.Calculation_Text
  FROM FieldsForTables f
  -- Klon-Scoping: datei-gleicher Join + Datei-Filter. Ohne ihn mischt eine geteilte
  -- Field_UUID (z.B. Archiv-Klon BEL/BELA) die Zeilen aller Klon-Dateien; der Controller
  -- reicht die aufgelöste Datei als getvariable('file') durch (NULL → Graceful Downgrade).
  JOIN ObjectCatalog oc ON f.Field_UUID = oc.Object_UUID AND oc.File_Name = f.File_Name
  WHERE oc.Object_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  LIMIT 1
),
-- Primary: Calculation_Text from XML <Text> CDATA (most reliable)
calc_text_lines AS (
  SELECT ROW_NUMBER() OVER () as line_num, line
  FROM (
    SELECT UNNEST(string_split(replace(Calculation_Text, chr(13), chr(10)), chr(10))) as line
    FROM field_match
    WHERE Calculation_Text IS NOT NULL AND Calculation_Text != ''
  )
),
-- Reconstruct readable formula from DDR_Calculations chunks
-- Uses first contiguous chunk group to avoid duplicates (same Calc_Hash can have multiple chunk sequences)
calc_indexed AS (
  SELECT d.Chunk_Index, d.Chunk_Content,
    LAG(d.Chunk_Index, 1, d.Chunk_Index) OVER (ORDER BY d.Chunk_Index) as prev_idx
  FROM DDR_Calculations d
  WHERE d.Calc_Hash = (SELECT DDR_Hash FROM field_match)
    AND (SELECT DDR_Hash FROM field_match) IS NOT NULL
),
calc_first_group AS (
  SELECT Chunk_Index, Chunk_Content,
    SUM(CASE WHEN Chunk_Index - prev_idx > 1 THEN 1 ELSE 0 END) OVER (ORDER BY Chunk_Index) as grp
  FROM calc_indexed
),
calc_formula AS (
  SELECT string_agg(
    CASE
      WHEN ctype = 'FieldRef' THEN to_name || '::' || field_name
      WHEN ctype = 'NoRef' AND text_content IS NULL THEN ' '
      WHEN ctype = 'NoRef' THEN text_content
      ELSE COALESCE(text_content, '')
    END,
    '' ORDER BY chunk_idx
  ) as formula
  FROM (
    SELECT Chunk_Index as chunk_idx,
      regexp_extract(Chunk_Content, '"@type":"([^"]+)"', 1) as ctype,
      regexp_extract(Chunk_Content, '"@name":"([^"]+)"', 1) as field_name,
      regexp_extract(Chunk_Content, 'TableOccurrenceReference.*?"@name":"([^"]+)"', 1) as to_name,
      CASE WHEN Chunk_Content LIKE '%#text%'
        THEN regexp_extract(Chunk_Content, '"#text":"(.+)"}}$', 1)
        ELSE NULL
      END as text_content
    FROM calc_first_group
    WHERE grp = 0
  ) chunks
),
-- Split formula into display lines (CR -> LF)
formula_lines AS (
  SELECT ROW_NUMBER() OVER () as line_num, line
  FROM (
    SELECT UNNEST(string_split(replace(formula, chr(13), chr(10)), chr(10))) as line
    FROM calc_formula
    WHERE formula IS NOT NULL
  )
),
-- Fallback: raw chunk list when no formula could be reconstructed
calc_chunks AS (
  SELECT d.Chunk_Index, d.Chunk_Type, d.Chunk_Content
  FROM DDR_Calculations d
  JOIN field_match fm ON fm.DDR_Hash = d.Calc_Hash
  WHERE fm.DDR_Hash IS NOT NULL
  ORDER BY d.Chunk_Index
)

SELECT content FROM (
  -- Header
  SELECT 1 as sort_key, 0 as sub_key,
    '=== Field Details ===' as content
  FROM field_match

  UNION ALL
  SELECT 2, 0, '' FROM field_match

  UNION ALL

  -- Field properties
  SELECT 3, 1, 'Field:        ' || fm.Field_Name FROM field_match fm
  UNION ALL
  SELECT 3, 2, 'Table:        ' || fm.Table_Name FROM field_match fm
  UNION ALL
  SELECT 3, 3, 'Field Type:   ' || fm.Field_Type FROM field_match fm
  UNION ALL
  SELECT 3, 4, 'Data Type:    ' || fm.Data_Type FROM field_match fm
  UNION ALL
  SELECT 3, 5, 'Global:       ' || CASE WHEN fm.Is_Global THEN 'Yes' ELSE 'No' END FROM field_match fm
  UNION ALL
  SELECT 3, 6, 'Repetitions:  ' || CAST(fm.Max_Repetitions AS VARCHAR) FROM field_match fm
  WHERE (SELECT Max_Repetitions FROM field_match) > 1
  UNION ALL
  SELECT 3, 7, 'Comment:      ' || fm.Field_Comment FROM field_match fm
  WHERE fm.Field_Comment IS NOT NULL AND fm.Field_Comment != ''
  UNION ALL
  -- FileMaker 26 (schema 1.28.0): free-text annotation of the field, only when set
  SELECT 3, 8, 'Annotation:   ' || fm.Field_Annotation FROM field_match fm
  WHERE fm.Field_Annotation IS NOT NULL AND fm.Field_Annotation != ''
  UNION ALL
  SELECT 3, 9, 'File:         ' || fm.File_Name FROM field_match fm
  UNION ALL
  SELECT 3, 10, 'UUID:         ' || fm.Field_UUID FROM field_match fm

  UNION ALL

  -- PRIMARY: Calculation formula from XML Text CDATA (most complete)
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM calc_text_lines) > 0
  UNION ALL
  SELECT 5, 1, '--- Calculation Formula ---'
  WHERE (SELECT COUNT(*) FROM calc_text_lines) > 0
  UNION ALL
  SELECT 6, CAST(ctl.line_num AS INTEGER),
    '  ' || ctl.line
  FROM calc_text_lines ctl

  UNION ALL

  -- FALLBACK 1: Reconstructed formula from DDR_Calculations chunks
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0
    AND (SELECT COUNT(*) FROM formula_lines) > 0
  UNION ALL
  SELECT 5, 1, '--- Calculation Formula (reconstructed) ---'
  WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0
    AND (SELECT COUNT(*) FROM formula_lines) > 0
  UNION ALL
  SELECT 6, CAST(fl.line_num AS INTEGER),
    '  ' || fl.line
  FROM formula_lines fl
  WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0

  UNION ALL

  -- FALLBACK 2: Raw chunk list (only when both Text and reconstruction failed)
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0
    AND (SELECT COUNT(*) FROM formula_lines) = 0
    AND (SELECT COUNT(*) FROM calc_chunks) > 0
  UNION ALL
  SELECT 5, 1, '--- Calculation Chunks (raw) ---'
  WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0
    AND (SELECT COUNT(*) FROM formula_lines) = 0
    AND (SELECT COUNT(*) FROM calc_chunks) > 0
  UNION ALL
  SELECT 6, CAST(c.Chunk_Index AS INTEGER),
    '  ' || c.Chunk_Content
  FROM calc_chunks c
  WHERE (SELECT COUNT(*) FROM calc_text_lines) = 0
    AND (SELECT COUNT(*) FROM formula_lines) = 0
) details
ORDER BY sort_key, sub_key;
