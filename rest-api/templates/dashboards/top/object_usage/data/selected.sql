-- One row: the selected object (params obj_uuid + obj_file) with its counts and
-- markers. Empty without a selection (the detail cards hide then).
SELECT
    u.Object_UUID   AS nav_uuid,
    u.Object_Type   AS object_type,
    u.Object_Name   AS object_name,
    u.File_Name     AS file_name,
    -- Same codes as usage.sql, without the rare/heavy view classes.
    CASE
        WHEN u.Usage_Class = 'relationship_bridge' THEN 'bridge'
        WHEN u.Low_Confidence AND u.Usage_Class IN ('unused', 'dead_branch', 'dead_island') THEN u.Usage_Class || '_unverified'
        ELSE u.Usage_Class
    END             AS usage_class,
    u.Usage_Owners  AS usage,
    u.Usage_Refs    AS refs,
    u.Usage_Files   AS files,
    array_to_string(u.Usage_Roles, ', ') AS roles,
    CASE WHEN u.Entry_Point    THEN TRUE END AS in_menu,
    CASE WHEN u.Key_Field      THEN TRUE END AS key_field,
    CASE WHEN u.Cross_File     THEN TRUE END AS cross_file,
    u.Low_Confidence AS low_confidence,
    u.Object_Type = 'TableOccurrence' AS is_to,
    u.Object_Type = 'Relationship'    AS is_relationship
FROM v_object_usage u
WHERE u.Object_UUID = NULLIF(CAST(getvariable('obj_uuid') AS VARCHAR), '')
  AND u.File_Name = NULLIF(CAST(getvariable('obj_file') AS VARCHAR), '');
