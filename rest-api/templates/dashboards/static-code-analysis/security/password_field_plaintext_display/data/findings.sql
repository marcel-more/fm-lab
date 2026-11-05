-- Passwort-Feld wird im Klartext angezeigt (Layout-Objekt-Ebene).
-- Ein Passwort-/PIN-benanntes Feld wird von einem Layout-Objekt dargestellt, das
-- KEIN „verschlüsseltes Bearbeitungsfeld" (Concealed Edit Box) ist — der Wert steht
-- also im Klartext auf dem Layout. Ergebnis ist bewusst PRO Layout-Objekt (ein Feld
-- kann auf mehreren Layouts / mehrfach unverschlüsselt gezeigt werden).
--
-- Locale-unabhängiges Merkmal: das Concealed-Rendering ist im Objekt-XML als
-- `<Field><Display Style="7"/>` kodiert (Style 7 = concealed, korpus-weit eindeutig;
-- Style 0 = normales Bearbeitungsfeld). Object_Type ist lokalisiert (EN „Edit Box"
-- vs. DE „Bearbeitungsfeld") und deshalb NICHT als Filter geeignet. Wir filtern per
-- LIKE auf dem XML — kein xml_extract_text/LOAD webbed (Ein-Statement-Constraint des
-- REST-Backends).
WITH pw AS (
    SELECT f.Field_UUID, f.File_Name, f.Table_Name, f.Field_Name
    FROM FieldsForTables f
    WHERE regexp_matches(LOWER(f.Field_Name), '(password|passwort|kennwort|\bpin\b)')
      AND f.Field_Type = 'Normal' AND COALESCE(f.Is_Global, '') <> 'True'
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'password-field-plaintext-display' AS rule_id, 'warning' AS severity,
        lo.File_Name AS file_name,
        pw.Table_Name || '::' || pw.Field_Name AS field_name,
        l.L_Name AS layout_name,
        l.L_UUID AS nav_uuid,
        pw.Field_UUID AS field_uuid,
        lo.Object_UUID AS object_uuid
    FROM ObjectLinks ol
    JOIN pw ON pw.Field_UUID = ol.Target_UUID AND pw.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN LayoutObjects lo ON lo.Object_UUID = ol.Source_UUID AND lo.File_Name = ol.Source_File
    JOIN Layouts l ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
    WHERE ol.Link_Role = 'displays_field'
      AND ol.Source_Type = 'LayoutObject'
      AND lo.Object_XML NOT LIKE '%<Display Style="7"%'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.field_name, u.layout_name, u) AS row_key
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
