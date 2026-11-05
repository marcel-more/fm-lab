-- Hand-maintained COUNT wrapper embedding the findings core of rule (cross_product_relationship).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'cross-product-relationship' AS rule_id, 'warning' AS severity,
    r.File_Name AS file_name, r.Left_TO_Name AS left_to, r.Right_TO_Name AS right_to,
    r.Left_TO_Name || ' × ' || r.Right_TO_Name AS relationship,
    row_number() OVER (ORDER BY r.File_Name, r.Left_TO_Name) AS row_key
FROM (SELECT DISTINCT File_Name, Rel_ID, Left_TO_Name, Right_TO_Name
      FROM RelationshipCatalog WHERE Operator = 'CartesianProduct') r
WHERE (getvariable('file') IS NULL OR r.File_Name = getvariable('file'))
ORDER BY r.File_Name, r.Left_TO_Name
) _summary;
