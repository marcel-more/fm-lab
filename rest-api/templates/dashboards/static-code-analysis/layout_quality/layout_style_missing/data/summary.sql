-- Summary of layout_style_missing: counts over the rule core in shared/core.sql (same as findings.sql).
WITH
--#include shared/core.sql
summary_end AS (SELECT 1)
SELECT COUNT(*)                   AS finding_count,
       COUNT(DISTINCT style)      AS missing_styles,
       COUNT(DISTINCT L_UUID)     AS affected_layouts
FROM sm_hits;
