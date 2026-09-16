# script_steps

Part of the [FM-Lab schema](../Schema.md) · Canonical core · `reference/fm_spec.duckdb` (fm-spec language reference)

The canonical identity of all 216 FileMaker script steps (207 documented for FileMaker 22 plus the nine steps FileMaker 26 introduced — the PDF family, Insert Image Caption(s) and Flush Web Viewer Cookies): the stable numeric `step_id` (the same ID SaXML writes as `Step/@id`), the English `canonical_name`, the element name used in emitted XML (`xml_name`), the category and the FileMaker version the step originated in. Everything else in fm-spec — names, options, XML templates, compatibility — hangs off this table.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `category_id` | `INTEGER` |
| `origin_version` | `VARCHAR` |
| `url_slug` | `VARCHAR` |
| `canonical_name` | `VARCHAR` |
| `xml_name` | `VARCHAR` |
| `xml_name_evidence` | `VARCHAR` |

## Notes

- `xml_name_evidence` records how the XML element name was verified.
- `StepsForScripts.Step_ID` in the solution catalog joins directly against `step_id`.

**See also:** [script_steps_lang](script_steps_lang.md) · [step_options](step_options.md) · [step_xml_map](step_xml_map.md) · [step_compat](step_compat.md)
