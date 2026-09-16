-- @template_type: report
-- @title: Layout symbol inventory
-- @description: Every {{…}} symbol placed in a layout text object, one row per text object × symbol with its occurrence count and whether the standard reference knows it as a Get parameter. Grouped by the CANONICAL Get parameter, so the German {{Seitennummer}} and the English {{PageNumber}} count as one symbol; the `typed` column keeps the spelling the developer actually wrote. A symbol is the value of Get(<Symbol>) at display time; FileMaker serialises the five menu symbols and everything from "Other Symbol…" the same way, and renders an unknown one literally. Symbols carry no where-used edges by design, so this inventory is the only place they become countable. The defect slice — symbols the reference does not know — is the rule "Invalid layout symbol"; merge fields (<<Field>>), merge variables (<<$$var>>) and layout calculations (<<ƒ:…>>) have their own inventories.
-- @icon: text-quote
-- @category: Layouts
-- @display: table
-- @chip_filter: symbol
-- @chip_param: symbol
-- @params: file (optional), limit (optional, default 2000), symbol (optional)
-- @click_action: openObject
-- @click_args: uuid={{_object_uuid}}&ref={{_nav_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_uuid}}
-- @row_action_label: Show in layout
-- @output_format: file_name, layout_name, object_name, symbol, typed, occurrences, status, _message, _chip_facets, _row_total
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "layout_symbols", "meaning": "Symbol placements on layout text objects in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, merge, symbols, inventory
--
-- Companion of the merge-field, merge-variable and layout-calculation
-- inventories: same shape, same scope model. Source is LayoutObjectSymbols
-- (P3 A.13) — the resolved inventory; never re-regex Text_Content.
--
-- `status` is the same comparison the rule uses: Symbol_Norm against
-- ref.function_name_lookup, chunk_role 'getparameter', over ALL languages the
-- reference covers (FileMaker accepts the localized parameter name too). The
-- reference's localized coverage is uneven, so 'unknown' is a hint, not a
-- verdict — hence this column instead of a filter.
--
-- Why the comparison and not the edge: since converter 2.28.0 P4 writes a
-- `displays_symbol` edge for every VALID symbol, so "symbol without edge" would
-- look like the cheaper test. It is not — on a catalog imported by an older
-- converter it reports every symbol as invalid. The reference comparison is the
-- source of truth either way and works on a catalog of any converter version.
--
-- The symbol chips switch SERVER-SIDE (`@chip_param: symbol`) over the whole
-- scope. `_chip_facets` counts over `base` — every filter EXCEPT the symbol
-- itself — while `_row_total` counts over `sel` (WITH that filter).
--
-- The chip key is the CANONICAL Get parameter, not the typed spelling: FileMaker
-- accepts the localized parameter name as a symbol, so one parameter otherwise
-- splits into one chip per language of whoever placed it — on a German solution
-- {{PageNumber}} (322) and {{Seitennummer}} (2) instead of one symbol with 324
-- placements, which is also exactly what the catalog resolves them to (one
-- BuiltinFunction node `Get(PageNumber)`, one `displays_symbol` edge each).
-- `typed` keeps the authored spelling per row — that is where an inconsistent
-- spelling stays visible, and sorting by it groups the odd ones out. A symbol
-- the reference does not know has no canonical name and keeps its typed
-- spelling as the chip key: unknown symbols must NOT collapse into one bucket,
-- they are individually the finding.
--
-- The default limit is 2000, not the usual 500 of the inventory family. Reason
-- measured, not guessed: symbol placements are the rarest merge grain — 577 rows
-- on a 57-file, 2.8 GB solution and 281 on a 1.1 GB one. At 500 the tail is cut
-- off, and because the table searches and sorts the LOADED page client-side, a
-- symbol beyond the cut is invisible to both: searching "Seite" for the two
-- {{Seitennummer}} rows at rank 566/567 returns nothing, and no sort order
-- brings them back (the two rows are the {{Seitennummer}} spelling, which the
-- canonical chip {{PageNumber}} now reaches server-side — but a text search over
-- a truncated page still cannot). Chips keep working because they filter
-- server-side. 2000
-- covers a corpus three times the largest measured one at ~300 KB of payload;
-- beyond that the truncation notice and the chips remain the fallback.
WITH lo AS (
    -- LayoutObjects can carry duplicate rows per (Object_UUID, File_Name).
    SELECT Object_UUID, Object_ID, File_Name, Object_Name, Object_Type,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
),
-- Symbol_Norm → kanonischer Get-Parameter, über ALLE Referenzsprachen. Eine
-- Zeile je Vergleichsschlüssel: innerhalb chunk_role 'getparameter' zeigt eine
-- Schreibweise auf genau eine Funktion (in der Referenz geprüft: 0 mehrdeutige
-- Namen), das min() ist nur Determinismus. Dieselbe Menge, die `status`
-- auswertet — der Join ersetzt also das EXISTS, er kommt nicht dazu.
getparam AS (
    SELECT lower(l.lookup_name) AS symbol_norm,
           min(f.canonical_name) AS canonical_name
    FROM ref.function_name_lookup l
    JOIN ref.functions f USING (function_id)
    WHERE l.chunk_role = 'getparameter'
      AND l.lookup_name IS NOT NULL AND l.lookup_name <> ''
    GROUP BY 1
),
base AS (
    SELECT
        s.File_Name AS file_name,
        ly.L_UUID   AS _nav_uuid,
        ly.L_Name   AS layout_name,
        COALESCE(NULLIF(trim(o.Object_Name), ''), '(unnamed)') AS object_name,
        -- Chip-Schlüssel: kanonischer Parameter, Fallback die getippte Form
        '{{' || COALESCE(g.canonical_name, s.Symbol_Text) || '}}' AS symbol,
        s.Symbol_Text AS typed,
        s.Occurrence_Count AS occurrences,
        CASE WHEN g.canonical_name IS NOT NULL THEN 'known' ELSE 'unknown' END AS status,
        o.Object_Type || ' ' || COALESCE(NULLIF(trim(o.Object_Name), ''), '(unnamed)')
          || ' — symbol {{' || s.Symbol_Text || '}}' AS _message,
        o.Object_UUID AS _object_uuid
    FROM LayoutObjectSymbols s
    JOIN lo o       ON o.Object_UUID = s.Object_UUID AND o.File_Name = s.File_Name AND o.rn = 1
    JOIN Layouts ly ON ly.L_ID = s.Layout_ID AND ly.File_Name = s.File_Name
    LEFT JOIN getparam g ON g.symbol_norm = s.Symbol_Norm
    WHERE (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
sel AS (
    SELECT * FROM base
    WHERE (getvariable('symbol') IS NULL OR symbol = getvariable('symbol'))
)
SELECT s.*,
    (SELECT json_group_object(symbol, n)
       FROM (SELECT symbol, count(*) AS n FROM base GROUP BY 1)) AS _chip_facets,
    (SELECT count(*) FROM sel) AS _row_total
FROM sel s
ORDER BY file_name, layout_name, object_name, symbol, typed
LIMIT CAST(COALESCE(getvariable('limit'), '2000') AS INTEGER);
