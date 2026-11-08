-- @template_type: report
-- @description: Relationship-graph context of a TableOccurrence for its detail view — its TO group (connected component), the layout anchors of that group and the shortest context path from the nearest anchor to this occurrence
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: table-occurrence, relationship, graph, context, anchor
-- @note: Companion of object_details_tableoccurrence, appended by the service. Reads only
--        RelationshipCatalog, TableOccurrenceCatalog and ObjectLinks (context_table), so it works
--        on every catalog schema. Flat rows with a `section` discriminator:
--          'group'     → one row: TOs in the group, layouts based on any of them, anchor count,
--                        layouts of this occurrence itself, distance of the nearest anchor.
--          'anchor'    → every anchor (TO of the group with layouts as context): most layouts
--                        first, then nearest first, then by name.
--          'path_step' → the context paths from the nearest anchors (up to three, `path_no`), one
--                        row per occurrence on the path from the anchor (`step_index` 0) to this
--                        occurrence; `hop_*` describe the relationship arriving at that step.
--        The graph of one file is a forest (FileMaker forbids cycles), so the walk from this
--        occurrence reaches every TO of its group exactly once; the depth bound only guards
--        against a damaged catalog.

WITH RECURSIVE
self AS (
  SELECT t.TO_UUID, t.File_Name
  FROM TableOccurrenceCatalog t
  WHERE t.TO_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  LIMIT 1
),
edges AS (
  SELECT DISTINCT r.Rel_ID, r.Left_TO_UUID AS a, r.Right_TO_UUID AS b
  FROM RelationshipCatalog r JOIN self s ON r.File_Name = s.File_Name
),
undirected AS (
  SELECT Rel_ID, a AS from_to, b AS to_to FROM edges
  UNION ALL
  SELECT Rel_ID, b, a FROM edges
),
walk(node, depth, path_nodes, path_rels) AS (
  SELECT s.TO_UUID, 0, [s.TO_UUID], CAST([] AS BIGINT[])
  FROM self s
  UNION ALL
  SELECT u.to_to, w.depth + 1, list_append(w.path_nodes, u.to_to), list_append(w.path_rels, u.Rel_ID)
  FROM walk w
  JOIN undirected u ON u.from_to = w.node
  WHERE NOT list_contains(w.path_nodes, u.to_to)
    AND w.depth < 200
),
-- one row per TO of the group (shortest walk wins — in a forest there is only one)
grp AS (
  SELECT node, min(depth) AS depth, arg_min(path_nodes, depth) AS path_nodes, arg_min(path_rels, depth) AS path_rels
  FROM walk GROUP BY node
),
layouts AS (
  SELECT g.node, count(DISTINCT ol.Source_UUID) AS n_layouts
  FROM grp g
  JOIN self s ON TRUE
  JOIN ObjectLinks ol
    ON ol.Target_UUID = g.node AND ol.Target_File = s.File_Name
   AND ol.Link_Role = 'context_table' AND ol.Source_Type = 'Layout'
  GROUP BY g.node
),
anchors AS (
  SELECT g.node, g.depth, g.path_nodes, g.path_rels, l.n_layouts, t.TO_Name,
         row_number() OVER (ORDER BY g.depth, l.n_layouts DESC, t.TO_Name) AS rank_by_distance
  FROM grp g
  JOIN layouts l ON l.node = g.node
  JOIN self s ON TRUE
  JOIN TableOccurrenceCatalog t ON t.TO_UUID = g.node AND t.File_Name = s.File_Name
),
nearest AS (
  SELECT * FROM anchors
  WHERE depth = (SELECT min(depth) FROM anchors)
    AND rank_by_distance <= 3
),
-- path from the anchor to this occurrence: reverse the walk (which started here)
path_steps AS (
  SELECT
    n.rank_by_distance AS path_no,
    st.i - 1 AS step_index,
    list_reverse(n.path_nodes)[st.i] AS to_uuid,
    CASE WHEN st.i > 1 THEN list_reverse(n.path_rels)[st.i - 1] END AS hop_rel_id,
    CASE WHEN st.i > 1 THEN list_reverse(n.path_nodes)[st.i - 1] END AS prev_to_uuid
  FROM nearest n,
       LATERAL (SELECT unnest(range(1, len(n.path_nodes) + 1)) AS i) st
),
-- label of the hop arriving at a step: the join fields read from the previous TO's side;
-- identical names on both sides collapse to one ("Artikel Nr" instead of "Artikel Nr = Artikel Nr")
hop_labels AS (
  SELECT
    p.path_no, p.step_index,
    string_agg(
      CASE
        WHEN (CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Left_Field_Name ELSE r.Right_Field_Name END)
           = (CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Right_Field_Name ELSE r.Left_Field_Name END)
          THEN CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Left_Field_Name ELSE r.Right_Field_Name END
        ELSE coalesce(CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Left_Field_Name ELSE r.Right_Field_Name END, '#' || CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Left_Field_ID ELSE r.Right_Field_ID END)
          || ' = '
          || coalesce(CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Right_Field_Name ELSE r.Left_Field_Name END, '#' || CASE WHEN r.Left_TO_UUID = p.prev_to_uuid THEN r.Right_Field_ID ELSE r.Left_Field_ID END)
      END,
      ', ' ORDER BY r.Predicate_Index) AS hop_label
  FROM path_steps p
  JOIN self s ON TRUE
  JOIN RelationshipCatalog r ON r.Rel_ID = p.hop_rel_id AND r.File_Name = s.File_Name
  GROUP BY p.path_no, p.step_index
)

SELECT * EXCLUDE (order_hint) FROM (
  SELECT
    'group' AS section,
    0 AS order_hint,
    (SELECT count(*) FROM grp) AS group_size,
    (SELECT coalesce(sum(n_layouts), 0) FROM layouts) AS group_layouts,
    (SELECT count(*) FROM anchors) AS anchor_count,
    coalesce((SELECT l.n_layouts FROM layouts l, self s WHERE l.node = s.TO_UUID), 0) AS self_layouts,
    (SELECT min(depth) FROM anchors) AS nearest_distance,
    CAST(NULL AS VARCHAR) AS to_uuid, CAST(NULL AS VARCHAR) AS to_name,
    CAST(NULL AS BIGINT) AS n_layouts, CAST(NULL AS BIGINT) AS distance,
    CAST(NULL AS BIGINT) AS path_no, CAST(NULL AS BIGINT) AS step_index,
    CAST(NULL AS BIGINT) AS hop_rel_id, CAST(NULL AS VARCHAR) AS hop_rel_uuid, CAST(NULL AS VARCHAR) AS hop_label
  FROM self

  UNION ALL

  SELECT
    'anchor', 1,
    NULL, NULL, NULL, NULL, NULL,
    a.node, a.TO_Name, a.n_layouts, a.depth,
    NULL, NULL, NULL, NULL, NULL
  FROM anchors a

  UNION ALL

  SELECT
    'path_step', 2,
    NULL, NULL, NULL, NULL, NULL,
    p.to_uuid, t.TO_Name, NULL, NULL,
    p.path_no, p.step_index,
    p.hop_rel_id, roc.Object_UUID, h.hop_label
  FROM path_steps p
  JOIN self s ON TRUE
  JOIN TableOccurrenceCatalog t ON t.TO_UUID = p.to_uuid AND t.File_Name = s.File_Name
  LEFT JOIN hop_labels h ON h.path_no = p.path_no AND h.step_index = p.step_index
  LEFT JOIN ObjectCatalog roc
    ON roc.Object_Type = 'Relationship' AND roc.Object_ID = p.hop_rel_id AND roc.File_Name = s.File_Name
)
ORDER BY order_hint, n_layouts DESC NULLS LAST, distance NULLS LAST, to_name, path_no, step_index;
