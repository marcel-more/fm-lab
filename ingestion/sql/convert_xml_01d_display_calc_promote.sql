/*
-- convert_xml_01d_display_calc_promote.sql — Phase 1d of the XML conversion
-- pipeline: promote the staged DisplayCalculations anchors of SaXML 2.3.0.0
-- files (profile saxml23) into the DDR tables — table-only, merged master.
--
-- Background: FileMaker 26 writes <DisplayCalculations membercount="12"> on
-- EVERY text object. Only the first n anchors are real layout calculations
-- (n = number of <<ƒ:…>> tokens in the object's text); the remaining anchors
-- are padding — they repeat the hash of the first slot or carry chunks parsed
-- from a foreign formula text. Read verbatim they became phantom calculation
-- instances and phantom field/function edges (12 instead of 2 on the coverage
-- fixture). FileMaker ≤ 22 writes exactly n anchors (rule verified on every
-- 22-era text object of the coverage fixture and three further catalogs:
-- membercount = <<ƒ:…>> token count, 0 counter-examples).
--
-- Mechanics (decision "staging + promotion"): P1 (profile saxml23) reads all
-- DisplayCalculations anchors into DDR_DisplayCalcAnchors23 instead of the DDR
-- tables (see convert_xml_01_extract.sql). This step joins them to their text
-- object (LayoutObjects.Text_Content lives in another turbo chunk — hence a
-- master stage) and copies the slots below the token count into
-- DDR_Calculations + DDR_ChunkListContexts; promoted rows are flagged
-- (Promoted = TRUE), the padding stays visible in the staging table (P6
-- v_check_saxml_profile, import-report line). Nothing is deleted from a catalog
-- table. Idempotent: a second pass finds no unpromoted candidate; a per-file
-- re-import resets the staging rows in P1 (Promoted = FALSE) and promotes
-- again. No-op for catalogs without saxml23 files (staging table empty).
--
-- Placement: run_phase2() in ingestion/convert_fm_xml.sh, after the heal
-- cascade (P1b) and the design-function retype (P1c), before any P2 statement
-- (P2 reads the DDR chunk stream). Soft-fail: without this step the padding
-- would surface as before — a visible P6/report finding, never wrong links.
*/

-- Guard: the staging table normally exists (P1 DDL). Without it the step is a
-- documented no-op (older catalogs, partial runs).
CREATE TABLE IF NOT EXISTS DDR_DisplayCalcAnchors23 (
    Calc_UUID VARCHAR, Calc_Hash VARCHAR, Chunk_Index BIGINT,
    Chunk_Type VARCHAR, Chunk_Content VARCHAR,
    Chunk_Count BIGINT, Context_TO_ID BIGINT, Context_TO_Name VARCHAR, Context_TO_UUID VARCHAR,
    Slot_Index BIGINT, Promoted BOOLEAN DEFAULT FALSE, File_Name VARCHAR,
    PRIMARY KEY (Calc_UUID, Chunk_Index, File_Name)
);

-- Token count per text object: number of <<ƒ:…>> layout-calculation tokens
-- (plain merge fields <<Field>> carry no DisplayCalculations anchor — same
-- token regex as the P2/P3/P4 display-calculation fallbacks).
DROP TABLE IF EXISTS _dc_promote;
CREATE TEMP TABLE _dc_promote AS
WITH tok AS (
    SELECT upper(Object_UUID) AS Owner_UUID, File_Name,
           MAX(len(regexp_extract_all(COALESCE(Text_Content, ''), '(?s)<<ƒ:(.*?)>>', 1))) AS Token_Count
    FROM LayoutObjects
    GROUP BY 1, 2
)
SELECT s.Calc_UUID, s.Calc_Hash, s.Chunk_Index, s.Chunk_Type, s.Chunk_Content,
       s.Chunk_Count, s.Context_TO_ID, s.Context_TO_Name, s.Context_TO_UUID, s.File_Name
FROM DDR_DisplayCalcAnchors23 s
JOIN tok t
  ON t.Owner_UUID = upper(regexp_extract(s.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
 AND t.File_Name  = s.File_Name
WHERE NOT s.Promoted
  AND s.Slot_Index IS NOT NULL
  AND s.Slot_Index < t.Token_Count;

INSERT INTO DDR_Calculations
SELECT Calc_UUID, Calc_Hash, Chunk_Index, Chunk_Type, Chunk_Content, File_Name
FROM _dc_promote
WHERE Chunk_Index >= 1
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO NOTHING;

INSERT INTO DDR_ChunkListContexts
SELECT Calc_UUID, Calc_Hash, Chunk_Count, Context_TO_ID, Context_TO_Name, Context_TO_UUID, File_Name
FROM _dc_promote
WHERE Chunk_Index = 0
ON CONFLICT (Calc_UUID, File_Name) DO NOTHING;

UPDATE DDR_DisplayCalcAnchors23
SET Promoted = TRUE
WHERE (Calc_UUID, File_Name) IN (SELECT DISTINCT Calc_UUID, File_Name FROM _dc_promote);

DROP TABLE IF EXISTS _dc_promote;
