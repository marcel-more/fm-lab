-- @template_type: report
-- @description: Aggregat-Kennzahlen für markierte Kommentar-Schritte in Scripts,
--               aufgeschlüsselt nach Notation (TO DO / FIX IT / TBD) plus Scripts/Dateien.
-- @params: file (optional)
--
-- Erkennt drei Notations-Familien (case-insensitiv, mit Wortgrenzen, damit Prosa
-- wie "today", "stop", "fix item" nicht trifft):
--   TO DO  : \bto[\s\-_]?do                                  (TODO, TO DO, To-Do, TO_DO …)
--   FIX IT : \bfix[\s\-_]?(it|me)\b                          (FIXIT, FIX IT, FIX-IT, FIXME, FIX ME; auch "==  FIX IT  ==")
--   TBD    : \btbd\b | \bto[\s\-_]be[\s\-_](done|defined)\b  (TBD, "to be done", "to-be-defined")
--
-- Klassifikation pro Zeile mit fester Präzedenz FIX IT > TBD > TO DO (CASE-Reihenfolge),
-- damit total_lines = todo_lines + fixit_lines + tbd_lines gilt (überschneidungsfreie
-- Aufteilung, keine Doppelzählung). Die KPIs werten den `pattern`-Filter bewusst NICHT
-- aus — sie sind die Filter-Buttons und zeigen stets alle Kategorie-Summen.
--
-- Comment-Text direkt aus Parameters_XML (kein xml_extract_text / LOAD webbed, da das
-- REST-API-Backend nur ein Statement pro prepare() erlaubt).
-- Spalte `file` gibt den aktiven Datei-Filter zurück (für {{file}}-Token im Hero-onClick,
-- damit der Datei-Filter beim Pattern-Wechsel erhalten bleibt).

WITH comment_steps AS (
    SELECT
        s.Script_UUID,
        s.File_Name,
        regexp_extract(s.Parameters_XML, '<Comment value="([^"]*)"', 1) AS comment_text
    FROM StepsForScripts s
    WHERE s.Step_ID = 89   -- '# (Comment)' — Step_ID ist locale-unabhängig (Step_Name lokalisiert)
      AND (getvariable('file') IS NULL OR getvariable('file') = '' OR s.File_Name = getvariable('file'))
),
classified AS (
    SELECT
        Script_UUID,
        File_Name,
        CASE
            WHEN regexp_matches(comment_text, '(?i)\bfix[\s\-_]?(it|me)\b')                              THEN 'FIX IT'
            WHEN regexp_matches(comment_text, '(?i)(\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)')  THEN 'TBD'
            WHEN regexp_matches(comment_text, '(?i)\bto[\s\-_]?do')                                  THEN 'TO DO'
        END AS pattern
    FROM comment_steps
    WHERE comment_text <> ''
)
SELECT
    COUNT(*)                                    AS total_lines,
    COUNT(*) FILTER (WHERE pattern = 'TO DO')   AS todo_lines,
    COUNT(*) FILTER (WHERE pattern = 'FIX IT')  AS fixit_lines,
    COUNT(*) FILTER (WHERE pattern = 'TBD')     AS tbd_lines,
    COUNT(DISTINCT Script_UUID)                 AS scripts,
    COUNT(DISTINCT File_Name)                   AS files,
    getvariable('file')                         AS file
FROM classified
WHERE pattern IS NOT NULL;
