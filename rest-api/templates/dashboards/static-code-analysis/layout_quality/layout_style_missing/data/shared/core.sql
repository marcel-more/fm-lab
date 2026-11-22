-- Style missing from the theme (layout_style_missing) — shared rule core of findings.sql and summary.sql.
-- Needs catalog schema 1.44.0 (font and style tables).
-- Objects whose applied style has no rule in the theme of their layout —
-- same definition as the import check v_check_layout_styles.style_without_rule_n.
sm_names AS (
    SELECT Object_UUID, File_Name, any_value(Object_Name) AS Object_Name
    FROM LayoutObjects
    GROUP BY ALL
),
sm_hits AS (
    SELECT s.File_Name, s.Object_UUID, s.Object_Type,
           coalesce(NULLIF(n.Object_Name, ''), s.Object_Type)               AS object_name,
           coalesce(s.Style_Display, s.Style_Name)                          AS style,
           s.Style_Name,
           coalesce(tc.Theme_Display, ly.L_Theme_Resolved_Name)             AS theme,
           ly.L_UUID, ly.L_Name
    FROM LayoutObjectStyles s
    JOIN Layouts ly ON ly.L_ID = s.Layout_ID AND ly.File_Name = s.File_Name
    LEFT JOIN sm_names n ON n.Object_UUID = s.Object_UUID AND n.File_Name = s.File_Name
    LEFT JOIN ThemeCatalog tc
           ON tc.File_Name = ly.File_Name AND tc.Theme_UUID = ly.L_Theme_Resolved_UUID
    WHERE s.Style_Name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ThemeStyleRules r
                       WHERE r.File_Name = s.File_Name
                         AND r.Theme_UUID = ly.L_Theme_Resolved_UUID
                         AND r.Style_Class = s.Style_Name)
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
