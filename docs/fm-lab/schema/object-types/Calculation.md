# Calculation

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **calculation** is one formula *instance* — one place in the solution where a formula is attached to an owning object: a field's calculation, auto-enter or validation formula, a script-step parameter, a hide condition, a conditional-formatting rule, a merge/layout display calculation, a script-trigger parameter, a portal filter, a web-viewer URL, a menu install condition, a record-access calc. As a catalog object every instance is addressable: detail view, deep links, annotations, object-scoped tests.

Calculation is a **synthetic** type: FileMaker exports no calculation catalog. The import pipeline derives one [CalculationsCatalog](../catalog-tables/CalculationsCatalog.md) row — and one [ObjectCatalog](../object-catalog/ObjectCatalog.md) entry — per instance, as the union of the DDR calculation anchors and the structural slots the export carries even without DDR-Info (field slots, step calcs, CF bodies, per-trigger parameter texts, record-access calcs); layout display formulas whose DDR chunk list is empty get a fallback instance recovered from the layout text. Identity is deliberately **structural** (`Owner × Calc_Role × Calc_Index`), never the formula hash: SaXML dedupes formula content, one hash can serve tens of thousands of instances, and `Get(AccountName)="admin"` as a hide condition, a privilege calc and a validation are three different things.

## Properties

| Property | In catalog | Notes |
|---|---|---|
| generated name | `Object_Name` | `<Owner> › <Role label>[ N]`, e.g. `Artikel_Liste::Preis › Conditional Formatting 2` |
| identity | `Object_UUID` | Synthetic UUID over file + owner + role + index (see [CalculationsCatalog](../catalog-tables/CalculationsCatalog.md)) |
| owner | `CalculationsCatalog.Owner_*` | Field, ScriptStep, LayoutObject, Layout, File, CustomFunction, CustomMenu, CustomMenuItem or PrivilegeSet |
| slot | `Calc_Role` / `Calc_Kind_Raw` / `Source_Path` | Normalized role vocabulary + raw DDR suffix + structural origin |
| formula | `Formula_Text` / `Display_Text` | Structural plaintext / chunk-reconstructed text — present also without DDR-Info |
| content hash | `Formula_Hash` | DDR enrichment (property, not identity); NULL without DDR-Info |
| static flag | `Is_Static` | TRUE = pure literal (e.g. a static popover title), no references |
| result type | `Result_Type` | Display calculations: the declared result type from the `%X:` prefix of the layout formula (`Text`, `Number`, `Date`, `Time`, `Timestamp`; default `Text`) |
| evaluation context | `Context_TO_UUID` / `Context_TO_Name` | The context table occurrence, where the export carries one (for display calculations sourced from [DDR_ChunkListContexts](../catalog-tables/DDR_ChunkListContexts.md)) |

## References

The **usage semantics stay on the owner**: the owner-projected edges (`reads_field`, `calls_function`, `calls_customfunction`, `calls_pluginfunction`, `validates_by_calc`) remain the canonical layer for where-used, dead-code and the graph — a Calculation never duplicates them.

### Incoming links (Calculation as target)

| Role | Source | Notes |
|---|---|---|
| `has_calculation` | the owner | structural containment, `Link_Subrole = Calc_Role[:Calc_Index]`; **never counts as usage** |

### Outgoing links (Calculation as source)

None physically. The per-slot detail resolution *Calculation → target* is the **derived view `v_calculation_links`** — it reconstructs which owner edges belong to which instance (via the slot-bearing `Link_Subrole`, for script steps instance-exactly via the P2 reference extracts). Variable targets are not part of the view (they live in [VariableUsages](../catalog-tables/VariableUsages.md)).

Because `has_calculation` is structural, Calculation objects never enter the logical graph or the clustering — no graph blow-up despite ~180k instances in a mid-size solution.

## Schema & tooling

- **DB schema:** [CalculationsCatalog](../catalog-tables/CalculationsCatalog.md) (instances) · [DDR_Calculations](../catalog-tables/DDR_Calculations.md) (chunks, via `DDR_Calc_UUID`/`Formula_Hash`) · [StepCalculations](../catalog-tables/StepCalculations.md) (step slots)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_calculation.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)); `/api/get-calc?uuid=<Calculation_UUID>` returns the token stream (the hash form stays as a dedup alias)
- **Frontend:** object list at `http://localhost:5173/?type=Calculation` (excluded from *unfiltered* name search — the generated names would flood every owner-name match)

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [CalculationsCatalog](../catalog-tables/CalculationsCatalog.md) · [Field](Field.md) · [ScriptStep](ScriptStep.md) · [LayoutObject](LayoutObject.md)
