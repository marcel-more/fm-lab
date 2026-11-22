# CalculationsCatalog

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** union of [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) calculation anchors and the structural calculation slots of [field definitions](../../xml/catalogs/XML%20FieldsForTables.md), [script steps](../../xml/catalogs/XML%20StepsForScripts.md), custom functions, layout objects and record-access privileges

One row per calculation **instance** — every place in the solution where a formula is attached to an owning object: a field's calculation or auto-enter formula, a step parameter, a hide condition, a conditional-formatting rule, a menu install condition, a record-access calc. Introduced with schema version 1.22.0; the rows are registered in [ObjectCatalog](../object-catalog/ObjectCatalog.md) as `Object_Type` [Calculation](../object-types/Calculation.md) and anchored to their owner via the structural `has_calculation` link.

The identity is **structural**, never content-based: `Owner × Calc_Role × Calc_Index`. A formula *hash* is a property of the instance — the SaXML export dedupes chunk lists by content, so one hash can serve tens of thousands of instances (`Get(AccountName)="admin"` as a hide condition, a privilege calc and a validation are three different things).

Instances exist **also without DDR-Info**: the structural slots (field slots, [StepCalculations](StepCalculations.md) rows, CF bodies, layout-object text slots including panel titles and the active-segment formula of button bars, per-trigger parameter texts on all three owner levels, record-access calcs) produce rows on their own, and layout display formulas whose DDR chunk list is empty get a fallback instance recovered from the layout text; the DDR side contributes the hash, the chunk aggregates and the reconstructed `Display_Text` where available.

## Columns

| Column | Type |
|---|---|
| `Calculation_UUID` | `VARCHAR` |
| `Owner_UUID` | `VARCHAR` |
| `Owner_Type` | `VARCHAR` |
| `Owner_Name` | `VARCHAR` |
| `Calc_Role` | `VARCHAR` |
| `Calc_Kind_Raw` | `VARCHAR` |
| `Calc_Index` | `BIGINT` |
| `Edge_Subrole` | `VARCHAR` |
| `Formula_Text` | `VARCHAR` |
| `Formula_Hash` | `VARCHAR` |
| `DDR_Calc_UUID` | `VARCHAR` |
| `Context_TO_UUID` | `VARCHAR` |
| `Context_TO_Name` | `VARCHAR` |
| `Is_Static` | `BOOLEAN` |
| `Chunk_Count` | `BIGINT` |
| `Ref_Count` | `BIGINT` |
| `Display_Text` | `VARCHAR` |
| `Source_Path` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Result_Type` | `VARCHAR` |

## Notes

- **`Calc_Role`** is the normalized, locale-independent slot vocabulary: `field_calculation`, `auto_enter`, `validation`, `validation_message`, `container_path` (external container storage path), `custom_function`, `step_parameter`, `step_xslt`, `step_sql_text` (the plain *SQL text* input of Execute SQL — FileMaker sends it verbatim and never evaluates it, so it carries no references even though the export lists formula chunks for it), `record_access`, `hide`, `tooltip`, `placeholder`, `conditional_format`, `portal_filter`, `web_viewer_url`, `button_label`, `button_action` (the script parameter of a button, and the parameter slots of a button's single script step — FileMaker anchors those at the embedded step; owner is the button, `Edge_Subrole` the slot number), `panel_title`, `popover_title`, `active_segment` (the active-segment formula of a button bar, DDR suffix `ButtonBar`), `display_calculation`, `chart_series`, `chart_title`, `chart_xaxis_title`, `chart_yaxis_title`, `script_trigger_parameter`, `menu_install`, `menu_title`, `menu_item_install`, `menu_item_name`, `menu_item_parameter`. An unknown DDR suffix falls back to its lowercased raw value and is reported by the P6 check `v_check_calc_roles` for curation.
- **`Calc_Kind_Raw`** keeps the raw DDR anchor suffix (`Hide`, `Condition_3`, `ScriptTrigger_4`, `DisplayCalculations_0`, a step's calc position, field slot codes `0`–`4`) — or `LabelText_<i>` for a layout calculation in a button label without DDR anchor (see below); `Calc_Index` is 1-based per owner × role in document/position order.
- **`Edge_Subrole`** is the `Link_Subrole` value the owner-projected [ObjectLinks](../object-catalog/ObjectLinks.md) edges of this instance carry — the join key of the derived view `v_calculation_links` (see [Calculation](../object-types/Calculation.md)).
- **`Formula_Text`** is the structural plaintext where the export carries one — field slots, per-trigger parameter calcs (from `ScriptTriggers.Trigger_Parameter_Text`), panel titles (`popover_title`, `panel_title` from `LayoutObjects.Title_Calculation_Text`), the active-segment formula of a button bar (`active_segment`, read from the bar's own layout-object XML) and, for `display_calculation` instances, the localized raw formula recovered from the layout text or button label; **`Display_Text`** is the chunk-reconstructed, entity-decoded formula (DDR side). Read `COALESCE(Formula_Text, Display_Text)` for display.
- **`Result_Type`** is populated for `display_calculation` instances: the declared result type of the layout formula (`Text`, `Number`, `Date`, `Time`, `Timestamp` — from the `%X:` prefix, default `Text`; an unknown prefix passes through as `%<X>`).
- **Button labels:** FileMaker evaluates a `<<ƒ:…>>` typed into the label of a button or popover button. Where it wrote a `DisplayCalculations` anchor, the instance runs through the DDR path like a text object's (`DisplayCalculations_<i>`). Where it did not — FileMaker writes that anchor for some labels and not for others, and a file exported without DDR-Info never has one — the instance carries `Calc_Kind_Raw` = `Edge_Subrole` = `LabelText_<i>` (i = token index), no `DDR_Calc_UUID`, the layout's table occurrence as context, and references matched from the formula text with that subrole (fields of the layout's TO or a qualified `TO::Field`, custom functions, variables; built-in names stay unresolved because they are typed localized). Fields of an external table occurrence resolve into the file that holds its base table, as long as that file is part of the import.
- **`DDR_Calc_UUID`** bridges to [DDR_Calculations](DDR_Calculations.md) (`_<OwnerUUID>_<Suffix>` anchor); NULL for structural-only instances (no DDR-Info, or slots FileMaker never anchors — field validation slots, for example). The anchor's context TO and chunk count live in [DDR_ChunkListContexts](DDR_ChunkListContexts.md).
- **Owner of a DDR anchor:** normally the object whose UUID the anchor name carries. Copies with the same UUID (layout objects pasted in FileMaker, steps of a duplicated script) share their anchor names, and FileMaker writes the chunk list only for the copy whose own `DDRREF` carries the hash; the other copies show `hash=""`. After [UUID healing](../UUID%20Healing%20and%20Duplicate%20Census.md) the copies have different catalog UUIDs, so the owner is the member of the healing group whose own XML carries the anchor name **and** the hash. A copy with `hash=""` has no chunks for that formula and therefore no DDR instance; for hide conditions, tooltips and the other layout-object text slots it keeps a structural instance without hash. The import check `v_check_calc_owner_hash` lists DDR-anchored layout-object and step instances whose hash is missing from the owner's own XML (expected: empty).
- The former analysis table `v_calc_anchors` is now a thin materialized facade over this table (DDR-anchored rows only, same column surface).

**See also:** [Calculation](../object-types/Calculation.md) · [DDR_Calculations](DDR_Calculations.md) · [StepCalculations](StepCalculations.md) · [ObjectCatalog](../object-catalog/ObjectCatalog.md) · [LinkRoleRegistry](../object-catalog/LinkRoleRegistry.md)
