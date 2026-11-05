-- @template_type: report
-- @title: Top layouts
-- @description: Layouts with the most objects.
-- @icon: layout
-- @display: table
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=Layout
-- @output_format: uuid, name, file, object_count
-- @object_types: Layout
-- @author: fm-lab core
-- @version: 1.1
-- @tags: layouts, top, ranking

WITH scored AS (
    SELECT
        l.L_UUID                  AS uuid,
        l.L_Name                  AS name,
        l.File_Name               AS file,
        COUNT(lo.Object_UUID)     AS object_count
    FROM Layouts l
    LEFT JOIN LayoutObjects lo ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
    WHERE (l.Folder_Type IS NULL) AND NOT l.Is_Separator
      AND (getvariable('file') IS NULL OR l.File_Name = getvariable('file'))
    GROUP BY ALL
)
SELECT uuid, name, file, object_count
FROM scored
WHERE object_count > 0
ORDER BY object_count DESC
LIMIT CAST(COALESCE(getvariable('limit'), '100') AS INTEGER);
