-- Summary of layout_font_local_redundant: counts over the rule core in shared/core.sql (same as findings.sql).
WITH
--#include shared/core.sql
summary_end AS (SELECT 1)
SELECT COUNT(*)                   AS finding_count,
       COUNT(DISTINCT L_UUID)     AS affected_layouts
FROM lr_hits;
