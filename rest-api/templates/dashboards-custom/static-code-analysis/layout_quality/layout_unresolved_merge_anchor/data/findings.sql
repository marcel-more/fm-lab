-- Merge-field anchors (<<Field>>) on a layout text object that FileMaker
-- cannot resolve.
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
--   resolved  — <FieldReference> entries inside the object's structural
--               <FieldList>: exactly one per RESOLVED anchor (fixture-
--               verified), none for an anchor that resolves to nothing.
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
    -- Merge anchors live on text objects only (measured: no other object type
    -- carries one), which also keeps container XML out of the comparison.
    SELECT Object_UUID, Object_ID, Layout_ID, File_Name, Object_Name, Object_Type,
           Text_Content, Object_XML,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Object_Type = 'Text' AND Text_Content LIKE '%<<%'
),
anchored AS (
    SELECT *,
        list_filter(regexp_extract_all(Text_Content, '(?s)<<(.*?)>>', 1),
                    lambda a: NOT (starts_with(a, '$') OR starts_with(a, 'ƒ:'))) AS anchor_list,
        regexp_extract_all(regexp_extract(Object_XML, '(?s)<FieldList>(.*?)</FieldList>', 1),
                           '<FieldReference[^>]*name="([^"]*)"', 1) AS ref_names
    FROM lo
    WHERE rn = 1
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
)
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
    row_number() OVER (ORDER BY c.File_Name, ly.L_Name, c.Object_Name) AS row_key
FROM counted c
JOIN Layouts ly ON ly.L_ID = c.Layout_ID AND ly.File_Name = c.File_Name
WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY row_key
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
