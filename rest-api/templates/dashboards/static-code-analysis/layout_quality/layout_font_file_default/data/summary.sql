-- Summary of layout_font_file_default: counts over the rule core in shared/core.sql (same as findings.sql).
WITH
--#include shared/core.sql
summary_end AS (SELECT 1)
SELECT COUNT(*)                          AS finding_count,
       COALESCE(SUM(default_objects), 0) AS default_objects,
       COUNT(DISTINCT File_Name)         AS affected_files
FROM fd_layouts;
