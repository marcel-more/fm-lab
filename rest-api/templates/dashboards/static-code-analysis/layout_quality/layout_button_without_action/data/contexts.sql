-- Distinct container contexts among the rule's findings — options dataset for
-- the context Select. Deliberately independent of the context filter itself so
-- the option list stays stable while filtering; file/scope filters still apply.
SELECT DISTINCT COALESCE(p.Object_Type, 'top-level') AS value,
                COALESCE(p.Object_Type, 'top-level') AS label
FROM LayoutObjects b
LEFT JOIN LayoutObjects p
       ON b.Parent_Object_ID = p.Object_ID AND b.Layout_ID = p.Layout_ID AND b.File_Name = p.File_Name
JOIN Layouts ly ON b.Layout_ID = ly.L_ID AND b.File_Name = ly.File_Name
WHERE b.Object_Type = 'Button'
  AND b.Object_XML NOT LIKE '%<ScriptReference%'
  AND b.Object_XML NOT LIKE '%<Step%'
  AND (getvariable('file') IS NULL OR b.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
