-- Font left to the file default (layout_font_file_default) — shared rule core of findings.sql and summary.sql.
-- Needs catalog schema 1.44.0 (font and style tables).
-- Text-bearing objects whose font no level names (v_layout_object_font,
-- Family_Source 'default'): one row per layout.
fd_layouts AS (
    SELECT ly.File_Name, ly.L_UUID, ly.L_Name,
           coalesce(any_value(tc.Theme_Display), any_value(ly.L_Theme_Resolved_Name)) AS theme,
           count(*) FILTER (WHERE f.Family_Source = 'default')            AS default_objects,
           count(*)                                                       AS text_objects
    FROM v_layout_object_font f
    JOIN Layouts ly ON ly.L_ID = f.Layout_ID AND ly.File_Name = f.File_Name
    LEFT JOIN ThemeCatalog tc
           ON tc.File_Name = ly.File_Name AND tc.Theme_UUID = ly.L_Theme_Resolved_UUID
    WHERE (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY ly.File_Name, ly.L_UUID, ly.L_Name
    HAVING count(*) FILTER (WHERE f.Family_Source = 'default') > 0
),
