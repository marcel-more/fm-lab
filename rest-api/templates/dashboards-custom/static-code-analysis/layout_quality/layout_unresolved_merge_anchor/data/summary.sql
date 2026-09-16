-- Hand-maintained wrapper around the rule core (layout_unresolved_merge_anchor).
WITH lo AS (
    SELECT Object_UUID, Object_ID, Layout_ID, File_Name, Text_Content, Object_XML,
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
    SELECT *, len(anchor_list) AS anchor_count, len(ref_names) AS resolved_count
    FROM anchored
    WHERE len(anchor_list) > len(ref_names)
)
SELECT COUNT(*) AS finding_count,
       COALESCE(SUM(c.anchor_count - c.resolved_count), 0) AS unresolved_anchors,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT c.File_Name) AS affected_files
FROM counted c
JOIN Layouts ly ON ly.L_ID = c.Layout_ID AND ly.File_Name = c.File_Name
WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
