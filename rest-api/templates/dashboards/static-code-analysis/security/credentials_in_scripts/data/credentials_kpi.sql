-- @template_type: report
-- @description: Aggregate KPI counts for credential keyword findings across all script steps.
-- @params: file (optional)
--
-- NOTE: The keyword pattern MUST be inlined (not stored in a CTE) — referencing it
-- via `(SELECT p FROM pat)` triggers a BLOCKWISE_NL_JOIN that scales catastrophically
-- (~6s on 200k rows). Keeping the pattern as a string literal lets DuckDB push the
-- regex filter into the table scan (~50ms).

SELECT
    COUNT(*)                       AS hit_count,
    COUNT(DISTINCT s.Script_UUID)  AS script_count,
    COUNT(DISTINCT s.File_Name)    AS file_count
FROM StepsForScripts s
JOIN DDR_ScriptSteps d ON s.Step_UUID = d.Step_UUID AND d.File_Name = s.File_Name
WHERE d.Step_Text IS NOT NULL
  AND regexp_matches(LOWER(d.Step_Text), '(password|passwort|pswd|kennwort|pwd|secret|apikey|api_key|api-key|credential|passphrase|token|bearer|mdp|senha|contrase|authorization|client_secret|clientsecret|access_token|accesstoken|refresh_token|refreshtoken|private_key|privatekey|basic_auth|hmac|signingkey|userpass|login_password|signature)')
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'));
