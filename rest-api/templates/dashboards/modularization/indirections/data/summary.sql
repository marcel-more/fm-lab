-- @template_type: report
-- @description: One row — totals and the counts of both chip bars. The target-type counts honour the chosen resolution and the resolution counts the chosen target type (cross-filtered facets); the mechanism filter narrows all counts.
-- @params: file, scope_uuids, disabled (hide|include, default hide), kind (default all), resolution (default all)
WITH
--#include shared/sites.sql
cur AS (
    SELECT * FROM lens WHERE in_kind AND in_resolution AND in_mechanism
)
SELECT
    (SELECT count(*) FROM cur)                                       AS total,
    (SELECT count(DISTINCT file_name) FROM cur)                      AS files,
    (SELECT count(DISTINCT (nav_uuid, file_name)) FROM cur)          AS carriers,
    (SELECT count(*) FROM cur WHERE guarded)                         AS guarded,
    -- target-type chips (under the resolution filter)
    count(*) FILTER (WHERE in_resolution AND kind NOT IN ('introspection', 'window')) AS k_all,
    count(*) FILTER (WHERE in_resolution AND kind = 'script')         AS k_script,
    count(*) FILTER (WHERE in_resolution AND kind = 'layout')         AS k_layout,
    count(*) FILTER (WHERE in_resolution AND kind = 'field')          AS k_field,
    count(*) FILTER (WHERE in_resolution AND kind = 'table')          AS k_table,
    count(*) FILTER (WHERE in_resolution AND kind = 'sql')            AS k_sql,
    count(*) FILTER (WHERE in_resolution AND kind = 'layout_object')  AS k_layout_object,
    count(*) FILTER (WHERE in_resolution AND kind = 'value_list')     AS k_value_list,
    count(*) FILTER (WHERE in_resolution AND kind = 'formula')        AS k_formula,
    count(*) FILTER (WHERE in_resolution AND kind = 'introspection')  AS k_introspection,
    count(*) FILTER (WHERE in_resolution AND kind = 'window')         AS k_window,
    -- resolution chips (under the target-type filter)
    count(*) FILTER (WHERE in_kind)                                   AS r_all,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'dynamic')            AS r_dynamic,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'literal_resolved')   AS r_literal_resolved,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'literal_unresolved') AS r_literal_unresolved,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'literal_external')   AS r_literal_external,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'literal_other_file') AS r_literal_other_file,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'empty')              AS r_empty,
    count(*) FILTER (WHERE in_kind AND resolution_class = 'no_target')          AS r_no_target
FROM lens
WHERE in_mechanism;
