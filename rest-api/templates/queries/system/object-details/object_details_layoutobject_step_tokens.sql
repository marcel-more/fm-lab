-- @template_type: report
-- @description: Button-eingebetteter Script-Step eines LayoutObjects als 1-Zeilen-Tokens-Payload (analog object_details_scriptstep_tokens.sql)
-- @params: uuid (required) — Object_UUID des Button-LayoutObjects; file (optional) — Klon-Disambiguierung
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.0
-- @tags: layout-objects, buttons, script-steps, ddr, tokens

-- Liefert 0 oder 1 Zeile: den button-eingebetteten Step (Grouped Button / Button)
-- als 1-Zeilen-Counterpart zu object_details_scriptstep_tokens.sql. line_index/indent
-- hartkodiert auf 0. Nicht-Button-Objekte liefern 0 Zeilen → das Frontend rendert
-- keine Step-Sektion.
--
-- Der Klartext kommt aus DDR_ScriptSteps über den DDRREF-StepText-Hash. Da der
-- Konverter UUID-lose StepText-Records per 'hash:'||Step_Hash keyt (sonst kollabieren
-- sie auf den leeren PK), kann derselbe Hash mit BEIDEN Schlüsseln auftauchen (ein
-- echter Script-Step gleichen Textes + der button-eingebettete). Darum die
-- DDR-Seite pro (File_Name, Step_Hash) deduplizieren, sonst multipliziert der JOIN
-- die Zeile.

SELECT
  0 AS line_index,
  0 AS indent,
  los.Step_ID AS step_id,
  -- Kein echter Step-UUID (button-eingebettete Steps haben <UUID/>): Träger-Objekt
  -- als stabile Identität.
  los.Object_UUID AS step_uuid,
  md5('ScriptStepType::' || los.Step_Name) AS step_type_uuid,
  los.Step_Name AS step_name,
  los.Step_Enabled AS enabled,
  CAST(NULL AS VARCHAR) AS parameter_type,
  CASE
    WHEN los.Step_ID = 89 AND d.Step_Text IS NULL THEN 'empty'
    WHEN los.Step_ID = 89                          THEN 'comment'
    ELSE 'step'
  END AS kind,
  -- Else/End-If/End-Loop rendert FileMaker ohne leeres "[  ]" (Konsistenz mit den
  -- Script-Tokens-Templates); für Buttons praktisch irrelevant, aber symmetrisch.
  CASE
    WHEN los.Step_Name IN ('Else','End If','End Loop',
                           'Commit Transaction','Revert Transaction','Open Transaction')
         AND d.Step_Text IS NOT NULL
    THEN regexp_replace(d.Step_Text, '\s*\[\s*\]\s*$', '')
    ELSE d.Step_Text
  END AS step_text
FROM LayoutObjectSteps los
LEFT JOIN (
    SELECT File_Name, Step_Hash, any_value(Step_Text) AS Step_Text
    FROM DDR_ScriptSteps
    GROUP BY File_Name, Step_Hash
) d ON d.Step_Hash = los.StepText_Hash AND d.File_Name = los.File_Name
WHERE los.Object_UUID = getvariable('uuid')
  AND (getvariable('file') IS NULL OR los.File_Name = getvariable('file'));
