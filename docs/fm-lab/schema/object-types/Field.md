# Field

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **field** is a column of a [base table](BaseTable.md) — the fundamental data-bearing object of a FileMaker solution. Its definition is the richest structure of the whole export: besides name, type and comment it bundles the complete auto-enter block (serial numbers, lookups, calculated values, constant data), storage and indexing options, the validation block (including validate-by-calculation and custom messages) and, for summary fields, the summary definition. FileMaker distinguishes the *field type* (Normal, Calculated, Summary) from the *data type* (Text, Number, Date, …) — a calculated field still has a data type for its result.

Field is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'Field'` mirrors one `<Field>` element of the export, and the full definition lands in [FieldsForTables](../catalog-tables/FieldsForTables.md) (57 columns — the widest type-specific table in the catalog).

## Properties

The tables below list the full property surface of the `<Field>` element in the XML export and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

### Identity & classification

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Field_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `Field_Name` | |
| `@fieldtype` | `Field_Type` | Normal / Calculated / Summary |
| `@datatype` | `Data_Type` | Result/data type; `Binary` = container |
| `@comment` | `Field_Comment` | Developer comment |
| `<UUID>` (text) | `Field_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md); the stamp of the per-table field catalog is in [CatalogChangeMeta](../catalog-tables/CatalogChangeMeta.md) |
| `<TagList>` | — | Field tags incl. `@primary` — **not extracted** |

### Auto-enter block (`<AutoEnter>`)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@type` | `AutoEnter_Type` | See [Enumerations](#enumerations) |
| `@prohibitModification` | `AutoEnter_ProhibitMod` | |
| `<SerialNumber>` `@increment` / `@nextvalue` / `@generate` | `Serial_Increment` / `Serial_NextValue` / `Serial_Generate` | |
| `<Looked_up>` source field / relationship | `Lookup_Field_*`, `Lookup_TO_*` | → `lookup_source` / `lookup_relationship` links |
| `<Looked_up>` `@dontCopyIfEmpty` / `@noMatchCopyOption` | `Lookup_DontCopyIfEmpty` / `Lookup_NoMatchOption` | |
| `<Calculated><Calculation>` | `AE_Calc_Text`, `AE_Calc_Hash` | Auto-enter calculation of a Normal field |
| `@overwriteExisting`, `@alwaysEvaluate` | `AE_Calc_OverwriteExisting`, `AE_Calc_AlwaysEvaluate` | |
| `<ConstantData>` | `AE_ConstantData` | |
| Auto-enter calculation context (TO reference) | — | The evaluation context of the auto-enter calc — **not extracted** |

### Storage block (`<Storage>`)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@global` | `Is_Global` | |
| `@maxRepetitions` | `Max_Repetitions` | |
| `@autoIndex` | `Storage_AutoIndex` | |
| `@index` | `Storage_Index` | None / Minimal / All |
| `@storeCalculationResults` | `Storage_StoreCalcResults` | Unstored calcs = `false` |
| `<LanguageReference>` | `Storage_IndexLanguage`, `Storage_IndexLanguage_ID` | Index language |
| `<Remote>` (`@type`, `<Location>`, `<BaseDirectoryReference>`) | — | External container storage (open/secure, storage path, base directory) — **not extracted** |

### Validation block (`<Validation>`)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@type` | `Validation_Type` | Always / OnlyDuringDataEntry |
| `@allowOverride`, `@notEmpty`, `@unique`, `@existing`, `@alwaysValidate` | `Validation_AllowOverride`, `Validation_NotEmpty`, `Validation_Unique`, `Validation_Existing`, `Validation_AlwaysValidate` | |
| `<Strict>` | `Validation_StrictType` | Strict data type (e.g. `FourDigitYear`) |
| `<MaximumSize>` | `Validation_MaxChars` | |
| `<Range>` `@from` / `@to` | `Validation_Range_From` / `Validation_Range_To` | |
| `<ValueListReference>` | `Validation_VL_ID` / `_Name` / `_UUID` | → `uses_valuelist` link (subrole `validation`) |
| `<Calculated>` | `Validation_Calc_Text`, `Validation_Calc_Hash` | → `validates_by_calc` links |
| `<Message>` / `<MessageCalc>` | `Validation_Message`, `Validation_Message_Calc_Hash` | Custom error message, fixed or calculated |

### Calculation & summary

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<Calculation><Text>` (field-level) | `Calculation_Text`, `DDR_Hash` | Formula of a true Calculated field |
| `<Calculation><TableOccurrenceReference>` | — | The calculation's evaluation context — **not extracted** |
| `<SummaryInfo>` `@operation` | `Summary_Operation` | |
| `<SummaryInfo>` `@restartEachGroup` / `@summarizeRepetition` | `Summary_RestartEachGroup` / `Summary_RepetitionMode` | |
| `<SummaryField><FieldReference>` | `Summary_Field_Name`, `Summary_Field_UUID` | → `summarizes_field` link (subrole = operation) |

`Calculation_Text`/`DDR_Hash` belong to Calculated fields; `AE_Calc_Text`/`AE_Calc_Hash` to Normal fields with an auto-enter calculation — a field never has both populated. All `*_Hash` columns join to the tokenized formula chunks in [DDR_Calculations](../catalog-tables/DDR_Calculations.md).

## References

Fields are the most connected object type of the catalog: their own calculations *produce* outgoing edges, while scripts, layouts, relationships and privilege sets *target* them from every direction. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Field as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `parent_table` | [BaseTable](BaseTable.md) | usage | The base table the field belongs to |
| `calls_function` | [BuiltinFunction](BuiltinFunction.md) | usage | Field calculation calls a built-in function |
| `calls_customfunction` | [CustomFunction](CustomFunction.md) | usage | Field calculation calls a custom function |
| `calls_pluginfunction` | [PluginFunction](PluginFunction.md) | usage | Field calculation calls a plugin function |
| `reads_field` | Field | usage | Field calculation reads another field |
| `reads_variable` | [Variable](Variable.md) | usage | Field calculation reads a global variable |
| `lookup_source` | Field | usage | Lookup copies from this source field |
| `lookup_relationship` | [TableOccurrence](TableOccurrence.md) | usage | Lookup resolves through this occurrence |
| `summarizes_field` | Field | usage | Summary field aggregates this field (subrole = operation) |
| `uses_valuelist` | [ValueList](ValueList.md) | usage | Validation by value list (subrole `validation`) |
| `validates_by_calc` | Field / [CustomFunction](CustomFunction.md) | usage | Validation calculation references the target |
| `has_calculation` | [Calculation](Calculation.md) | containment | Every calculation slot of the field (field calc, auto-enter, validation, validation message, …) as an addressable instance (subrole = `Calc_Role`, indexed for repeating slots) — never counts as usage |

Since schema 1.22.0 the calculation-carried usage edges are **slot-precise**: references from the auto-enter calculation carry `Link_Subrole = auto_enter`, validate-by-calculation references carry `validation`, and a calculated error message carries `validation_message` — so a where-used can tell the three apart.

### Incoming links (Field as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `sets_field` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Set-Field-class steps write the field |
| `reads_field` | [Script](Script.md) / Field / [CustomFunction](CustomFunction.md) / [LayoutObject](LayoutObject.md) / [PrivilegeSet](PrivilegeSet.md) | usage | A step or calculation reads the field |
| `references_field` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Fallback role for field references of uncurated step types |
| `inputs_to_field` | [Script](Script.md) | usage | Insert-class steps target the field |
| `imports_to_field` | [Script](Script.md) | usage | Import-class steps write the field |
| `exports_from_field` | [Script](Script.md) | usage | Export-class steps read the field |
| `finds_in_field` | [Script](Script.md) | usage | Find-class steps constrain on the field |
| `navigates_to_field` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Go-to-Field-class steps target the field |
| `sorts_by_field` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Sort Records / portal sort / button-embedded sort |
| `displays_field` | [LayoutObject](LayoutObject.md) / [Layout](Layout.md) | usage | Field control or merge field displays the field |
| `breaks_on_field` | [LayoutPart](LayoutPart.md) | usage | Sub-summary part breaks on the field |
| `left_field` / `right_field` | [Relationship](Relationship.md) | usage | Join-predicate field of a relationship side |
| `sort_field` | [Relationship](Relationship.md) | usage | Relationship sort field (subrole `left`/`right`) |
| `source_field` | [ValueList](ValueList.md) | usage | Field-based value list sources its values here (subrole `primary`/`secondary`/`secondary_sort`) |
| `lookup_source` | Field | usage | Another field looks its value up from here |
| `summarizes_field` | Field | usage | A summary field aggregates this field |
| `validates_by_calc` | Field | usage | Another field's validation calc references this field |
| `restricts_field` | [PrivilegeSet](PrivilegeSet.md) | restriction | Field-level custom privilege restriction — never counts as usage |

## Enumerations

Values marked *(corpus)* are the literals observed in the ooe-fm test corpus; the XML literal set beyond them is not independently documented.

| Property | Values |
|---|---|
| `Field_Type` | `Normal`, `Calculated`, `Summary` |
| `Data_Type` | `Text`, `Number`, `Date`, `Time`, `Timestamp`, `Binary` (= container) |
| `AutoEnter_Type` | `CreationTimestamp`, `CreationAccountName`, `ModificationTimestamp`, `ModificationAccountName`, `SerialNumber`, `Looked_up`, `Calculated`, `ConstantData` *(corpus — creation/modification date, time and user-name variants follow the same naming pattern)* |
| `Validation_Type` | `OnlyDuringDataEntry`, `Always` |
| `Storage_Index` | `None`, `Minimal`, `All` |
| `Serial_Generate` | `OnCreation` *(corpus)* — FileMaker also supports on-commit generation |
| `Lookup_NoMatchOption` | `DoNotCopy`, `ConstantData`, `NextLower`, `NextHigher` |
| `Summary_Operation` | `List` *(corpus)* — FileMaker's full set covers total, average, count, minimum, maximum, standard deviation and fraction-of-total |

## Schema & tooling

- **XML schema:** [XML FieldsForTables](../../xml/catalogs/XML%20FieldsForTables.md) — `<FieldsForTables>` branch, one `<FieldCatalog>` per base table
- **DB schema:** [FieldsForTables](../catalog-tables/FieldsForTables.md) · formulas tokenized in [DDR_Calculations](../catalog-tables/DDR_Calculations.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_field.sql` (+ `object_details_field_tokens.sql` for the calculation token view), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=Field`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [BaseTable](BaseTable.md) · [TableOccurrence](TableOccurrence.md) · [ValueList](ValueList.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
