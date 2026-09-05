/*
-- convert_xml_01c_design_function_retype.sql — Phase 1c of the XML conversion
-- pipeline: re-classify FileMaker design functions in the DDR chunk stream.
--
-- Background: the SaXML export tags the design functions (DatabaseNames,
-- WindowNames, LayoutIDs, ValueListItems, ScriptNames, …) as
-- <Chunk type="PluginFunctionRef"> — the chunk type otherwise used for plug-in
-- calls — and keeps their names in the language of the authoring client
-- (`Fensternamen`, `WindowNames`, …). Every other built-in function arrives as
-- FunctionRef with its canonical English name. Taken literally, each design
-- function became a synthetic PluginFunction object with calls_pluginfunction
-- edges: plug-in statistics, plug-in dashboards and the cluster god-node list
-- counted them as plug-ins.
--
-- This step retypes those chunks to FunctionRef BEFORE Phase 2 reads the chunk
-- stream, so every downstream consumer follows without change: the FunctionRef
-- blocks of P2 register them in XMLCalcReferences (Ref_Type='function'), P4
-- creates BuiltinFunction objects (raw token, like the localized Get parameters)
-- and calls_function edges, the cluster projection excludes them as built-ins,
-- and the token renderers show a function token.
--
-- Match rule: a POSITIVE name list only — DesignFunctionNames, generated from
-- the reference DB by ingestion/gen_design_functions.sh (every reference
-- language) and created in this session by sql/generated/design_functions_seed.sql.
-- The SaXML chunk type also covers plug-ins without a namespace and
-- unresolvable identifiers (deleted custom functions); those must stay
-- PluginFunctionRef, so "no namespace" is never a criterion here.
-- Case-insensitive (FileMaker function names are), and matched against both
-- the plain name and its XML numeric char-ref form (Name_XML): the DOM fragment
-- path serializes non-ASCII chunk text as &#xHH; (`WertelisteEintr&#xE4;ge`),
-- the SAX path writes it literally.
--
-- Placement: runs ONCE on the merged master DB — run_phase2() in
-- ingestion/convert_fm_xml.sh, right after the heal cascade and before any P2
-- statement (covers batch, turbo, partitioned and single-file mode; the P2
-- slices see DDR_Calculations read-only). Idempotent: a second pass finds
-- nothing; a per-file re-import resets the raw type in P1 and is retyped
-- again here. Only the type attribute of Chunk_Content is rewritten, the token
-- text stays as serialized. TABLE-ONLY (no XML access, no extension needed).
-- Failure mode: without the seed (missing/failed) the guard below leaves an
-- empty name table and the step is a documented no-op — the catalog then
-- classifies design functions as plug-in functions, as before this phase.
*/

-- Guard: the seed normally creates and fills this table in the same session.
-- If it did not run, the UPDATE below matches nothing (documented no-op).
CREATE TABLE IF NOT EXISTS DesignFunctionNames (
    Function_ID    INTEGER,
    Canonical_Name VARCHAR,
    Language       VARCHAR,
    Name           VARCHAR,
    Name_XML       VARCHAR
);

UPDATE DDR_Calculations
SET Chunk_Type    = 'FunctionRef',
    Chunk_Content = regexp_replace(Chunk_Content, 'type="PluginFunctionRef"', 'type="FunctionRef"')
WHERE Chunk_Type = 'PluginFunctionRef'
  AND lower(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1)) IN (
        SELECT lower(Name)     FROM DesignFunctionNames
        UNION ALL
        SELECT lower(Name_XML) FROM DesignFunctionNames WHERE Name_XML IS NOT NULL
  );
