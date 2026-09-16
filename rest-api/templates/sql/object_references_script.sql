-- @template_type: report
-- @description: Object references per script step — vollständige Heimat-Auflösung über ObjectHomes + TableOccurrenceResolution
-- @params: uuid (required)
-- @author: Marcel
-- @version: 2.0
-- @tags: scripts, references, tokens

-- v2.0:
--   - Heimat-Datei für Field/Script/Layout/CF kommt aus ObjectHomes statt FieldsForTables
--   - TO-Resolution (TableOccurrenceResolution) liefert kanonische BaseTable + Cross-File-Indikator
--   - Cross-File-Script-Aufrufe via XMLStepReferences.Data_Source_*
--   - Variable-Refs (Set/Read) und Plugin-Function-Refs als eigene Ref-Typen
-- v2.1:
--   - GTRR-TO-Refs (Ref_Type='tableOccurrence') über tor_gtrr-JOIN auf
--     TableOccurrenceResolution (Ref_UUID = TO_UUID). Heimat ist die BT-Heimat,
--     nicht die TO-Definitions-Datei.
-- v2.2:
--   - Plugin-Funktion-Refs liefern `sub_function` aus XMLCalcReferences.Ref_SubName
--     (fachlicher MBS-Funktionsname, z.B. 'List.AddPrefix'). NULL für nicht-Container-
--     Plugins (Standard-Plugins ohne MBS-Container-Verhalten).
-- v2.3 Variable-UUIDs:
--   - Variable-Refs (Set + Read) liefern jetzt die synthetische ObjectCatalog-UUID
--     (md5(Scope || '::' || Scope_Anchor || '::' || Name)) statt NULL, damit
--     RefSpan den Cross-Reference-Highlight per UUID-Match anwenden kann.
--     Scope_Anchor-Konvention spiegelt VariableUsages (siehe create_universal_catalogs.sql A.7e).
--
-- Source-Priorität: Step-Direkt-Refs (0) gewinnen gegen identische Treffer aus
-- DDR-Calc-Chunks (1+) durch first-wins-Dedup im Formatter.
--
-- Spalten pro Ref-Zeile:
--   line_index, source_priority, type, name, uuid
--   field_file, field_basetable, to_name
--   cross_file (BOOLEAN), data_source
--   variable_scope, variable_usage
--   sub_function (nur für type='pluginFunction' bei Container-Plugins)

-- (1) Step-Direkt-Refs aus XMLStepReferences (Set Field, Go to Field, GTRR-Field,
--     GTRR-TO, GTRR-Layout, Go to Layout, Perform Script, Set Variable)
SELECT
  CAST(xsr.Step_Index AS INTEGER) AS line_index,
  0 AS source_priority,
  -- Ref_Type ist bereits die Frontend-RefType-Kennung — bis auf 'valuelist',
  -- das im TS-Union als camelCase 'valueList' geführt wird (Sort-Records-Custom-
  -- Sortierung nach Werteliste). Ohne Mapping bliebe die Werteliste im Step-Text
  -- unklickbar (RefSpan kennt nur 'valueList').
  CASE WHEN xsr.Ref_Type = 'valuelist' THEN 'valueList' ELSE xsr.Ref_Type END AS type,
  xsr.Ref_Name AS name,
  -- Variable-Refs (Set Variable Step): synthetische UUID aus Scope/Anchor/Name
  -- (parallel zu VariablesCatalog.Object_UUID), damit Cross-Reference-Highlight
  -- per UUID-Match greift. Set Variable hat immer ein Script — kein __file-Fallback.
  CASE
    WHEN xsr.Ref_Type = 'variable' AND xsr.Variable_Scope = 'global'
      THEN md5('global::' || xsr.File_Name || '::' || xsr.Ref_Name)
    WHEN xsr.Ref_Type = 'variable' AND xsr.Variable_Scope = 'local'
      THEN md5('local::' || xsr.Script_UUID || '::' || xsr.Ref_Name)
    WHEN xsr.Ref_Type = 'variable' AND xsr.Variable_Scope = 'superglobal'
      THEN md5('superglobal::__global::' || xsr.Ref_Name)
    ELSE xsr.Ref_UUID
  END AS uuid,
  -- Heimat-Datei pro Ref_Type:
  --   field           → ObjectHomes.Home_File via Field_UUID
  --   script          → ObjectHomes.Home_File via Script_UUID, Fallback auf Data_Source_Name
  --   layout          → ObjectHomes.Home_File via Layout_UUID
  --   tableOccurrence → TableOccurrenceResolution.Home_File via TO_UUID+File_Name
  --                     (NICHT ObjectHomes — das wäre die TO-Definitions-Datei,
  --                      nicht die BT-Heimat / das Navigations-Ziel)
  --   variable        → File_Name des Source-Steps (Variables haben keine Cross-File-Heimat)
  CASE
    WHEN xsr.Ref_Type = 'field'           THEN oh_field.Home_File
    WHEN xsr.Ref_Type = 'script'          THEN COALESCE(oh_script.Home_File, xsr.Data_Source_Name)
    WHEN xsr.Ref_Type = 'layout'          THEN oh_layout.Home_File
    WHEN xsr.Ref_Type = 'tableOccurrence' THEN tor_gtrr.Home_File
    WHEN xsr.Ref_Type = 'variable'        THEN xsr.File_Name
    WHEN xsr.Ref_Type = 'valuelist'       THEN oh_vl.Home_File
  END AS field_file,
  -- BaseTable für Field-Refs (kanonisch aus TableOccurrenceResolution) und
  -- für tableOccurrence-Refs (GTRR-TO direkt aus tor_gtrr).
  CASE
    WHEN xsr.Ref_Type = 'field'           THEN tor.Canonical_BT_Name
    WHEN xsr.Ref_Type = 'tableOccurrence' THEN tor_gtrr.Canonical_BT_Name
  END AS field_basetable,
  xsr.TO_Name AS to_name,
  -- Cross-File-Indikator pro Ref_Type:
  --   field           → TO ist via DataSource cross-file
  --   script          → DataSourceReference im Step-XML vorhanden
  --   tableOccurrence → TO ist via DataSource cross-file (GTRR-Sprung in andere Datei)
  --   layout/variable → kein Cross-File-Konzept
  CASE
    WHEN xsr.Ref_Type = 'field'           THEN (tor.Resolution_Type = 'cross_file_ds')
    WHEN xsr.Ref_Type = 'script'          THEN (xsr.Data_Source_Name IS NOT NULL)
    WHEN xsr.Ref_Type = 'tableOccurrence' THEN (tor_gtrr.Resolution_Type = 'cross_file_ds')
    ELSE FALSE
  END AS cross_file,
  COALESCE(tor.Data_Source_Name, tor_gtrr.Data_Source_Name, xsr.Data_Source_Name) AS data_source,
  xsr.Variable_Scope AS variable_scope,
  xsr.Usage_Type     AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM XMLStepReferences xsr
LEFT JOIN ObjectHomes oh_field
       ON xsr.Ref_UUID = oh_field.Object_UUID AND xsr.Ref_Type = 'field'
LEFT JOIN ObjectHomes oh_script
       ON xsr.Ref_UUID = oh_script.Object_UUID AND xsr.Ref_Type = 'script'
LEFT JOIN ObjectHomes oh_layout
       ON xsr.Ref_UUID = oh_layout.Object_UUID AND xsr.Ref_Type = 'layout'
LEFT JOIN ObjectHomes oh_vl
       ON xsr.Ref_UUID = oh_vl.Object_UUID AND xsr.Ref_Type = 'valuelist'
LEFT JOIN TableOccurrenceResolution tor
       ON xsr.TO_UUID  = tor.TO_UUID
      AND xsr.File_Name = tor.File_Name
LEFT JOIN TableOccurrenceResolution tor_gtrr
       ON xsr.Ref_UUID  = tor_gtrr.TO_UUID
      AND xsr.File_Name = tor_gtrr.File_Name
      AND xsr.Ref_Type  = 'tableOccurrence'
WHERE xsr.Script_UUID = getvariable('uuid')
  -- Klon-Disambiguierung: geteilte Script_UUID matcht sonst alle Klon-Dateien
  AND (getvariable('file') IS NULL OR xsr.File_Name = getvariable('file'))

UNION ALL

-- (2) Field-Refs aus XMLCalcReferences (Calculations innerhalb von Steps)
SELECT
  CAST(xcr.Source_Subkey AS INTEGER) AS line_index,
  1 AS source_priority,
  'field' AS type,
  xcr.Ref_Name AS name,
  xcr.Ref_UUID AS uuid,
  oh.Home_File AS field_file,
  tor.Canonical_BT_Name AS field_basetable,
  xcr.TO_Name AS to_name,
  (tor.Resolution_Type = 'cross_file_ds') AS cross_file,
  tor.Data_Source_Name AS data_source,
  CAST(NULL AS VARCHAR) AS variable_scope,
  CAST(NULL AS VARCHAR) AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM XMLCalcReferences xcr
LEFT JOIN ObjectHomes oh
       ON xcr.Ref_UUID = oh.Object_UUID
LEFT JOIN TableOccurrenceResolution tor
       ON xcr.TO_UUID  = tor.TO_UUID
      AND xcr.File_Name = tor.File_Name
WHERE xcr.Source_UUID  = getvariable('uuid')
  AND (getvariable('file') IS NULL OR xcr.File_Name = getvariable('file'))
  AND xcr.Source_Type  = 'Script'
  AND xcr.Ref_Type     = 'field'
  AND xcr.Source_Subkey IS NOT NULL

UNION ALL

-- (3) CustomFunction-Refs (file-lokal — CF wird per Name+File aus ObjectHomes aufgelöst)
SELECT
  CAST(xcr.Source_Subkey AS INTEGER) AS line_index,
  2 AS source_priority,
  'customFunction' AS type,
  xcr.Ref_Name AS name,
  oh.Object_UUID AS uuid,
  oh.Home_File AS field_file,
  CAST(NULL AS VARCHAR) AS field_basetable,
  CAST(NULL AS VARCHAR) AS to_name,
  FALSE AS cross_file,
  CAST(NULL AS VARCHAR) AS data_source,
  CAST(NULL AS VARCHAR) AS variable_scope,
  CAST(NULL AS VARCHAR) AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM XMLCalcReferences xcr
LEFT JOIN ObjectHomes oh
       ON oh.Object_Name = xcr.Ref_Name
      AND oh.Object_Type = 'CustomFunction'
      AND oh.Home_File   = xcr.File_Name
WHERE xcr.Source_UUID  = getvariable('uuid')
  AND (getvariable('file') IS NULL OR xcr.File_Name = getvariable('file'))
  AND xcr.Source_Type  = 'Script'
  AND xcr.Ref_Type     = 'customfunction'
  AND xcr.Source_Subkey IS NOT NULL

UNION ALL

-- (4) PluginFunction-Refs (extern, kein Heimat-File, kein crossFile)
-- sub_function: bei MBS-Container-Plugin der fachliche Funktionsname.
-- uuid: synthetische ObjectCatalog-UUID für Cross-Navigation
-- (deterministisch via md5), KATALOG-VALIDIERT: der md5-Kandidat wird gegen
-- das ObjectCatalog geprüft und nur ausgeliefert, wenn das Objekt existiert.
-- Container-Aufrufe ohne aufgelösten SubName (dynamisches 1. Argument,
-- `MBS($var; …)`) haben konstruktionsbedingt keinen Katalog-Eintrag — sie
-- blieben sonst als garantiert toter Link („not found") in der Ansicht.
SELECT
  CAST(xcr.Source_Subkey AS INTEGER) AS line_index,
  3 AS source_priority,
  'pluginFunction' AS type,
  xcr.Ref_Name AS name,
  pf.Object_UUID AS uuid,
  CAST(NULL AS VARCHAR) AS field_file,
  CAST(NULL AS VARCHAR) AS field_basetable,
  CAST(NULL AS VARCHAR) AS to_name,
  FALSE AS cross_file,
  CAST(NULL AS VARCHAR) AS data_source,
  CAST(NULL AS VARCHAR) AS variable_scope,
  CAST(NULL AS VARCHAR) AS variable_usage,
  xcr.Ref_SubName AS sub_function
FROM XMLCalcReferences xcr
-- Container-Plugins (MBS): der Katalog-Plugin_Function_Name ist `<Plugin>:<SubName>`
-- (einfacher Doppelpunkt), nicht der bloße Ref_Name `MBS`. Ohne Rekonstruktion zeigte
-- der Link auf eine nicht existierende UUID. Vgl. convert_xml_04_catalog.sql.
LEFT JOIN ObjectCatalog pf
       ON pf.Object_Type = 'PluginFunction'
      AND pf.Object_UUID = md5('PluginFunction::' ||
          CASE WHEN xcr.Ref_SubName IS NOT NULL AND xcr.Ref_SubName <> ''
               THEN xcr.Ref_Name || ':' || xcr.Ref_SubName
               ELSE xcr.Ref_Name END
          || '::' || COALESCE(xcr.Ref_SubName, ''))
WHERE xcr.Source_UUID  = getvariable('uuid')
  AND (getvariable('file') IS NULL OR xcr.File_Name = getvariable('file'))
  AND xcr.Source_Type  = 'Script'
  AND xcr.Ref_Type     = 'pluginfunction'
  AND xcr.Source_Subkey IS NOT NULL

UNION ALL

-- (5) Variable-Lesungen aus Calc-Chunks (immer 'read').
--     Set-Variable-Definitionen kommen über Block 1 (XMLStepReferences mit usage='set').
--     UUID-Berechnung parallel zu Block (1) — Source_Type='Script' garantiert,
--     dass xcr.Source_UUID ein Script_UUID ist (Scope_Anchor für 'local').
SELECT
  CAST(xcr.Source_Subkey AS INTEGER) AS line_index,
  4 AS source_priority,
  'variable' AS type,
  xcr.Ref_Name AS name,
  CASE
    WHEN xcr.Variable_Scope = 'global'
      THEN md5('global::' || xcr.File_Name || '::' || xcr.Ref_Name)
    WHEN xcr.Variable_Scope = 'local'
      THEN md5('local::' || xcr.Source_UUID || '::' || xcr.Ref_Name)
    WHEN xcr.Variable_Scope = 'superglobal'
      THEN md5('superglobal::__global::' || xcr.Ref_Name)
    ELSE CAST(NULL AS VARCHAR)
  END AS uuid,
  xcr.File_Name AS field_file,
  CAST(NULL AS VARCHAR) AS field_basetable,
  CAST(NULL AS VARCHAR) AS to_name,
  FALSE AS cross_file,
  CAST(NULL AS VARCHAR) AS data_source,
  xcr.Variable_Scope AS variable_scope,
  xcr.Usage_Type     AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM XMLCalcReferences xcr
WHERE xcr.Source_UUID  = getvariable('uuid')
  AND (getvariable('file') IS NULL OR xcr.File_Name = getvariable('file'))
  AND xcr.Source_Type  = 'Script'
  AND xcr.Ref_Type     = 'variable'
  AND xcr.Source_Subkey IS NOT NULL

UNION ALL

-- (6) Engine-Funktion-Refs aus DDR_Calculations (Chunks vom Typ FunctionRef).
-- Verbindung: XMLCalcReferences liefert Calc_Hash je Script-Step (Source_Subkey),
-- DDR_Calculations enthält die FunctionRef-Chunks. Wir lesen pro Step die
-- distinct Engine-Funktions-Namen — DISTINCT auf (step_index, name), da
-- dieselbe Funktion mehrmals pro Step vorkommen kann.
-- Anreicherung mit Reference-DB-Daten (function_name_lookup → functions_lang)
-- erfolgt im Controller via referenceService.enrichFunctionTokens.
-- Der Chunk-ROHTEXT ist entity-kodiert (`AnzahlGefundeneDatens&#xE4;tze` — so
-- serialisiert FileMakers DOM-Pfad nach Chunk_Content). v_builtin_token_lookup
-- führt beide Achsen, kodiert und dekodiert, also wird hier mit dem Rohtext
-- nachgeschlagen und die lesbare Schreibweise (gleiche Sprache, nur dekodiert)
-- aus der View übernommen; ohne Treffer bleibt der Rohtext stehen.
SELECT DISTINCT
  CAST(xcr.Source_Subkey AS INTEGER) AS line_index,
  5 AS source_priority,
  'function' AS type,
  COALESCE(bl.Name_Decoded, fn.token) AS name,
  -- Cross-Navigation: NACHSCHLAGEN statt aus dem Namen rechnen. Die UUID eines
  -- Built-ins ist seit Katalog-Schema 1.32.0 aus dem kanonischen englischen
  -- Referenznamen gebildet, nicht aus dem Token — `md5('BuiltinFunction::' ||
  -- <Token>)` traf bei lokalisierten Formeln (`Seitennummer`) einen Knoten, den
  -- es nicht gibt, und bei Namen mit Umlaut zusätzlich einen, der wegen der
  -- Entity-Kodierung nie existieren konnte. v_builtin_token_lookup kennt jede
  -- Referenzsprache, beide Namensräume, beide Text-Achsen und die
  -- Namens-Fallback-Knoten; ein Token ohne Treffer bleibt über den LEFT JOIN
  -- uuidlos und rendert unverlinkt statt auf 404 zu zeigen.
  bl.Object_UUID AS uuid,
  CAST(NULL AS VARCHAR) AS field_file,
  CAST(NULL AS VARCHAR) AS field_basetable,
  CAST(NULL AS VARCHAR) AS to_name,
  FALSE AS cross_file,
  CAST(NULL AS VARCHAR) AS data_source,
  CAST(NULL AS VARCHAR) AS variable_scope,
  CAST(NULL AS VARCHAR) AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM XMLCalcReferences xcr
JOIN DDR_Calculations dc
  ON dc.Calc_Hash = xcr.Calc_Hash
 AND dc.File_Name = xcr.File_Name
CROSS JOIN LATERAL (
  SELECT regexp_extract(dc.Chunk_Content, '<Chunk[^>]*>(.+?)</Chunk>', 1) AS token
) fn
LEFT JOIN v_builtin_token_lookup bl
  ON bl.Name_Norm = lower(fn.token)
WHERE xcr.Source_UUID  = getvariable('uuid')
  AND (getvariable('file') IS NULL OR xcr.File_Name = getvariable('file'))
  AND xcr.Source_Type  = 'Script'
  AND xcr.Source_Subkey IS NOT NULL
  AND dc.Chunk_Type    = 'FunctionRef'
  -- Boolean-Operatoren sind in der DDR als FunctionRef gelistet, sind aber
  -- keine FileMaker-Funktionen (kein Reference-DB-Eintrag, kein Hilfe-Link).
  -- Wir filtern sie hier raus, damit das Frontend keine Popover-losen
  -- function-Refs anzeigen muss. `xor`/`not` defensiv mit drin.
  AND fn.token NOT IN ('and', 'or', 'not', 'xor')

ORDER BY line_index, source_priority, type, name, sub_function NULLS FIRST;
