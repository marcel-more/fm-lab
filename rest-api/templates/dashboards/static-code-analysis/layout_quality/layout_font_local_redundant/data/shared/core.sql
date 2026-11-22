-- Local font equals the inherited font (layout_font_local_redundant) — shared rule core of findings.sql and summary.sql.
-- Needs catalog schema 1.44.0 (font and style tables).
-- Objects whose local font family equals the inherited one
-- (v_layout_object_font, Family_Source 'local_redundant').
lr_hits AS (
    SELECT f.File_Name, f.Object_UUID, f.Object_Type,
           coalesce(NULLIF(f.Object_Name, ''), f.Object_Type)              AS object_name,
           f.Font_Family, f.Font_PostScript, ly.L_UUID, ly.L_Name
    FROM v_layout_object_font f
    JOIN Layouts ly ON ly.L_ID = f.Layout_ID AND ly.File_Name = f.File_Name
    WHERE f.Family_Source = 'local_redundant'
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
