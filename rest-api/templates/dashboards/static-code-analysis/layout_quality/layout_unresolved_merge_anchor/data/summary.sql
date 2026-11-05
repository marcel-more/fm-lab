-- Hand-maintained wrapper around the rule core (layout_unresolved_merge_anchor).
WITH lo AS (
    SELECT Object_UUID, Object_ID, Layout_ID, File_Name, Object_Kind, Text_Content, Object_XML,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Object_Kind IN (2, 10, 14) AND Text_Content LIKE '%<<%'
),
label_refs AS (
    -- Button labels: one field row per resolved anchor occurrence (see findings.sql).
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
