-- Hand-maintained aggregate over the same core as data/findings.sql - keep
-- the CTEs and scope filters in sync. The default result counts SCRIPTS
-- (unit "scripts"); the per-OS columns feed the consolidated OS matrix of the
-- platform-os-binding set (a desktop-only script counts for macOS AND
-- Windows).
WITH aff AS (
    SELECT step_id,
           bool_or(affinity = 'exclusive')   AS has_exclusive,
           bool_or(affinity = 'unsupported') AS has_unsupported,
           bool_or(affinity = 'exclusive' AND os = 'macos')   AS excl_macos,
           bool_or(affinity = 'exclusive' AND os = 'windows') AS excl_windows,
           bool_or(affinity = 'exclusive' AND os = 'linux')   AS excl_linux,
           bool_or(affinity = 'exclusive' AND os = 'ios')     AS excl_ios,
           bool_or(affinity = 'unsupported' AND os = 'macos')   AS unsup_macos,
           bool_or(affinity = 'unsupported' AND os = 'windows') AS unsup_windows,
           bool_or(affinity = 'unsupported' AND os = 'linux')   AS unsup_linux,
           bool_or(affinity = 'unsupported' AND os = 'ios')     AS unsup_ios,
           bool_or(affinity = 'variant' AND os = 'macos')   AS var_macos,
           bool_or(affinity = 'variant' AND os = 'windows') AS var_windows,
           bool_or(affinity = 'variant' AND os = 'linux')   AS var_linux,
           bool_or(affinity = 'variant' AND os = 'ios')     AS var_ios
    FROM ref.step_os_affinity
    GROUP BY step_id
),
hostf AS (
    SELECT c.step_id,
           bool_or(m.os = 'macos')   AS host_macos,
           bool_or(m.os = 'windows') AS host_windows,
           bool_or(m.os = 'linux')   AS host_linux,
           bool_or(m.os = 'ios')     AS host_ios
    FROM ref.step_compat c
    JOIN ref.runtime_os_matrix m ON m.supported
     AND m.fm_env IN ('pro', 'server', 'go', 'webdirect', 'cloud', 'dataapi', 'cwp')
     AND CASE m.fm_env
           WHEN 'pro' THEN c.pro WHEN 'server' THEN c.server WHEN 'go' THEN c.go
           WHEN 'webdirect' THEN c.webdirect WHEN 'cloud' THEN c.cloud
           WHEN 'dataapi' THEN c.dataapi WHEN 'cwp' THEN c.cwp
         END IS DISTINCT FROM false
    GROUP BY c.step_id
),
effective AS (
    SELECT a.step_id,
        CASE WHEN a.has_exclusive THEN a.excl_macos
             WHEN a.has_unsupported THEN COALESCE(h.host_macos, false) AND NOT a.unsup_macos
             ELSE a.var_macos END AS macos,
        CASE WHEN a.has_exclusive THEN a.excl_windows
             WHEN a.has_unsupported THEN COALESCE(h.host_windows, false) AND NOT a.unsup_windows
             ELSE a.var_windows END AS windows,
        CASE WHEN a.has_exclusive THEN a.excl_linux
             WHEN a.has_unsupported THEN COALESCE(h.host_linux, false) AND NOT a.unsup_linux
             ELSE a.var_linux END AS linux,
        CASE WHEN a.has_exclusive THEN a.excl_ios
             WHEN a.has_unsupported THEN COALESCE(h.host_ios, false) AND NOT a.unsup_ios
             ELSE a.var_ios END AS ios
    FROM aff a
    LEFT JOIN hostf h USING (step_id)
    WHERE a.has_exclusive OR a.has_unsupported OR a.step_id = 57
),
core AS (
    SELECT s.File_Name AS file_name, s.Script_UUID AS nav_uuid, s.Step_ID AS step_id,
           e.macos, e.windows, e.linux, e.ios
    FROM StepsForScripts s
    JOIN effective e ON e.step_id = s.Step_ID
    WHERE s.Is_Enabled
)
-- Per-OS counts apply the OS-SPECIFIC rule (shared with the OS matrix and
-- the profile tile): only bindings confined to at most TWO operating systems
-- mark a script as bound to an OS.
SELECT
    COUNT(DISTINCT nav_uuid) AS script_count,
    COUNT(*) AS finding_count,
    COUNT(DISTINCT step_id) AS distinct_steps,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE macos AND os_specific)   AS os_macos_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE windows AND os_specific) AS os_windows_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE linux AND os_specific)   AS os_linux_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE ios AND os_specific)     AS os_ios_scripts,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
    SELECT *,
        (CAST(macos AS INT) + CAST(windows AS INT)
         + CAST(linux AS INT) + CAST(ios AS INT)) <= 2 AS os_specific
    FROM core
)
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
