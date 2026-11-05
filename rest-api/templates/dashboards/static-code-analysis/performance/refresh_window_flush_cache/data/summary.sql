-- Hand-maintained COUNT wrapper for rule (refresh_window_flush_cache).
-- Keep filters in sync with data/findings.sql. The flush_kind chips must show
-- their true totals, so the flush_kind filter is deliberately NOT applied.
-- plain_refresh_count is a context KPI: Refresh Window without any flush is
-- cheap and produces no findings — the number only puts the flushes in
-- proportion.
WITH refreshes AS (
    SELECT File_Name, Script_UUID,
           regexp_matches(Step_XML, 'id="256" value="True"') AS flush_join,
           regexp_matches(Step_XML, 'id="512" value="True"') AS flush_external
    FROM StepsForScripts
    WHERE Step_ID = 80 AND Is_Enabled
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT
    COUNT(*) FILTER (WHERE flush_join OR flush_external) AS finding_count,
    'warning' AS severity,
    COUNT(*) FILTER (WHERE flush_join) AS join_count,
    COUNT(*) FILTER (WHERE flush_external) AS external_count,
    COUNT(*) FILTER (WHERE NOT (flush_join OR flush_external)) AS plain_refresh_count,
    COUNT(DISTINCT Script_UUID) FILTER (WHERE flush_join OR flush_external) AS affected_scripts,
    COUNT(DISTINCT File_Name) FILTER (WHERE flush_join OR flush_external) AS affected_files
FROM refreshes;
