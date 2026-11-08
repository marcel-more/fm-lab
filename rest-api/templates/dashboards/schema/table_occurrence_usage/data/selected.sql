-- One row: the selected table occurrence (params to_uuid + to_file) with its class and
-- path facts. Empty without a selection (the detail cards hide then).
SELECT
    c.TO_UUID        AS nav_uuid,
    c.TO_Name        AS to_name,
    c.File_Name      AS file_name,
    c.BT_Name        AS base_table,
    -- Code; the captions are valueLabels in the layout (same codes as usage.sql).
    -- Without DDR info a dead or unused class is unverified (own code).
    CASE
        WHEN c.Usage_Class = 'relationship_bridge' THEN CASE c.Reason WHEN 'cascade_delete' THEN 'bridge_cascade_delete' ELSE 'bridge_path' END
        WHEN c.Low_Confidence AND c.Usage_Class IN ('dead_branch', 'dead_island', 'unused') THEN c.Usage_Class || '_unverified'
        ELSE c.Usage_Class
    END              AS usage_class,
    c.Usage_Ref_Count AS usage_refs,
    c.User_Count     AS users,
    c.Relationship_Count AS relationships,
    c.Used_Branches  AS used_branches,
    c.Anchor_TO_Name AS anchor_to,
    c.Dead_Group_Size AS dead_group_size,
    c.Low_Confidence AS low_confidence,
    (c.Dead_Group_ID IS NOT NULL) AS has_dead_group
FROM v_table_occurrence_class c
WHERE c.TO_UUID = NULLIF(CAST(getvariable('to_uuid') AS VARCHAR), '')
  AND c.File_Name = NULLIF(CAST(getvariable('to_file') AS VARCHAR), '');
