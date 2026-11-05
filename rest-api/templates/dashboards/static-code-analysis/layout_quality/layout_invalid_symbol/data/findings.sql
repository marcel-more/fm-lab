-- Layout symbols ({{…}}) that are not a Get parameter.
--
-- A symbol is, per Claris, the value of Get(<Symbol>) at display time: the
-- five menu symbols (CurrentDate, CurrentTime, UserName, PageNumber,
-- RecordNumber) and everything behind "Other Symbol…" are Get parameters.
-- A symbol FileMaker cannot resolve is not dropped — it renders LITERALLY in
-- browse and preview mode (screenshot-verified), so the layout shows the raw
-- {{Text}} to the user. That is almost always an author's typo.
--
-- Source of truth for validity is the standard reference:
-- ref.function_name_lookup, chunk_role = 'getparameter'. Deliberately WITHOUT
-- a match_source filter: FileMaker accepts the localized parameter name too
-- ({{Seitennummer}} renders correctly and stays literal in the export), so a
-- localized name is valid, not a defect. The comparison runs over Symbol_Norm
-- (lower) — symbols are case-insensitive.
--
-- Two honest limits, both reasons why this rule is a WARNING, never an error:
--   1. The reference's localized coverage is uneven — it carries the Get
--      parameters in canonical English plus de/fr/it/ja/ko/nl/sv/zh-Hans;
--      Spanish and Portuguese names are absent entirely and German is partly
--      covered via the string-resource axis. A symbol typed in an uncovered
--      language can still be reported here.
--   2. Bracket forms such as {{Get(FoundCount)}} never reach
--      LayoutObjectSymbols at all (the P3 extractor only accepts bare
--      alphanumeric names) — they render literally too, but this rule is
--      blind to them.
--
-- Never re-regex Text_Content for symbols: LayoutObjectSymbols (P3 A.13) is
-- the resolved inventory. Since the inventory also lists the symbols of button
-- labels (which FileMaker never evaluates), the rule keeps to text objects —
-- via Object_Kind, which every catalog carries, not via the newer
-- LayoutObjectSymbols.Is_Evaluated column that says the same.
--
-- Why the comparison and not the edge: since converter 2.28.0 P4 writes a
-- `displays_symbol` edge for every VALID symbol, so "symbol without edge" would
-- look like the cheaper test. It is not — on a catalog imported by an older
-- converter it reports every symbol as invalid. The reference comparison is the
-- source of truth either way and works on a catalog of any converter version.
WITH lo AS (
    -- LayoutObjects can carry duplicate rows per (Object_UUID, File_Name).
    SELECT Object_UUID, Object_ID, File_Name, Object_Name, Object_Type,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
),
invalid AS (
    SELECT s.*
    FROM LayoutObjectSymbols s
    WHERE NOT EXISTS (SELECT 1 FROM ref.function_name_lookup f
                      WHERE f.chunk_role = 'getparameter'
                        AND lower(f.lookup_name) = s.Symbol_Norm)
      -- Text objects only (kind 2): FileMaker evaluates symbols nowhere else;
      -- in a button label every symbol stays literal (rule layout_button_label_symbol).
      AND EXISTS (SELECT 1 FROM LayoutObjects k
                  WHERE k.Object_UUID = s.Object_UUID AND k.File_Name = s.File_Name
                    AND k.Object_Kind = 2)
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-invalid-symbol' AS rule_id, 'warning' AS severity,
        i.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        o.Object_UUID AS object_uuid, o.Object_Type AS object_type,
        COALESCE(NULLIF(trim(o.Object_Name), ''), '(unnamed)') AS object_name,
        '{{' || i.Symbol_Text || '}}' AS symbol,
        i.Occurrence_Count AS occurrences,
        'unknown-symbol' AS defect,
        o.Bounds_Left AS x, o.Bounds_Top AS y,
        (o.Bounds_Right - o.Bounds_Left) AS w, (o.Bounds_Bottom - o.Bounds_Top) AS h,
        '{{' || i.Symbol_Text || '}} is not a known Get parameter — the text renders literally' AS message,
           i.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           o.Object_Name AS _ord_3,
           i.Symbol_Norm AS _ord_4
    FROM invalid i
    JOIN lo o     ON o.Object_UUID = i.Object_UUID AND o.File_Name = i.File_Name AND o.rn = 1
    JOIN Layouts ly ON ly.L_ID = i.Layout_ID AND ly.File_Name = i.File_Name
    WHERE (getvariable('file') IS NULL OR i.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
