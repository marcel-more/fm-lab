-- @template_type: report
-- @title: Graph Search (Fokus-Autocomplete)
-- @description: ObjectCatalog-Suche für die Explorer-Sucheingabe (Fokus-Wahl)
-- @params: q (required), id_term, type, file, limit
-- @version: 1.1.0
-- @author: Marcel / Claude
-- @tags: graph, explorer, search
-- @note: Plan plan_graphify_style_visualisierung.md §6.1 Begleit-Endpoint
--        GET /api/graph/search. q wird von der Engine quote-escaped (injection-safe);
--        %/_ im Suchterm wirken bewusst als ILIKE-Wildcards.
--        id_term: vom Service normalisierte UUID bzw. Import-Schlüssel (oder
--        NULL). Trifft nur per Gleichheit, also nur als ganzer Begriff — nie
--        als Teilstring; ein UUID-Treffer steht vor allen Namenstreffern.

WITH q AS (
  SELECT CAST(getvariable('q') AS VARCHAR)       AS term,
         CAST(getvariable('id_term') AS VARCHAR) AS id_term
)
SELECT
  oc.Object_UUID AS id,
  oc.Object_Name AS label,
  oc.Object_Type AS type,
  oc.File_Name   AS file
FROM ObjectCatalog oc, q
WHERE (oc.Object_Name ILIKE '%' || q.term || '%' OR oc.Object_UUID = q.id_term)
  AND (getvariable('type') IS NULL OR oc.Object_Type = CAST(getvariable('type') AS VARCHAR))
  AND (getvariable('file') IS NULL OR oc.File_Name   = CAST(getvariable('file') AS VARCHAR))
ORDER BY
  coalesce(oc.Object_UUID = q.id_term, FALSE) DESC, -- UUID-Treffer zuerst
  (oc.Object_Name ILIKE q.term || '%') DESC,   -- Präfix-Treffer zuerst
  length(oc.Object_Name) ASC,                  -- kürzere (= näher am Term) zuerst
  oc.Object_Name ASC
LIMIT CAST(getvariable('limit') AS INT);
