-- Merge-field anchors (<<Field>>) on a layout text object, button or popover
-- button that FileMaker cannot resolve.
--
-- An unresolvable anchor is not dropped: it renders LITERALLY in browse and
-- preview mode (screenshot-verified), so the user sees the raw <<Field>> where
-- a value was meant to be. Because the anchor resolves to nothing, it also
-- leaves no trace in the catalog — no displays_field edge, no object of its
-- own. This rule is the only place such an anchor becomes visible.
--
-- Detection compares two counts on the SAME object:
--   anchors   — <<…>> in Text_Content, WITHOUT <<$…>> (merge variables) and
--               WITHOUT <<ƒ:…>> (layout calculations). Both exclusions are
--               mandatory: layout calculations write no FieldReference, so
--               counting them produces false positives. A repetition
--               (<<Field[2]>>) and a qualified anchor (<<TO::Field>>) each
--               count as ONE anchor — FileMaker puts the repetition into the
--               `repetition` attribute and the qualification into the nested
--               TableOccurrenceReference, not into the name.
--   resolved  — text objects: <FieldReference> entries inside the object's
--               structural <FieldList>: exactly one per RESOLVED anchor
--               (fixture-verified), none for an anchor that resolves to
--               nothing. Buttons and popover buttons never get a FieldList,
--               although FileMaker evaluates typed anchors in their label at
--               runtime; the converter resolves those from the label text
--               (one field row per resolved occurrence in XMLLayoutReferences,
--               unqualified anchors against the layout's table occurrence).
--               An anchor on an EXTERNAL table occurrence whose file is not
--               part of the import keeps an open row (Ref_UUID NULL): it cannot
--               be verified, so it counts as not literal — no finding.
-- The difference is the number of anchors that render literally. Counting,
-- not name matching, decides the finding: XML attribute values are entity-
-- encoded (Stra&#xDF;e) while Text_Content is decoded, so a name comparison
-- would break on exactly the non-ASCII field names.
--
-- `unresolved_anchors` names the suspects as a best effort via that same name
-- comparison, and is NULL whenever it disagrees with the count — a wrong name
-- is worse than none. The count columns always hold.
WITH lo AS (
    -- LayoutObjects can carry duplicate rows per (Object_UUID, File_Name).
    -- Merge anchors live in the text of text objects (kind 2) and in the labels
    -- of buttons (kind 10) and popover buttons (kind 14) — Text_Content holds
    -- exactly that text, so container XML stays out of the comparison. Dispatch
    -- on @kind, because Object_Type comes from the localized @type.
    SELECT Object_UUID, Object_ID, Layout_ID, File_Name, Object_Name, Object_Type, Object_Kind,
           Text_Content, Object_XML,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Object_Kind IN (2, 10, 14) AND Text_Content LIKE '%<<%'
),
label_refs AS (
    -- Button labels: every resolved anchor occurrence is one field row of the
    -- button in XMLLayoutReferences (written from the label text). A button
    -- carries neither a FieldList nor a field of its own, so all its field
    -- rows are label-text rows — no need to name the column that says so,
    -- which keeps the rule runnable on catalogs of older converters.
    SELECT Object_UUID, File_Name, list(Ref_Name ORDER BY Ref_Name) AS names
    FROM XMLLayoutReferences
    WHERE Ref_Type = 'field'
      AND Object_UUID IN (SELECT Object_UUID FROM lo WHERE Object_Kind IN (10, 14))
    GROUP BY ALL
),
anchored AS (
    SELECT lo.*,
        list_filter(regexp_extract_all(lo.Text_Content, '(?s)<<(.*?)>>', 1),
                    lambda a: NOT (starts_with(a, '$') OR starts_with(a, 'ƒ:'))) AS anchor_list,
        CASE WHEN lo.Object_Kind = 2
             THEN regexp_extract_all(regexp_extract(lo.Object_XML, '(?s)<FieldList>(.*?)</FieldList>', 1),
                                     '<FieldReference[^>]*name="([^"]*)"', 1)
             ELSE COALESCE(lr.names, CAST([] AS VARCHAR[]))
        END AS ref_names
    FROM lo
    LEFT JOIN label_refs lr
           ON lr.Object_UUID = lo.Object_UUID
          AND lr.File_Name   = lo.File_Name
    WHERE lo.rn = 1
),
counted AS (
    SELECT *,
        len(anchor_list) AS anchor_count,
        len(ref_names)   AS resolved_count,
        -- Best-effort suspects: anchor name (TO prefix and repetition
        -- stripped) absent from the FieldList names, case-insensitively.
        list_filter(anchor_list, lambda a: NOT list_contains(
            list_transform(ref_names, lambda n: lower(n)),
            lower(regexp_replace(regexp_replace(trim(a), '^.*::', ''), '\[\s*\d+\s*\]\s*$', '')))) AS unmatched
    FROM anchored
    WHERE len(anchor_list) > len(ref_names)
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-unresolved-merge-anchor' AS rule_id, 'warning' AS severity,
        c.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        c.Object_UUID AS object_uuid, c.Object_Type AS object_type,
        COALESCE(NULLIF(trim(c.Object_Name), ''), '(unnamed)') AS object_name,
        c.anchor_count, c.resolved_count,
        c.anchor_count - c.resolved_count AS unresolved_count,
        list_aggregate(list_transform(c.anchor_list, lambda a: '<<' || a || '>>'), 'string_agg', ', ') AS anchors,
        CASE WHEN len(c.unmatched) = c.anchor_count - c.resolved_count
             THEN list_aggregate(list_transform(c.unmatched, lambda a: '<<' || a || '>>'), 'string_agg', ', ')
        END AS unresolved_anchors,
        'unresolved-anchor' AS defect,
        c.Bounds_Left AS x, c.Bounds_Top AS y,
        (c.Bounds_Right - c.Bounds_Left) AS w, (c.Bounds_Bottom - c.Bounds_Top) AS h,
        CASE WHEN len(c.unmatched) = c.anchor_count - c.resolved_count
             THEN (c.anchor_count - c.resolved_count) || ' of ' || c.anchor_count
                  || ' merge anchors render literally: '
                  || list_aggregate(list_transform(c.unmatched, lambda a: '<<' || a || '>>'), 'string_agg', ', ')
             ELSE (c.anchor_count - c.resolved_count) || ' of ' || c.anchor_count
                  || ' merge anchors render literally'
        END AS message,
           c.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           c.Object_Name AS _ord_3
    FROM counted c
    JOIN Layouts ly ON ly.L_ID = c.Layout_ID AND ly.File_Name = c.File_Name
    WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u) AS row_key
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
