-- @template_type: report
-- @description: Lists every script step that contains a credential-related keyword
--               (password, secret, apikey, token, …). Surgical masking: only string
--               literals in structural "value position" (Set Variable Value, JSON
--               setter value, send-mail parameter value, HTTP-header value inside
--               a string literal) are replaced with "*****". Dialog labels and
--               unrelated strings stay readable. The matched keyword is returned
--               separately so the frontend can highlight it on click via ?sq=<keyword>.
-- @params: file (optional), limit (optional, default 500)
--
-- Click navigation: uuid is the Script_UUID, type=Script, and params.sq carries the
-- keyword so the script detail view can scroll/highlight to the relevant lines.
--
-- NOTE: The keyword pattern MUST be inlined (not stored in a CTE) — referencing it
-- via `(SELECT p FROM pat)` triggers a BLOCKWISE_NL_JOIN that scales catastrophically
-- (~4s on 200k rows). Keeping the pattern as a string literal lets DuckDB push the
-- regex filter into the table scan (~60ms).

WITH hits AS (
    SELECT
        s.Script_UUID,
        s.Script_Name,
        s.Step_UUID,
        s.Step_Index,
        s.Step_Name,
        s.Step_ID,
        s.File_Name,
        d.Step_Text                                            AS txt_orig,
        -- Surgical masking — four targeted patterns chained:
        --   A) Set Variable [$<credentialVar>; Value:"X"]     → mask "X"
        --   B) JSON setter ["<credentialKey>"; "X"; …]        → mask "X"
        --   C) Send-Mail / parameter "<Keyword>: "X""         → mask "X" (word-boundary required)
        --   D) HTTP-header inside one string: "Authorization: Bearer X" → mask after the header marker
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(d.Step_Text,
                '(?i)(\$\$?[A-Za-z_0-9]*(password|passwort|pswd|kennwort|secret|apikey|api_key|credential|passphrase|token|bearer|client_secret|clientsecret|access_token|accesstoken|refresh_token|refreshtoken|private_key|privatekey|basic_auth|hmac|signingkey|userpass|login_password)[A-Za-z_0-9]*\s*;\s*Value:\s*)"[^"]*"',
                '\1"*****"', 'g'),
              '(?i)("[A-Za-z_]*(password|passwort|secret|apikey|api_key|credential|passphrase|token|client_secret|access_token|refresh_token|private_key|signingkey)[A-Za-z_]*"\s*[;,]\s*)"[^"]*"',
              '\1"*****"', 'g'),
            '(?i)((^|[\s;,\[])(Password|Passwort|Token|API[_\- ]?Key|Secret|Authorization)\s*:\s*)"[^"]+"',
            '\1"*****"', 'g'),
          '(?i)"((Authorization|X[-_]API[-_]Key|Cookie|Bearer)\s*:?\s*)([^"]+)"',
          '"\1*****"', 'g')                                    AS txt_masked,
        regexp_extract(LOWER(d.Step_Text), '(password|passwort|pswd|kennwort|pwd|secret|apikey|api_key|api-key|credential|passphrase|token|bearer|mdp|senha|contrase|authorization|client_secret|clientsecret|access_token|accesstoken|refresh_token|refreshtoken|private_key|privatekey|basic_auth|hmac|signingkey|userpass|login_password|signature)') AS matched_keyword
    FROM StepsForScripts s
    JOIN DDR_ScriptSteps d ON s.Step_UUID = d.Step_UUID AND d.File_Name = s.File_Name
    WHERE d.Step_Text IS NOT NULL
      AND regexp_matches(LOWER(d.Step_Text), '(password|passwort|pswd|kennwort|pwd|secret|apikey|api_key|api-key|credential|passphrase|token|bearer|mdp|senha|contrase|authorization|client_secret|clientsecret|access_token|accesstoken|refresh_token|refreshtoken|private_key|privatekey|basic_auth|hmac|signingkey|userpass|login_password|signature)')
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
located AS (
    SELECT
        *,
        POSITION(matched_keyword IN LOWER(txt_masked)) AS pos_m
    FROM hits
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        Script_UUID                                        AS uuid,
        File_Name                                          AS file,
        Script_Name                                        AS script,
        Step_Index + 1                                         AS step_index,
        Step_Name                                          AS step_name,
        matched_keyword                                    AS keyword,
        CASE
            WHEN pos_m > 0
                THEN SUBSTRING(txt_masked, GREATEST(1, pos_m - 60), 200)
            ELSE SUBSTRING(txt_masked, 1, 200)
        END                                                AS snippet,
        -- Chip key: If and Else If share one chip (by step id, locale-independent).
        CASE WHEN Step_ID IN (68, 125) THEN 'If / Else If' ELSE Step_Name END AS _chip_step
    FROM located
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file, u.script, u.step_index, u) AS row_key
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
-- Chip filter: narrows the whole result; its counts (_chip_facets) leave out
-- the search and the chip itself.
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('step') IS NULL OR _chip_step = getvariable('step'))
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
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((_chip_step, n) ORDER BY _chip_step)))
       FROM (SELECT _chip_step, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
