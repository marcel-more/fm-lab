-- @template_type: report
-- @description: One row per mechanism of the current lens (target type × resolution; the mechanism filter itself is not applied, so the list stays the menu of all mechanisms). Feeds the mechanism table and the mechanism select.
-- @params: file, scope_uuids, disabled (hide|include, default hide), kind (default all), resolution (default all)
WITH
--#include shared/sites.sql
cur AS (
    SELECT * FROM lens WHERE in_kind AND in_resolution
)
SELECT
    c.mechanism_id,
    any_value(c.mechanism_label)                                           AS mechanism_label,
    any_value(c.kind)                                                      AS kind,
    count(*)                                                               AS sites,
    count(DISTINCT c.file_name)                                            AS files,
    count(DISTINCT (c.nav_uuid, c.file_name))                              AS carriers,
    count(*) FILTER (WHERE c.resolution_class = 'dynamic')                 AS dynamic,
    count(*) FILTER (WHERE c.resolution_class = 'literal_resolved')        AS literal_resolved,
    count(*) FILTER (WHERE c.resolution_class = 'literal_unresolved')      AS literal_unresolved
FROM cur c
GROUP BY c.mechanism_id
ORDER BY sites DESC, c.mechanism_id;
