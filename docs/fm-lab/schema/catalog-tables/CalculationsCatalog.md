# CalculationsCatalog

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** union of [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) calculation anchors and the structural calculation slots of [field definitions](../../xml/catalogs/XML%20FieldsForTables.md), [script steps](../../xml/catalogs/XML%20StepsForScripts.md), custom functions, layout objects and record-access privileges

One row per calculation **instance** — every place in the solution where a formula is attached to an owning object: a field's calculation or auto-enter formula, a step parameter, a hide condition, a conditional-formatting rule, a menu install condition, a record-access calc. Introduced with schema version 1.22.0; the rows are registered in [ObjectCatalog](../object-catalog/ObjectCatalog.md) as `Object_Type` [Calculation](../object-types/Calculation.md) and anchored to their owner via the structural `has_calculation` link.

The identity is **structural**, never content-based: `Owner × Calc_Role × Calc_Index`. A formula *hash* is a property of the instance — the SaXML export dedupes chunk lists by content, so one hash can serve tens of thousands of instances (`Get(AccountName)="admin"` as a hide condition, a privilege calc and a validation are three different things).

Instances exist **also without DDR-Info**: the structural slots (field slots, [StepCalculations](StepCalculations.md) rows, CF bodies, layout-object text slots, per-trigger parameter texts on all three owner levels, record-access calcs) produce rows on their own, and layout display formulas whose DDR chunk list is empty get a fallback instance recovered from the layout text; the DDR side contributes the hash, the chunk aggregates and the reconstructed `Display_Text` where available.

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

- **`Calc_Role`** is the normalized, locale-independent slot vocabulary: `field_calculation`, `auto_enter`, `validation`, `validation_message`, `container_path` (external container storage path), `custom_function`, `step_parameter`, `step_xslt`, `record_access`, `hide`, `tooltip`, `placeholder`, `conditional_format`, `portal_filter`, `web_viewer_url`, `button_label`, `button_action`, `panel_title`, `popover_title`, `display_calculation`, `chart_series`, `chart_title`, `chart_xaxis_title`, `chart_yaxis_title`, `script_trigger_parameter`, `menu_install`, `menu_title`, `menu_item_install`, `menu_item_name`, `menu_item_parameter`. An unknown DDR suffix falls back to its lowercased raw value and is reported by the P6 check `v_check_calc_roles` for curation.
- **`Calc_Kind_Raw`** keeps the raw DDR anchor suffix (`Hide`, `Condition_3`, `ScriptTrigger_4`, a step's calc position, field slot codes `0`–`4`); `Calc_Index` is 1-based per owner × role in document/position order.
- **`Edge_Subrole`** is the `Link_Subrole` value the owner-projected [ObjectLinks](../object-catalog/ObjectLinks.md) edges of this instance carry — the join key of the derived view `v_calculation_links` (see [Calculation](../object-types/Calculation.md)).
- **`Formula_Text`** is the structural plaintext where the export carries one — field slots, per-trigger parameter calcs (from `ScriptTriggers.Trigger_Parameter_Text`) and, for `display_calculation` instances, the localized raw formula recovered from the layout text; **`Display_Text`** is the chunk-reconstructed, entity-decoded formula (DDR side). Read `COALESCE(Formula_Text, Display_Text)` for display.
- **`Result_Type`** is populated for `display_calculation` instances: the declared result type of the layout formula (`Text`, `Number`, `Date`, `Time`, `Timestamp` — from the `%X:` prefix, default `Text`; an unknown prefix passes through as `%<X>`).
- **`DDR_Calc_UUID`** bridges to [DDR_Calculations](DDR_Calculations.md) (`_<OwnerUUID>_<Suffix>` anchor); NULL for structural-only instances (no DDR-Info, or slots FileMaker never anchors — field validation slots, for example). The anchor's context TO and chunk count live in [DDR_ChunkListContexts](DDR_ChunkListContexts.md).
- The former analysis table `v_calc_anchors` is now a thin materialized facade over this table (DDR-anchored rows only, same column surface).

**See also:** [Calculation](../object-types/Calculation.md) · [DDR_Calculations](DDR_Calculations.md) · [StepCalculations](StepCalculations.md) · [ObjectCatalog](../object-catalog/ObjectCatalog.md) · [LinkRoleRegistry](../object-catalog/LinkRoleRegistry.md)
