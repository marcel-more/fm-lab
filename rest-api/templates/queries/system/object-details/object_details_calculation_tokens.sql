-- @template_type: report
-- @description: Standalone calculation by Calculation_UUID (primary) or hash (alias)
-- @params: uuid (optional), hash (optional; one of both required), file (optional)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.4
-- @tags: calculations, ddr, tokens

-- Primary path (schema 1.22.0): ?uuid=<Calculation_UUID> resolves the INSTANCE via
-- CalculationsCatalog → DDR_Calc_UUID (exact, owner-scoped). Hash alias: Calc_Hash is
-- NOT unique — multiple Calc_UUIDs may share a hash (identical multi-file copies, or
-- genuine collisions across different formulas); the minimal (Calc_UUID, File_Name)
-- pair is a best-effort pick. Callers that know the owner should pass the uuid.
-- Structural-only instances (DDR_Calc_UUID NULL — no DDR info) have no chunk rows;
-- the controller reports them as not-found for the token format.
--
-- v1.4 (display-calculation rescue, schema 1.27.0): the uuid path also carries the
-- owner + slot so misclassified '%X:<field>' VariableReference chunks (FileMaker DDR
-- defect in TYPED layout calculations with a single field reference) can be paired
-- with their rescued field reference from XMLCalcReferences (P2 A.5.1b — resolved
-- against the ChunkList's context TO). The join runs over (owner, subrole), NEVER
-- over the hash (shared hashes, own context TO per anchor). Shape assumption
-- (fixture-verified): the misclassification only occurs when the WHOLE formula is a
-- single field reference, so the (owner, slot) rescue row is unique; MIN() guards
-- determinism should FileMaker ever produce a mixed broken ChunkList. The hash-alias
-- path has no instance context — rescue columns stay NULL there and the formatter
-- degrades the chunk to plain text (best-effort contract of the alias).
WITH calc_inst AS (
  SELECT cc.DDR_Calc_UUID AS Calc_UUID, cc.File_Name,
         cc.Owner_UUID, cc.Calc_Kind_Raw,
         (cc.Calc_Kind_Raw LIKE 'DisplayCalculations\_%' ESCAPE '\') AS Is_Display_Slot
  FROM CalculationsCatalog cc
  WHERE getvariable('uuid') IS NOT NULL
    AND cc.Calculation_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR cc.File_Name = getvariable('file'))
    AND cc.DDR_Calc_UUID IS NOT NULL
  UNION ALL
  SELECT Calc_UUID, File_Name,
         CAST(NULL AS VARCHAR) AS Owner_UUID,
         CAST(NULL AS VARCHAR) AS Calc_Kind_Raw,
         FALSE AS Is_Display_Slot
  FROM (
    SELECT Calc_UUID, File_Name
    FROM DDR_Calculations
    WHERE getvariable('uuid') IS NULL
      AND Calc_Hash = getvariable('hash')
    ORDER BY Calc_UUID, File_Name
    LIMIT 1
  )
  LIMIT 1
),
-- Rescued field reference of the display slot (≤ 1 row by shape assumption).
rescued AS (
  SELECT
    MIN(xcr.Ref_UUID) AS Ref_UUID,
    MIN(xcr.Ref_Name) AS Ref_Name,
    MIN(xcr.TO_Name)  AS TO_Name
  FROM XMLCalcReferences xcr
  JOIN calc_inst c
    ON xcr.Source_UUID = c.Owner_UUID
   AND xcr.Subrole     = c.Calc_Kind_Raw
   AND xcr.File_Name   = c.File_Name
  WHERE xcr.Ref_Type = 'field'
    AND c.Is_Display_Slot
)
SELECT
  d.Calc_Hash AS hash,
  d.Chunk_Index AS chunk_index,
  d.Chunk_Type AS chunk_type,
  d.Chunk_Content AS chunk_content,
  -- Fachlicher Container-Plugin-Funktionsname (MBS) aus MBS_SubnameMap —
  -- positionsgenau (Calc_UUID + Chunk_Index) und inklusive der P3.5-Klartext-
  -- Recovery. Autoritativ gegenüber der Nachbar-Chunk-Heuristik des Formatters,
  -- die bei DDR-Chunk-Verlust (Kommentar am Aufruf, verschachtelte Aufrufe)
  -- prinzipbedingt leer ausgeht. NULL = kein MBS-Ref oder echt dynamisches
  -- 1. Argument.
  msn.SubName AS sub_function,
  c.Is_Display_Slot AS is_display_slot,
  -- Rescue columns: only on the misclassified chunk itself (prefix pattern),
  -- NULL everywhere else — the formatter keys its field-token rewrite on them.
  CASE WHEN d.Chunk_Type = 'VariableReference'
        AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
       THEN r.Ref_UUID END AS rescued_field_uuid,
  CASE WHEN d.Chunk_Type = 'VariableReference'
        AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
       THEN r.Ref_Name END AS rescued_field_name,
  CASE WHEN d.Chunk_Type = 'VariableReference'
        AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
       THEN r.TO_Name END AS rescued_to_name
FROM DDR_Calculations d
JOIN calc_inst c ON d.Calc_UUID = c.Calc_UUID AND d.File_Name = c.File_Name
CROSS JOIN rescued r
LEFT JOIN MBS_SubnameMap msn
       ON msn.Calc_UUID = d.Calc_UUID
      AND msn.File_Name = d.File_Name
      AND msn.Plugin_Chunk_Index = d.Chunk_Index
ORDER BY d.Chunk_Index;
