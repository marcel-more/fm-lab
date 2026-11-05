-- @template_type: content
-- @description: Display FileMaker script steps with automatic indentation for nested control structures
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: content
-- @author: Marcel
-- @version: 3.1
-- @tags: scripts, script-steps, ddr, formatting
-- @note: Use generic parameters: uuid, name, file (consistent with REST API)
-- @note: Returns pre-formatted text with line numbers and indentation
-- @note: Every UUID join is File_Name-scoped — clone suites share Script/Step UUIDs across files

WITH step_changes AS (
  SELECT
    s.File_Name,
    s.Step_Index,
    s.Step_Name,
    s.Step_UUID,
    -- Calculate depth change for the NEXT step
    CASE
      WHEN s.Step_Name IN ('If', 'Loop') THEN 1
      WHEN s.Step_Name IN ('End If', 'End Loop') THEN -1
      ELSE 0
    END AS depth_change_after,
    -- Calculate depth change for the CURRENT step
    CASE
      WHEN s.Step_Name IN ('Else', 'Else If', 'End If', 'End Loop') THEN -1
      ELSE 0
    END AS depth_change_self
  FROM StepsForScripts s
  JOIN ScriptCatalog sc ON s.Script_UUID = sc.Script_UUID AND s.File_Name = sc.File_Name
  WHERE (
    -- Match by UUID (preferred)
    (getvariable('uuid') IS NOT NULL AND sc.Script_UUID = getvariable('uuid')
     AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file')))
    OR
    -- Match by Name (with optional file filter)
    (getvariable('name') IS NOT NULL AND sc.Script_Name = getvariable('name')
     AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file')))
    OR
    -- Match by ID (legacy, numeric)
    (getvariable('id') IS NOT NULL AND sc.Script_ID = CAST(getvariable('id') AS INTEGER))
  )
),
step_depths AS (
  SELECT
    File_Name,
    Step_Index,
    Step_Name,
    Step_UUID,
    -- Calculate the indentation depth for subsequent steps
    GREATEST(0,
      COALESCE(SUM(depth_change_after) OVER (
        PARTITION BY File_Name ORDER BY Step_Index
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0)
    ) AS base_depth,
    depth_change_self
  FROM step_changes
)
SELECT
  -- Formatted output with line number and indentation as 'content' column
  printf('%2d. %s%s',
    Step_Index + 1,
    repeat('  ', CAST(GREATEST(0, base_depth + depth_change_self) AS BIGINT)),
    CASE
      WHEN (SELECT Has_DDR_INFO FROM XMLMetadata x WHERE x.File_Name = sd.File_Name LIMIT 1) = 'True'
      THEN COALESCE(
        -- FileMaker's script editor renders these keywords without the bare
        -- "[  ]" suffix that the DDR export still produces. Strip it so the
        -- rendered text matches what developers see in FileMaker itself.
        CASE
          WHEN sd.Step_Name IN ('Else','End If','End Loop',
                                'Commit Transaction','Revert Transaction','Open Transaction')
               AND d.Step_Text IS NOT NULL
          THEN regexp_replace(d.Step_Text, '\s*\[\s*\]\s*$', '')
          ELSE d.Step_Text
        END,
        sd.Step_Name
      )
      ELSE sd.Step_Name
    END
  ) as content
FROM step_depths sd
LEFT JOIN DDR_ScriptSteps d ON sd.Step_UUID = d.Step_UUID AND sd.File_Name = d.File_Name
ORDER BY sd.File_Name, Step_Index;
