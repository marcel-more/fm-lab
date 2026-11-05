-- Options for the header version select: every plugin release version that
-- appears as a documented introduction version in plugref, descending - only
-- real releases are selectable, and the list grows with the reference stand.
-- The neutral first entry ('' = no check) keeps the dashboard a pure
-- inventory until the user actively picks a version (see manifest params).
SELECT value, label
FROM (
    SELECT '' AS value, chr(8211) || ' no check ' || chr(8211) AS label, 1000000 AS ord
    UNION ALL
    SELECT DISTINCT since_version, since_version, since_version_num
    FROM plugref.plugin_functions
    WHERE since_version IS NOT NULL
)
ORDER BY ord DESC;
