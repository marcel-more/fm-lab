-- Options of the type filter: the object types of v_object_usage that occur
-- (within the app-level file filter).
SELECT Object_Type AS value, Object_Type AS label
FROM v_object_usage
WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
GROUP BY Object_Type
ORDER BY Object_Type;
