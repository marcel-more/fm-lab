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
  `<ChunkList>`). *Verified at `tools/tests/fixtures/xml/…_v2_2_3_0__fm_v22_0_4…`.*
- **SaXML v2.3.0.0 (FileMaker 26+):** the `<CalcsForCustomFunctions>` section is gone;
  `<Calculation>` is **embedded directly inside each `<CustomFunction>`** within
  `<CustomFunctionsCatalog>`. The embedded `<Calculation>` has **no `<ChunkList>`** —
  only `<DDRREF kind="ChunkList" hash="…">` (the chunks remain reachable via the hash in
  `<DDR_INFO>`) and `<Text>`. *Verified at `tools/tests/fixtures/xml/v26/Ooe.xml` (v2.3.0.0 / FM 26.0.1).*

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
and v2.3.0.0 / FM 26). The extractor handles **both** forms via a structure-tolerant double
extraction (no version switch).

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
