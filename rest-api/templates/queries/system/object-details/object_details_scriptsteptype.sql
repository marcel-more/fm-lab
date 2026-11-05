-- @template_type: content
-- @description: Detail view of an aggregated ScriptStep type — all callers across scripts and buttons
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.1
-- @tags: scriptsteptype, details, aggregate
-- @note: Synthetic ObjectCatalog entry — Object_Name = 'Set Variable', 'Go to Layout', etc.
--        Aggregates step instances from StepsForScripts AND LayoutObjectSteps
--        (button-embedded steps) — no ObjectLinks-Spiegelung.

WITH self AS (
  SELECT Object_UUID, Object_Type, Object_Name, Source_Table
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('uuid')
    AND Object_Type = 'ScriptStepType'
  LIMIT 1
),
-- Aufrufer-Instanzen aus beiden Step-Trägern. Buttons haben keinen Step_Index
-- (genau ein Step pro Objekt) → 0 als stabiler Sortier-Anker.
instances AS (
  SELECT
    s.Script_UUID AS Caller_UUID,
    s.Script_Name AS Caller_Name,
    'Script'      AS Caller_Type,
    s.File_Name,
    s.Step_Index
  FROM StepsForScripts s
  JOIN self t ON s.Step_Name = t.Object_Name

  UNION ALL

  SELECT
    los.Object_UUID AS Caller_UUID,
    COALESCE(oc.Object_Name, 'Button') AS Caller_Name,
    'Button'        AS Caller_Type,
    los.File_Name,
    0               AS Step_Index
  FROM LayoutObjectSteps los
  JOIN self t ON los.Step_Name = t.Object_Name
  LEFT JOIN ObjectCatalog oc
    ON oc.Object_UUID = los.Object_UUID
   AND oc.File_Name   = los.File_Name
),
caller_summary AS (
  SELECT
    Caller_UUID AS Script_UUID,
    Caller_Name AS Script_Name,
    Caller_Type,
    File_Name,
    COUNT(*) as Step_Count,
    MIN(Step_Index) as First_Index
  FROM instances
  GROUP BY Caller_UUID, Caller_Name, Caller_Type, File_Name
),
total_count AS (
  SELECT COUNT(*) as total FROM instances
)

SELECT content FROM (
  -- Header
  SELECT 1 as sort_key, 0 as sub_key,
    '=== ScriptStep Type Details ===' as content
  FROM self

  UNION ALL
  SELECT 2, 0, '' FROM self

  UNION ALL

  -- Properties
  SELECT 3, 1, 'Step Name:    ' || s.Object_Name FROM self s
  UNION ALL
  SELECT 3, 2, 'Type:         ScriptStepType' FROM self
  UNION ALL
  SELECT 3, 3, 'Scope:        Solution-wide (lösungs-unabhängig)' FROM self
  UNION ALL
  SELECT 3, 4, 'Total Usages: ' || CAST((SELECT total FROM total_count) AS VARCHAR) FROM self

  UNION ALL

  -- Usage Summary
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM caller_summary) > 0
  UNION ALL
  SELECT 5, 1,
    '--- Usage Summary --- ('
    || CAST((SELECT COUNT(*) FROM caller_summary WHERE Caller_Type = 'Script') AS VARCHAR)
    || ' scripts, '
    || CAST((SELECT COUNT(*) FROM caller_summary WHERE Caller_Type = 'Button') AS VARCHAR)
    || ' buttons, '
    || CAST((SELECT total FROM total_count) AS VARCHAR)
    || ' total steps)'
  WHERE (SELECT COUNT(*) FROM caller_summary) > 0

  UNION ALL

  -- Detailed caller list (scripts and button-embedded steps)
  SELECT 8, 0, '' WHERE (SELECT COUNT(*) FROM caller_summary) > 0
  UNION ALL
  SELECT 8, 1, '--- Callers ---'
  WHERE (SELECT COUNT(*) FROM caller_summary) > 0
  UNION ALL
  SELECT 9, ROW_NUMBER() OVER (ORDER BY Caller_Type, Step_Count DESC, Script_Name),
    '  <- ' || Caller_Type || ': ' || Script_Name
    || ' [' || File_Name || ']'
    || ' (' || CAST(Step_Count AS VARCHAR) || ' step'
    || CASE WHEN Step_Count > 1 THEN 's' ELSE '' END
    || ')'
  FROM caller_summary
) details
ORDER BY sort_key, sub_key;
