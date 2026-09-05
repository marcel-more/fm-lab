# LayoutObject

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **layout object** is anything placed on a [layout](Layout.md): field controls, text blocks, buttons, portals, tab and slide controls, web viewers, charts, shapes. It is the catalog's heaviest *reference carrier* — a single object can display a field, use a value list, perform a script, sort a portal and hide itself by calculation all at once, and container objects (tab panels, slide panels, groups, popovers, portals) nest further objects recursively. Buttons may either reference a script or embed a **single script step** directly.

LayoutObject is an **exported** type: each `<LayoutObject>` element becomes a row in [LayoutObjects](../catalog-tables/LayoutObjects.md) and in [ObjectCatalog](../object-catalog/ObjectCatalog.md). The 26 subtypes are refined in the `Object_Type` column of [LayoutObjects](../catalog-tables/LayoutObjects.md) — the raw XML type attribute is localized, so the import canonicalizes it to English names; the full subtype list with its five groups (Input, Display, Action, Container, Shape) is enumerated on [Object Types](../object-catalog/Object%20Types.md). In the frontend, layout objects are **hoisted** into the layout detail view: the wireframe draws them at their real coordinates, and each object additionally has a dedicated detail view of its own.

## Properties

The `<LayoutObject>` element has a small common surface plus a **type-specific payload** in a child element named after the subtype (`<Field>`, `<Text>`, `<Portal>`, `<TabControl>`, `<GroupedButton>`, `<WebViewer>`, …). The catalog extracts the common surface, the nesting, and the frequently needed calculation texts; everything else stays available in the raw `Object_XML` column. Properties marked **not extracted** have no dedicated column (most are still inside `Object_XML`).

### Common surface

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Object_ID` | Unique only within a layout — `Object_UUID` is the global key |
| `@type` | `Object_Type` | Localized in the export; canonicalized to English at import |
| `@kind` | `Object_Kind` | Locale-independent numeric type signal |
| `@name` | `Object_Name` | The object name (empty for unnamed objects) |
| `@hash` | `Object_Hash` | |
| `@position`, `@Options` | — | Undocumented attributes on the object tag — **not extracted** |
| `<UUID>` (text) | `Object_UUID` | Stable identity |
| `<Bounds>` `@top` / `@left` / `@bottom` / `@right` | `Bounds_Top` / `Bounds_Left` / `Bounds_Bottom` / `Bounds_Right` | Position on the layout |
| `<Options>` (child element, packed value) | — | Object-level option bitmask — **not extracted** |
| `<LocalCSS>` (`@name`, `@displayName`, CSS text) | — | Local style overrides — **not extracted** (in `Object_XML`) |
| `<ExtendedAttributes>` | — | **not extracted** (in `Object_XML`) |
| part assignment | `Part_Type` | The [part](LayoutPart.md) the object sits in |
| nesting | `Parent_Object_ID`, `Nesting_Level`, `Z_Order` | Derived container hierarchy and stacking order, see [Object hierarchy](#object-hierarchy) |

### Type-specific payload

| Property (XML) | In catalog | Notes |
|---|---|---|
| object references in the payload (`<FieldReference>`, `<ScriptReference>`, `<ValueListReference>`, `<TableOccurrenceReference>`, `<LayoutReference>`) | — (links) | Resolved into [ObjectLinks](../object-catalog/ObjectLinks.md) at import (`displays_field`, `triggers_script`, `uses_valuelist`, `portal_context`, `navigates_to_layout`, …) — never regex `Object_XML` for these |
| hide condition calculation | `Hide_Calculation_Text` | Also tokenized via its `DDRREF` hash |
| tooltip calculation | `Tooltip_Calculation_Text` | |
| button/label calculation | `Label_Calculation_Text` | |
| script trigger parameter | `ScriptTrigger_Parameter_Text` | Object-level aggregate (all parameter texts concatenated); the per-trigger truth is `ScriptTriggers.Trigger_Parameter_Text` |
| text content (`<Text>/<StyledText>/<Data>`) | `Text_Content` | Plain text of Text objects — including merge fields (`<<::field>>`), merge variables (`<<$$var>>`) and layout calculations (`<<ƒ:…>>`), which resolve into `displays_field` / `displays_variable` edges and `display_calculation` instances |
| conditional formatting (`<Conditions><Formatting>`) | [LayoutObjectConditions](../catalog-tables/LayoutObjectConditions.md) | One row per rule with parsed condition, operands, enable bit and format — never regex `Object_XML` for CF |
| `{{…}}` symbols in the text | [LayoutObjectSymbols](../catalog-tables/LayoutObjectSymbols.md) | Symbol inventory per text object — never regex `Text_Content` for symbols |
| button-embedded step (`Button/action/<Step>`) | — (links) | The single step's references are resolved into links; the step type registers as [ScriptStepType](ScriptStepType.md); the raw step stays in `Object_XML` |
| placeholders, chart definitions, sort specifications, formatting/styles, tab order, animations, icon data | — | Payload details without dedicated columns — **not extracted** (in `Object_XML`); their calculations are covered via `DDRREF` hashes ([XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)) and appear as links with calc-slot subroles |

## Object hierarchy

Every layout object links to its [Layout](Layout.md) via `parent_layout`. Container objects — tab panels, slide panels, groups, popovers, portals — carry their children inside panel elements; the import flattens this into `parent_object` links between layout objects plus the `Parent_Object_ID` / `Nesting_Level` columns (depth 5 occurs in practice). Object-level [script triggers](ScriptTrigger.md) hang on the object via `trigger_owner` (subrole = event type, e.g. `OnObjectSave`).

In the web frontend, objects are hoisted into the layout wireframe (with nesting and part assignment); the object's own detail view adds the resolved references, calculation texts and — for buttons with an embedded step — the tokenized step.

## References

Layout objects carry more link roles than any other source type: display edges, action edges, navigation edges and calculation edges from every calc slot (hide, tooltip, conditional formatting, placeholder, chart series, portal filter). Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (LayoutObject as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `displays_field` | [Field](Field.md) | usage | Field control displays the field |
| `displays_variable` | [Variable](Variable.md) | usage | Merge variable displayed on the layout |
| `triggers_script` | [Script](Script.md) | usage | Button action or trigger mirror performs the script (subrole = event or `button_action`) — the counting where-used edge for trigger-fired scripts |
| `uses_valuelist` | [ValueList](ValueList.md) | usage | Field control uses the value list |
| `portal_context` | [TableOccurrence](TableOccurrence.md) | usage | The portal's data-source occurrence |
| `navigates_to_layout` | [Layout](Layout.md) | usage | Button-embedded Go to Layout / GTRR step |
| `navigates_to_field` | [Field](Field.md) | usage | Button-embedded Go-to-Field-class step |
| `navigates_to_to` | [TableOccurrence](TableOccurrence.md) | usage | Button-embedded GTRR target occurrence |
| `sets_field` | [Field](Field.md) | usage | Button-embedded Set-Field-class step writes the field |
| `reads_field` | [Field](Field.md) | usage | An object calculation reads the field |
| `reads_variable` | [Variable](Variable.md) | usage | An object calculation reads the variable |
| `references_field` | [Field](Field.md) | usage | Fallback role for field references of uncurated step types |
| `sorts_by_field` | [Field](Field.md) | usage | Portal sort or button-embedded sort (subrole `portal` / `button`) |
| `sorts_by_valuelist` | [ValueList](ValueList.md) | usage | Custom sort order by value list (subrole `portal` / `button`) |
| `calls_function` | [BuiltinFunction](BuiltinFunction.md) | usage | An object calculation calls a built-in function |
| `calls_customfunction` | [CustomFunction](CustomFunction.md) | usage | An object calculation calls a custom function |
| `calls_pluginfunction` | [PluginFunction](PluginFunction.md) | usage | An object calculation calls a plugin function |
| `parent_layout` | [Layout](Layout.md) | containment | The object belongs to the layout |
| `parent_object` | LayoutObject | containment | The object's container parent (tab panel, group, popover, …) |
| `has_calculation` | [Calculation](Calculation.md) | containment | Every calculation slot of the object (hide, tooltip, conditional formatting, portal filter, …) as an addressable instance (subrole = `Calc_Role`, indexed for repeating slots) — never counts as usage |

### Incoming links (LayoutObject as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `parent_object` | LayoutObject | containment | A nested child object points here |
| `trigger_owner` | [ScriptTrigger](ScriptTrigger.md) | containment | Object-level trigger hangs on this object (subrole = event type) |

For calculation-carried roles the `Link_Subrole` names the **calc slot** that contains the reference — the DDR calc-anchor suffix: `Hide`, `Tooltip`, `Placeholder`, `Condition_1` (conditional formatting), `Filter` (portal filter), `ScriptTrigger_<id>` (trigger parameter), `DisplayCalculations_<i>` (merge/layout calculation), chart series keys like `Series_Value` / `YSeriesList_0_Value` *(corpus)*. References of a button-embedded step carry the step index instead. This makes "which formula on this object touches that field?" answerable from the link table alone.

## Enumerations

| Property | Values |
|---|---|
| `Object_Type` (subtypes) | 26 subtypes in five groups — Input (`Edit Box`, `Drop-down List`, `Checkbox Set`, …), Display (`Text`, `Graphic`, `Web Viewer`, `Chart`, …), Action (`Button`, `Button Bar`, `Popover Button`, …), Container (`Portal`, `Group`, `Tab Control`, `Slide Control`, `Panel`, `PopoverPanel`), Shape (`Rectangle`, `Rounded Rectangle`, `Oval`, `Line`) — authoritative grouped table on [Object Types](../object-catalog/Object%20Types.md); unknown raw types are kept as-is and reported by the P6 checks |

## Schema & tooling

- **XML schema:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — `<LayoutObject>` elements inside each part's `<ObjectList>`, nesting recursively in container payloads
- **DB schema:** [LayoutObjects](../catalog-tables/LayoutObjects.md) · references resolved in [ObjectLinks](../object-catalog/ObjectLinks.md) · calculations tokenized in [DDR_Calculations](../catalog-tables/DDR_Calculations.md)
- **Detail view template:** `rest-api/templates/sql/object_details_layoutobject.sql` (+ `object_details_layoutobject_step_tokens.sql` for the button-embedded step token view and `object_references_layoutobject_step.sql` for its references), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md); additionally hoisted into the layout wireframe (`display_layout_objects_data.sql`, see [Detail View Templates](../../templates/Detail%20View%20Templates.md))
- **Frontend:** object list at `http://localhost:5173/?type=LayoutObject`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Layout](Layout.md) · [LayoutPart](LayoutPart.md) · [ScriptTrigger](ScriptTrigger.md) · [Field](Field.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
