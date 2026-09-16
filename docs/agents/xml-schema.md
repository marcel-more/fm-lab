## FileMaker SaveAsXML

**Save a Copy as XML** (often shortened to _SaveAsXML_) is a function in Claris FileMaker for exporting an open FileMaker file as an XML document. The XML contains all schema and structural details of the FileMaker solution — tables, field definitions, layouts, scripts, value lists, security privileges, etc. — but does not include any record data from the tables. The XML file therefore serves as documentation of the application and lets developers track changes to the structure of the FileMaker file.


## XML structure

This is the high-level structure of the XML export produced from a FileMaker file.

```XML
<?xml version="1.0" encoding="utf-8"?>
<FMSaveAsXML version="2.2.0.0" Source="19.6.3" File="Filename.fmp12" UUID="3577981F-2DDF-45FC-9720-9570570760DB" locale="German">
    <Structure membercount="1">
        <AddAction membercount="18">
            <BaseDirectoryCatalog membercount="1" generate="True" temporary="True">...</BaseDirectoryCatalog>
            <ExternalDataSourceCatalog membercount="4">...</ExternalDataSourceCatalog>
            <BaseTableCatalog membercount="5">...</BaseTableCatalog>
            <TableOccurrenceCatalog membercount="7">...</TableOccurrenceCatalog>
            <CustomFunctionsCatalog membercount="28">...</CustomFunctionsCatalog>
            <FieldsForTables membercount="5">...</FieldsForTables>
            <ValueListCatalog membercount="1">...</ValueListCatalog>
            <RelationshipCatalog membercount="3">...</RelationshipCatalog>
            <CalcsForCustomFunctions membercount="28">...</CalcsForCustomFunctions>
            <ScriptCatalog membercount="106">...</ScriptCatalog>
            <ThemeCatalog membercount="1">...</ThemeCatalog>
            <LayoutCatalog membercount="7">...</LayoutCatalog>
            <PrivilegeSetsCatalog membercount="6">...</PrivilegeSetsCatalog>
            <ExtendedPrivilegesCatalog membercount="9">...</ExtendedPrivilegesCatalog>
            <AccountsCatalog membercount="6">...</AccountsCatalog>
            <StepsForScripts membercount="82">...</StepsForScripts>
            <CustomMenuCatalog membercount="24">...</CustomMenuCatalog>
            <CustomMenuSetCatalog membercount="3">...</CustomMenuSetCatalog>
            <FileAccessCatalog sameHost="False" required="True">...</FileAccessCatalog>
            <Library membercount="2">...</Library>
            <PasteIndexList membercount="0"></PasteIndexList>
        </AddAction>
    </Structure>
    <Metadata membercount="1">
        <AddAction membercount="9">…file options (see below)…</AddAction>
    </Metadata>
    <DDR_INFO>…calculation/script chunks (only with "Include details for analysis tools")…</DDR_INFO>
</FMSaveAsXML>
```

**Further branches (quick reference → DuckDB table):**

| Branch | Content | Table(s) |
|---|---|---|
| `CustomMenuSetCatalog` | Menu sets with a `CustomMenuReference` member list | `CustomMenuSetCatalog` |
| `FileAccessCatalog` | Inter-file authorizations (`UUID` entries with a file reference) | `FileAccessAuthorizations` |
| `Library` | Library entries (binary blobs; only metadata retained) | `LibraryReferences` |
| `Metadata/AddAction` | File options: `PageSetup`, `Encryption`, `Minimum`, `Login` (type=1 + `AccountName` = auto-login!), `ShowSignInFields`, `Spelling`, `Hide*Sharing`, `Defaults/LayoutReference` (start layout), file-global `ScriptTriggers` | `FileOptionsCatalog`, `ScriptTriggers` |
| `DDR_INFO/Calculation` | Formula chunks per calc anchor `_<UUID>_<kind>` (hash → `DDRREF` joins); chunk types `NoRef`, `FieldRef`, `VariableReference`, `FunctionRef`, `CustomFunctionRef`, `PluginFunctionRef`, `Comment`. **`PluginFunctionRef` means "external or unresolvable", not "plug-in":** besides plug-in calls it carries FileMaker's design functions (`WindowNames`/`Fensternamen`, `DatabaseNames`, `LayoutIDs`, …, in the authoring client's language — every other built-in is normalized to English as `FunctionRef`) and unresolvable identifiers such as deleted custom functions; the importer re-types the design functions to `FunctionRef` in phase 1c | `DDR_Calculations` |
| `DDR_INFO/Script` | Human-readable script-step texts | `DDR_ScriptSteps` |
| `PrivilegeSet/access/Records/Custom` | Custom Record Privileges (table × operation, calcs, field level) | `PrivilegeSetRecordAccess`, `PrivilegeSetFieldAccess` |
| `PrivilegeSet/access/{Layouts,ValueLists,Scripts}/Custom` | Object-level Custom Privileges | `PrivilegeSetObjectAccess` |

Note on the name collision: theme-internal `<Metadata><namedstyles>` blocks (inside
`ThemeCatalog`) are NOT the file-options branch — only a `<Metadata>` with an
`<AddAction>` child counts (the P1 parser filters accordingly).

## SaXML profiles (version-explicit import)

The converter reads the root attribute `FMSaveAsXML/@version` of every export and
imports the file under one of two **profiles** (converter 2.24.0, schema 1.28.0):

| `@version` | Profile | FileMaker | Encoding of the export |
|---|---|---|---|
| 2.1.0.0 – 2.2.x | `saxml22` | 19 – 22 | UTF-16 (converted by the pre-processor) |
| 2.3.0.0 and later | `saxml23` | 26+ | UTF-8 |
| 2.0.0.0 (`<FMDynamicTemplate>`) | — (skipped) | 18 | |

The profile is persisted in `FilesCatalog.SaXML_Version`/`SaXML_Profile` and
`XMLMetadata.SaXML_Profile`. Extractions that exist in only one form live in
`-- @P1_PROFILE:<profile>@ … -- @END_P1_PROFILE@` blocks of the P1 template; the driver
filters them in every mode. A corpus may mix files of both profiles — the decision is
per file. **Never** import the FileMaker 22 and the FileMaker 26 export of the *same*
file into one catalog: they share every object UUID.

Vocabulary delta of **SaXML 2.3.0.0** (evidence: `ingestion/fixtures/saxml/
fmlab_coverage__saxml_v2_3_0_0__fm_v26_0_2__ddr_info.xml` vs. the 2.2.3.0 export of the
same file):

| Element / attribute | 2.2.x (`saxml22`) | 2.3.0.0 (`saxml23`) | Catalog target |
|---|---|---|---|
| Root | `version Source File UUID locale Has_DDR_INFO` | + `binary_under_lo`, `split_catalogs` | `XMLMetadata`/`FilesCatalog` |
| `<Structure>` | `AddAction` (+ others) | `AddAction` only | — |
| Value-list options | top-level `<OptionsForValueLists>` | embedded in `ValueListCatalog/ValueList` (`Source`, `Field`, `CustomValues`, `External`) | `OptionsForValueLists` (one read per profile) |
| Custom-function formulas | top-level `<CalcsForCustomFunctions>` (also a row per folder/separator) | `<Calculation>` embedded in `<CustomFunction>` (no `<ChunkList>`) | `CalcsForCustomFunctions` (folders/separators: no row in either profile) |
| `Field/Annotation/Text`, `Field/DisplayNames@enable` + `Calculation` | — | new; the display-names formula anchors in `DDR_INFO` as `_<Field-UUID>_5` | `FieldsForTables.Field_Annotation`, `Field_DisplayNames_Enabled`, `DisplayNames_Calc_Text/Hash`; calc role `display_names` |
| Field validation calc anchor | `_<Field-UUID>_2` | `_<Field-UUID>_4_2` (message calc stays `_4`) | folded to slot `2` = role `validation` in P4 (owner-bound — step anchors use the same `<pos>_<sub>` form) |
| Disabled definitions `AutoEnter/Calculated@enable`, `AutoEnter/Looked_up@enable`, `Validation/Calculated@enable`, `Validation/MessageCalc@enable` | absent — a disabled definition is not exported at all | `enable="True"` on active, `enable="False"` on disabled definitions (formula, DDR anchor and chunks are still written) | `FieldsForTables.*_Enabled`; `CalculationsCatalog.Is_Enabled`; no operational links for disabled slots |
| `Part@type` of `Part@kind="5"` | `Trailing Grand Summary` (Claris mislabel; real trailing grand summary is kind 6) | `Trailing Sub-summary` | `LayoutParts.Part_Type` canonical from the kind (schema 1.29.0), raw value in `Definition_Type` |
| `Step id="144"` (Save Records as PDF) boolean options | `Append …`, `With dialog` | `With dialog`, `Append …`, + `Create folders`, `SaveResult` | `StepsForScripts.Boolean_Type/Value` is the first slot — differs across versions; all options in `Parameters_XML` |
| `Step id="36"` (Export Records) XSLT | `DataSourceReference/XSL` calculation not exported | exported (`step_xslt` instances) | Claris source gap of 2.2.3.0, no converter action |
| `Layout/TableView/ObjectList/TableViewLayoutObject{hidden,id,name,width}/FieldReference` | — | new (every layout carries its table-view columns) | `LayoutTableViewColumns`; edge Layout → Field `displays_field`/`table_view_column` |
| `LayoutObject … /DisplayCalculations@membercount` | = number of `<<ƒ:…>>` layout-calculation tokens of the text | always 12 — padding anchors repeat the first slot's hash or carry foreign chunks | staged in `DDR_DisplayCalcAnchors23`; stage P1d promotes only slots below the token count |
| `Step id="138"` (Re-Login) | `DataSourceReference` not written — in the coverage fixture not even for a Re-Login into an external file | always present (`id="0"` = current file; external file with `id`, `name`, `UUID`) | edge Script → ExternalDataSource `data_source` for external sources — from the 2.3.0.0 export only |
| Steps introduced in FileMaker 26 (`id` 238, 240–246: Configure Persistent Data, Insert Image Caption(s), Print/Create/Append/Close/Open PDF) | exported bare — `id`, `name`, `Options`, DDR anchor, **no `ParameterValues`** | full parameters | `StepsForScripts` row in both profiles; parameters, calculations and links from 2.3.0.0 only |
| `Step id="144"` saving into a container field (FileMaker 26) | legacy path form (Booleans + `UniversalPathList`) — the configuration is unknown to FileMaker 22 | `Target` field reference + `SaveResult` "Currently open PDF", no Boolean slot | `Boolean_Type` NULL in 26, `sets_field` link to the container — cross-version comparison of such steps is not meaningful |
| `Step id="87"` (Show Custom Dialog) | — | `height`/`width`/`top`/`left` calculations (dialog geometry) | `StepCalculations` slots `Parameter:height` … |
| `Step id="96"` (Save a Copy as Add-on Package) | no `ParameterValues` | Boolean "Replace UUIDs" (id 262144) + package path calculation | `Parameters_XML`, `StepCalculations` |
| Steps 215 / 218 / 219 (LLM) | — | `LLMParameters` (215, 218); `RAGTokensPerTextChunk`, `RAGAddDataResponse` + `Target`/`Variable` (219) | calculation slots; response target yields the field/variable link |
| Other additions (read transparently) | | `ExternalDataSourceCatalog/SortOrder`, `SortSpecification@blanksLast`, `ImportField/Options@keepOriginalData`, `SQL@HasODBCAuthCalc`, `LocalCSS@type`, `enable` on `Calculated`/`Looked_up`/`MessageCalc`, `UseDefaultFields@enable`; `LibraryCatalog` before `LayoutCatalog`; new step parameter types of the FileMaker 26 steps (`PersistentStore`, `PDFtoPrint`, `PageSetup`, `SaveTo`, `From`, `PDFPassword`, `LLMBulkEmbeddingField`, `RAGTokensPerTextChunk`, `RAGAddDataResponse`, `LightMode`, `SaveResult`, dialog geometry) | typed struct reads ignore unknown attributes |

**Step slots the SaXML export never carries** (only reachable via the clipboard
format) are reference data since fm-spec 2.7.0: `reference/fm_spec.duckdb` →
`step_constraints` rows of kind `saxml_omission`, scoped by `coverage` (`*` = every
SaXML version, `22`/`26` = that version's export only) — query them instead of
maintaining a list here. Current rows: the zoom formula of step 97 and the
"automatically open"/"create email" flags of steps 36 and 144 (every version), the
XSLT stylesheet of step 36's XML export (2.2.3.0 only — 2.3.0.0 writes
`DataSourceReference/XSL`), the `Option` flag of step 215 and the flags of step 245
(2.3.0.0; FileMaker 22 does not know them). `DetectVertical` of step 219 is **not** a
gap: FileMaker 22 has no such option, 2.3.0.0 writes it as the Boolean "Detect
vertical text" (id 32768). Layout-object gaps of 2.2.3.0 (portal sort order,
`CanEntryCalc`) stay fm-lab data: `tools/tests/quality/baselines/shape_22_26.tsv`.

### Boolean attributes of 2.3.0.0 — value coverage

The converter ignores attributes it does not know, so a new attribute counts as "read
transparently" only as long as every export carries its default value; the non-default
semantics stay unverified until a fixture carries the other value. Status per attribute
(coverage fixtures, 2026-09-10; "—" = non-default value not yet evidenced):

| Attribute (2.3.0.0) | Where | Default observed | Non-default evidenced | Catalog effect of the non-default value |
|---|---|---|---|---|
| `AutoEnter/Calculated@enable` | Field | `True` | `False`: coverage 26 (1 field) | `FieldsForTables.AE_Calc_Enabled = false`, instance `Is_Enabled = false`, no operational links |
| `AutoEnter/Looked_up@enable` | Field | `True` | `False`: coverage 26 (1 field) | `Lookup_Enabled = false`, no lookup links |
| `Validation/Calculated@enable` | Field | `True` | `False`: coverage 26 (1 field) | `Validation_Calc_Enabled = false` |
| `Validation/MessageCalc@enable` | Field | `True` | `False`: coverage 26 (1 field) | `Validation_Message_Calc_Enabled = false` |
| `DisplayNames@enable` | Field | `False` | `True`: coverage 26 (2 fields) | `Field_DisplayNames_Enabled`, role `display_names`, `FieldDisplayNames` |
| `UseDefaultFields@enable` | BaseTable | `False` | — | none (read transparently) |
| `SortSpecification@blanksLast` | Sort Records (39), portal sorts | `False` | `True`: coverage 26 (3 sort steps; portal sorts still —) | none (read transparently) |
| `ImportField/Options@keepOriginalData` | Import Records (35) | `False` | `True`: coverage 26 (1 import) | none (read transparently) |
| `SQL@HasODBCAuthCalc` | Execute SQL (117) | `False` | — | none (read transparently) |
| `Boolean "Replace UUIDs"` (id 262144) | Save a Copy as Add-on Package (96) | `False` | — | `Parameters_XML` only |
| `Boolean "Detect vertical text"` (id 32768) | Perform RAG Action (219) | `False` | — | `Parameters_XML` only |
| `Boolean` "Specify options as JSON" / "Save each layout object's binary data under its node" | Save a Copy as XML (3) | mixed | yes (coverage 26) | `Parameters_XML`; JSON options calc as `Parameter:JSONOutput` in `StepCalculations` |


## Field entry behaviour (`<Field><Options>` bitmask + `<CanEntryCalc>`)

A field-bearing layout object carries its per-mode entry rule as a bitmask in
`LayoutObject/Field/Options`, and the formula of the `by_calculation` state in a
separate element `LayoutObject/CanEntryCalc/Calculation`. **Two bits per mode**
encode four states; both SaXML profiles write the same values (verified against
12 probes of the coverage file, FileMaker 22.0.6 and 26.0.2):

| Bits (Browse / Find) | State | `Entry_Browse` / `Entry_Find` |
|---|---|---|
| none | entry allowed | `allow` |
| 24 / 25 | selection only | `select_only` |
| 2 / 4 | display only | `view_only` |
| 24 + 2 / 25 + 4 | governed by the formula | `by_calculation` |

Base value of a default object is `1048608`; `51380276` is "both modes by
calculation". The converter keeps the raw value (`LayoutObjects.Entry_Options_Raw`)
because the remaining bits are undecoded.

**One formula for both modes:** `<CanEntryCalc>` exists at most once per object —
FileMaker's options dialog offers a single formula field, so a `by_calculation`
state in both modes shares one formula. The state without a formula is legal
(bits set, no element).

**Only 2.3.0.0 writes the formula.** A FileMaker 22 export carries the identical
bits but neither the `<CanEntryCalc>` element nor a DDR chunk list for it — the
formula is unreadable there (an omission of the export, not of the file).

**DDR key collision (FileMaker defect).** In 2.3.0.0 the chunk list of the entry
formula is written under the SAME key as the hide condition, `_<ObjectUUID>_Hide`.
An object that has BOTH formulas therefore ships only ONE chunk list — the entry
formula's; the hide condition's chunks are gone. The converter assigns the anchor
by comparing the reconstructed chunk text with both plain-text slots
(`fm_lo_ddr_is_entry`, P4): the matching formula becomes the calculation instance
of role `field_entry` or `hide`, the other keeps its instance without edges
(`Edge_Subrole` NULL). Since converter 2.30.0 the edges of the entry formula carry
`field_entry` as `Link_Subrole` (P4 retags the reference rows of that anchor after
the assignment; hide-condition edges keep `Hide`), so `Link_Subrole`,
`Edge_Subrole` and `v_calculation_links` agree on the slot.

## Custom sort by value list (`<Sort type="Custom">` with `<ValueListReference>`)

A custom sort order carries its reference value list as a `<ValueListReference>`
next to the `<PrimaryField>`. **Only** `<Sort type="Custom">` carries such a reference.
Four carriers (all → link role `sorts_by_valuelist`, distinguished by `Source_Type`):

| Carrier | Path | Source in the converter |
|---|---|---|
| "Sort Records" script step (step ID 39) | `Step > ParameterValues > Parameter > SortSpecification > SortList > Sort[Custom]` | P2 via `StepsForScripts.Step_XML` |
| Portal sort | `LayoutObject[Portal] > Portal > SortSpecification > SortList > Sort[Custom]` | P2 via `LayoutObjects.Object_XML` (anchored path) |
| Button-embedded sort step | `LayoutObject > GroupedButton/Button > action > Step[39] > … > Sort[Custom]` | P2 via `LayoutObjects.Object_XML` (anchored path) |
| Relationship sort ("Sort records") | `Relationship > {Left,Right}Table > SortSpecification > SortList > Sort[Custom]` | P1 `RelationshipCatalog` (`Left/Right_Sort_ValueList_UUIDs`) |

Note on `Object_XML` extractions: the fragment contains the **full subtree** of a
layout object — a `//` XPath would additionally match inherited portal sorts on ancestor
containers (Panel/Tab Control). Hence absolute paths anchored to the owning object.

## Button-embedded step references (`GroupedButton/Button > action > Step`)

Instead of a script call (`<ScriptReference>` → `triggers_script`), a button can execute a
**single embedded script step**. Its references produce the same **reused** link roles as
the script side (`Source_Type='LayoutObject'` distinguishes the carrier; no new registry
roles). Extraction in P2 from `LayoutObjects.Object_XML` with the `action/Step` path
anchored at the button (the `action` branch contains no child objects — those live under
`…/ObjectList` — so `//` **inside** the anchored `action/Step` is duplicate-free). FileMaker
allows only **one** step per button.

| Reference class | `Ref_Type` | Path (under `action/Step`) | Link role |
|---|---|---|---|
| Layout (Go to Layout step 6, GTRR target layout step 74) | `layout_step` | `//LayoutReference` (scalar `[1]`) | `navigates_to_layout` |
| TableOccurrence (**GTRR only**, step 74) | `table_occurrence_step` | `//TableOccurrenceReference` (scalar `[1]`) | `navigates_to_to` |
| Field (Go to Field 17, Sort Records 39, …) | `field_step` | `ParameterValues//FieldReference` | via `ScriptStepRoleMap` (`navigates_to_field`/`sorts_by_field`/… ; fallback `references_field`) |

**Semantic gating** as on the script side: `navigates_to_to` applies **only** to GTRR
(`Step_ID=74`). A Go-to-Field / Sort-Records step does carry a `<TableOccurrenceReference>`,
but that is the **context TO** of the target/sort field, not a navigation target (the script
side stores it analogously in `XMLStepReferences.TO_UUID`, not as a link). The step `@id` is
carried along in the additive column `XMLLayoutReferences.Step_ID` and carries the
locale-independent field role. Closes the largest remaining where-used gap class (layouts
reachable only via a button appeared as false positives in `unused_layout`).

## External value lists (`<Source value="External">`)

A local value-list wrapper can source its values from a VL in **another file**:

```xml
<ValueList>
    <ValueListReference id="7" name="Lieferbedingung" UUID="44639478-…"/>  <!-- self-identity -->
    <Source value="External"/>
    <External>
        <DataSourceReference id="64" name="Gruppen" UUID="AFA2D47E-…">
            <UniversalPathList>file:Gruppen</UniversalPathList>
        </DataSourceReference>
        <ValueListReference id="9" name="Lieferbedingungen" UUID=""/>      <!-- target VL: UUID EMPTY! -->
    </External>
</ValueList>
```

The target `ValueListReference` carries an **empty UUID** — resolution runs via the data
source (→ target file) + VL `id` (fallback: name). Converter: `OptionsForValueLists.External_*`
columns (P1) → links `ValueList → ValueList (source_valuelist)` and
`ValueList → ExternalDataSource (data_source)` (P4); unresolvable targets are reported by
`v_check_external_vl_unresolved` (P6).

## CustomFunction calculations — format differs by SaXML version

The location of a custom function's calculation body changed between SaXML versions:

- **SaXML ≤ v2.2.x (FileMaker ≤ 22):** `<CustomFunctionsCatalog>` carries only the
  signature (`id`/`name`/`UUID`/`Display`/parameters). The formula bodies live in a
  **separate top-level `<CalcsForCustomFunctions>`** section, one `<CustomFunctionCalc>`
  per function (with `<CustomFunctionReference>` + `<Calculation>` incl. an inline
  `<ChunkList>`) — **also one entry per folder and separator** (without `<Calculation>`).
  *Verified at `ingestion/fixtures/saxml/fmlab_coverage__saxml_v2_2_3_0__fm_v22_0_6__ddr_info.xml`.*
- **SaXML v2.3.0.0 (FileMaker 26+):** the `<CalcsForCustomFunctions>` section is gone;
  `<Calculation>` is **embedded directly inside each `<CustomFunction>`** within
  `<CustomFunctionsCatalog>`. The embedded `<Calculation>` has **no `<ChunkList>`** —
  only `<DDRREF kind="ChunkList" hash="…">` (the chunks remain reachable via the hash in
  `<DDR_INFO>`) and `<Text>`. *Verified at `ingestion/fixtures/saxml/fmlab_coverage__saxml_v2_3_0_0__fm_v26_0_2__ddr_info.xml`.*

```xml
<!-- v2.3.0.0 (FM 26): Calculation embedded in CustomFunctionsCatalog -->
<CustomFunction id="2" name="OrderOfOperations" access="All">
    <UUID …>D87A5E62-…</UUID>
    <Calculation>
        <DDRREF kind="ChunkList" hash="804DF992…">_D87A5E62-…</DDRREF>
        <Text><![CDATA[Contacts::OrderOfOperationsTest_u & If ( … )]]></Text>
    </Calculation>
    <Display>OrderOfOperations</Display>
</CustomFunction>
```

The exact FM version that introduced the embedded format is unknown (between v2.2.3.0 / FM 22
and v2.3.0.0 / FM 26). The extractor reads **one** form per file, selected by the SaXML profile
(`saxml22` → section, `saxml23` → embedded; see *SaXML profiles* above); folders and separators
get no formula row in either profile.

> The high-level structure block above (`version="2.2.0.0"`, with a top-level
> `<CalcsForCustomFunctions>`) reflects the FM 19 export; under v2.3.0.0 that section
> is absent and the calculation moves into `<CustomFunction>` as shown here.

## AutoEnter node (inside Field elements)

Each `<Field>` element in `FieldsForTables` may contain an `<AutoEnter>` child:

```xml
<AutoEnter type="<TYPE>" prohibitModification="True|False">
    <!-- type-specific children -->
</AutoEnter>
```

### AutoEnter types

| Type | Children |
|-----|--------|
| `SerialNumber` | `<SerialNumber increment="1" nextvalue="207782" generate="OnCreation"/>` |
| `Looked_up` | `<Looked_up>` with FieldReference (see below) |
| `Calculated` | `<Calculated>` with Calculation/Text (formula) and DDRREF (hash) |
| `ConstantData` | `<ConstantData>Value</ConstantData>` |
| `CreationDate`, `CreationTime`, `CreationTimestamp`, `CreationName`, `CreationAccountName` | none |
| `ModificationDate`, `ModificationTime`, `ModificationTimestamp`, `ModificationName`, `ModificationAccountName` | none |

### Lookup structure (Looked_up)

```xml
<AutoEnter type="Looked_up" prohibitModification="False">
    <Looked_up dontCopyIfEmpty="False" noMatchCopyOption="DoNotCopy">
        <FieldReference id="12" name="Default 9" UUID="3082C86A-...">
            <TableOccurrenceReference id="1065097" name="Article Range" UUID="11A6B529-..."/>
        </FieldReference>
        <Context>
            <TableOccurrenceReference id="1065089" name="Article" UUID="73ECAA67-..."/>
        </Context>
    </Looked_up>
</AutoEnter>
```

### AutoEnter Calculated structure

```xml
<AutoEnter type="Calculated" prohibitModification="False" overwriteExisting="True" alwaysEvaluate="False">
    <Calculated>
        <Calculation>
            <TableOccurrenceReference id="1065089" name="Stocks" UUID="0DD01566-..."/>
            <DDRREF kind="ChunkList" hash="5754CB6D...">...</DDRREF>
            <Text><![CDATA[Shelves::Index]]></Text>
        </Calculation>
    </Calculated>
</AutoEnter>
```

### ConstantData structure

```xml
<AutoEnter type="ConstantData" prohibitModification="False">
    <ConstantData>1</ConstantData>
</AutoEnter>


```xml
    <Metadata membercount="1">
        <AddAction membercount="6">
            <Encryption type="0"></Encryption>
            <Minimum version="16.0" value="1600"></Minimum>
            <Login type="1">...</Login>
            <Defaults>...</Defaults>
            <Spelling underline="False"></Spelling>
            <ScriptTriggers membercount="1">...</ScriptTriggers>
        </AddAction>
    </Metadata>
</FMSaveAsXML>
```
