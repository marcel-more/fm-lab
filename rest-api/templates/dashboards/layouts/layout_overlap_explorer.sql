-- @template_type: report
-- @title: Layout object overlaps
-- @description: Pairwise overlaps between sibling objects on a layout, with stack order and overlap area, largest area first. An inventory, not a defect list — most overlaps are deliberate design (a text on its background rectangle, a graphic inside a grouped button). The telling cases are congruent pairs of the same type and large objects fully covered by a sibling. The relation chips filter server-side across the whole scope, as do same_type and min_overlap_pct (default 10 %, hiding objects that merely graze each other).
-- @icon: layers
-- @display: table
-- @chip_filter: relation
-- @chip_param: relation
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional), relation (optional: identical|contained|partial), same_type (optional: 1 = only pairs of the same object type), min_overlap_pct (optional, default 10)
-- @click_action: openObject
-- @click_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_a_uuid}}&marks={{_object_b_uuid}}
-- @output_format: file_name, layout_name, part_type, object_a, type_a, z_a, object_b, type_b, z_b, overlap_px, overlap_pct, relation, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "overlap_pairs", "meaning": "Overlapping sibling pairs (inventory — overlaps are common by design, not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, geometry, overlap, layout_quality
--
-- Pairing rule, deliberately identical to the stacked-duplicate rule: objects
-- are compared only against their SIBLINGS — same layout, same parent container
-- and same part. Coordinates are parent-relative, so comparing across nesting
-- levels would be meaningless. Tab panels and popover panels are excluded
-- entirely: they occupy the same rectangle as their neighbours by definition.
-- Keeping the criteria in sync means the stacked-duplicate rule is exactly the
-- `relation = identical` + `same_type = 1` slice of this inventory.
--
-- `overlap_pct` relates the intersection to the SMALLER of the two objects,
-- which is what makes it readable: 100 % means the smaller object is completely
-- covered by (or congruent with) the larger one.
--
-- Ordering is by overlap AREA, not by percentage: a large object buried under
-- a sibling matters more than a tiny one covered to 100 %. It also keeps the
-- loaded page mixed across all three relations instead of filling it with
-- 100 % pairs, which is what makes the page itself readable.
--
-- `min_overlap_pct` defaults to 10: below that, objects are neighbours that
-- graze each other rather than a stack (measured on a large solution, roughly
-- one pair in six is such a graze). The self-join itself is cheap — well under
-- a second over 165k objects — so no layout filter is enforced; scope, the
-- filters and the limit shape the result instead.
--
-- The relation chips switch SERVER-SIDE (`@chip_param: relation`) and carry the
-- true counts of the whole scope — which matters here more than anywhere else,
-- since 93k pairs against a 500-row page would otherwise turn the chips into a
-- sample of half a percent. `_chip_facets` counts over `result` — every filter
-- EXCEPT the search and the relation itself, otherwise each chip would only ever show its own
-- selection — while `_row_total` counts over `filtered`, i.e. WITH that filter, so
-- the header names the truncation and only then.
--
-- Row click highlights BOTH partners: `ref` carries the first object (which
-- also drives the origin pill and its dismiss/ESC path), `marks` adds the
-- second one as a literal UUID. The detail view unions the two into one
-- highlight set — an overlap only makes sense when you see both objects.
WITH sib AS (
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_ID, lo.Object_UUID, lo.Object_Type,
           lo.Object_Name, lo.Parent_Object_ID, lo.Part_Type, lo.Z_Order,
           lo.Bounds_Left AS bl, lo.Bounds_Top AS bt, lo.Bounds_Right AS br, lo.Bounds_Bottom AS bb
    FROM LayoutObjects lo
    WHERE lo.Object_Type NOT IN ('Panel', 'PopoverPanel')
),
pairs AS (
    SELECT
        a.File_Name, a.Layout_ID, a.Part_Type,
        a.Object_UUID AS object_a_uuid, a.Object_Name AS object_a, a.Object_Type AS type_a, a.Z_Order AS z_a,
        b.Object_UUID AS object_b_uuid, b.Object_Name AS object_b, b.Object_Type AS type_b, b.Z_Order AS z_b,
        (a.Object_Type = b.Object_Type) AS same_type,
        (LEAST(a.br, b.br) - GREATEST(a.bl, b.bl))
          * (LEAST(a.bb, b.bb) - GREATEST(a.bt, b.bt)) AS overlap_px,
        LEAST((a.br - a.bl) * (a.bb - a.bt), (b.br - b.bl) * (b.bb - b.bt)) AS smaller_px,
        (a.bl = b.bl AND a.bt = b.bt AND a.br = b.br AND a.bb = b.bb) AS congruent
    FROM sib a
    JOIN sib b
      ON a.File_Name = b.File_Name
     AND a.Layout_ID = b.Layout_ID
     AND COALESCE(a.Parent_Object_ID, -1) = COALESCE(b.Parent_Object_ID, -1)
     AND a.Part_Type IS NOT DISTINCT FROM b.Part_Type
     AND a.Object_ID < b.Object_ID
    -- Overlap means a shared AREA; touching edges do not count. Congruent
    -- pairs are admitted separately so that zero-extent objects (lines) still
    -- appear when they sit exactly on top of each other — that is a real
    -- stacking finding even though the intersection area is 0 px².
    WHERE (a.bl < b.br AND b.bl < a.br AND a.bt < b.bb AND b.bt < a.bb)
       OR (a.bl = b.bl AND a.bt = b.bt AND a.br = b.br AND a.bb = b.bb)
),
classified AS (
    SELECT p.*,
        CASE WHEN p.congruent THEN 'identical'
             WHEN p.smaller_px > 0 AND p.overlap_px >= p.smaller_px THEN 'contained'
             ELSE 'partial' END AS relation,
        -- Congruent zero-extent pairs cover each other completely; reporting
        -- 0 % for them (0 px² / 0 px²) would read as "barely overlapping".
        CASE WHEN p.congruent THEN 100.0
             WHEN p.smaller_px > 0 THEN ROUND(100.0 * p.overlap_px / p.smaller_px, 1)
             ELSE 0 END AS overlap_pct
    FROM pairs p
)
-- The three UUID columns carry an underscore prefix on purpose: they exist
-- only to feed the row-click deep link, and the table primitive hides
-- underscore-prefixed columns. Without that the widest columns in the result
-- would be three opaque identifiers.
, result AS MATERIALIZED (
    SELECT
        c.File_Name AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        c.Part_Type AS part_type,
        COALESCE(NULLIF(trim(c.object_a), ''), '(unnamed)') AS object_a, c.type_a, c.z_a,
        COALESCE(NULLIF(trim(c.object_b), ''), '(unnamed)') AS object_b, c.type_b, c.z_b,
        c.overlap_px, c.overlap_pct, c.relation,
        -- One-line summary of the pair: the tests tab renders findings by their
        -- _message column, and the individual columns only exist in the table view.
        c.type_a || ' ' || COALESCE(NULLIF(trim(c.object_a), ''), '(unnamed)') || ' (z ' || c.z_a || ')'
          || ' / ' || c.type_b || ' ' || COALESCE(NULLIF(trim(c.object_b), ''), '(unnamed)') || ' (z ' || c.z_b || ')'
          || ' — ' || c.relation || ', ' || c.overlap_pct || ' % of the smaller object' AS _message,
        c.object_a_uuid AS _object_a_uuid,
        c.object_b_uuid AS _object_b_uuid
    FROM classified c
    JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
    WHERE (getvariable('same_type') IS NULL OR getvariable('same_type') = '' OR c.same_type)
      AND c.overlap_pct >= CAST(COALESCE(getvariable('min_overlap_pct'), '10') AS DOUBLE)
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- >>> shared paging search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) <> 'uuid'))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging search block
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('relation') IS NULL OR relation = getvariable('relation'))
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((relation, n) ORDER BY relation)))
       FROM (SELECT relation, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ overlap_px DESC, overlap_pct DESC, file_name, layout_name, _object_a_uuid, _object_b_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
