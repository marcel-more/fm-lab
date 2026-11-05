-- Hand-maintained COUNT wrapper for rule (relationship_with_sort).
-- Keep filters (file filter) in sync with data/findings.sql. The consumer
-- chips must show their true totals, so the consumer_filter param is
-- deliberately NOT applied here (established chip pattern).
WITH sorted_rels AS (
    SELECT DISTINCT File_Name, Rel_ID,
           CASE WHEN Left_Sort_Enabled = 'True' THEN Left_TO_UUID END AS sorted_left_uuid,
           CASE WHEN Right_Sort_Enabled = 'True' THEN Right_TO_UUID END AS sorted_right_uuid
    FROM RelationshipCatalog
    WHERE Left_Sort_Enabled = 'True' OR Right_Sort_Enabled = 'True'
),
portal_ctx AS (
    SELECT ol.Source_UUID AS portal_uuid, ol.Target_UUID AS to_uuid
    FROM ObjectLinks ol
    JOIN ObjectCatalog s ON ol.Source_UUID = s.Object_UUID AND s.Object_Type = 'LayoutObject'
    WHERE ol.Link_Role = 'portal_context'
),
portal_sorted AS (
    SELECT DISTINCT Source_UUID AS portal_uuid FROM ObjectLinks WHERE Link_Role = 'sorts_by_field'
),
consumers AS (
    SELECT sr.File_Name, sr.Rel_ID,
           count(DISTINCT pc.portal_uuid) AS consumer_portals,
           count(DISTINCT pc.portal_uuid) FILTER (WHERE ps.portal_uuid IS NOT NULL) AS portals_own_sort
    FROM sorted_rels sr
    JOIN portal_ctx pc ON pc.to_uuid IN (sr.sorted_left_uuid, sr.sorted_right_uuid)
    LEFT JOIN portal_sorted ps ON ps.portal_uuid = pc.portal_uuid
    GROUP BY 1, 2
)
SELECT
    COUNT(*) AS finding_count,
    'info' AS severity,
    COUNT(*) FILTER (WHERE COALESCE(c.consumer_portals, 0) > 0) AS with_portals_count,
    COUNT(*) FILTER (WHERE COALESCE(c.portals_own_sort, 0) > 0) AS with_sorted_portals_count,
    COUNT(DISTINCT r.File_Name) AS affected_files
FROM sorted_rels r
LEFT JOIN consumers c ON c.File_Name = r.File_Name AND c.Rel_ID = r.Rel_ID
WHERE (getvariable('file') IS NULL OR r.File_Name = getvariable('file'));
