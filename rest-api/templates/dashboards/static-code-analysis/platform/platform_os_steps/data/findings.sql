-- OS binding via Claris script steps (axis b, OS sub-axis - inventory, not
-- defects). Source: ref.step_os_affinity (fm_spec >= 1.13.0) - a CURATED,
-- SPARSE set distilled from the Claris help prose (there is no structured
-- Claris OS table); absence of a row means "no Claris statement", never
-- "runs everywhere". OS vocabulary is strictly macos|windows|linux|ios
-- ('ios' = the operating system, hosting both FileMaker Go and iOS SDK apps);
-- runtime terms never appear here.
--   exclusive   - the step works only on the listed OS (Perform AppleScript).
--   unsupported - Claris names an OS it does NOT work on (Dial Phone: macOS);
--                 stored source-true inverse and resolved against the HOST OS
--                 of the step's runtimes (step_compat x runtime_os_matrix,
--                 'Partial'/NULL counts as potentially running) - never
--                 against all four OS (Dial Phone => windows+ios, not linux).
--   variant     - runs everywhere with OS-dependent behavior; Tranche 2 stays
--                 out of the findings (fm-spec badge only) EXCEPT step 57
--                 Send Event: one step id with two OS-exclusive option sets
--                 (a macOS configuration does nothing useful on Windows and
--                 vice versa) - the single variant with a findings row.
-- Severity is always 'info': findings are neutral properties (v5 convention),
-- never defects; nothing here colours a traffic light.
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
           bool_or(affinity = 'variant' AND os = 'ios')     AS var_ios,
           string_agg(os, ', ' ORDER BY os) FILTER (WHERE affinity = 'unsupported') AS unsup_list
    FROM ref.step_os_affinity
    GROUP BY step_id
),
-- Host base for the unsupported resolution: every OS on which at least one
-- runtime that can run the step exists (hard 'No' excludes the runtime,
-- NULL = Partial keeps it).
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
    SELECT a.step_id, a.has_exclusive, a.has_unsupported, a.unsup_list,
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
             ELSE a.var_ios END AS ios,
        CASE WHEN a.has_exclusive THEN 'exclusive'
             WHEN a.has_unsupported THEN 'unsupported'
             ELSE 'variant' END AS affinity
    FROM aff a
    LEFT JOIN hostf h USING (step_id)
    -- Tranche 2 variants are doc knowledge, not bindings - only the Send
    -- Event dual-variant (57) joins the findings (see header).
    WHERE a.has_exclusive OR a.has_unsupported OR a.step_id = 57
),
profiled AS (
    SELECT *,
        CASE
            WHEN step_id = 57 THEN 'desktop-variant'
            WHEN macos AND NOT windows AND NOT linux AND NOT ios THEN 'macos-only'
            WHEN windows AND NOT macos AND NOT linux AND NOT ios THEN 'windows-only'
            WHEN linux AND NOT macos AND NOT windows AND NOT ios THEN 'linux-only'
            WHEN ios AND NOT macos AND NOT windows AND NOT linux THEN 'ios-only'
            WHEN macos AND windows AND NOT linux AND NOT ios THEN 'desktop-only'
            WHEN macos AND ios AND NOT windows AND NOT linux THEN 'apple-only'
            ELSE 'mixed'
        END AS os_profile,
        concat_ws(', ',
            CASE WHEN macos THEN 'macOS' END,
            CASE WHEN windows THEN 'Windows' END,
            CASE WHEN linux THEN 'Linux' END,
            CASE WHEN ios THEN 'iOS' END) AS supported_list
    FROM effective
),
core AS (
    SELECT 'platform-os-steps' AS rule_id,
        'info' AS severity,
        s.File_Name AS file_name, s.Script_UUID AS nav_uuid,
        'Script' AS object_type, s.Script_Name AS script_name,
        s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
        COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
        st.url_slug AS doc_slug,
        p.os_profile, p.macos, p.windows, p.linux, p.ios,
        p.affinity,
        CASE WHEN p.affinity = 'variant' THEN 'variant' ELSE 'exclusive' END AS signal,
        CASE p.affinity
             WHEN 'exclusive'
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID)
                  || ' works only on ' || p.supported_list || ' (' || p.os_profile || ') - on every other OS the step is ignored or fails'
             WHEN 'unsupported'
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID)
                  || ' is not supported on ' || p.unsup_list || ' (Claris prose, stored source-true); effective OS set: '
                  || p.supported_list || ' (' || p.os_profile || ', resolved against the host OS of its runtimes)'
             ELSE COALESCE(st.canonical_name, 'Step ' || s.Step_ID)
                  || ' carries two OS-exclusive option sets (macOS: Apple events, Windows: DDE/application actions) - a configuration made for one OS does nothing useful on the other (desktop-variant)'
        END AS message
    FROM StepsForScripts s
    JOIN profiled p ON p.step_id = s.Step_ID
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    WHERE s.Is_Enabled
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT *,
           os_profile AS _ord_1,
           file_name AS _ord_2,
           script_name AS _ord_3,
           step_no AS _ord_4
    FROM core
    WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
