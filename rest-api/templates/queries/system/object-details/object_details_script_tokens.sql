-- @template_type: report
-- @description: Script steps with indent, kind classification, and references for token-based output
-- @params: uuid (required)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.2
-- @tags: scripts, script-steps, ddr, tokens

WITH step_changes AS (
  SELECT
    s.Step_Index,
    s.Step_ID,
    s.Step_Name,
    s.Is_Enabled,
    s.Parameter_Type,
    s.Step_UUID,
    s.File_Name,
    -- Eingefügter Literaltext (nur "Insert Text"): der DDR-Step_Text lässt den
    -- <Parameter type="Text"><Text value="…">-Payload weg. Bereits in P2 (resolve)
    -- per xml_extract_text DEKODIERT in die Hilfsspalte StepsForScripts.Inserted_Text
    -- aufgelöst — hier nur durchgereicht, keine XML-/Entity-Behandlung im Server
    -- (der READ_ONLY-API-Server kann webbed nicht laden). Der tokens.formatter
    -- normalisiert/kürzt nur noch für die Anzeige.
    s.Inserted_Text AS inserted_text,
    -- Kommentartext (nur Step_ID 89): DDR-unabhängig in P3 vorberechnet
    -- (StepsForScripts.Comment_Text, aus <Comment value="…"/> bzw. <Comment>…</Comment>).
    -- Fallback für Dateien ohne DDR-Info, deren Kommentare sonst als leere
    -- Zeilen erschienen; bei vorhandenem DDR gewinnt unten weiter d.Step_Text.
    s.Comment_Text AS comment_text,
    -- Fallback-Payloads für Steps OHNE DDR-Text (Dateien ohne DDR-Info): bereits
    -- in P1 materialisierte Step-Bestandteile, aus denen der tokens.formatter eine
    -- Klartext-Näherung komponiert (Step-Name [ $Var ; Refs ; Flag ; Calc ]).
    -- Bei vorhandenem DDR bleiben sie ungenutzt (d.Step_Text gewinnt).
    s.Calculation_Text AS calculation_text,
    s.Variable_Name AS variable_name,
    s.Boolean_Type AS boolean_type,
    s.Boolean_Value AS boolean_value,
    -- Find-/Sort-Payload (Perform Find 28, Enter Find Mode 22, Constrain 126,
    -- Extend 127, Sort Records 39): Suchkriterien (<find criteria="…"> je
    -- FieldReference) und Sortierkriterien (<Sort type="…"> + optionale
    -- ValueListReference) stehen NUR im Step_XML — weder DDR-Step_Text-Fallback
    -- noch die aufgelösten Step-Refs tragen sie. Der tokens.formatter parst die
    -- Struktur und hängt sie als Klammer-Segmente an die Zeile.
    CASE WHEN s.Step_ID IN (22, 28, 39, 126, 127) THEN s.Step_XML END AS step_xml,
    CASE
      WHEN s.Step_Name IN ('If', 'Loop') THEN 1
      WHEN s.Step_Name IN ('End If', 'End Loop') THEN -1
      ELSE 0
    END AS depth_change_after,
    CASE
      WHEN s.Step_Name IN ('Else', 'Else If', 'End If', 'End Loop') THEN -1
      ELSE 0
    END AS depth_change_self
  FROM StepsForScripts s
  -- Klon-Disambiguierung: ohne File-Filter matcht eine geteilte Script_UUID die
  -- Schritte ALLER Klon-Dateien → jede Zeile erschiene mehrfach.
  WHERE s.Script_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
step_depths AS (
  SELECT
    *,
    GREATEST(0,
      COALESCE(SUM(depth_change_after) OVER (
        PARTITION BY File_Name
        ORDER BY Step_Index
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0)
    ) + depth_change_self AS indent_level
  FROM step_changes
)
SELECT
  sd.Step_Index AS line_index,
  CAST(GREATEST(0, sd.indent_level) AS INTEGER) AS indent,
  sd.Step_ID AS step_id,
  sd.Step_UUID AS step_uuid,
  -- Synthetischer ScriptStepType-UUID
  -- für Cross-Navigation vom Step-Namen zur Pseudo-Objekt-Detailseite.
  md5('ScriptStepType::' || sd.Step_Name) AS step_type_uuid,
  sd.Step_Name AS step_name,
  sd.Is_Enabled AS enabled,
  sd.Parameter_Type AS parameter_type,
  -- FileMaker's script editor renders these keywords without the bare "[  ]"
  -- suffix that the DDR export still produces. Strip it here so all consumers
  -- (token clients, plain-text renderers, future ones) see the canonical form.
  CASE
    WHEN sd.Step_Name IN ('Else','End If','End Loop',
                          'Commit Transaction','Revert Transaction','Open Transaction')
         AND d.Step_Text IS NOT NULL
    THEN regexp_replace(d.Step_Text, '\s*\[\s*\]\s*$', '')
    -- Kommentare DDR-unabhängig: ohne DDR-Zeile (Has_DDR_INFO=False) liefert die
    -- P3-Hilfsspalte den Text; mit DDR bleibt d.Step_Text maßgeblich (Regression 0).
    WHEN sd.Step_ID = 89 THEN COALESCE(d.Step_Text, sd.comment_text)
    ELSE d.Step_Text
  END AS step_text,
  sd.inserted_text AS inserted_text,
  sd.calculation_text AS calculation_text,
  sd.variable_name AS variable_name,
  sd.boolean_type AS boolean_type,
  sd.boolean_value AS boolean_value,
  sd.step_xml AS step_xml,
  -- has_ddr: unterscheidet im Formatter "DDR-Zeile fehlt für diesen Step" von
  -- "Datei hat gar kein DDR" — die Fallback-Komposition greift nur ohne DDR-Text.
  (d.Step_UUID IS NOT NULL) AS has_ddr,
  CASE
    WHEN sd.Step_ID = 89 AND COALESCE(d.Step_Text, sd.comment_text) IS NULL THEN 'empty'
    WHEN sd.Step_ID = 89                                                     THEN 'comment'
    ELSE 'step'
  END AS kind
FROM step_depths sd
-- Step_UUIDs sind ebenfalls geklont → DDR-Join auf die gleiche Datei skopieren,
-- sonst multipliziert der LEFT JOIN die Zeilen erneut.
LEFT JOIN DDR_ScriptSteps d ON sd.Step_UUID = d.Step_UUID AND sd.File_Name = d.File_Name
ORDER BY sd.File_Name, sd.Step_Index;
