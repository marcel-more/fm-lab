-- Summary of layout_many_fonts: counts over the rule core in shared/core.sql (same as findings.sql).
WITH
--#include shared/core.sql
summary_end AS (SELECT 1)
SELECT COUNT(*)                       AS finding_count,
       COUNT(DISTINCT File_Name)      AS affected_files,
       (SELECT m FROM fu_max)         AS font_max
FROM fu_hits;
