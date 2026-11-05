-- @template_type: report
-- @description: Structured detail of a ValueList — source type, custom values (one row each), field source (TO + field, optional second field), or external ValueList reference
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 2.0
-- @tags: valuelists, details, options
-- @note: Flat rows with a `section` discriminator:
--          'meta'            → one row, value-list-level scalars (name, source type, file, uuid).
--          'custom_value'    → one row per custom value (Custom_Values is stored as a single
--                              newline-joined array element in the export → split on chr(10) so
--                              every value becomes its own uniform row; the old template gave only
--                              the first value a "- " prefix).
--          'field_source'    → one row (Source_Type='Field'): source TO + field, optional second
--                              field for display, sort flags. UUIDs make TO/field clickable.
--          'external_source' → one row (Source_Type='External'): external data source + target
--                              value list; target_vl_uuid/file resolved via the source_valuelist
--                              link so the referenced list in the other file is clickable.

WITH vl_match AS (
  -- Clone-Scoping: UUID ist bei geklonten Dateien nicht eindeutig → zusätzlich nach File_Name filtern
  SELECT vl.VL_ID, vl.VL_Name, vl.Source_Type, vl.VL_UUID, vl.File_Name
  FROM ValueListCatalog vl
  JOIN ObjectCatalog oc ON vl.VL_UUID = oc.Object_UUID AND oc.File_Name = vl.File_Name
  WHERE oc.Object_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR vl.File_Name = getvariable('file'))
  LIMIT 1
),
vl_opt AS (
  SELECT ovl.*
  FROM OptionsForValueLists ovl
  JOIN vl_match vm ON ovl.VL_UUID = vm.VL_UUID AND ovl.File_Name = vm.File_Name
  LIMIT 1
),
-- Custom-Values entpacken: das Export-Format legt alle Werte als EIN
-- newline-verbundenes Array-Element ab → pro Zeile eine eigene Zeile.
-- Trailing \r (CRLF-Exporte) entfernen, damit keine Steuerzeichen im Wert bleiben.
custom_vals AS (
  SELECT
    idx AS seq,
    rtrim(val, chr(13)) AS value
  FROM vl_opt,
       LATERAL unnest(
         flatten(list_transform(Custom_Values, lambda x: string_split(x, chr(10))))
       ) WITH ORDINALITY AS t(val, idx)
  WHERE Custom_Values IS NOT NULL AND len(Custom_Values) > 0
),
-- Externe Werteliste: Ziel-VL (source_valuelist) + Datenquelle (data_source)
-- über die aufgelösten Graph-Links beziehen, damit beide klickbar werden.
ext_link AS (
  SELECT
    MAX(CASE WHEN ol.Link_Role = 'source_valuelist' THEN ol.Target_UUID END) AS target_vl_uuid,
    MAX(CASE WHEN ol.Link_Role = 'source_valuelist' THEN ol.Target_File END) AS target_vl_file,
    MAX(CASE WHEN ol.Link_Role = 'data_source'      THEN ol.Target_UUID END) AS ds_uuid,
    MAX(CASE WHEN ol.Link_Role = 'data_source'      THEN ol.Target_File END) AS ds_file
  FROM vl_match vm
  JOIN ObjectLinks ol
    ON ol.Source_UUID = vm.VL_UUID AND ol.Source_File = vm.File_Name
   AND ol.Source_Type = 'ValueList'
   AND ol.Link_Role IN ('source_valuelist', 'data_source')
)

SELECT * FROM (
  -- ── META (one row) ──
  SELECT
    'meta' AS section,
    0 AS order_hint,
    CAST(NULL AS BIGINT)  AS seq,
    CAST(NULL AS VARCHAR) AS value,
    vm.VL_Name    AS vl_name,
    vm.Source_Type AS source_type,
    vm.File_Name  AS file_name,
    vm.VL_UUID    AS vl_uuid,
    vm.VL_ID      AS vl_id,
    CAST(NULL AS VARCHAR) AS to_name,        CAST(NULL AS VARCHAR) AS to_uuid,
    CAST(NULL AS VARCHAR) AS field_name,     CAST(NULL AS VARCHAR) AS field_uuid,
    CAST(NULL AS VARCHAR) AS secondary_to_name,    CAST(NULL AS VARCHAR) AS secondary_to_uuid,
    CAST(NULL AS VARCHAR) AS secondary_field_name, CAST(NULL AS VARCHAR) AS secondary_field_uuid,
    CAST(NULL AS BOOLEAN) AS field_sort,     CAST(NULL AS BOOLEAN) AS secondary_sort,
    CAST(NULL AS VARCHAR) AS external_ds_name, CAST(NULL AS VARCHAR) AS external_ds_uuid, CAST(NULL AS VARCHAR) AS external_ds_file,
    CAST(NULL AS VARCHAR) AS external_vl_name, CAST(NULL AS VARCHAR) AS target_vl_uuid,   CAST(NULL AS VARCHAR) AS target_vl_file,
    CAST(NULL AS VARCHAR) AS to_file,        CAST(NULL AS VARCHAR) AS field_file,
    CAST(NULL AS VARCHAR) AS secondary_to_file, CAST(NULL AS VARCHAR) AS secondary_field_file
  FROM vl_match vm

  UNION ALL

  -- ── CUSTOM VALUES (one row each) ──
  SELECT
    'custom_value', 1,
    cv.seq, cv.value,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL
  FROM custom_vals cv

  UNION ALL

  -- ── FIELD SOURCE (one row, only when the VL draws from a field) ──
  -- Home-Datei je Referenz aus ObjectHomes auflösen: das Quell-TO ist datei-lokal
  -- (VL-Datei), das dahinterliegende Feld liegt aber im Home der Basistabelle und
  -- ist damit oft cross-file → die VL-Datei als `file` würde einen 404 erzeugen.
  SELECT
    'field_source', 2,
    NULL, NULL, NULL, NULL, vo.File_Name, NULL, NULL,
    vo.TO_Name, vo.TO_UUID,
    vo.Field_Name, vo.Field_UUID,
    vo.Secondary_TO_Name, vo.Secondary_TO_UUID,
    vo.Secondary_Field_Name, vo.Secondary_Field_UUID,
    vo.Field_Sort, vo.Secondary_Sort,
    NULL, NULL, NULL, NULL, NULL, NULL,
    COALESCE((SELECT Home_File FROM ObjectHomes WHERE Object_UUID = vo.TO_UUID), vo.File_Name),
    (SELECT Home_File FROM ObjectHomes WHERE Object_UUID = vo.Field_UUID),
    (SELECT Home_File FROM ObjectHomes WHERE Object_UUID = vo.Secondary_TO_UUID),
    (SELECT Home_File FROM ObjectHomes WHERE Object_UUID = vo.Secondary_Field_UUID)
  FROM vl_opt vo
  WHERE vo.Field_Name IS NOT NULL OR vo.TO_Name IS NOT NULL

  UNION ALL

  -- ── EXTERNAL SOURCE (one row, only when the VL references another file's VL) ──
  SELECT
    'external_source', 3,
    NULL, NULL, NULL, NULL, vo.File_Name, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    vo.External_DS_Name, COALESCE(el.ds_uuid, vo.External_DS_UUID), el.ds_file,
    vo.External_VL_Name, el.target_vl_uuid, el.target_vl_file,
    NULL, NULL, NULL, NULL
  FROM vl_opt vo
  LEFT JOIN ext_link el ON TRUE
  WHERE vo.Source_Type = 'External'
     OR vo.External_VL_Name IS NOT NULL
     OR vo.External_DS_Name IS NOT NULL
) details
ORDER BY order_hint, seq NULLS FIRST;
