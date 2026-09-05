# Schema

FM-Lab stores everything it knows in DuckDB databases — there is no hidden application model behind them. Two databases matter:

- **The solution catalog** — `db/fm_catalog.duckdb`, one per [solution](../rest-api/endpoints/Solutions%20API.md) bundle. It is built by the [XML conversion pipeline](../Wiki/katana-engine.md) from a `SaveCopyAsXML` export (structure documented in the [FileMaker XML reference](../xml/XML.md)) and describes *your* solution: every object, every property, every reference.
- **The language reference** — `reference/fm_spec.duckdb`, shipped with FM-Lab and solution-independent. It describes *FileMaker itself*: the script-step and function vocabulary, localized names, machine-readable syntax and XML emission rules (see [fm-spec](../Wiki/fm-spec.md)).

Every analysis, dashboard, REST endpoint and code-generation gate in FM-Lab works against these tables. This page is the map; each table links to a sub-page with its purpose and the exact column list.

## Conventions

A few rules hold across the whole solution catalog:

- **ID / Name / UUID triplets.** Every catalog table identifies its objects with an `…_ID`, an `…_Name` and an `…_UUID` column (e.g. `Script_ID` / `Script_Name` / `Script_UUID`). Numeric FileMaker IDs are only unique *per file* — join them together with `File_Name`, or better, join across tables via the UUID columns.
- **`File_Name` scoping.** Nearly every table carries `File_Name`, keyed against [FilesCatalog](object-catalog/FilesCatalog.md) — the catalog holds all files of a multi-file solution side by side.
- **Order is preserved.** Row order matches the FileMaker solution; script steps additionally carry an explicit `Step_Index`.
- **References are pre-resolved.** Which fields a script sets, which scripts a button calls, which value list a field uses — all of that is resolved at import time into [ObjectLinks](object-catalog/ObjectLinks.md). Raw `*_XML` columns exist as a last resort, not as the primary query surface.
- **Names are localized, IDs are not.** SaXML exports write object and step names in the UI language of the exporting client. Robust analyses key on numeric IDs (e.g. `Step_ID`) and UUIDs, never on name literals.
- **Duplicate UUIDs are healed.** FileMaker exports occasionally carry the same UUID on two different objects of one file (a copy-paste artifact). The import keeps both objects: one keeps the original UUID, every further twin gets a deterministic synthetic replacement UUID — an md5 hex string, 32 characters without dashes, formally distinguishable from a native UUID. The original↔replacement mapping is preserved in the census; see [UUID Healing and Duplicate Census](UUID%20Healing%20and%20Duplicate%20Census.md).
- **The schema itself is versioned.** Every built catalog carries its schema version in the `SchemaInfo` table; a version mismatch triggers an automatic full rebuild. All versions and their changes: [Schema Version History](Schema%20Version%20History.md).


---

## 1 · The FileMaker object catalog

The heart of the solution catalog is a deliberately simple pair: a registry of **objects** and a registry of the **links** between them. Whatever the object type — a field, a script, a layout object five levels deep inside a tab control, even a synthetic object like a variable or a plugin function — it has exactly one row in [ObjectCatalog](object-catalog/ObjectCatalog.md) and one stable `Object_UUID`. Every reference between two objects, whether functional ("this script sets that field") or structural ("this object sits on that layout"), is one row in [ObjectLinks](object-catalog/ObjectLinks.md).

This pair is what makes FM-Lab's dependency analysis uniform: *where-used*, *dead code*, call chains, cross-file dependencies and the graph views are all walks over the same edge list, regardless of object type. The vocabulary of those edges — 60 link roles — is classified in [LinkRoleRegistry](object-catalog/LinkRoleRegistry.md), which also records the crucial distinction between links that count as real usage and links that do not (a privilege restriction on a layout, for instance, is not a usage of that layout).

| Table | Content |
|---|---|
| [ObjectCatalog](object-catalog/ObjectCatalog.md) | Central registry of every object across all files (25+ types) |
| [ObjectLinks](object-catalog/ObjectLinks.md) | All resolved references between objects — operational and structural, including cross-file |
| [LinkRoleRegistry](object-catalog/LinkRoleRegistry.md) | Classification of the 60 link roles: usage / containment / restriction, where-used relevance |
| [FilesCatalog](object-catalog/FilesCatalog.md) | The imported FileMaker files: version, DDR-Info flag, import metadata |

Two enumeration references document the vocabularies of this pair in detail: [Link Roles and Subroles](object-catalog/Link%20Roles%20and%20Subroles.md) (all 60 `Link_Role` values with source/target types and every `Link_Subrole` pattern) and [Object Types](object-catalog/Object%20Types.md) (all `Object_Type` values incl. the synthetic types and the LayoutObject subtypes). Beyond the enumerations, [FileMaker Object Types](object-types/FileMaker%20Object%20Types.md) documents each type *semantically* — its full property surface in the export (including what the catalog does not extract), its object hierarchies and its reference vocabulary, one page per type.


---

## 2 · Object-type tables

The [XML export](../xml/XML.md) represents each object type as its own dictionary — tables, fields, scripts, layouts, value lists and so on (each branch documented in the [FileMaker XML reference](../xml/XML.md)). The conversion pipeline mirrors this structure: each type gets one or more tables that preserve the type-specific detail the generic object registry deliberately leaves out — the 57 columns of a field definition, the step sequence of a script, the container hierarchy of a layout. The object catalog answers *"what exists and what references what"*; these tables answer *"what exactly does this object look like"*.

### Scripts & script steps

| Table | Content |
|---|---|
| [ScriptCatalog](catalog-tables/ScriptCatalog.md) | All scripts incl. folder tree, options and modification metadata |
| [StepsForScripts](catalog-tables/StepsForScripts.md) | Every script step, ordered, with extracted parameters |
| [StepCalculations](catalog-tables/StepCalculations.md) | Every positioned calculation of a step with its slot context |
| [DDR_ScriptSteps](catalog-tables/DDR_ScriptSteps.md) | Human-readable step text (requires DDR-Info) |
| [ScriptTriggers](catalog-tables/ScriptTriggers.md) | Script triggers with owner (file / layout / object) and target script |

### Calculations & variables

| Table | Content |
|---|---|
| [CalculationsCatalog](catalog-tables/CalculationsCatalog.md) | Every calculation instance (owner × role × index) as an addressable object |
| [DDR_Calculations](catalog-tables/DDR_Calculations.md) | Tokenized formula chunks for dependency analysis (requires DDR-Info) |
| [DDR_ChunkListContexts](catalog-tables/DDR_ChunkListContexts.md) | Context TO and chunk count per ChunkList anchor — records empty ChunkLists too (requires DDR-Info) |
| [DesignFunctionNames](catalog-tables/DesignFunctionNames.md) | FileMaker design-function names in every reference language — positive match list of the phase-1c chunk retype (generated from the reference database, not from the export) |
| [VariablesCatalog](catalog-tables/VariablesCatalog.md) | Aggregated view per variable: scope, counts, reliability |
| [VariableUsages](catalog-tables/VariableUsages.md) | Every single variable set/read with its context |
| [PluginFunctionUsages](catalog-tables/PluginFunctionUsages.md) | Plugin function calls (e.g. MBS) found in calculations |

### Data model

| Table | Content |
|---|---|
| [BaseTableCatalog](catalog-tables/BaseTableCatalog.md) | Base tables (schema level) |
| [FieldsForTables](catalog-tables/FieldsForTables.md) | Full field definitions: type, storage, auto-enter, validation, summary |
| [TableOccurrenceCatalog](catalog-tables/TableOccurrenceCatalog.md) | Table occurrences incl. graph-canvas geometry |
| [RelationshipCatalog](catalog-tables/RelationshipCatalog.md) | Relationships, one row per join predicate, incl. sort definitions |
| [ExternalDataSourceCatalog](catalog-tables/ExternalDataSourceCatalog.md) | External data sources |

### Layouts

| Table | Content |
|---|---|
| [Layouts](catalog-tables/Layouts.md) | Layouts incl. folder tree, context TO, theme/menu-set refs, view options |
| [LayoutParts](catalog-tables/LayoutParts.md) | Layout parts in sequence, incl. sub-summary break fields |
| [LayoutObjects](catalog-tables/LayoutObjects.md) | All layout objects (22 types) with real container nesting |
| [LayoutObjectConditions](catalog-tables/LayoutObjectConditions.md) | Conditional-formatting rules, one row per rule, with parsed condition and format |
| [LayoutObjectSymbols](catalog-tables/LayoutObjectSymbols.md) | `{{…}}` symbol inventory per text layout object |
| [ThemeCatalog](catalog-tables/ThemeCatalog.md) | Layout themes incl. raw CSS rule set |

### Custom functions

| Table | Content |
|---|---|
| [CustomFunctionsCatalog](catalog-tables/CustomFunctionsCatalog.md) | Custom functions with parameter list |
| [CalcsForCustomFunctions](catalog-tables/CalcsForCustomFunctions.md) | Their formulas, plain text and tokenized |

### Value lists

| Table | Content |
|---|---|
| [ValueListCatalog](catalog-tables/ValueListCatalog.md) | Value lists with source type |
| [OptionsForValueLists](catalog-tables/OptionsForValueLists.md) | Definition details: custom values, field sources, external wrappers |

### Security

| Table | Content |
|---|---|
| [AccountsCatalog](catalog-tables/AccountsCatalog.md) | User accounts with privilege-set assignment |
| [PrivilegeSetsCatalog](catalog-tables/PrivilegeSetsCatalog.md) | Privilege sets with class-level permissions |
| [ExtendedPrivilegesCatalog](catalog-tables/ExtendedPrivilegesCatalog.md) | Extended privileges and the sets granting them |
| [PrivilegeSetRecordAccess](catalog-tables/PrivilegeSetRecordAccess.md) | Custom Record Privileges per table × operation, incl. access calcs |
| [PrivilegeSetFieldAccess](catalog-tables/PrivilegeSetFieldAccess.md) | Custom Record Privileges per field |
| [PrivilegeSetObjectAccess](catalog-tables/PrivilegeSetObjectAccess.md) | Custom privileges for layouts, value lists and scripts |
| [FileAccessAuthorizations](catalog-tables/FileAccessAuthorizations.md) | Inter-file access authorizations |

### Custom menus

| Table | Content |
|---|---|
| [CustomMenuSetCatalog](catalog-tables/CustomMenuSetCatalog.md) | Menu sets with member menus |
| [CustomMenuCatalog](catalog-tables/CustomMenuCatalog.md) | Custom menus (raw definition) |
| [CustomMenuItemCatalog](catalog-tables/CustomMenuItemCatalog.md) | Parsed menu items: commands, separators, submenus |

### File level

| Table | Content |
|---|---|
| [FileOptionsCatalog](catalog-tables/FileOptionsCatalog.md) | File options: encryption, auto-login, default layout, sharing |
| [BaseDirectoryCatalog](catalog-tables/BaseDirectoryCatalog.md) | Base directories for external paths |
| [LibraryReferences](catalog-tables/LibraryReferences.md) | Embedded-library references (metadata only) |
| [XMLMetadata](catalog-tables/XMLMetadata.md) | Root attributes of the XML export: format version, locale, DDR flag |

### Internal & auxiliary tables

Beyond the documented surface, the catalog contains working tables the pipeline and the tooling use internally: raw reference extractions before resolution (`XMLStepReferences`, `XMLLayoutReferences`, `XMLCalcReferences`, `LayoutObjectSteps`), resolver helpers (`TableOccurrenceResolution`, `ObjectHomes`, `ScriptStepRoleMap`, `GetSubparameterMap`, `MBS_SubnameMap`, `DataSourceFileMap`, `step_metadata`, `sql_name_wrappers`), import monitoring and the [duplicate census](UUID%20Healing%20and%20Duplicate%20Census.md) (`DuplicateAbsorptions`, `DuplicateAbsorptionDetails`, `MergeAbsorptions` — since schema 1.19.0 also the UUID-healing mapping), bookkeeping (`PasteIndexList`, `SchemaInfo`) and the graph-clustering layer (`ObjectClusters`, `CommunityNames`, `ClusterNodeUniverse`, `ClusterEdgesBaseMat`). A set of `v_check_*` views implements the import quality gate, and analysis views (`v_calculation_links`, `v_script_block_tree`, `v_cross_file_dependencies`, `LogicalLinks`, `FolderHierarchy`, …) provide prepared perspectives for common queries — `v_calc_anchors` lives on as a materialized compatibility facade over [CalculationsCatalog](catalog-tables/CalculationsCatalog.md) (a table, not a view, since schema 1.22.0). They are stable enough to query, but their shape follows the pipeline's needs and may change between releases — treat the tables above as the documented contract.


---

## 3 · fm-spec — the language reference

Where the object catalog describes your solution, [fm-spec](../Wiki/fm-spec.md) describes FileMaker itself. `reference/fm_spec.duckdb` is a solution-independent, machine-readable reference of the FileMaker language: all 207 script steps and 367 calculation functions with stable IDs, official documentation links in up to 11 locales, structured parameter definitions, and — the part no documentation site offers — a machine-readable emission layer: per-step XML templates, option grammars with allowed values, structural constraints, per-step platform compatibility and curated per-function platform affinity. Names are treated strictly as a localized display layer over stable IDs, which is why FM-Lab's analyses and generated artifacts work regardless of the language a developer's FileMaker runs in.

The database is organized in five layers plus a build stamp:

### Canonical core

| Table | Content |
|---|---|
| [script_steps](fm-spec-tables/script_steps.md) | 207 script steps: stable ID, canonical name, XML element name |
| [script_steps_categories](fm-spec-tables/script_steps_categories.md) | Script-step categories |
| [functions](fm-spec-tables/functions.md) | 367 calculation functions: ID, opcode, return type, category |
| [function_categories](fm-spec-tables/function_categories.md) | Function categories |
| [function_parameters](fm-spec-tables/function_parameters.md) | Function parameter positions, optional/variadic flags |
| [step_options](fm-spec-tables/step_options.md) | Option grammar per step: type, required, display rules, XML path |
| [step_option_values](fm-spec-tables/step_option_values.md) | Allowed values of enumerated options |
| [script_triggers](fm-spec-tables/script_triggers.md) | Script-trigger events: stable slot ID, owner level, parameter capability, origin version |
| [script_step_legacy_ids](fm-spec-tables/script_step_legacy_ids.md) | Undocumented / legacy step IDs seen in real exports |

### Language layer (locales & docs reference)

| Table | Content |
|---|---|
| [script_steps_lang](fm-spec-tables/script_steps_lang.md) | Localized step names, descriptions and Claris doc URLs (11 locales) |
| [script_steps_categories_lang](fm-spec-tables/script_steps_categories_lang.md) | Localized category names |
| [script_step_parameters_lang](fm-spec-tables/script_step_parameters_lang.md) | Localized parameter names and descriptions |
| [script_step_name_lookup](fm-spec-tables/script_step_name_lookup.md) | Any localized name → canonical step ID |
| [functions_lang](fm-spec-tables/functions_lang.md) | Localized function names, signatures, descriptions, examples, doc URLs |
| [function_categories_lang](fm-spec-tables/function_categories_lang.md) | Localized function-category names |
| [function_parameters_lang](fm-spec-tables/function_parameters_lang.md) | Localized function-parameter names |
| [function_name_lookup](fm-spec-tables/function_name_lookup.md) | Any localized name → canonical function ID |
| [script_triggers_lang](fm-spec-tables/script_triggers_lang.md) | Localized trigger-event labels as the trigger dialogs write them |
| [language_constants](fm-spec-tables/language_constants.md) | Canonical spellings of language constants |

### Emission layer (machine-readable syntax & grammar)

| Table | Content |
|---|---|
| [step_xml_map](fm-spec-tables/step_xml_map.md) | XML snippet template, element order and SaXML example per step |
| [step_repeat_groups](fm-spec-tables/step_repeat_groups.md) | Repeat groups (lists) per step: container, item template, notation label |
| [step_skeleton_elements](fm-spec-tables/step_skeleton_elements.md) | Skeleton hulls per step that survive the pruning of unconfigured content |
| [step_option_element_bindings](fm-spec-tables/step_option_element_bindings.md) | Option-value/element couplings per step (mode-bound elements, e.g. device modes) |
| [step_option_implications](fm-spec-tables/step_option_implications.md) | Parse-side option implications of the text notation (keywords, reference forms, mode switches) |
| [step_constraints](fm-spec-tables/step_constraints.md) | Structural rules a valid snippet must satisfy — plus the registry of documented FileMaker serialization bugs (warning class) |
| [constraint_kinds](fm-spec-tables/constraint_kinds.md) | Registry of the constraint-kind vocabulary with consumer-facing lead texts for the bug kinds |
| [step_compat](fm-spec-tables/step_compat.md) | Platform matrix per step: Pro, Server, Go, WebDirect, Cloud, Data API, CWP (tri-state: Yes / No / Partial) |
| [function_platform_affinity](fm-spec-tables/function_platform_affinity.md) | Curated platform *affinity* per function ("meaningful results only there") — Claris publishes no function compatibility table |
| [ref_element_semantics](fm-spec-tables/ref_element_semantics.md) | How reference elements resolve against the solution catalog |

### Platform/OS layer

| Table | Content |
|---|---|
| [step_os_affinity](fm-spec-tables/step_os_affinity.md) | Curated OS affinity per step (macOS / Windows / Linux / iOS): exclusive, source-true inverse *unsupported*, behavioral variants — distilled from Claris help prose, quote per row |
| [function_os_affinity](fm-spec-tables/function_os_affinity.md) | Curated OS affinity per function, plus the `os_probe` class (Get(SystemPlatform) & co — the guard idiom, not a binding) |
| [runtime_os_matrix](fm-spec-tables/runtime_os_matrix.md) | Host matrix runtime × OS — the only sanctioned translator between the runtime and OS axes |

### Action layer

| Table | Content |
|---|---|
| [action_catalog](fm-spec-tables/action_catalog.md) | fmIDE ActionScript actions, literals and plugin requirements |
| [step_action_map](fm-spec-tables/step_action_map.md) | Action ↔ script-step mapping incl. parameter mapping |

### Metadata

| Table | Content |
|---|---|
| [reference_meta](fm-spec-tables/reference_meta.md) | Build stamp: schema version, FileMaker coverage, attribution pointer |

## 4 · plugin-spec — the plug-in platform map

A second, smaller reference database sits next to fm-spec: `reference/plugin_spec.duckdb` describes the platform surface of **plug-in functions** (MBS first, plugin-agnostic schema) — verbatim vendor flags per OS/Server/iOS-SDK axis plus a curated interpretation layer that translates them into FM-Lab's runtime and OS vocabulary. It is derived locally from the installed MBS documentation mirror, not shipped. See [plugin-spec](plugin-spec.md) for the schema and the two-layer design.
