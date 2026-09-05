-- ============================================================================
-- Phase 3.5 — MBS-SubName-Recovery aus dem Calc-Klartext
-- ============================================================================
-- Problem: FileMakers DDR-Export verliert in bestimmten Konstellationen den
-- NoRef-Chunk mit dem 1. String-Argument eines Container-Plugin-Aufrufs
-- (beobachtet: Argumenttext zwischen PluginFunctionRef und folgendem
-- Comment-Chunk; Argumenttext zwischen zwei direkt verschachtelten MBS-Refs,
-- z.B. MBS("List.Sort"; MBS("List.RemoveDuplicateItems"; …))). Die
-- Chunk-Proximity-Paarung in P2 (MBS_SubnameMap) kann diese Fälle prinzipiell
-- nicht lösen — die Information fehlt in der Chunk-Kette vollständig.
--
-- Recovery-Quelle ist der CDATA-Klartext derselben Calculation. Text-Träger
-- (Calc_UUID-Konventionen empirisch verifiziert):
--   Script-Step:     '_' || Step_UUID || '_' || Calc_Position  → StepCalculations.Calc_Text
--   CustomFunction:  '_' || CF_UUID   (ohne Positions-Suffix)  → CalcsForCustomFunctions.Calculation_Code
--   Field Formel:    '_' || Field_UUID || '_0'                 → FieldsForTables.Calculation_Text
--   Field AutoEnter: '_' || Field_UUID || '_1'                 → FieldsForTables.AE_Calc_Text
-- (Validation-Calcs erscheinen im DDR nicht mit ChunkLists — kein Träger.)
--
-- Invariante: PluginFunctionRef-Chunks gehen nie verloren (nur NoRef-Text) —
-- der k-te MBS-Ref-Chunk entspricht dem k-ten lexikalisch echten MBS-Token im
-- Klartext. Der Tokenizer überspringt String-Literale (inkl. \"-Escapes) und
-- Kommentare; eine naive Regex würde fehlpaaren ("MBS" kommt real als
-- String-Literal in Formeln vor, z.B. als Argument von Registration.Register).
--
-- Sicherheit / Idempotenz:
--   * Invarianten-Guard: Paarung nur, wenn #Ref-Chunks == #gelexte Calls im
--     Calc — ein falscher SubName ist strukturell ausgeschlossen, im
--     Zweifelsfall bleibt NULL (heutiger Zustand).
--   * Der Pass füllt ausschließlich SubName-NULL-Zeilen; dynamische
--     1. Argumente (MBS($var; …)) bleiben korrekt NULL.
--   * Re-Run ist ein No-Op (UPDATE-auf-NULL-Semantik).
--
-- Einbauort: NACH P3 (braucht StepCalculations) und VOR P4 (Katalog-Block 26
-- und Link-Block 34 lesen MBS_SubnameMap live). XMLCalcReferences.Ref_SubName
-- und die A.10-Qualifizierung von PluginFunctionUsages sind P2-Kopien der Map
-- und werden hier nachgezogen.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Klartext-Aufrufe lexen: pro Calc der k-te echte MBS-Aufruf + sein
--    literales 1. Argument (NULL bei dynamischem 1. Argument).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE _mbs_text_calls AS
WITH texts AS (
    SELECT '_' || sc.Step_UUID || '_' || sc.Calc_Position AS Calc_UUID,
           sc.File_Name, sc.Calc_Text
    FROM StepCalculations sc
    WHERE sc.Calc_Text LIKE '%MBS%'
    UNION ALL
    -- Join-Spalte ist CF_UUID: DDR_UUID ist identisch, wo DDR-Info existiert,
    -- aber NULL für CFs aus Dateien ohne DDR-Info (die haben keine ChunkLists
    -- und sind hier ohnehin irrelevant).
    SELECT '_' || CF_UUID, File_Name, Calculation_Code
    FROM CalcsForCustomFunctions
    WHERE Calculation_Code LIKE '%MBS%'
    UNION ALL
    SELECT '_' || Field_UUID || '_0', File_Name, Calculation_Text
    FROM FieldsForTables
    WHERE Calculation_Text LIKE '%MBS%'
    UNION ALL
    SELECT '_' || Field_UUID || '_1', File_Name, AE_Calc_Text
    FROM FieldsForTables
    WHERE AE_Calc_Text LIKE '%MBS%'
),
toks AS (
    -- Tokenizer: String-Literale (inkl. \"-Escapes), Block-/Zeilenkommentare
    -- und Identifier als Atome; jedes Restzeichen einzeln. (?s): '.' matcht
    -- auch Zeilenumbrüche. Verschachtelte Blockkommentare kann RE2 nicht —
    -- solche Calcs fallen unten durch den Invarianten-Guard (SubName bleibt
    -- NULL statt fehlgepaart).
    SELECT Calc_UUID, File_Name, t.tok, t.ord
    FROM texts,
         UNNEST(regexp_extract_all(Calc_Text,
             '(?s)"(?:\\.|[^"\\])*"|/\*[^*]*\*+(?:[^/*][^*]*\*+)*/|//[^' || chr(10) || chr(13) || ']*|[A-Za-z_][A-Za-z0-9_.]*|.'
         )) WITH ORDINALITY AS t(tok, ord)
),
sig AS (
    -- Signifikante Tokens: Whitespace-Einzelzeichen und Kommentare raus.
    SELECT Calc_UUID, File_Name, tok, ord
    FROM toks
    WHERE NOT regexp_matches(tok, '^\s$')
      AND NOT (tok LIKE '/*%')
      AND NOT (tok LIKE '//%' AND length(tok) > 1)
),
looked AS (
    SELECT Calc_UUID, File_Name, tok, ord,
           LEAD(tok, 1) OVER w AS t1,
           LEAD(tok, 2) OVER w AS t2
    FROM sig
    WINDOW w AS (PARTITION BY Calc_UUID, File_Name ORDER BY ord)
)
SELECT Calc_UUID, File_Name,
       ROW_NUMBER() OVER (PARTITION BY Calc_UUID, File_Name ORDER BY ord) AS k,
       count(*)     OVER (PARTITION BY Calc_UUID, File_Name)              AS n_calls,
       CASE WHEN t1 = '(' AND t2 LIKE '"%'
            THEN substr(t2, 2, length(t2) - 2)
       END AS SubName
FROM looked
WHERE tok = 'MBS';

-- ----------------------------------------------------------------------------
-- 2. Ref-Chunk-Ordinale: pro Calc der k-te MBS-PluginFunctionRef-Chunk.
--    Läuft über ALLE Calc-Instanzen (nicht hash-dedupliziert), damit die Map
--    und die Usages jeder Instanz erreichbar sind.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE _mbs_ref_ranks AS
SELECT Calc_UUID, File_Name, Calc_Hash, Chunk_Index,
       ROW_NUMBER() OVER (PARTITION BY Calc_UUID, File_Name ORDER BY Chunk_Index) AS k,
       count(*)     OVER (PARTITION BY Calc_UUID, File_Name)                      AS n_refs
FROM DDR_Calculations
WHERE Chunk_Type = 'PluginFunctionRef'
  AND regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) = 'MBS';

-- ----------------------------------------------------------------------------
-- 3. Recovery pro (Calc_Hash, File_Name, Ordinal) aggregieren. Gleicher Hash
--    = gleiche Formel = gleiches Ergebnis; die Hash-Ebene propagiert den
--    SubName auch auf Instanzen ohne eigenen Text-Träger (z.B. LayoutObjects
--    mit formelgleichem Hash). Konsistenz-HAVING als Zusatzwächter.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE _mbs_recovered AS
SELECT r.Calc_Hash, r.File_Name, r.k, max(c.SubName) AS SubName
FROM _mbs_ref_ranks r
JOIN _mbs_text_calls c
  ON c.Calc_UUID = r.Calc_UUID
 AND c.File_Name = r.File_Name
 AND c.k         = r.k
WHERE r.n_refs = c.n_calls          -- Invarianten-Guard (pro Calc)
  AND c.SubName IS NOT NULL
GROUP BY 1, 2, 3
HAVING min(SubName) = max(SubName);

-- ----------------------------------------------------------------------------
-- 4. MBS_SubnameMap: NULL-Zeilen füllen (alle Instanzen, via Hash-Ordinal).
-- ----------------------------------------------------------------------------
UPDATE MBS_SubnameMap m
SET SubName = rec.SubName
FROM _mbs_ref_ranks r
JOIN _mbs_recovered rec
  ON rec.Calc_Hash = r.Calc_Hash
 AND rec.File_Name = r.File_Name
 AND rec.k         = r.k
WHERE m.Calc_UUID          = r.Calc_UUID
  AND m.File_Name          = r.File_Name
  AND m.Plugin_Chunk_Index = r.Chunk_Index
  AND m.SubName IS NULL;

-- ----------------------------------------------------------------------------
-- 5. PluginFunctionUsages nachqualifizieren (Spiegel der A.10-Logik in P2:
--    'MBS' → 'MBS:<Methode>'; nicht auflösbare bleiben generisch 'MBS').
-- ----------------------------------------------------------------------------
UPDATE PluginFunctionUsages p
SET Plugin_Function_Name = 'MBS:' || m.SubName
FROM MBS_SubnameMap m
WHERE p.Plugin_Function_Name = 'MBS'
  AND m.Calc_UUID          = p.Calc_UUID
  AND m.File_Name          = p.File_Name
  AND m.Plugin_Chunk_Index = p.Plugin_Chunk_Index
  AND m.SubName IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 6. XMLCalcReferences.Ref_SubName nachziehen. Die MBS-Zeilen einer Gruppe
--    (Source × Calc_Hash) sind ohne Positionsspalte nicht einzeln adressierbar
--    (mehrere NULL-Zeilen wären ununterscheidbar) — deshalb werden betroffene
--    Gruppen komplett gelöscht und aus dem aktuellen Map-Stand neu aufgebaut:
--    eine Zeile pro MBS-Chunk-Ordinal des Hashes, Kardinalität identisch zum
--    P2-Aufbau (der über die hash-kanonische Instanz _ddr_chunks_by_hash lief).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE _mbs_xcr_groups AS
SELECT DISTINCT x.Source_UUID, x.Source_Type, x.Source_Subkey, x.Subrole,
                x.Calc_Hash, x.File_Name
FROM XMLCalcReferences x
JOIN (SELECT DISTINCT Calc_Hash, File_Name FROM _mbs_recovered) rec
  ON rec.Calc_Hash = x.Calc_Hash AND rec.File_Name = x.File_Name
WHERE x.Ref_Type    = 'pluginfunction'
  AND x.Ref_Name    = 'MBS'
  AND x.Ref_SubName IS NULL;

-- Aktueller SubName-Stand pro (Hash, Ordinal) — nach Schritt 4 instanzweit
-- konsistent; unaufgelöste Ordinale (dynamische Argumente) bleiben NULL.
CREATE OR REPLACE TEMP TABLE _mbs_hash_subnames AS
SELECT r.Calc_Hash, r.File_Name, r.k, max(m.SubName) AS SubName
FROM _mbs_ref_ranks r
JOIN MBS_SubnameMap m
  ON m.Calc_UUID          = r.Calc_UUID
 AND m.File_Name          = r.File_Name
 AND m.Plugin_Chunk_Index = r.Chunk_Index
GROUP BY 1, 2, 3;

DELETE FROM XMLCalcReferences x
USING _mbs_xcr_groups g
WHERE x.Source_UUID = g.Source_UUID
  AND x.Source_Type = g.Source_Type
  AND x.Source_Subkey IS NOT DISTINCT FROM g.Source_Subkey
  AND x.Subrole       IS NOT DISTINCT FROM g.Subrole
  AND x.Calc_Hash   = g.Calc_Hash
  AND x.File_Name   = g.File_Name
  AND x.Ref_Type    = 'pluginfunction'
  AND x.Ref_Name    = 'MBS';

INSERT INTO XMLCalcReferences
SELECT g.Source_UUID, g.Source_Type, g.Source_Subkey, g.Subrole,
       g.Calc_Hash, 'pluginfunction',
       NULL,                -- Ref_UUID
       'MBS',               -- Ref_Name
       g.File_Name,
       NULL, NULL,          -- TO_Name, TO_UUID
       NULL, NULL,          -- Variable_Scope, Usage_Type
       h.SubName,           -- Ref_SubName
       NULL, NULL           -- Ref_ID, TO_Ref_ID
FROM _mbs_xcr_groups g
JOIN _mbs_hash_subnames h
  ON h.Calc_Hash = g.Calc_Hash AND h.File_Name = g.File_Name;

DROP TABLE IF EXISTS _mbs_text_calls;
DROP TABLE IF EXISTS _mbs_ref_ranks;
DROP TABLE IF EXISTS _mbs_recovered;
DROP TABLE IF EXISTS _mbs_xcr_groups;
DROP TABLE IF EXISTS _mbs_hash_subnames;
