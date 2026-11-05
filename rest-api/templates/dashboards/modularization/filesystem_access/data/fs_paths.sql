-- @template_type: report
-- @description: Extrahierte Pfad-Literale (file:/filewin:/filemac:) aus Script-Step-Formeln — beantwortet „wohin schreibt/liest die Lösung?". Mit Normalisierung auf Verzeichnis-Ebene (Dateiname entfernt). Klick auf eine Zeile öffnet das Script am Step.
-- @params: file (optional), limit (optional, default 200)

WITH raw AS (
    SELECT
        c.File_Name                                             AS file,
        s.Script_Name                                           AS carrier,
        s.Step_Name                                             AS detail,
        s.Step_Index + 1                                            AS step_index,
        s.Script_UUID                                           AS nav_uuid,
        c.Owner_UUID                                            AS step_uuid,
        -- Alternation statt (?:win|mac)?-Gruppe: der API-SQL-Präprozessor ersetzt
        -- ":win" in einer non-capturing Gruppe sonst durch NULL (":<wort>"-Bindung).
        -- Längste Variante zuerst (filewin/filemac vor file).
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
            '(?i)(filewin|filemac|file):[^"''\n\r]*', 0)         AS path_literal
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE regexp_matches(COALESCE(c.Formula_Text, c.Display_Text), '(?i)(filewin|filemac|file):')
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        file,
        carrier,
        detail,
        step_index,
        trim(path_literal)                                          AS path_literal,
        -- Verzeichnis-Normalisierung: letzten Pfadbestandteil (Dateiname) entfernen
        regexp_replace(trim(path_literal), '/[^/]*$', '/')          AS directory,
        nav_uuid,
        step_uuid
    FROM raw
    WHERE path_literal <> ''
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file, u.carrier, u.step_index, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 200), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
