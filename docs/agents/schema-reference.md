# Schema Reference — DuckDB Tables & Link Roles

> Referenced from CLAUDE.md §4. Read this when you need column-level detail,
> link-role semantics, or the complete table list. For the pipeline that builds
> these tables see `pipeline-reference.md`; for the underlying XML structure see
> `docs/agents/xml-schema.md`.

## All tables

The table names mirror the XML branches of the corresponding object types:

- **XMLMetadata** — Root attributes of the XML file (version, DDR-Info status)
- **ExternalDataSourceCatalog** — External data sources
- **DataSourceFileMap** — Derived (P4): per `(File_Name, DS_UUID)` the **imported** file a FileMaker data source resolves to (`Resolved_File`) — direct `DS_Name` match first, then the `Path` list in FileMaker search order (protocol prefixes and directories stripped, case-insensitive; closes the `_dev`-suffix gap where the declared name and the imported file name differ). Data sources without an imported match have no row (partial corpus). Used by the P4 clone scoping (base_table block, prefer-declared-source pass) and the P6 view `v_check_phantom_links`
- **BaseTableCatalog** — Base tables of the FileMaker solution
- **TableOccurrenceCatalog** — Table occurrences in the relationship graph
- **RelationshipCatalog** — Relationships between table occurrences (per predicate, column `Predicate_Index`)
- **FieldsForTables** — Fields of all tables with type, properties and AutoEnter details (Lookup, Calculated, ConstantData)
- **CustomFunctionsCatalog** — Custom functions
- **CalcsForCustomFunctions** — Formulas of the custom functions
- **ScriptCatalog** — All scripts, folders and separators
- **StepsForScripts** — Script steps with parameters. Note `Calculation_Text` = the step's **first** calculation in document order, excluding repetition/window-geometry (`Bounds`) slots — NULL when the step carries only such slots (e.g. a `New Window` without a name). For every calculation of a multi-calc step use **StepCalculations**. `Opens_Window` (derived, P3): TRUE/FALSE for the two window-capable steps only (`New Window` = always TRUE, `Go to Related Record` = TRUE iff its "New window" option is set), NULL for all other steps
- **StepCalculations** — One row per positioned calculation of a step (derived in P3 from `Step_XML`): `Slot` (parent element of the calculation — `Name`, `height`, `URL`, `Title`, `value`, `repetition`, … or `Parameter:<type>` when directly under a `<Parameter>`), `Calc_Position` (the `@position` attribute — NOT step-unique, FileMaker restarts numbering in some parameter containers), `Slot_Seq` (1-based ordinal within one slot parent, e.g. JavaScript argument lists), `Calc_Text`. Covers what `Calculation_Text` cannot: window names vs. geometry, dialog title vs. message, URL vs. cURL options
- **Layouts** — Layouts of the solution
- **LayoutObjects** — All layout objects across all layouts (22 types, real container hierarchy via direct child axes; corpus reaches nesting depth 5)
- **LayoutParts** — Layout sections (Header, Body, Footer, Sub-summaries; one row per part via `Part_Seq` — multiple sub-summaries of the same kind stay distinct; `Break_Field_*`/`Break_TO_*` = sub-summary break field)
- **LayoutObjectConditions** — Conditional-formatting rules, one row per rule (schema 1.25.0, derived in P3 from `Object_XML`, **depth-anchored** at `/LayoutObject/Conditions/Formatting/Condition` — own rules only, container nesting cannot double-count; use this table for ANY CF question instead of regexing `Object_XML`). Columns: `Rule_UUID` (synthetic md5), `Object_UUID` (owning layout object), `Layout_ID`, `Rule_Index` (1-based serialization order = FileMaker dialog order = `Condition/@id`+1 = DDR suffix `Condition_N`), `Condition_Type` (raw `@type`, fixture-verified: 0 = formula, 1 between, 2 not between, 3 equal, 4 not equal, 5 greater, 6 less, 7 greater/equal, 8 less/equal, 9 contains, 10 does not contain, 11 begins with, 12 ends with, 13 empty — a "not empty" operator does not exist), `Condition_Kind` (`formula`/`value`), `Options_Raw` (format-selection bitmask, raw; **bit0 = rule ENABLED** — 0 means the rule is disabled in the dialog, so `aktiv = Options_Raw & 1`; bit1 text color, bit2 fill color, bit4 "more formatting", bit7 icon color; the text-style toggles bold/italic/underline/strikethrough set NO bit and materialize only in `Local_CSS`), `Calc_Text` (condition formula — **also filled for value rules**: FileMaker serializes the equivalent `Self` formula), `Calc_Hash` (DDRREF, NULL without DDR-Info), `Calculation_UUID` (FK → CalculationsCatalog role `conditional_format`, filled in P4; NULL for rules without an anchor — value rules without calc, no-DDR files, foreign-anchor copy artifacts), `Range_Start`/`Range_End` (value-rule operands as raw expression text — numbers, quoted strings, variables; FM pre-encoding decoded; a leftover `Range` can survive an operator switch on a type-0 rule — `@type` is authoritative for the kind, never `Range` presence), `Formatting_Membercount` (`@membercount` of the own Formatting block, P6 anti-nesting guard `v_check_cf_rules`), `Local_CSS` (applied format as raw CSS, parsing is API/frontend territory; includes dialog defaults such as `background-color`/`color` even when not actively chosen — the Options bits tell what was selected). Carrier types: leaf-ish objects plus Panels and Button-Bar segments; **Group and Portal never persist own CF** (a rule applied there is dropped on save — fixture-verified), so their `Object_XML` CF matches are always nested children
- **LayoutObjectSymbols** — Inventory of `{{…}}` symbols in text objects (schema 1.27.0, derived in P3 from `Text_Content`; `{{CurrentDate}}`, `{{FoundCount}}`, … — semantically the result of `Get(X)` at display time). One row per (layout object × symbol): `Object_UUID`, `Layout_ID`, `Symbol_Text` (as typed), `Symbol_Norm` (lowercased grouping key — symbols are case-insensitively typable), `Occurrence_Count`. **Deliberately no where-used edges** (symbols are runtime states, not catalog objects) — answer "which layouts show {{PageNumber}}?" by querying this table and joining `LayoutObjects`/`Layouts`
- **ValueListCatalog** — Value lists
- **OptionsForValueLists** — Details of value lists (CustomValues, field references, External source: `External_DS_*`/`External_VL_*` columns for value lists sourced from another file)
- **AccountsCatalog** — User accounts
- **PrivilegeSetsCatalog** — Privilege sets
- **PrivilegeSetRecordAccess** — Custom Record Privileges, table level (per Privilege Set × table × operation View/Edit/Create/Delete; access mode, calc text/hash, evaluation context)
- **PrivilegeSetFieldAccess** — Custom Record Privileges, field level (per Privilege Set × table × field; per-field access mode, only for tables with `Fields access="Custom"`)
- **PrivilegeSetObjectAccess** — Custom Privileges for Layouts/ValueLists/Scripts (per Privilege Set × object; per-object access mode, Layout records-access, class create flag)
- **DDR_ScriptSteps** — Human-readable script steps (optional, only when DDR-Info is available)
- **DDR_Calculations** — Formula chunks for dependency analysis (optional, only when DDR-Info is available). `Chunk_Type` is canonicalized once after extraction (phase 1c): FileMaker's **design functions** (`WindowNames`/`Fensternamen`, `DatabaseNames`, `LayoutIDs`, `ValueListItems`, …) arrive as `PluginFunctionRef` — the chunk type otherwise used for plug-in calls — and are re-typed to `FunctionRef` by a positive name match against `DesignFunctionNames` (the `type` attribute inside `Chunk_Content` is rewritten too, the token text stays as exported); every other chunk keeps its exported type
- **DesignFunctionNames** — Solution-independent name list of FileMaker's design functions in every reference language (`Function_ID`, `Canonical_Name`, `Language`, `Name`, `Name_XML` = the `&#xHH;` char-ref form of non-ASCII names as the DOM chunk path serializes them; NULL when identical). Rebuilt on every import by the generated seed `ingestion/sql/generated/design_functions_seed.sql` (derived from `reference/fm_spec.duckdb` by `ingestion/gen_design_functions.sh`). The positive match list of the phase-1c chunk retype and of `v_check_design_function_retype`; not an object catalog — never joins into ObjectCatalog/ObjectLinks
- **DDR_ChunkListContexts** — One row per ChunkList anchor of the DDR_INFO part (schema 1.27.0), **including empty ChunkLists** (`Chunk_Count = 0` — those leave no row in DDR_Calculations because they have no chunks; FileMaker writes them for typed layout calculations with an expression, losing all references). Carries the anchor's context TO (`Context_TO_ID/Name/UUID` — the direct `TableOccurrenceReference` child next to the `ChunkList`). Join anchors ALWAYS via `Calc_UUID` (anchor name `_<Owner-UUID>_<Slot>`), never via `Calc_Hash`: identical formulas share the hash but each anchor carries its own context TO. Consumers: field-name resolution against the context TO (P2), display-calculation enrichment + empty-ChunkList fallback instances (P4), `v_check_display_empty_chunklist` (P6)
- **PasteIndexList** — List of object IDs for copy/paste operations
- **BaseDirectoryCatalog** — Base directory of the FileMaker file
- **ScriptTriggers** — Script triggers on all three owner levels (`Owner_Type` = `File`/`Layout`/`LayoutObject`; e.g. OnFirstWindowOpen, OnRecordLoad, OnObjectSave). `Trigger_Action` is a generic passthrough of the SaXML `action` attribute (no enum). Mode scope (schema 1.24.0): `Trigger_BrowseMode`/`Trigger_FindMode`/`Trigger_PreviewMode` — SaXML writes only ACTIVATED modes as attributes, so NULL means "mode off", never "unknown". `Trigger_ScriptParameter_FieldName` (1.24.0, OnWindowTransaction only): name-only field reference whose content FileMaker adds to the JSON script parameter — late-bound per triggering table; resolved since 1.26.0 as name-CANDIDATE edges `reads_field · transaction_parameter_field` (one edge per same-named field of the OWN file — a deterministic 1:1 edge is impossible by design; an orphaned name after a field rename is a legitimate state, reported by P6 `v_report_trigger_parameter_fields`, deliberately no FAIL gate). `Trigger_Parameter_Text` (1.26.0): structural plain text of the trigger's parameter calculation (`ScriptReference/Calculation/Text`, CDATA-decoded; all three owner levels) — P4 feeds it into `Formula_Text` of the `script_trigger_parameter` instances (DDR anchors AND a per-trigger no-DDR fallback with `Calc_Kind_Raw='ScriptTrigger_<id>'`, replacing the former collapsed one-instance-per-object fallback), so trigger parameters are visible without DDR-Info too. File-level triggers have no script parameter (the FileMaker dialog offers none); `Trigger_XML` is populated only for Layout/File owners
- **ExtendedPrivilegesCatalog** — Extended privileges (fmwebdirect, fmxdbc, fmapp, etc.)
- **CustomMenuCatalog** — Custom menus with nested hierarchy
- **CustomMenuItemCatalog** — Individual menu items (from Menu_XML: commands, submenu/separator flags)
- **CustomMenuSetCatalog** — Menu sets with member-menu ID lists
- **ThemeCatalog** — CSS rule sets for layouts
- **FileOptionsCatalog** — File options from the Metadata branch: encryption status, minimum version, **auto-login account (security-relevant)**, sharing visibility, default/start layout (→ `default_layout` link)
- **FileAccessAuthorizations** — Inter-file access authorizations
- **LibraryReferences** — Library references (metadata only, blobs discarded)
- **LinkRoleRegistry** — Link-role classification per role: columns `Link_Role`, `Link_Kind` (`usage`/`containment`/`restriction`), `Counts_For_Where_Used` (boolean). No prose/`Description` column — the meaning of each role is the "Link roles" list below. P6 warns when an ObjectLinks role lacks a registry entry
- **ScriptStepRoleMap** — Curated Step_ID → Link_Role mapping for Script→Field links (locale-independent; `Step/@name` is localized in SaXML exports). Canonical_Name documents the English reference name; IDs verified against the reference index `reference/fm_spec.duckdb` (`script_steps.step_id` ≙ SaXML `Step/@id`), which is deliberately NOT a runtime dependency of the converter
- **FilesCatalog** — Metadata of all imported FileMaker files (multi-file support)
- **ObjectCatalog** — Central object registry covering all 25+ object types across all files
- **ObjectLinks** — Links between objects (operational & structural, including cross-file links)
- **VariableUsages** — Every individual variable usage with its context (script, field, layout)
- **VariablesCatalog** — Aggregated overview per variable (set/read counts, scope, files)
- **CalculationsCatalog** — One row per calculation **instance** (schema 1.22.0; successor/superset of the former `v_calc_anchors` build). Identity = Owner × `Calc_Role` × `Calc_Index` (synthetic `Calculation_UUID`, type-tagged md5 — a formula HASH is a property, never the identity: SaXML dedupes chunk lists by content, one hash can serve tens of thousands of instances). Union of the DDR anchors (`DDR_Calc_UUID`, hash/chunk aggregates, `Display_Text`) and the structural slots without a DDR anchor (field validation/message slots, `StepCalculations`, CF bodies, LayoutObject text slots, record-access calcs) — instances exist **also without DDR-Info** (`Formula_Hash`/`Chunk_Count`/… are enrichment, may be NULL). Key columns: `Owner_UUID/Type/Name`, `Calc_Role` (normalized slot vocabulary: `field_calculation`, `auto_enter`, `validation`, `validation_message`, `container_path`, `custom_function`, `step_parameter`, `step_xslt`, `record_access`, `hide`, `tooltip`, `conditional_format`, `script_trigger_parameter`, `menu_install`, …), `Calc_Kind_Raw` (raw DDR suffix), `Calc_Index` (1-based per owner × role, document/position order), `Edge_Subrole` (the `Link_Subrole` the owner-projected edges of this instance carry — join key of `v_calculation_links`), `Formula_Text` (structural plaintext), `Display_Text` (chunk-reconstructed), `Result_Type` (schema 1.27.0, `display_calculation` only: result type from the `%X:` prefix of the merge syntax — `Text` (no prefix, the default), `Number` (`%N:`), `Date` (`%D:`), `Time` (`%I:`), `Timestamp` (`%M:`); unknown prefixes stay raw as `%<X>`; NULL for every other role), `Source_Path` (structural origin). Registered in ObjectCatalog as `Object_Type='Calculation'`; owner containment via the structural `has_calculation` link. **`display_calculation` instances** (schema 1.27.0): `Formula_Text` carries the localized raw formula from the owner's `Text_Content` (i-th `<<ƒ:…>>` occurrence, wrapper + `%X:` prefix stripped) and `Context_TO_UUID/Name` come from `DDR_ChunkListContexts`; typed layout calculations with an EMPTY DDR ChunkList (FileMaker defect) get a fallback instance (`Formula_Hash` = md5 of the empty string, `Display_Text` NULL) plus recovered references matched from the formula text: `reads_field` against the context TO's field names (on a field↔CF name collision the field must appear `${…}`-quoted — FileMaker serializes it that way; unquoted means the CF), `calls_customfunction` against the file's CF names (locale-independent, unlike builtins) and `reads_variable` via the `$`-syntax (string literals stripped) — only BUILTIN function references remain unresolved (localized names). A `%X:`-prefixed chunk whose remainder starts with `$` is a REAL variable behind the result type (`<<ƒ:%N:$$var>>`) and keeps its usage with the prefix stripped
- **v_calculation_links** — VIEW (P4): Calculation → target, **derived** from the canonical owner-projected usage edges (variant A — no physical duplicate edges, no where-used double counting). Non-step owners resolve via ObjectLinks (`Link_Subrole` ↔ `Edge_Subrole`, role whitelist `reads_field`/`validates_by_calc`/`calls_customfunction`/`calls_function`/`calls_pluginfunction`); ScriptStep owners resolve instance-exactly via `XMLCalcReferences`/`PluginFunctionUsages` (`Source_Subkey` = step index — the ObjectLinks anchor is the script and would be ambiguous). Known limits: variable targets missing (live in VariableUsages), `calls_script` via MBS:FM.RunScript missing
- **DuplicateAbsorptions** — Dup-absorption census (monitoring): parsed source-record counts per catalog × file × chunk, written in P1. The P6 view `v_check_absorbed_dups` compares against live row counts — a positive difference means the per-file upsert silently collapsed duplicate-UUID source objects (export defect); reported as a warn finding in the import report
- **DuplicateAbsorptionDetails** — per-occurrence details of colliding intra-file duplicate UUIDs (type, name, container context, plaintext, payload). Schema 1.19.0 adds the UUID-healing mapping: `Healed_UUID` (deterministic md5 replacement UUID a twin received in the catalog, NULL = kept original / absorbed), `Heal_Status` (`kept-original` | `healed` | `absorbed`) and `Discriminator` (the internal FM id the replacement UUID is derived from) — the census is the bidirectional original↔replacement lookup layer. Discriminator formats per catalog: `script_id=N` (ScriptCatalog), `layout_id=N` (Layouts), `to_id=N`, `vl_id=N`, `cf_id=N`, `account_id=N`, `ds_id=N`, `table_id=N` (BaseTable), `table_id=N·field_id=M` (Fields), `script_id=N·step_index=M` (script steps — position-stable only), `layout_id=N·object_id=M` (layout objects). Rows with `Chunk_Seq = -1` were derived at the turbo merge point (duplicate pair split across sub-chunk windows — no chunk-local census exists for those). Replacement UUIDs are 32-char md5 hex WITHOUT dashes → distinguishable from native 8-4-4-4-12 UUIDs by format; `Heal_Status = 'absorbed'` remains only for double serialization (same UUID and same internal id), `FM_UUID_HEAL=0` runs and pre-1.19.0 databases
- **XMLStepReferences / XMLLayoutReferences / XMLCalcReferences** — P2 reference extracts (volatile, rebuilt every run). Schema 1.19.0 adds `Ref_ID` (FileMaker-internal `@id` of the referenced element — the SaXML reference triple is `id`+`name`+`UUID`) and `TO_Ref_ID` (context-TO `@id`, field references only: `FieldReference/@id` is table-local, the field key is two-stage via the TO). Used by the P4 rewrite stage to disambiguate intra-file duplicate UUIDs; NULL where the source carries no reference element (variables, name-only chunk types)
- **v_script_block_tree** — MATERIALIZED per-step control-flow nesting (built with the analysis views): for every script step its Loop and If depth (`loop_depth_before/after`, `if_depth_before/after`, `block_depth_before`, raw `if_running_depth` for unbalanced-If detection). **Use this whenever branch scope matters** (is step X inside a Loop / which If level — e.g. dead-code or window-lifecycle reasoning); never reconstruct nesting by hand from sequential `Step_Index` reads. Partition key is `(File_Name, Script_ID)` — not `Script_UUID`, which is non-unique in merge-artifact cases

### Common columns

Every table contains:
- An `ID` column (e.g. `BT_ID`, `Script_ID`, `Field_ID`)
- A `Name` column (e.g. `BT_Name`, `Script_Name`, `Field_Name`)
- A `UUID` column for unique referencing

Use UUIDs for JOINs; the row order matches the FileMaker solution; script steps additionally carry `Step_Index`.

**`Step_Index` is 0-based and gapless** (per script: `min = 0`, `max = n-1`). FileMaker's
Script Workspace and every fm-lab user-facing surface count 1-based — **always render
`Step_Index + 1` when quoting a step number to a user**, and subtract 1 when translating a
user-quoted step number back into a `Step_Index` filter. Sort/join on the raw `Step_Index`.

## FieldsForTables — column details

Base columns: Table_ID/Name/UUID, Field_ID/Name/Type, Data_Type, Field_Comment, Field_UUID, Is_Global, Max_Repetitions, DDR_Hash, Calculation_Text. Plus 13 AutoEnter columns:

**AutoEnter base attributes (all types):**
- `AutoEnter_Type` — Type: `Looked_up`, `SerialNumber`, `Calculated`, `ConstantData`, `CreationDate`, etc. (NULL for fields without AutoEnter)
- `AutoEnter_ProhibitMod` — May the user overwrite the value?

**Lookup details (only AutoEnter_Type = 'Looked_up'):**
- `Lookup_Field_Name` / `Lookup_Field_UUID` — Source field (name and UUID)
- `Lookup_TO_Name` / `Lookup_TO_UUID` — Relationship TO (name and UUID)
- `Lookup_DontCopyIfEmpty` — Do not copy empty values?
- `Lookup_NoMatchOption` — `DoNotCopy` or `ConstantData`

**AutoEnter Calculated details (only AutoEnter_Type = 'Calculated'):**
- `AE_Calc_Text` — Plain-text formula (complementary to `Calculation_Text` for true Calculated Fields)
- `AE_Calc_Hash` — DDR hash (complementary to `DDR_Hash`; JOIN with DDR_Calculations possible)
- `AE_Calc_OverwriteExisting` — Overwrite existing values?
- `AE_Calc_AlwaysEvaluate` — Re-evaluate on every change?

**ConstantData (only AutoEnter_Type = 'ConstantData'):**
- `AE_ConstantData` — Fixed default value

**Note:** `Calculation_Text`/`DDR_Hash` apply to `fieldtype="Calculated"` (true Calculated Fields), while `AE_Calc_Text`/`AE_Calc_Hash` apply to `fieldtype="Normal"` with an AutoEnter calculation. A field never has both populated at the same time.

**Validation / storage / serial / summary columns (schema 1.5.0):**
- `Validation_Type/_AllowOverride/_NotEmpty/_Unique/_Existing` — field validation options; `Validation_VL_ID/_Name/_UUID` — validation by value list (→ `uses_valuelist` link, Subrole `validation`)
- `Storage_AutoIndex`, `Storage_Index` (`None`/`All`/`Minimal`), `Storage_StoreCalcResults` — indexing/storage options
- `Serial_Increment/_NextValue/_Generate` — serial-number details (only `AutoEnter_Type='SerialNumber'`)
- `Summary_Operation`, `Summary_Field_Name/_UUID` — summary definition (only `fieldtype='Summary'`; → `summarizes_field` link)

**Field-option coverage (schema 1.10.0):**
- `Validation_AlwaysValidate` — `<Validation @alwaysValidate>`
- `Validation_StrictType` — strict data type from `<Strict>` (`FourDigitYear`, numeric-only, time-of-day; raw token, no enum constraint)
- `Validation_MaxChars` — `<MaximumSize>` (max characters)
- `Validation_Range_From/_To` — `<Range @from/@to>`
- `Validation_Calc_Text/_Calc_Hash` — validate-by-calculation (`<Validation><Calculated>`; hash → `DDR_Calculations`, feeds the `validates_by_calc` link)
- `Validation_Message` — static custom error message (`<Message>`); `Validation_Message_Calc_Hash` — `<MessageCalc>` (message-by-calc)
- `Storage_IndexLanguage/_IndexLanguage_ID` — default index language (`<Storage><LanguageReference @name/@id>`; a **child element**, not an attribute)
- `Summary_RestartEachGroup`, `Summary_RepetitionMode` (`Together`/`Individually`) — `<SummaryInfo @restartEachGroup/@summarizeRepetition>`

**Layouts metadata columns (schema 1.5.0):** `L_TO_UUID` (context TO by UUID), `L_Width`, `L_Theme_ID/_Name/_UUID` (raw `<LayoutThemeReference>` triple), `L_Theme_Base` (schema 1.9.0, `@Base`).

**Layout theme — always read `L_Theme_Resolved_Name/_UUID` (schema 1.21.0), never the raw columns.**
SaXML encodes the **Classic theme as an empty element** `<LayoutThemeReference/>` — no `id`, `name`, `UUID` or `Base`. Only non-Classic themes carry the attribute triple, so the raw `L_Theme_*` columns are `NULL` for **every** Classic layout and the literal `'com.filemaker.theme.classic'` appears in no layout row at all. A rule that tests `L_Theme_Name = '…classic'` (or `L_Theme_Base`) therefore silently returns zero findings on a solution that is entirely Classic.

The derived columns (filled in P3, `uses_theme` links built from them in P4) resolve this:
- `L_Theme_Resolved_Name` — effective theme name, locale-independent; empty reference → `com.filemaker.theme.classic`. Display name via `ThemeCatalog.Theme_Display`.
- `L_Theme_Resolved_UUID` — effective theme UUID; for Classic taken from the file's `ThemeCatalog` **by theme name** (`Theme_ID = 1` is *not* reliably Classic), `NULL` if the file has no Classic entry.

Both are populated for real layouts only — folders (`Folder_Type` `True`/`Marker`) and separators never carry a theme and stay `NULL`. When a query must also work against catalogs older than 1.21.0, fall back to `L_Theme_Base = '…classic' OR L_Theme_Name = '…classic' OR L_Theme_ID IS NULL` (plus the folder/separator exclusion).

## LayoutObjects — structure

**Base attributes:**
- `Layout_ID` — Link to the layout (JOIN with Layouts.L_ID)
- `Part_Type` — Layout section (Header, Body, Footer)
- `Object_ID` — Object ID (unique only within a layout)
- `Object_UUID` — Unique UUID of the object
- `Object_Type` — Type of the object (Text, Edit Box, Button, Portal, Rectangle, etc.)
- `Object_Name` — User-defined name (often empty)

**Positioning:** `Bounds_Top`, `Bounds_Left`, `Bounds_Bottom`, `Bounds_Right` — position and size in pixels

**Nesting:**
- `Parent_Object_ID` — Reference to the parent object (NULL = top-level)
- `Nesting_Level` — Nesting level (0 = top-level; nested containers reach depth 5 in practice — e.g. Tab Control → Panel → Group → Grouped Button → object)

**Polymorphic properties:** `Object_XML` — full object definition as a raw XML fragment, queryable via `xml_extract_text(Object_XML, '/xpath')[1]` (requires `LOAD webbed;`)

**Object types (22):**
- **Input**: Edit Box, Drop-down List, Pop-up Menu, Radio Button Set, Checkbox Set, Drop-down Calendar
- **Display**: Text, Graphic, Container, Web Viewer
- **Action**: Button, Grouped Button, Button Bar, Popover Button
- **Container**: Portal, Group, Tab Control, Panel, Slide Control, PopoverPanel
- **Graphic**: Rectangle, Line, Oval

## PrivilegeSetRecordAccess (Custom Record Privileges)

When a privilege set uses **Custom Record Privileges**, the `<Records>` element only carries `Custom="True"` and `PrivilegeSetsCatalog.Records_*` no longer reflect the real access. The detail tree (`Records/Custom/ObjectList/Table`) is parsed into **PrivilegeSetRecordAccess** — one row per privilege set × table × operation:

- `PrivilegeSet_ID` / `PrivilegeSet_Name` / `PrivilegeSet_UUID` — owning privilege set
- `BaseTable_ID` / `BaseTable_Name` / `BaseTable_UUID` — target base table (NULL when `Table_Type='New'`)
- `Table_Type` — `existing` or `New` (the default rule for future, not-yet-existing tables)
- `Operation` — `View` | `Edit` | `Create` | `Delete`
- `Access_Mode` — `NoAccess` | `ReadOnly` | `ReadWrite` | `Calculation` | `Custom` | … (kept as VARCHAR, no enum, so unknown modes survive)
- `Calculation_Text` — plain-text formula (CDATA) when `Access_Mode='Calculation'`, normalized
- `DDR_Hash` — `Calculation/DDRREF/@hash`; JOIN-able with `DDR_Calculations.Calc_Hash`
- `Context_TO_Name` / `Context_TO_UUID` — evaluation context (the calc's table occurrence)
- `Fields_Access` — the table's `<Fields>@access` (one value per table; `Custom` opens a per-field detail tree → PrivilegeSetFieldAccess)
- `File_Name`

**Graph integration:** all references inside record-access calcs (via `DDR_Hash` → `DDR_Calculations`) are emitted into `XMLCalcReferences` with `Source_Type='PrivilegeSet'` and resolved to graph links (Link_Subrole = `<Operation>:<Table>` where applicable): **FieldRef** → `PrivilegeSet → Field (reads_field)`, **CustomFunctionRef** → `PrivilegeSet → CustomFunction (calls_customfunction)`, **PluginFunctionRef** → `PrivilegeSet → PluginFunction (calls_pluginfunction)` (via `PluginFunctionUsages`). **VariableReference** is handled separately — it has no generic XMLCalcReferences→link pass, so its read-usage is registered in `VariableUsages` (`Context_Type='record_access_calc'`) and becomes a `PrivilegeSet → Variable (reads_variable)` link. Together these close the where-used gap for any field/variable/CF/plugin referenced **only** by a Custom Record Privilege calc. Requires DDR-Info; without it the table is still populated (calc text comes from the CDATA subtree), but no graph links are created.

**Field level — `PrivilegeSetFieldAccess`:** when a table's `Fields_Access='Custom'`, the per-field detail tree (`…/Table/Fields/Field`) is parsed into one row per privilege set × table × field: `BaseTable_*`, `Field_ID`/`Field_Name`/`Field_UUID`, `Field_Type` (`existing`/`New`), `Access_Mode` (`NoAccess`/`ReadOnly`/`ReadWrite`), `File_Name`. Tables without custom field access produce no rows here.

**Other object classes — `PrivilegeSetObjectAccess`:** the same `Custom="True"` mechanism applies to Layouts, ValueLists and Scripts. Unified table with an `Object_Class` discriminator (`Layout`/`ValueList`/`Script`), one row per privilege set × object: `Object_ID`/`Object_Name`/`Object_UUID`, `Item_Type` (`existing`/`New`), `Access_Mode`, `Records_Access` (Layouts only), `Class_Allow_Create`, `File_Name`. Classes left in the simple attribute form (e.g. `<ValueLists Create="True" …>`) produce no rows.

Both feed the graph via **scoped restriction links** (`restricts_field` / `restricts_object`), but only for actual restrictions (`Access_Mode <> 'ReadWrite'`). **A restriction is *not* a usage** — these roles never make an object appear "used" in where-used or dead-code analysis. Folders/separators in the access tree are excluded. Link_Subrole carries the access mode.

## VariableUsages / VariablesCatalog

**VariableUsages** — every individual usage of a variable:
- `Variable_Name` — Full name including the prefix (`$sort`, `$$Module`)
- `Variable_Scope` — `global`, `local`, `superglobal`, `let_local`
- `Usage_Type` — `set` (assignment) or `read` (read access)
- `Context_Type` — `script_step`, `calculation`, `auto_enter_calc`, `custom_function`, `layout_object`, `record_access_calc` (variable read inside a Custom Record Privilege calc; Context_Name = `<PrivilegeSet> › <Operation>:<Table>`)
- `Context_UUID`, `Context_Name` — UUID and name of the context
- `Script_Name`, `Script_UUID`, `Step_Index` — Script context
- `Table_Name`, `Field_Name` — Field context
- `Source` — `set_variable_step`, `ddr_chunk`, `mbs_variable_call`, `merge_variable`, `regex_fallback`
- `File_Name` — FileMaker file

**VariablesCatalog** — aggregated overview per variable:
- `Variable_Name`, `Variable_Scope`, `Display_Name`, `Normalized_Name`
- `Set_Count`, `Read_Count`, `Script_Count`, `File_Count`
- `Files` (VARCHAR[]) — list of file names
- `Has_Spaces` — spaces in the name?
- `Source_Reliability` — `ddr`, `mbs`, `merge`, `regex`

**Data sources:** DDR_Calculations VariableReference chunks (primary), Set Variable steps, MBS superglobals (Variable.Set/Get), merge variables from layouts, LayoutObject formula hashes (Conditional Formatting, Hide, Tooltip, etc.), regex fallback for files without DDR, display-calculation recovery (`Source='display_calc_recovery'`, 2.20.0 — variables regex-matched from the recovered formula text of empty-ChunkList layout calculations).

**Prefix convention for Display_Name:** `$` → local, `$$` → global, `$$$` → superglobal (synthetic, MBS Plugin)

**ObjectCatalog integration:** Variables are registered with `Object_Type = 'Variable'`. UUID = `md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name)` — the scope anchor is the script for local variables, the file for global variables, `__global` for superglobals.

**ObjectLinks roles:** `sets_variable`, `reads_variable`, `displays_variable`

## DDR-Info support (optional)

Starting with FileMaker 21, the export option **"Include details for analysis tools"** adds detailed metadata.

**Check availability:**
```sql
SELECT Has_DDR_INFO, FileMaker_Version, Filename FROM XMLMetadata;
```

**DDR_ScriptSteps** and **DDR_Calculations** are always created, but only populated when `Has_DDR_INFO = 'True'`.

**Usage with conditional display:**
```sql
SELECT
    s.Script_Name,
    s.Step_Index,
    CASE WHEN (SELECT Has_DDR_INFO FROM XMLMetadata) = 'True'
         THEN ddr.Step_Text
         ELSE s.Step_Name END as Display_Text
FROM StepsForScripts s
LEFT JOIN DDR_ScriptSteps ddr ON s.DDR_UUID = ddr.Step_UUID;
```

### DDR_Hash for Calculated Fields & CustomFunctions

With FileMaker 21+ and DDR-Info enabled, **FieldsForTables** and **CustomFunctionsCatalog** carry a `DDR_Hash` column that joins to **DDR_Calculations** via `DDR_Hash = Calc_Hash`:

- `FieldsForTables.DDR_Hash` — hash for Calculated Fields (NULL for other field types)
- `CustomFunctionsCatalog.DDR_Hash` — copied from `CalcsForCustomFunctions.DDR_Hash`

```sql
-- Dependencies of a Calculated Field
SELECT f.Field_Name, f.Table_Name, COUNT(d.Chunk_Index) as Dependency_Count
FROM FieldsForTables f
JOIN DDR_Calculations d ON f.DDR_Hash = d.Calc_Hash
WHERE f.Field_Type = 'Calculated'
GROUP BY f.Field_Name, f.Table_Name;

-- Dependencies of a CustomFunction
SELECT cf.CF_Name, COUNT(d.Chunk_Index) as Chunk_Count
FROM CustomFunctionsCatalog cf
JOIN DDR_Calculations d ON cf.DDR_Hash = d.Calc_Hash
GROUP BY cf.CF_Name;
```

## Universal catalogs

**FilesCatalog** — metadata of all imported FileMaker files:
- `File_Name` — file name without the .fmp12 suffix (PRIMARY KEY)
- `File_FullName`, `File_UUID`, `FileMaker_Version` (e.g. "ProAdvanced 22.0.4"), `Has_DDR_INFO`, `Import_Timestamp`, `XML_Path`

**ObjectCatalog** — central object registry:
- `Object_UUID` (PRIMARY KEY), `Object_Type`, `Object_Name`, `File_Name`, `Source_Table`, `Object_ID`

**Supported object types:**
- BaseTable, TableOccurrence, Field, Relationship
- Script, ScriptStep, Layout, LayoutObject (26 subtypes)
- CustomFunction, ValueList, Account, PrivilegeSet
- Theme, CustomMenu, ExtendedPrivilege, ScriptTrigger
- ExternalDataSource, BaseDirectory, LayoutPart
- File (owner anchor for file-level triggers; UUID = `FMSaveAsXML/@UUID`)
- Variable (see above), PluginFunction / PluginComponent
- Calculation (schema 1.22.0) — one calculation **instance** per owner slot (`CalculationsCatalog`); generated names `<Owner> › <Role label>[ N]`. High-cardinality like ScriptStep/LayoutObject: countable everywhere, listable via explicit type filter, excluded from unfiltered name search (generated names would flood owner-name matches)

**ObjectLinks** — links between objects:
- `Source_UUID` / `Target_UUID` — source and target object UUIDs
- `Source_Type` / `Target_Type` — object types
- `Link_Type` — `operational` (functional dependencies) or `structural` (container hierarchies)
- `Link_Role` — specific role (e.g. calls_script, displays_field, parent_layout)
- `Is_Cross_File`, `Source_File` / `Target_File` — multi-file analyses

## Link roles (60 registered: 49 usage, 9 containment, 2 restriction)

Authoritative list incl. semantics: **`LinkRoleRegistry` table** — query it when in doubt. Overview:

- Field → BaseTable (parent_table)
- Field → Field (lookup_source) — Lookup target field references the source field
- Field → TableOccurrence (lookup_relationship) — Lookup target field uses this relationship
- Field → Variable (reads_variable) — Calculated/AutoEnter formula references the variable
- Field → Field/CustomFunction (validates_by_calc) — a field-validation calc (`<Validation><Calculated>`) or its custom-message calc (`<MessageCalc>`) references the target; Link_Subrole `validation` (check calc) / `validation_message` (message calc — separate since schema 1.22.0). A real usage → counts for where-used. Closes the gap for objects referenced **only** by a field validation. Field AutoEnter references carry Link_Subrole `auto_enter` since 1.22.0 (role stays reads_field/calls_*) — the slot separation feeds `v_calculation_links`
- TableOccurrence → BaseTable (base_table)
- TableOccurrence → ExternalDataSource (data_source)
- Relationship → TableOccurrence (left_table, right_table)
- Relationship → Field (left_field, right_field) — join-predicate fields; multi-field joins produce one pair **per predicate** since schema 1.2.0 (`Predicate_Index`)
- Relationship → Field (sort_field) — field of a relationship side's sort order; Link_Subrole = `left`/`right`. A real sort dependency, appears in the field's where-used (schema 1.3.0)
- Layout → TableOccurrence (context_table)
- LayoutObject → Layout (parent_layout)
- LayoutObject → LayoutObject (parent_object, structural)
- LayoutObject → Field (displays_field)
- LayoutObject/Layout/File → Script (triggers_script) — trigger AND button action, one role for both (where-used/graph consumers never split it), and since converter 2.17.0 the **only counting where-used representation** of a script trigger (the granular `trigger_script` edge is demoted, see below). `Link_Subrole` distinguishes the kinds since converter 2.14.0: the canonical trigger event (e.g. `OnObjectSave`; raw `Trigger_Action` passthrough, so a source-locale leak flows through as-is) vs. `button_action` for Button/GroupedButton/PopoverButton actions. Since converter 2.17.0 the event mirrors exist **symmetrically on all three owner levels** (`Source_Type` = LayoutObject/Layout/File, one edge per `ScriptTriggers` row with a script — invariant guarded by P6 `v_check_trigger_mirror_symmetry`); button actions exist only on the object level. Attribution is **owner-exact** since converter 2.15.0: one edge per **own** reference of the object (P2 ancestor guard — containers no longer inherit their descendants' script refs, which previously produced one phantom `button_action` copy per nesting level on Portal/Tab Control/Panel/Group/Button Bar/…). Within the object the split stays a multiset reconstruction per (object, file, script) group: t edges from `ScriptTriggers` carry the event, the remaining own rows are `button_action` (invariant: own rows = t + own actions). Catalogs imported before 2.14.0 carry NULL subroles; before 2.15.0 still the container phantom edges; before 2.17.0 no layout-/file-level mirrors (and `trigger_script` still counting)
- LayoutObject → ValueList (uses_valuelist) — field uses the value list
- LayoutObject → TableOccurrence (portal_context) — portal data source
- LayoutObject → Variable (displays_variable, reads_variable) — merge variable, trigger parameter, DDR formulas (Conditional, Hide, Tooltip, etc.)
- LayoutObject → Layout/TableOccurrence/Field (navigates_to_layout, navigates_to_to, navigates_to_field/sorts_by_field/… via `ScriptStepRoleMap`) — **button-embedded single step** (`GroupedButton/Button/action/Step`): a button can execute a single script step instead of calling a script. Its references produce the same **reused** roles as the script side (`Source_Type='LayoutObject'` distinguishes the carrier; no new registry roles). Extracted in P2 from `Object_XML` with paths anchored at the button (`Ref_Type='layout_step'`/`table_occurrence_step'`/`field_step'`; step `@id` in additive column `XMLLayoutReferences.Step_ID` carries the locale-independent field role). Semantic gating like the script side: `navigates_to_to` only for GTRR (`Step_ID=74`) — the context TO of a Go-to-Field/Sort step is not a navigation target. Closes the largest remaining where-used gap class (layouts reachable only via button appeared as false positives in `unused_layout`)
- ScriptStep → Script (parent_script, structural)
- Script → Script (calls_script) — `Link_Subrole` qualifies the call context (since schema 1.20.0): `on_server` (Perform Script on Server, step 164) / `on_server_callback` (step 210) mark the callee as **server-side executed** (the platform-binding evidence for FileMaker Server); `MBS:FM.RunScript` marks plugin-mediated calls; NULL = ordinary Perform Script. One role for all consumers — where-used and call chains never need to enumerate subroles. Note: "By name" PSoS callsites (target computed at runtime) have no static target and therefore no edge — their expression lives in `StepCalculations` (Slot `List`)
- Script → Field (sets_field, navigates_to_field; plus reads_field/finds_in_field/sorts_by_field/imports_to_field/exports_from_field/inputs_to_field per step-type group, and references_field as the fallback for uncurated step types). Role assignment is locale-independent via the step ID (`ScriptStepRoleMap` table): SaXML writes `Step/@name` in the exporting client's UI language, so name matching broke for localized (German) exports. Uncurated step IDs land in references_field and are reported by the P6 check `v_check_step_roles`
- Script → Layout (navigates_to_layout) — Go to Layout steps (and the target layout of "Go to Related Record")
- Script → TableOccurrence (navigates_to_to) — target TO of "Go to Related Record" (`Ref_Type='tableOccurrence'`). Closes the where-used gap for TOs serving only as GTRR targets
- Script → ValueList (sorts_by_valuelist) — reference value list of a custom sort in "Sort Records" (`<Sort type="Custom">` with `<ValueListReference>`; `Ref_Type='valuelist'`). Closes the where-used gap for value lists used only as sort reference (the sort *field* is linked via `sorts_by_field`)
- LayoutObject → ValueList (sorts_by_valuelist, Subrole `portal`/`button`) — custom sort of a portal or a button-embedded sort step. P2 extraction over `Object_XML` with paths **anchored** at the owning object (`Ref_Type='valuelist_sort'`; a `//` XPath would double-match inherited portal sorts on ancestor containers, since `Object_XML` contains the full subtree)
- Relationship → ValueList (sorts_by_valuelist, Subrole `left`/`right`) — custom sort of a relationship side (`RelationshipCatalog.Left/Right_Sort_ValueList_UUIDs`, analogous to `sort_field`)
- ValueList → ValueList (source_valuelist) — external value list: local wrapper (`<Source value="External">`) → target VL of the source file. The target UUID is EMPTY in the XML → resolved via data source (target file) + VL ID (fallback name); unresolved targets reported by P6 `v_check_external_vl_unresolved`
- ValueList → ExternalDataSource (data_source) — data source of an external wrapper (same role as TableOccurrence → ExternalDataSource)
- Script → Variable (sets_variable, reads_variable)
- CustomFunction → Variable (reads_variable, sets_variable)
- ValueList → Field (source_field)
- ValueList → TableOccurrence (source_table)
- ScriptTrigger → Script (trigger_script) — granular detail edge of the reified trigger node. Since converter 2.17.0 `Counts_For_Where_Used=FALSE` (kind stays `usage`): where-used runs over the owner mirrors (`triggers_script·<event>`, all three owner levels), otherwise the same `ScriptTriggers` row would count twice. The edge remains for navigation, the trigger detail page and the graph focus bridge; it is excluded from `LogicalLinks`/`ClusterEdges` (graph policy: trigger nodes were pure script satellites — 0 incoming edges)
- ScriptTrigger → Layout/LayoutObject/File (trigger_owner) — structural back-link from a trigger to its owner; Link_Subrole = trigger type (e.g. `OnObjectSave`). Lets "which triggers hang on layout/object/file X?" be a direct graph query. The REST-API resolves reference-list containers from this edge for ALL three owner types (Layout and File directly, LayoutObject via one `parent_layout` hop) — file-level trigger references carry `Container_Type='File'`
- ScriptTrigger → Field (reads_field, Subrole `transaction_parameter_field`) — name-CANDIDATE edges for the OnWindowTransaction `scriptParameterFieldName` (schema 1.26.0): one edge per same-named field of the OWN file. The binding is name-only and late-bound per triggering table, so candidates are the model limit (no cross-file guessing); 0 candidates = orphaned name (legitimate, see P6 `v_report_trigger_parameter_fields`). Counts for where-used like every `reads_field`; excluded from `LogicalLinks`/`ClusterEdges` since converter 2.17.0 (speculative late-binding — would keep the trigger node in the graph as a satellite)
- Account → PrivilegeSet (privilege_set)
- PrivilegeSet → Field (reads_field) — field referenced by a Custom Record Privilege calc; Link_Subrole = `<Operation>:<Table>`
- PrivilegeSet → Variable (reads_variable) — variable read by a Custom Record Privilege calc; via `VariableUsages.Context_Type='record_access_calc'`. A *read*, not a restriction — counts for where-used/dead-code (unlike `restricts_*`)
- PrivilegeSet → CustomFunction (calls_customfunction) / PrivilegeSet → PluginFunction (calls_pluginfunction) — CF/plugin called by a Custom Record Privilege calc
- PrivilegeSet → Field (restricts_field) — field-level restriction; Link_Subrole = access mode. Scoped to restrictions only (`Access_Mode <> 'ReadWrite'`); **never counts as usage**
- PrivilegeSet → Layout/ValueList/Script (restricts_object) — object-level restriction; Link_Subrole = access mode. Scoped to restrictions only; folders/separators excluded
- PrivilegeSet → ExtendedPrivilege (grants_privilege) — which sets grant fmapp/fmxdbc/fmwebdirect etc. (access audit)
- Layout → Theme (uses_theme) — layouts carrying a `LayoutThemeReference` (theme cleanup: which themes are in use?)
- Layout → CustomMenuSet (uses_menuset) — layout-bound menu set (the built-in default id=0/"[File Default]" is normalized to NULL in P1 and produces no link)
- Script → CustomMenuSet (installs_menuset) — Install-Menu-Set steps (via `XMLStepReferences` Ref_Type='menuset')
- CustomMenuItem → CustomMenu (opens_menu) — submenu item (`isSubMenuItem="True"`) → the menu it opens (`CustomMenuReference/@id`, no UUID → P4 resolves via `(File_Name, Menu_ID)` against `CustomMenuCatalog`; menu IDs are file-local). A real usage, deliberately NOT `parent_menu` (the containment-style owner backlink): closes the where-used gap for menus that only serve as a submenu of another (those need not be menu-set members → `contains_menu` doesn't cover them) and makes the menu hierarchy navigable. Unresolvable target IDs (built-in menu / outside the corpus) reported by P6 `v_check_submenu_unresolved`
- LayoutPart → Layout (parent_layout, structural) — parts anchored to their layout; Link_Subrole = part type
- LayoutPart → Field (breaks_on_field) — sub-summary break field (`Part/Definition/FieldReference`); Link_Subrole = part type. Closes the where-used gap for fields used only as a sub-summary break
- Field → ValueList (uses_valuelist, Subrole `validation`) — field validation by value list (a VL used only for validation no longer appears unused)
- Field → Field (summarizes_field) — summary field → summarized field; Link_Subrole = operation (Total/Average/…)
- File → Layout (default_layout) — start layout from the file options
- File → Account (auto_login_account) — auto-login account from the file options (security-relevant; unresolved when the referenced account does not exist)
- Owner → Calculation (has_calculation, structural/containment) — every calculation instance hangs on its owner (Field/ScriptStep/LayoutObject/Layout/File/CustomFunction/CustomMenu[Item]/PrivilegeSet); Link_Subrole = `Calc_Role[:Calc_Index]`. **Never counts as usage** (variant A: the usage semantics stay on the owner-projected edges; Calculation → target is only the derived view `v_calculation_links`); being structural it also never enters LogicalLinks/ClusterEdges
- Layout/File → Field/CustomFunction/BuiltinFunction/PluginFunction (reads_field, calls_customfunction, calls_function, calls_pluginfunction) — layout-/file-level **script-trigger parameter** calcs (schema 1.22.0, harvested from `ScriptTriggers.Trigger_XML`); Link_Subrole = `ScriptTrigger_<id>`. Closes the where-used gap for objects referenced only in a layout-/file-trigger parameter
- PluginFunction naming: qualified as `MBS:<Sub>::<Sub>` (e.g. `MBS:List.Sort::List.Sort`); PluginComponents aggregate as `MBS::<Component>` via `groups_into`. SubNames resolve in **two stages**: chunk-proximity pairing in P2 (`MBS_SubnameMap`) plus a plain-text recovery pass in P3.5 (FileMaker's DDR export drops the argument NoRef chunk when a comment sits next to the call or calls nest — the lexer recovers those from the calc CDATA). A `PluginFunctionUsages.Plugin_Function_Name` still reading bare `'MBS'` therefore means a **genuinely dynamic first argument** (`MBS($var; …)`) — such calls have no catalog object and stay unlinked by design. **Design functions are never PluginFunctions:** the SaXML export tags `WindowNames`, `DatabaseNames`, `LayoutIDs`, `ValueListItems`, … as `PluginFunctionRef` in the authoring client's language (`Fensternamen`); phase 1c re-types those chunks, so they register as `BuiltinFunction` (raw token, canonicalized at query time like the localized Get parameters) with `calls_function` edges. The chunk type also covers plug-ins without a namespace and unresolvable identifiers (deleted custom functions) — those stay PluginFunction

## Reference attachments (`ref` / `plugref`) — platform & OS tables

Not part of the solution catalog: two solution-independent reference DBs the
REST-API attaches read-only (`ref` = `reference/fm_spec.duckdb`, `plugref` =
`reference/plugin_spec.duckdb`; the fm-test direct path attaches them itself).
Full schema: fm-spec repo `db/schema.md` (fm_spec) and the schema page
`docs/fm-lab/schema/plugin-spec.md` (plugin_spec — bundled with every release,
provenance in its `reference_meta` table). The platform/OS layer in
brief:

- **`ref.step_compat`** — Claris runtime tri-state per step (NULL = Partial,
  see CLAUDE.md §7).
- **`ref.function_platform_affinity`** (≥ 1.12.0) — curated runtime affinity
  of functions (`go`/`dedicated` rows; affinity, never compatibility).
- **`ref.step_os_affinity` / `ref.function_os_affinity`** (≥ 1.13.0) — the
  curated OS sub-axis from the Claris help prose. **OS vocabulary strictly
  `macos|windows|linux|ios`** — `ios` is the operating system (hosts
  FileMaker Go AND Claris iOS SDK apps); runtime terms never appear in an OS
  column. Affinity classes: `exclusive` (only on the listed OS) /
  `unsupported` (source-true inverse — resolve against the host-OS set of the
  object's runtimes, never against all 4) / `variant` (runs everywhere,
  OS-dependent behavior; no findings consumption) / `os_probe`
  (functions only, `os IS NULL`: Get(SystemPlatform) & co — guard idiom,
  not a binding). Absence of a row = "Claris states nothing", never
  "runs everywhere".
- **`ref.runtime_os_matrix`** (≥ 1.13.0) — host matrix runtime × OS
  (`fm_env` = step_compat vocabulary + `odata` + `ios_sdk`); the ONLY
  sanctioned translator between the runtime and OS axes. `cloud` has no rows
  until its host OS is documented with a Claris source.
- **`plugref.plugin_function_platforms`** — verbatim vendor flags (MBS:
  binary per macos/windows/linux/server/ios_sdk axis).
- **`plugref.plugin_os_map`** (≥ 1.1.0) — curated fold of the vendor platform
  axes into the OS vocabulary (macos/windows/linux 1:1; `ios_sdk` → `ios`
  with qualifier `sdk-only`; `server` is a runtime statement — no OS row).
