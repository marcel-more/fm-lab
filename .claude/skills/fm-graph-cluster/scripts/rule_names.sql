-- @title: Rule-based names for formulaic communities (Phase E, before the hints)
-- @description: Names communities that are pure scaffolding — per-file access-rights sets
--               (PrivilegeSet/Account/ExtendedPrivilege) and menu overrides
--               (CustomMenu/CustomMenuItem) — directly in SQL, so the hint list the model reads
--               shrinks to the communities that need real reading (on a large corpus 151 → ~25).
-- @version: 1.0.0
-- @tags: graph, cluster, naming
-- @note: read-write (UPDATE CommunityNames). Only rows with Semantic_Name IS NULL; never overwrites.
--        Language lives in the templates the skill passes (prompt language), not in SQL.
-- Variables:
--   engine      VARCHAR   required
--   threshold   INTEGER   Member_Count >= threshold (default 3) — below-threshold stays heuristic
--   tpl_access  VARCHAR   e.g. 'Access rights {file}'           / 'Zugriffsrechte {file}'
--   tpl_menu    VARCHAR   e.g. 'Menu overrides {file} · {menu}'  / 'Menü-Overrides {file} · {menu}'
--   min_share   DOUBLE    share of formulaic-type members required (default 0.7) — protects
--                         mixed communities (e.g. a file trigger script + its rights scaffold)
CREATE OR REPLACE TEMP TABLE _rule_targets AS
WITH share AS (
  SELECT cl.Community,
         COUNT(*) AS n,
         COUNT(*) FILTER (WHERE oc.Object_Type IN ('PrivilegeSet', 'Account', 'ExtendedPrivilege', 'File')) AS n_access,
         COUNT(*) FILTER (WHERE oc.Object_Type IN ('CustomMenu', 'CustomMenuItem', 'CustomMenuSet')) AS n_menu
  FROM ObjectClusters cl
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = cl.Object_UUID AND oc.File_Name IS NOT DISTINCT FROM cl.File_Name
  WHERE cl.Engine = getvariable('engine')
  GROUP BY cl.Community
)
SELECT cn.Community,
       CASE WHEN s.n_access * 1.0 / s.n >= COALESCE(getvariable('min_share'), 0.7) THEN 'access'
            WHEN s.n_menu   * 1.0 / s.n >= COALESCE(getvariable('min_share'), 0.7) THEN 'menu' END AS kind,
       cn.Dominant_File, cn.Top_Member_Label
FROM CommunityNames cn
JOIN share s ON s.Community = cn.Community
WHERE cn.Engine = getvariable('engine')
  AND cn.Semantic_Name IS NULL
  AND cn.Member_Count >= COALESCE(getvariable('threshold'), 3)
  AND (s.n_access * 1.0 / s.n >= COALESCE(getvariable('min_share'), 0.7)
       OR s.n_menu * 1.0 / s.n >= COALESCE(getvariable('min_share'), 0.7));

UPDATE CommunityNames cn
SET Semantic_Name = replace(replace(
      CASE t.kind WHEN 'access' THEN COALESCE(getvariable('tpl_access'), 'Access rights {file}')
                  ELSE COALESCE(getvariable('tpl_menu'), 'Menu overrides {file} · {menu}') END,
      '{file}', COALESCE(t.Dominant_File, '?')),
      '{menu}', COALESCE(t.Top_Member_Label, '?'))
FROM _rule_targets t
WHERE cn.Community = t.Community AND cn.Engine = getvariable('engine');

SELECT kind, COUNT(*) AS rule_named FROM _rule_targets GROUP BY kind ORDER BY kind;
