-- @template_type: report
-- @title: Graph Atlas — Topology Meta-Graph (Super-Nodes + Inter-Segment-Kanten)
-- @description: Topologie-Achse des Graph-Atlas — 1 Super-Node je Segment (Community/Datei), Kanten = aggregierte Kopplung
-- @params: weight, segment_by, include_builtins, activity, activity_bulk
-- @version: 1.0.0
-- @author: Marcel / Claude
-- @tags: graph, atlas, overview, meta-graph, topology
-- @note: Endpoint /api/graph/overview (view=topology). Nur segment_by=community|file.
--        Cytoscape-fertig: getaggte Union (row_kind='node'|'edge'), die der Service partitioniert
--        — analog graph_subgraph.sql. Top-K/„Rest"-Faltung der Super-Nodes übernimmt der Service.
--
-- ============================================================================
-- PARAMETER
-- ============================================================================
--   weight            'domain' (ClusterEdges) | 'logical' (LogicalLinks)  (Default 'domain')
--   segment_by        'community' | 'file'                                (Default 'community')
--   include_builtins  BOOL — nur bei weight='logical' relevant            (Default FALSE)
--   activity          BOOL — Änderungs-Aktivität mitrechnen (Farbmodi des Atlas)   (Default FALSE)
--   activity_bulk     'hide' | 'include' — Massenstempel datieren die letzte Änderung (Default 'hide')
--
-- AUSGABE — getaggte Union:
--   row_kind='node' → key, label, member_count, weight, color_type, top_member_uuid, top_member_file
--                     + Änderungs-Aktivität der Mitglieder (shared activity block): activity_class,
--                     class_counts, newest_change, newest_age_days, active_90, median_age_days,
--                     median_saves, stamped, undated, saves_level, saves_sum, saves_n, data_state
--   row_kind='edge' → source, target, weight   (ungerichtet, least/greatest-normalisiert)
-- Inter-Segment-Kanten kommen IMMER aus ClusterEdges (Domänen-Kopplung), unabhängig vom
-- Knoten-Gewicht — sie sind das Topologie-Signal des Atlas.
-- ============================================================================

WITH
-- ClusterEdges genau einmal materialisieren — wird sowohl für den Knoten-Grad (deg, bei
-- weight=domain) ALS AUCH für die Inter-Segment-Kanten (immer Domänen-Kopplung) gebraucht.
-- Mehrfach-Scan der teuren View-Kette → OOM bei 8 Threads/2GB.
ce AS MATERIALIZED (
  SELECT Source_UUID AS s, Source_File AS sf, Target_UUID AS t, Target_File AS tf FROM ClusterEdges
),
-- Aktive Kanten-Sicht für den Knoten-Grad (domain ← ce, logical ← LogicalLinks).
edges AS MATERIALIZED (
  SELECT s, sf, t, tf FROM ce WHERE getvariable('weight') = 'domain'
  UNION ALL
  SELECT Source_UUID, Source_File, Target_UUID, Target_File
    FROM LogicalLinks WHERE getvariable('weight') = 'logical'
),
deg AS MATERIALIZED (
  SELECT uuid, file, COUNT(*) AS w FROM (
    SELECT s AS uuid, sf AS file FROM edges
    UNION ALL SELECT t, tf FROM edges
  ) GROUP BY ALL
),
node AS MATERIALIZED (
  -- Object_Name ungenutzt (Labels: CommunityNames bzw. Datei-Key) → kleinerer Peak.
  SELECT d.uuid, d.file, d.w,
         oc.Object_Type,
         cl.Community, cl.Engine
  FROM deg d
  LEFT JOIN ObjectCatalog  oc ON oc.Object_UUID = d.uuid AND oc.File_Name IS NOT DISTINCT FROM d.file
  LEFT JOIN ObjectClusters cl ON cl.Object_UUID = d.uuid AND cl.File_Name IS NOT DISTINCT FROM d.file
  WHERE (getvariable('weight') = 'domain'
     OR getvariable('include_builtins') = TRUE
     OR oc.Object_Type <> 'BuiltinFunction')
    AND (getvariable('exclude_types') IS NULL
         OR oc.Object_Type NOT IN (SELECT unnest(string_split(CAST(getvariable('exclude_types') AS VARCHAR), ','))))
),
-- ── Super-Nodes: 1 je Segment ───────────────────────────────────────────────
nodes_community AS (
  SELECT
    CAST(n.Community AS VARCHAR)                                        AS key,
    COALESCE(any_value(cn.Semantic_Name), any_value(cn.Heuristic_Name),
             'Community ' || CAST(n.Community AS VARCHAR))              AS label,
    COUNT(*)                                                           AS member_count,
    SUM(n.w)                                                           AS weight,
    COALESCE(any_value(cn.Dominant_Type), arg_max(n.Object_Type, n.w)) AS color_type,
    arg_max(n.uuid, n.w)                                               AS top_member_uuid,
    arg_max(n.file, n.w)                                               AS top_member_file
  FROM node n
  LEFT JOIN CommunityNames cn ON cn.Community = n.Community AND cn.Engine = n.Engine
  WHERE getvariable('segment_by') = 'community' AND n.Community IS NOT NULL
  GROUP BY n.Community
),
nodes_file AS (
  SELECT
    n.file                                AS key,
    n.file                                AS label,
    COUNT(*)                              AS member_count,
    SUM(n.w)                              AS weight,
    arg_max(n.Object_Type, n.w)           AS color_type,
    arg_max(n.uuid, n.w)                  AS top_member_uuid,
    arg_max(n.file, n.w)                  AS top_member_file
  FROM node n
  WHERE getvariable('segment_by') = 'file' AND n.file IS NOT NULL
  GROUP BY n.file
),
seg_nodes AS (
  SELECT * FROM nodes_community
  UNION ALL
  SELECT * FROM nodes_file
),
-- ── Änderungs-Aktivität je Super-Node (Farbmodi des Atlas) ──────────────────
-- >>> shared overview activity input block — identical in the three overview
-- templates (unit test activity-block guards it); change it in all files at once.
--   activity_input  every change stamp with the curated technical flag of the alias
--                   overlay (v_change_meta_authors). activity_bulk=include lets a
--                   mass stamp date the last change like an individual one. Only with
--                   activity=TRUE (the Atlas colours by activity or saves): the block
--                   costs ~10–15 ms, the type colouring needs none of it — without it
--                   every tile gets class 7 and the service drops the columns
activity_input AS (
  SELECT m.Object_UUID, m.File_Name, m.Object_Type, m.Modified_At, m.Modifications,
         m.Bulk_Event_ID IS NULL
           AND NOT COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL)            AS Is_Individual,
         COALESCE(CAST(getvariable('activity_bulk') AS VARCHAR), 'hide') = 'include'
           OR (m.Bulk_Event_ID IS NULL
               AND NOT COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL))       AS Age_Known
  FROM ObjectChangeMeta m
  LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
  WHERE m.Modified_At IS NOT NULL
    AND COALESCE(CAST(getvariable('activity') AS BOOLEAN), FALSE)
)
-- <<< shared overview activity input block
,
activity_members AS (
  SELECT CASE WHEN getvariable('segment_by') = 'community' THEN CAST(n.Community AS VARCHAR)
              ELSE n.file END                       AS Group_Key,
         n.uuid                                     AS Object_UUID,
         n.file                                     AS File_Name
  FROM node n
  WHERE COALESCE(CAST(getvariable('activity') AS BOOLEAN), FALSE)
),
-- >>> shared activity block — identical in every dataset, graph overview template
-- and skill script that classifies change activity (unit test activity-block guards
-- it); change it in all files at once.
--   activity_input    defined by each carrier right before: one row per stamped
--                     object — Object_UUID, File_Name, Object_Type, Modified_At,
--                     Modifications, Is_Individual (no mass event, no technical
--                     author) and Age_Known (the stamp dates the last real change:
--                     Is_Individual, or every stamp when mass events are included)
--   activity_members  defined by each carrier right before: Group_Key, Object_UUID,
--                     File_Name — the members of every tile or module; a member
--                     without stamp counts as "no stamp"
--   activity_anchor   the data state: newest individual change, else newest stamp
--   activity_nodes    class per stamped object: 1 ≤ 30 days · 2 ≤ 90 days · 3 ≤ 1 year
--                     · 4 ≤ 2 years · 5 > 2 years · 6 unknown. A stamp that does not
--                     date the last real change (mass event, technical author) only
--                     bounds it from above: older than 2 years → 5, else unknown,
--                     never young. saves_rank = mid-rank of the lifetime save counter
--                     within the object type, solution-wide: (percent_rank + cume_dist)
--                     / 2, so ties share the middle of their range and a filter never
--                     moves it (activity_ranks computes it over the distinct counter
--                     values of each type — a window over every stamp costs ~10× more)
--   activity_groups   per Group_Key: activity_class = the youngest class of a member
--                     (6 = only unknown members, 7 = no member with a stamp),
--                     class_counts = members per class 1…7, newest_change and its age,
--                     active_90 (members with a dated change ≤ 90 days), median age
--                     and saves, undated (stamped members whose stamp is undated),
--                     saves_level 1…5 from the mean saves_rank (limits 0.3 · 0.4 · 0.5
--                     · 0.6), and saves_sum/saves_n to merge groups
activity_anchor AS (
    SELECT COALESCE(max(ai.Modified_At) FILTER (WHERE ai.Is_Individual),
                    max(ai.Modified_At))                               AS anchor_at
    FROM activity_input ai
),
activity_ranks AS (
    SELECT v.Object_Type, v.saves,
           ((CASE WHEN v.n > 1 THEN v.below / (v.n - 1) ELSE 0 END) + (v.below + v.c) / v.n) / 2
                                                                       AS saves_rank
    FROM (
        SELECT g.Object_Type, g.saves, g.c,
               sum(g.c) OVER (PARTITION BY g.Object_Type ORDER BY g.saves) - g.c AS below,
               sum(g.c) OVER (PARTITION BY g.Object_Type)                    AS n
        FROM (SELECT ai.Object_Type, COALESCE(ai.Modifications, 0) AS saves, count(*) AS c
                FROM activity_input ai
               GROUP BY ai.Object_Type, COALESCE(ai.Modifications, 0)) g
    ) v
),
activity_nodes AS (
    SELECT
        ai.Object_UUID, ai.File_Name, ai.Object_Type, ai.Modified_At, ai.Modifications,
        ai.Is_Individual, ai.Age_Known,
        date_diff('day', ai.Modified_At, aa.anchor_at)                 AS age_days,
        CASE
            WHEN NOT ai.Age_Known
                 AND ai.Modified_At >= aa.anchor_at - INTERVAL 730 DAY   THEN 6
            WHEN ai.Modified_At >= aa.anchor_at - INTERVAL 30 DAY       THEN 1
            WHEN ai.Modified_At >= aa.anchor_at - INTERVAL 90 DAY       THEN 2
            WHEN ai.Modified_At >= aa.anchor_at - INTERVAL 365 DAY      THEN 3
            WHEN ai.Modified_At >= aa.anchor_at - INTERVAL 730 DAY      THEN 4
            ELSE 5
        END                                                            AS activity_class,
        ar.saves_rank
    FROM activity_input ai
    CROSS JOIN activity_anchor aa
    JOIN activity_ranks ar
      ON ar.Object_Type = ai.Object_Type AND ar.saves = COALESCE(ai.Modifications, 0)
),
activity_groups AS (
    SELECT
        am.Group_Key,
        CAST(count(*) AS INTEGER)                                      AS members,
        CAST(COALESCE(min(an.activity_class),  7) AS INTEGER)          AS activity_class,
        [CAST(count(*) FILTER (WHERE an.activity_class = 1) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class = 2) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class = 3) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class = 4) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class = 5) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class = 6) AS INTEGER),
         CAST(count(*) FILTER (WHERE an.activity_class IS NULL) AS INTEGER)] AS class_counts,
        strftime(max(an.Modified_At) FILTER (WHERE an.Age_Known), '%Y-%m-%d %H:%M:%S') AS newest_change,
        CAST(min(an.age_days) FILTER (WHERE an.Age_Known) AS INTEGER)  AS newest_age_days,
        CAST(count(*) FILTER (WHERE an.Age_Known AND an.activity_class <= 2) AS INTEGER) AS active_90,
        CAST(round(median(an.age_days) FILTER (WHERE an.Age_Known)) AS INTEGER) AS median_age_days,
        CAST(round(median(an.Modifications)) AS INTEGER)               AS median_saves,
        CAST(count(an.Object_UUID) AS INTEGER)                         AS stamped,
        CAST(count(*) FILTER (WHERE NOT an.Age_Known) AS INTEGER)      AS undated,
        CASE WHEN count(an.saves_rank) = 0 THEN NULL
             WHEN avg(an.saves_rank) > 0.6 THEN 5
             WHEN avg(an.saves_rank) > 0.5 THEN 4
             WHEN avg(an.saves_rank) > 0.4 THEN 3
             WHEN avg(an.saves_rank) > 0.3 THEN 2
             ELSE 1 END                                                AS saves_level,
        sum(an.saves_rank)                                             AS saves_sum,
        CAST(count(an.saves_rank) AS INTEGER)                          AS saves_n
    FROM activity_members am
    LEFT JOIN activity_nodes an
           ON an.Object_UUID = am.Object_UUID AND an.File_Name = am.File_Name
    GROUP BY am.Group_Key
)
-- <<< shared activity block
,
-- ── Inter-Segment-Kanten aus ClusterEdges (ungerichtet, normalisiert) ───────
edges_community AS (
  SELECT
    CAST(least(a.Community, b.Community) AS VARCHAR)    AS source,
    CAST(greatest(a.Community, b.Community) AS VARCHAR) AS target,
    COUNT(*)                                           AS weight
  FROM ce e
  JOIN ObjectClusters a ON a.Object_UUID = e.s AND a.File_Name IS NOT DISTINCT FROM e.sf
  JOIN ObjectClusters b ON b.Object_UUID = e.t AND b.File_Name IS NOT DISTINCT FROM e.tf
  WHERE getvariable('segment_by') = 'community'
    AND a.Community IS NOT NULL AND b.Community IS NOT NULL
    AND a.Community <> b.Community
  GROUP BY 1, 2
),
edges_file AS (
  SELECT
    least(e.sf, e.tf)    AS source,
    greatest(e.sf, e.tf) AS target,
    COUNT(*)             AS weight
  FROM ce e
  WHERE getvariable('segment_by') = 'file'
    AND e.sf IS NOT NULL AND e.tf IS NOT NULL
    AND e.sf <> e.tf
  GROUP BY 1, 2
),
seg_edges AS (
  SELECT * FROM edges_community
  UNION ALL
  SELECT * FROM edges_file
)
-- ── getaggte Ausgabe ────────────────────────────────────────────────────────
SELECT
  'node'            AS row_kind,
  sn.key,
  sn.label,
  sn.member_count,
  sn.weight,
  sn.color_type,
  sn.top_member_uuid,
  sn.top_member_file,
  NULL              AS source,
  NULL              AS target,
  ag.activity_class, ag.class_counts, ag.newest_change, ag.newest_age_days,
  ag.active_90, ag.median_age_days, ag.median_saves, ag.stamped, ag.undated,
  ag.saves_level, ag.saves_sum, ag.saves_n,
  (SELECT strftime(aa.anchor_at, '%Y-%m-%d %H:%M') FROM activity_anchor aa) AS data_state
FROM seg_nodes sn
LEFT JOIN activity_groups ag ON ag.Group_Key = sn.key
UNION ALL
SELECT
  'edge'            AS row_kind,
  NULL              AS key,
  NULL              AS label,
  NULL              AS member_count,
  weight,
  NULL              AS color_type,
  NULL              AS top_member_uuid,
  NULL              AS top_member_file,
  source,
  target,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM seg_edges
ORDER BY row_kind, weight DESC;
