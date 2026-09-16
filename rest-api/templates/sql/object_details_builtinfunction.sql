-- @template_type: report
-- @description: Structured detail of a built-in FileMaker function - identity (canonical + localized spelling, reference id) and the where-used summary per link role and source type
-- @params: uuid (required), lang (optional)
-- @output_format: json
-- @author: Marcel
-- @version: 2.0
-- @tags: builtinfunction, details, reference
-- @note: Synthetic ObjectCatalog entry (file-independent). Object_Name is the
--        CANONICAL English reference name since catalog schema 1.32.0 ('Length',
--        'Get(PageNumber)') - language-independent by design, because that is the
--        node's identity. `lang` adds the localized spelling NEXT TO it (never
--        instead of it): a German developer reads 'Hole ( Seitennummer )' but must
--        still be able to recognize which node they are on. Resolved by LOOKUP -
--        BuiltinFunctionIdentity.Function_ID -> ref.functions_lang - never from the
--        name. Without `lang`, without an identity row (name fallback) or without a
--        reference entry only the canonical name is shown.
--
--        Flat rows with a `section` discriminator:
--          'meta'  -> one row: catalog name, localized spelling, reference
--                     function_id + namespace (NULL when the node carries no
--                     identity row), plus the where-used totals.
--          'usage' -> one row per (link role x source type): distinct source
--                     objects, distinct files and total occurrences.
--        The caller LIST is deliberately NOT part of this projection - the
--        References tab is its home (every inbound edge, navigable). The summary
--        counts every operational inbound edge, so merge-field usage
--        (`displays_symbol`) is included next to `calls_function`.
--
--        `function_id` is the join key into the reference layer: the view links
--        into the fm-spec browser (/fm-spec/function/<id>) and the Claris help
--        page from it - both resolved client-side via /api/reference/functions.

WITH self AS (
  SELECT oc.Object_UUID, oc.Object_Type, oc.Object_Name, oc.Source_Table,
         bfi.Function_ID, bfi.Canonical_Name, bfi.Namespace
  FROM ObjectCatalog oc
  LEFT JOIN BuiltinFunctionIdentity bfi ON bfi.Object_UUID = oc.Object_UUID
  WHERE oc.Object_UUID = getvariable('uuid')
    AND oc.Object_Type = 'BuiltinFunction'
  LIMIT 1
),
-- Lokalisierte Schreibweise der aktiven UI-Sprache. NULL, wenn keine Sprache
-- übergeben wurde, die Referenz die Funktion nicht kennt, oder der lokalisierte
-- Name mit dem kanonischen übereinstimmt (dann wäre die Dopplung nur Rauschen).
localized AS (
  SELECT NULLIF(trim(fl.display_name), '') AS display_name
  FROM self s
  JOIN ref.functions_lang fl
    ON fl.function_id = s.Function_ID
   AND fl.language = getvariable('lang')
  WHERE getvariable('lang') IS NOT NULL
    AND NULLIF(trim(fl.display_name), '') IS NOT NULL
    AND regexp_replace(trim(fl.display_name), '\s+', '', 'g')
        <> regexp_replace(trim(s.Object_Name), '\s+', '', 'g')
),
-- Jede operationale Eingangskante (Link_Type='operational') ist eine Verwendung;
-- BuiltinFunction-Knoten kennen keine anderen Eingangsrollen.
usages AS (
  SELECT
    ol.Link_Role,
    src.Object_Type AS used_by_type,
    src.Object_UUID AS src_uuid,
    ol.Source_File  AS src_file
  FROM ObjectLinks ol
  JOIN ObjectCatalog src ON src.Object_UUID = ol.Source_UUID
  WHERE ol.Target_UUID = getvariable('uuid')
    AND ol.Link_Type = 'operational'
),
usage_groups AS (
  SELECT
    Link_Role AS link_role,
    used_by_type,
    COUNT(DISTINCT src_uuid) AS object_count,
    COUNT(DISTINCT src_file) AS file_count,
    COUNT(*) AS occurrence_count
  FROM usages
  GROUP BY Link_Role, used_by_type
),
usage_totals AS (
  SELECT
    COUNT(DISTINCT src_uuid) AS total_objects,
    COUNT(DISTINCT src_file) AS total_files,
    COUNT(*) AS total_occurrences
  FROM usages
)

SELECT * FROM (
  -- ── META (one row) ──
  SELECT
    'meta' AS section,
    0 AS order_hint,
    s.Object_Name AS object_name,
    (SELECT display_name FROM localized) AS localized_name,
    s.Function_ID    AS function_id,
    s.Namespace      AS namespace,
    s.Canonical_Name AS canonical_name,
    (SELECT total_objects     FROM usage_totals) AS total_objects,
    (SELECT total_files       FROM usage_totals) AS total_files,
    (SELECT total_occurrences FROM usage_totals) AS total_occurrences,
    CAST(NULL AS VARCHAR) AS link_role,
    CAST(NULL AS VARCHAR) AS used_by_type,
    CAST(NULL AS BIGINT)  AS object_count,
    CAST(NULL AS BIGINT)  AS file_count,
    CAST(NULL AS BIGINT)  AS occurrence_count
  FROM self s

  UNION ALL

  -- ── USAGE (one row per link role x source type) ──
  SELECT
    'usage', 1,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL,
    ug.link_role, ug.used_by_type,
    ug.object_count, ug.file_count, ug.occurrence_count
  FROM usage_groups ug
) details
ORDER BY order_hint, occurrence_count DESC NULLS FIRST, used_by_type;
