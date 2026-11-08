-- Shared type-specific base queries for object description / analysis.
-- Consumed by fm-summarize (Step 2) and fm-analyze (Step 2 core data).
-- Not directly executable: substitute the <PLACEHOLDER> tokens, then run each
-- statement individually via: duckdb db/fm_catalog.duckdb -c "…"
--
-- Every lookup filters on File_Name AND the type UUID — names and numeric FM IDs
-- are only unique per file (clone/modular files share UUIDs and IDs).

-- ============================================================ Script
-- S1 — header
SELECT * FROM ScriptCatalog WHERE Script_UUID = '<UUID>' AND File_Name = '<FILE>';

-- S2 — steps (DDR_ScriptSteps.Step_Text preferred for display when NOT NULL)
SELECT
    s.Step_Index,
    s.Step_Name,
    s.Is_Enabled,
    s.Variable_Name,
    s.Calculation_Text,
    ddr.Step_Text
FROM StepsForScripts s
LEFT JOIN DDR_ScriptSteps ddr
    ON s.DDR_UUID = ddr.Step_UUID
   AND s.File_Name = ddr.File_Name
WHERE s.Script_UUID = '<UUID>' AND s.File_Name = '<FILE>'
ORDER BY s.Step_Index;
-- Script dependencies via ObjectLinks (see the dependency queries in the skill body):
--   outgoing roles: calls_script, sets_field, navigates_to_field, navigates_to_layout,
--                   sets_variable, reads_variable   (Source_UUID = Script UUID)
--   incoming roles: calls_script, triggers_script, trigger_script  (Target_UUID = Script UUID)

-- ============================================================ Field
-- F1 — field record (evaluate: Field_Type, Data_Type, Field_Comment, Is_Global,
--       Max_Repetitions; for Calculated: Calculation_Text/DDR_Hash;
--       for AutoEnter: AutoEnter_Type selects the detail columns —
--         Looked_up  → Lookup_Field_Name, Lookup_TO_Name, Lookup_DontCopyIfEmpty, Lookup_NoMatchOption
--         Calculated → AE_Calc_Text, AE_Calc_Hash, AE_Calc_OverwriteExisting, AE_Calc_AlwaysEvaluate
--         ConstantData → AE_ConstantData ; SerialNumber/CreationDate/… → type only)
SELECT * FROM FieldsForTables WHERE Field_UUID = '<UUID>' AND File_Name = '<FILE>';

-- ============================================================ Layout
-- L1 — layout itself
SELECT L_ID, L_Name, L_TO_Name, File_Name FROM Layouts
WHERE L_UUID = '<UUID>' AND File_Name = '<FILE>';

-- L2 — parts (Header/Body/Footer/…)
SELECT * FROM LayoutParts WHERE Layout_ID = <L_ID> AND File_Name = '<FILE>';

-- L3 — object statistics (never list hundreds of objects individually — aggregate)
SELECT Object_Type, COUNT(*) AS Anzahl, MAX(Nesting_Level) AS Max_Tiefe
FROM LayoutObjects
WHERE Layout_ID = <L_ID> AND File_Name = '<FILE>'
GROUP BY Object_Type
ORDER BY Anzahl DESC;

-- L4 — script triggers of the layout
SELECT * FROM ScriptTriggers WHERE Object_UUID = '<L_UUID>' AND File_Name = '<FILE>';
-- Referenced fields/scripts/value lists via ObjectLinks: Source_Type = 'LayoutObject',
-- parent_layout points to this layout.

-- ============================================================ CustomFunction
-- CF1 — catalog record
SELECT * FROM CustomFunctionsCatalog WHERE CF_UUID = '<UUID>' AND File_Name = '<FILE>';

-- CF2 — formula
SELECT Calculation_Code FROM CalcsForCustomFunctions
WHERE CF_UUID = '<UUID>' AND File_Name = '<FILE>';
-- Callers: ObjectLinks with Target_UUID = CF UUID.

-- ============================================================ ValueList
-- VL1 — value list + its option rows
SELECT vl.*, o.Source_Type, o.Custom_Values, o.Field_Name, o.TO_Name
FROM ValueListCatalog vl
LEFT JOIN OptionsForValueLists o
    ON vl.VL_UUID = o.VL_UUID AND vl.File_Name = o.File_Name
WHERE vl.VL_UUID = '<UUID>' AND vl.File_Name = '<FILE>';
-- Users: ObjectLinks Target_UUID = VL UUID, Link_Role = uses_valuelist.

-- ============================================================ BaseTable
-- BT1 — base table
SELECT * FROM BaseTableCatalog WHERE BT_UUID = '<UUID>' AND File_Name = '<FILE>';

-- BT2 — fields
SELECT Field_Name, Field_Type, Data_Type, Is_Global, Field_Comment
FROM FieldsForTables WHERE Table_UUID = '<UUID>' AND File_Name = '<FILE>'
ORDER BY Field_ID;

-- BT3 — table occurrences
SELECT TO_Name, TO_ID FROM TableOccurrenceCatalog
WHERE BT_UUID = '<UUID>' AND File_Name = '<FILE>';

-- ============================================================ TableOccurrence
-- TO1 — table occurrence
SELECT * FROM TableOccurrenceCatalog WHERE TO_UUID = '<UUID>' AND File_Name = '<FILE>';

-- TO2 — relationships this TO participates in
--   NOTE: the OR must be parenthesized so File_Name filters BOTH sides
--   (otherwise A OR (B AND C) leaks cross-file rows).
SELECT * FROM RelationshipCatalog
WHERE (Left_TO_UUID = '<UUID>' OR Right_TO_UUID = '<UUID>')
  AND File_Name = '<FILE>';

-- TO3 — usage per category (schema >= 1.38.0; on older catalogs the table is
--   missing — skip TO3/TO4 and say that only the edges were read).
--   A TO::Field reference links only the FIELD, so the incoming ObjectLinks of
--   a TO miss formulas, script steps and layout fields; this table has them,
--   edges included (Is_Edge). Pattern + pitfalls: docs/agents/query-cookbook.md
--   § Where-used for Table Occurrences.
SELECT Category, User_Type,
       count(DISTINCT User_UUID)    AS Users,
       CAST(sum(Ref_Count) AS BIGINT) AS Refs,
       bool_or(Is_Edge)             AS Via_Edge
FROM v_table_occurrence_usage
WHERE TO_UUID = '<UUID>' AND File_Name = '<FILE>'
GROUP BY ALL
ORDER BY Refs DESC;

-- TO4 — usage class (unused · used · relationship_bridge · dead_branch · dead_island;
--   Low_Confidence = file without DDR info → unused/dead_* unverified)
SELECT Usage_Class, Reason, Usage_Ref_Count, Relationship_Count, Text_Ref_Count,
       Dead_Group_Size, Anchor_TO_Name, Low_Confidence
FROM v_table_occurrence_class
WHERE TO_UUID = '<UUID>' AND File_Name = '<FILE>';

-- ============================================================ Relationship
-- R1 — relationship (predicates in Left_*/Right_* columns, operator in Operator)
SELECT * FROM RelationshipCatalog WHERE Rel_ID = <REL_ID> AND File_Name = '<FILE>';

-- ============================================================ Calculation (schema 1.22.0)
-- C1 — calculation instance (owner × role × index; exists WITHOUT DDR info too —
--      Formula_Text/Display_Text carry the readable formula, Formula_Hash/DDR_Calc_UUID
--      are DDR enrichment and may be NULL)
SELECT Owner_Type, Owner_Name, Calc_Role, Calc_Index, Source_Path,
       Is_Static, COALESCE(Formula_Text, Display_Text) AS Formula,
       Formula_Hash, DDR_Calc_UUID, File_Name
FROM CalculationsCatalog
WHERE Calculation_UUID = '<UUID>' AND File_Name = '<FILE>';

-- C2 — resolved targets of the instance (derived view, variant A — the usage
--      semantics live on the OWNER edges; this is the per-slot detail resolution)
SELECT vl.Link_Role, vl.Target_Type, vl.Target_File,
       (SELECT Object_Name FROM ObjectCatalog WHERE Object_UUID = vl.Target_UUID) AS Target_Name
FROM v_calculation_links vl
WHERE vl.Calculation_UUID = '<UUID>'
ORDER BY vl.Link_Role, Target_Name;

-- C3 — all calculation instances of an OWNER object (slot inventory)
SELECT Calc_Role, Calc_Index, Source_Path, Is_Static,
       left(COALESCE(Formula_Text, Display_Text), 120) AS Formula_Preview
FROM CalculationsCatalog
WHERE Owner_UUID = '<UUID>' AND File_Name = '<FILE>'
ORDER BY Calc_Role, Calc_Index;

-- ============================================================ Generic fallback
-- G0 — basic info (any Object_Type without a specific template above)
SELECT * FROM ObjectCatalog WHERE Object_UUID = '<UUID>' AND File_Name = '<FILE>';

-- G1 — incoming links (what uses the object)
-- (UUID and file on both sides — clone and modular files share UUIDs)
SELECT Source_Type, Source_File, Link_Role,
       (SELECT Object_Name FROM ObjectCatalog
         WHERE Object_UUID = ol.Source_UUID AND File_Name IS NOT DISTINCT FROM ol.Source_File) AS Source_Name
FROM ObjectLinks ol
WHERE Target_UUID = '<UUID>' AND Target_File = '<FILE>'
ORDER BY Source_Type;

-- G2 — outgoing links (what the object uses)
SELECT Target_Type, Target_File, Link_Role,
       (SELECT Object_Name FROM ObjectCatalog
         WHERE Object_UUID = ol.Target_UUID AND File_Name IS NOT DISTINCT FROM ol.Target_File) AS Target_Name
FROM ObjectLinks ol
WHERE Source_UUID = '<UUID>' AND Source_File = '<FILE>'
ORDER BY Target_Type;

-- ============================================================ Optional: DDR calc chunks
-- D1 — resolved formula chunks (Field DDR_Hash / AE_Calc_Hash, or CustomFunction DDR_Hash)
SELECT Chunk_Index, Chunk_Type, Chunk_Content
FROM DDR_Calculations
WHERE Calc_Hash = '<HASH>' AND File_Name = '<FILE>'
ORDER BY Chunk_Index;
