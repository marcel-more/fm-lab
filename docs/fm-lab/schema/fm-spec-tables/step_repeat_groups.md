# step_repeat_groups

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Repeat groups (lists) per script step: for every step whose XML carries a variable number of item elements — sort levels, find requests and their criteria, import filters, table aliases, web-script parameters — this table names the group, its container element and the per-item XML template. The main template in [step_xml_map](step_xml_map.md) shows a single-instance exemplar; the repetition itself is grounded here. The canonical text notation addresses these groups with a group label and per-item brackets (notation T9); a one-value group renders as a scalar repetition.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `group_key` | `VARCHAR` |
| `group_label` | `VARCHAR` |
| `parent_group` | `VARCHAR` |
| `container_path` | `VARCHAR` |
| `count_attr` | `VARCHAR` |
| `item_form` | `VARCHAR` |
| `item_template` | `VARCHAR` |
| `max_items` | `INTEGER` |
| `slot_positional` | `BOOLEAN` |
| `pad_mode` | `VARCHAR` |
| `empty_item_template` | `VARCHAR` |
| `default_item_template` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `coverage` | `VARCHAR` |

## Notes

- Four build forms cover all groups: `item_form` is either `bracket` (each item is a bracketed option group, e.g. sort levels) or `scalar` (each item is a single value); groups nest via a `{key[]}` placeholder in the parent's `item_template` (find criteria inside a request row); `{#index}` inside an `item_template` expands to the 0-based item index; `count_attr` names the container attribute that carries the item count (e.g. `Count`) and is derived at emission, never authored.
- `parent_group` links a nested group to its parent row (criteria → request); top-level groups have `NULL`.
- **Fixed-slot groups** (schema 1.16.0, Show Custom Dialog): `max_items` declares a constant slot count and `slot_positional` marks the slot index as semantic (`Get ( LastMessageChoice )`), so these groups are slot-addressed in the text notation (`Button2:`, `Input1Label:` — labels derived from the `[n]` convention in [step_options](step_options.md)`.xml_path`), never bracketed. `pad_mode` `all_when_any` means one configured slot makes FileMaker persist all slots — unconfigured ones as the `empty_item_template` hull; `default_item_template` is the item FileMaker injects as slot 1 when the whole group is unconfigured on a configured step (the OK commit button). A fully unconfigured step exports bare, without container or default.
- 15 rows across 9 steps (22, 28, 39, 87, 126, 127, 131, 214, 220), all `paired` at 22.0.6.
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.

- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override/addition of one FileMaker coverage (`26`); a consumer resolving a target coverage prefers the row of that coverage with the same key and falls back to `*` — rule and keys on [Coverage resolution](../Coverage%20resolution.md).

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [step_xml_map](step_xml_map.md) · [step_options](step_options.md)
