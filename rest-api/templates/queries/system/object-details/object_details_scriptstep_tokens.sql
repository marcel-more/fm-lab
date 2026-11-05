-- @template_type: report
-- @description: Single script step as a 1-line tokens payload (analog to object_details_script_tokens.sql, filtered to one Step_UUID)
-- @params: uuid (required) — Step_UUID
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.0
-- @tags: scripts, script-steps, ddr, tokens

-- Liefert genau eine Zeile pro Aufruf: den ScriptStep mit dem übergebenen UUID,
-- gerendert als 1-Zeilen-Counterpart zu object_details_script_tokens.sql. Die
-- Spalten line_index/indent sind hartkodiert auf 0, damit der ScriptViewer den
-- Step ohne Kontext (keine Nachbar-Steps, kein Indent-Tree) rendert.
--
-- Zusätzliche Spalten am Ende liefern den Parent-Script-Kontext (UUID, Name,
-- Datei, Original-Step-Index) — wird vom Controller in object.parentScript
-- abgelegt, damit der Detail-Header eine Karte mit Sprung-Link zum Skript
-- anzeigen kann.

SELECT
  0 AS line_index,
  0 AS indent,
  s.Step_ID    AS step_id,
  s.Step_UUID  AS step_uuid,
  -- Synthetischer ScriptStepType-UUID
  md5('ScriptStepType::' || s.Step_Name) AS step_type_uuid,
  s.Step_Name  AS step_name,
  s.Is_Enabled AS enabled,
  s.Parameter_Type AS parameter_type,
  -- FileMaker rendert Else/End-If/End-Loop ohne leeres "[  ]" — Konsistenz mit
  -- dem mehrzeiligen Script-Tokens-Template.
  CASE
    WHEN s.Step_Name IN ('Else','End If','End Loop',
                         'Commit Transaction','Revert Transaction','Open Transaction')
         AND d.Step_Text IS NOT NULL
    THEN regexp_replace(d.Step_Text, '\s*\[\s*\]\s*$', '')
    ELSE d.Step_Text
  END AS step_text,
  CASE
    WHEN s.Step_ID = 89 AND d.Step_Text IS NULL THEN 'empty'
    WHEN s.Step_ID = 89                          THEN 'comment'
    ELSE 'step'
  END AS kind,
  -- Find-/Sort-Payload (Perform Find 28, Enter Find Mode 22, Constrain 126,
  -- Extend 127, Sort Records 39): Such-/Sortierkriterien stehen nur im Step_XML
  -- — Konsistenz mit dem mehrzeiligen Script-Tokens-Template (der
  -- tokens.formatter hängt sie an).
  CASE WHEN s.Step_ID IN (22, 28, 39, 126, 127) THEN s.Step_XML END AS step_xml,
  -- Parent-Script-Kontext (vom Controller in object.parentScript gepackt)
  s.Script_UUID AS parent_script_uuid,
  s.Script_Name AS parent_script_name,
  s.Step_Index  AS parent_step_index,
  s.File_Name   AS parent_file_name
FROM StepsForScripts s
-- Klon-Disambiguierung: Step_UUIDs sind geklont → DDR-Join auf dieselbe Datei
-- skopieren, sonst multipliziert der LEFT JOIN die Zeile.
LEFT JOIN DDR_ScriptSteps d ON s.Step_UUID = d.Step_UUID AND s.File_Name = d.File_Name
WHERE s.Step_UUID = getvariable('uuid')
  -- ohne File-Filter matcht eine geteilte Step_UUID alle Klon-Dateien
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'));
