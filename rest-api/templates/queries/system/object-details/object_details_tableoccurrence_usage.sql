-- @template_type: report
-- @description: Usage profile of a TableOccurrence for its detail view — usage class (v_table_occurrence_class) and usage counts per category (v_table_occurrence_usage)
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: table-occurrence, usage, where-used, unused-code
-- @note: Companion of object_details_tableoccurrence — the service appends these rows only when
--        both analysis tables exist (schema >= 1.38.0), so the main template stays valid on older
--        catalogs. Flat rows with a `section` discriminator:
--          'usage_class' → one row: Usage_Class, Reason, counts, dead group + anchor, Low_Confidence.
--          'usage'       → one row per category: distinct users, summed Ref_Count, plus the
--                          edge roles (`edge_roles`) and whether edgeless usages exist
--                          (`has_non_edge`) — the client builds the references-tab filter from them.

WITH u AS (
  SELECT *
  FROM v_table_occurrence_usage
  WHERE TO_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
)

SELECT * EXCLUDE (order_hint) FROM (
  SELECT
    'usage_class' AS section,
    0 AS order_hint,
    c.Usage_Class AS usage_class,
    c.Reason AS usage_reason,
    CAST(c.Usage_Ref_Count AS BIGINT) AS usage_ref_count,
    c.User_Count AS user_count,
    CAST(c.Relationship_Count AS BIGINT) AS class_relationship_count,
    c.Dead_Group_Size AS dead_group_size,
    c.Anchor_TO_UUID AS anchor_to_uuid,
    c.Anchor_TO_Name AS anchor_to_name,
    c.Low_Confidence AS low_confidence,
    CAST(NULL AS VARCHAR) AS category,
    CAST(NULL AS BIGINT) AS users,
    CAST(NULL AS BIGINT) AS refs,
    CAST(NULL AS VARCHAR[]) AS edge_roles,
    CAST(NULL AS BOOLEAN) AS has_non_edge
  FROM v_table_occurrence_class c
  WHERE c.TO_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))

  UNION ALL

  SELECT
    'usage', 1,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    u.Category,
    COUNT(DISTINCT u.User_UUID),
    CAST(SUM(u.Ref_Count) AS BIGINT),
    list_sort(list_distinct(list(u.Role) FILTER (WHERE u.Is_Edge))),
    bool_or(NOT u.Is_Edge)
  FROM u
  GROUP BY u.Category
)
ORDER BY order_hint, refs DESC NULLS LAST, category;
