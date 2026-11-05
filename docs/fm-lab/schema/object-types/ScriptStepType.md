# ScriptStepType

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **script step type** is one entry of FileMaker's step vocabulary — `Set Variable`, `Go to Layout`, `Perform Script` — promoted to a catalog object. Where a [ScriptStep](ScriptStep.md) is one concrete line in one script, ScriptStepType is the *aggregate over all of them*: it answers "where is Insert from URL used anywhere in this solution?" as an ordinary object question with a detail view, instead of an ad-hoc query.

ScriptStepType is a **synthetic** type: FileMaker exports no such catalog. The import pipeline derives one [ObjectCatalog](../object-catalog/ObjectCatalog.md) entry per step ID in use across the solution — including **button-embedded steps** (a layout button carrying a single step counts toward the type even though no [ScriptStep](ScriptStep.md) object exists for it). The vocabulary itself is documented solution-independently in [fm-spec](../../Wiki/fm-spec.md): [script_steps](../fm-spec-tables/script_steps.md) holds all 207 canonical steps with stable IDs, localized names and XML mappings; a ScriptStepType object is the solution-side projection "this entry of the vocabulary actually occurs here". The ooe-fm test corpus yields 211 objects *(corpus)* — the full vocabulary plus placeholder entries such as unknown steps of missing plug-ins.

## Properties

The property surface is minimal — the type is an aggregation anchor, not a data carrier.

| Property (derived) | In catalog | Notes |
|---|---|---|
| step display name | `Object_Name` | As written by the exporting client (localized, e.g. `# (comment)`); the locale-independent identity is the numeric step ID (`StepsForScripts.Step_ID` ↔ `script_steps.step_id` in [fm-spec](../../Wiki/fm-spec.md)) |
| identity | `Object_UUID` | Synthetic UUID derived at import |
| numeric ID | `Object_ID` | `NULL` — a step type has no per-file FileMaker ID |
| source | `Source_Table` | `StepsForScripts` |
| per-instance data | [StepsForScripts](../catalog-tables/StepsForScripts.md) rows (+ internal `LayoutObjectSteps` for button-embedded steps) | Step options, parameters and calculations belong to the instances, see [ScriptStep](ScriptStep.md) |

Everything else about a step type — canonical name, category, option grammar, platform compatibility, XML template — lives in [fm-spec](../../Wiki/fm-spec.md) ([script_steps](../fm-spec-tables/script_steps.md), [step_options](../fm-spec-tables/step_options.md), [step_compat](../fm-spec-tables/step_compat.md), [step_xml_map](../fm-spec-tables/step_xml_map.md)), not in the solution catalog.

## References

ScriptStepType participates in **no [ObjectLinks](../object-catalog/ObjectLinks.md) edges** — neither as source nor as target. The usage aggregation is computed on demand by the detail template, which joins the step instances from [StepsForScripts](../catalog-tables/StepsForScripts.md) and the button-embedded steps from the internal `LayoutObjectSteps` table; it is deliberately not mirrored into the graph, where it would drown every real dependency under thousands of "uses Set Variable" edges.

### Outgoing links (ScriptStepType as source)

None — no link role has ScriptStepType as its source.

### Incoming links (ScriptStepType as target)

None — no link role targets ScriptStepType.

## Schema & tooling

- **XML schema:** no catalog of its own — derived from the steps in [XML StepsForScripts](../../xml/catalogs/XML%20StepsForScripts.md) and the button-embedded steps in [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)
- **DB schema:** [StepsForScripts](../catalog-tables/StepsForScripts.md) (instances) · vocabulary reference in [fm-spec](../../Wiki/fm-spec.md) ([script_steps](../fm-spec-tables/script_steps.md) and satellites)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_scriptsteptype.sql` — all caller scripts and buttons of the step type (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=ScriptStepType`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [ScriptStep](ScriptStep.md) · [Script](Script.md) · [fm-spec](../../Wiki/fm-spec.md)
