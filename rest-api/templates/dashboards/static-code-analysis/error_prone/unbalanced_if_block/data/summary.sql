-- Hand-maintained COUNT wrapper embedding the findings core of rule (unbalanced_if_block).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'error'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
-- Only enabled steps execute: a disabled If or End If left over from editing
-- does not change the nesting FileMaker runs, so the balance and the running
-- depth are computed over the enabled steps alone (v_script_block_tree itself
-- counts every step — its depths drive the indentation of the script view).
WITH active AS (
    SELECT File_Name, Script_ID, Script_UUID, Script_Name,
        CASE WHEN Is_Enabled IS NOT FALSE THEN if_delta ELSE 0 END AS active_if_delta,
        SUM(CASE WHEN Is_Enabled IS NOT FALSE THEN if_delta ELSE 0 END)
            OVER (PARTITION BY File_Name, Script_ID ORDER BY Step_Index
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS active_running_depth
    FROM v_script_block_tree
),
bal AS (
    SELECT File_Name, Script_ID,
        MIN(Script_UUID) AS Script_UUID, MIN(Script_Name) AS Script_Name,
        CAST(SUM(active_if_delta) AS INTEGER) AS net_if_balance,
        CAST(MIN(active_running_depth) AS INTEGER) AS worst_running_depth
    FROM active GROUP BY File_Name, Script_ID
)
SELECT 'unbalanced-if-block' AS rule_id, 'error' AS severity,
    File_Name AS file_name, Script_UUID AS nav_uuid, Script_Name AS script_name,
    'If/End-If imbalance (' || net_if_balance || ') — structurally broken block nesting' AS message,
    row_number() OVER (ORDER BY File_Name, Script_Name) AS row_key
FROM bal
WHERE (net_if_balance <> 0 OR worst_running_depth < 0) AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY File_Name, Script_Name
) _summary;
