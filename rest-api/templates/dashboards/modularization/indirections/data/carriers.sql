-- @template_type: report
-- @description: Top 20 carriers (scripts, custom functions, fields, layout objects) with the most indirect references in the current lens, grouped by type and name across files — a script embedded in every file (a developer tool, a module copy) is one row with its file count. For a custom function, cf_callers sums the objects that call it — an indirection there acts at every caller.
-- @params: file, scope_uuids, disabled (hide|include, default hide), kind (default all), resolution (default all), mechanism (optional)
WITH
--#include shared/sites.sql
cur AS (
    SELECT * FROM lens WHERE in_kind AND in_resolution AND in_mechanism
),
per_object AS (
    SELECT c.nav_uuid, c.file_name, c.carrier_type, c.carrier_name, count(*) AS sites,
           list(DISTINCT c.mechanism_label ORDER BY c.mechanism_label) AS mechanisms
    FROM cur c
    GROUP BY c.nav_uuid, c.file_name, c.carrier_type, c.carrier_name
)
SELECT
    p.carrier_type,
    p.carrier_name,
    sum(p.sites)                                                       AS sites,
    count(*)                                                           AS objects,
    count(DISTINCT p.file_name)                                        AS files,
    any_value(p.nav_uuid)                                              AS nav_uuid,
    array_to_string(list_sort(list_distinct(flatten(list(p.mechanisms)))), ' · ') AS mechanisms,
    sum(u.Usage_Owners) FILTER (WHERE p.carrier_type = 'CustomFunction') AS cf_callers
FROM per_object p
LEFT JOIN v_object_usage u
  ON p.carrier_type = 'CustomFunction'
 AND u.Object_UUID = p.nav_uuid AND u.File_Name = p.file_name AND u.Object_Type = 'CustomFunction'
GROUP BY p.carrier_type, p.carrier_name
ORDER BY sites DESC, p.carrier_name
LIMIT 20;
