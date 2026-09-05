# Schema Version History

The solution catalog carries an internal schema version, independent of the fm-lab release version. It is declared in the Phase-1 template of the conversion pipeline (`ingestion/sql/convert_xml_01_extract.sql`, marker `@SCHEMA_VERSION`) and stamped into every built database via the `SchemaInfo` table. On each import the pipeline compares the template version against the version persisted in the database — a mismatch triggers an **automatic rebuild**: the catalog is discarded and fully rebuilt, so it can never silently mix schema generations. (Not to be confused with [UUID healing](UUID%20Healing%20and%20Duplicate%20Census.md), which repairs duplicate object UUIDs *inside* a build.) An MD5 hash over the core SQL templates serves as a secondary drift indicator (hash drift alone warns; only a version bump forces the rebuild). That is why even pure content-semantic corrections get a version bump: the bump is what guarantees existing catalogs are rebuilt.

Two scope notes: this history covers the **solution catalog** (`db/fm_catalog.duckdb`) only — the [fm-spec](../Wiki/fm-spec.md) reference database has its own, independent `schema_version` in [reference_meta](fm-spec-tables/reference_meta.md). And versions up to 1.4.1 predate the fm-lab version manifest (introduced with v0.8.6), so no fm-lab release can be assigned to them; entries older than 1.4.0 are reconstructed from the git history.

## Versions

| Schema version | fm-lab version | Date |
|---|---|---|
| [1.27.0](#1270) | 0.9.9 | 2026-09-02 |
| [1.26.0](#1260) | 0.9.9 | 2026-09-01 |
| [1.25.0](#1250) | 0.9.9 | 2026-08-29 |
| [1.24.0](#1240) | 0.9.9 | 2026-08-29 |
| [1.23.0](#1230) | 0.9.8 | 2026-08-25 |
| [1.22.0](#1220) | 0.9.7 | 2026-08-23 |
| [1.21.0](#1210) | 0.9.7 | 2026-08-15 |
| [1.20.0](#1200) | 0.9.7 | 2026-08-11 |
| [1.19.0](#1190) | 0.9.6 | 2026-08-10 |
| [1.18.0](#1180) | 0.9.6 | 2026-08-09 |
| [1.17.0](#1170) | 0.9.6 | 2026-08-04 |
| [1.16.0](#1160) | 0.9.5 | 2026-07-31 |
| [1.15.0](#1150) | 0.9.5 | 2026-07-30 |
| [1.14.0](#1140) | 0.9.3 | 2026-07-16 |
| [1.13.0](#1130) | 0.9.0 | 2026-07-15 |
| [1.12.1](#1121) | 0.9.0 | 2026-07-15 |
| [1.12.0](#1120) | 0.9.0 | 2026-07-15 |
| [1.11.0](#1110) | 0.9.0 | 2026-07-15 |
| [1.10.0](#1100) | 0.9.0 | 2026-07-15 |
| [1.9.0](#190) | 0.9.0 | 2026-07-15 |
| [1.8.0](#180) | 0.9.0 | 2026-07-15 |
| [1.7.0](#170) | 0.8.9 | 2026-07-08 |
| [1.6.1](#161) | 0.8.6 | 2026-07-04 |
| [1.6.0](#160) | 0.8.6 | 2026-07-03 |
| [1.5.2](#152) | 0.8.6 | 2026-07-03 |
| [1.5.1](#151) | 0.8.6 | 2026-07-02 |
| [1.5.0](#150) | 0.8.6 | 2026-07-02 |
| [1.4.1](#141) | — | 2026-06-23 |
| [1.4.0](#140) | — | 2026-06-18 |
| [1.3.0](#130) | — | 2026-06-18 |
| [1.2.0](#120) | — | 2026-06-18 |
| [1.1.0](#110) | — | 2026-06-13 |
| [1.0.0](#100) | — | 2026-05-13 |

## Changes by version

### 1.27.0

Display-calculation gaps of the merge family closed. New P1 table
[DDR_ChunkListContexts](catalog-tables/DDR_ChunkListContexts.md): the context table occurrence and chunk count of every
ChunkList anchor in DDR-Info — including **empty** ChunkLists, which appear
nowhere else in the export. New P3 table [LayoutObjectSymbols](catalog-tables/LayoutObjectSymbols.md): the `{{…}}`
symbol inventory per text layout object (deliberately without where-used
edges). [CalculationsCatalog](catalog-tables/CalculationsCatalog.md) gains `Result_Type` (the result type from the
`%X:` prefix of a layout formula, default Text); `display_calculation`
instances gain `Formula_Text` (the localized raw formula recovered from
`Text_Content`) and their context TO. Two documented FileMaker DDR defects are
compensated: `%X:` mis-chunks (a `VariableReference` chunk where a `FieldRef`
belongs) no longer produce phantom variables — the field reference is rescued
against the context TO; empty `DisplayCalculations` ChunkLists get a fallback
instance plus field edges derived from `Text_Content`.

### 1.26.0

`ScriptTriggers.Trigger_Parameter_Text`: the structural plain text of a
trigger's parameter calculation, extracted per trigger on all three owner
levels (file, layout, layout object). It fills `Formula_Text` of the
`script_trigger_parameter` calculation instances, provides per-trigger fallback
instances for files without DDR-Info (`Calc_Kind_Raw = 'ScriptTrigger_<id>'`),
and feeds the candidate edges `reads_field · transaction_parameter_field` for
the OnWindowTransaction parameter field (name candidates, file-local).

### 1.25.0

Conditional formatting as structured rules: new table
[LayoutObjectConditions](catalog-tables/LayoutObjectConditions.md) — one row per rule, extracted depth-anchored from
the object payload so container nesting can never double-count. Carries the
raw condition type (formula or value operator), the enable bit, the condition
formula (for value-based rules the equivalent self formula FileMaker
serializes alongside), the value operands, the applied format as raw CSS, and
a foreign key to the rule's calculation instance (role `conditional_format`,
matched via `Calc_Kind_Raw = 'Condition_<N>'`). New P6 guard view
`v_check_cf_rules` (membercount and FK coverage).

### 1.24.0

`ScriptTriggers` completion: three new columns. `Trigger_FindMode` and
`Trigger_PreviewMode` — SaXML writes only the *activated* modes per trigger,
so all three mode flags are needed to tell browse-only from browse+find
apart. `Trigger_ScriptParameter_FieldName` — the OnWindowTransaction
attribute naming the field whose content FileMaker includes in the JSON
script parameter (a late-bound name reference without table qualification).

### 1.23.0

int32 hardening of all XML-fed numeric columns. FileMaker serializes some
numeric slots as unsigned 32-bit values — most prominently `4294967295`
(UINT32_MAX), the unsigned representation of a `-1` sentinel — which overflow a
32-bit `INTEGER` column. The XML reader (webbed) hard-aborts the **entire file
scan** on the first such value (upstream issue #102; the abort also applies
when the column type is declared explicitly, in DOM and SAX mode alike), so a
single sentinel value could fail the import of a whole file. All `INTEGER`
declarations fed from XML values were therefore widened to `BIGINT`: the
`read_xml` column specifications and their target DDL in
[TableOccurrenceCatalog](catalog-tables/TableOccurrenceCatalog.md) (`Box_Height`, `Coord_*`, `Color_*`),
[FieldsForTables](catalog-tables/FieldsForTables.md) (`Max_Repetitions`, `Validation_MaxChars`),
[ScriptCatalog](catalog-tables/ScriptCatalog.md) (`Option_Bitmask`), [Layouts](catalog-tables/Layouts.md) (`L_Width`,
`Modifications`), [AccountsCatalog](catalog-tables/AccountsCatalog.md) (`Account_Kind`),
[PrivilegeSetsCatalog](catalog-tables/PrivilegeSetsCatalog.md) (`Other_Value`) and [CustomMenuItemCatalog](catalog-tables/CustomMenuItemCatalog.md)
(`Item_Index`), plus the extraction casts behind [StepsForScripts](catalog-tables/StepsForScripts.md)
(`Step_Index`, `Step_ID`), [LayoutParts](catalog-tables/LayoutParts.md) (`Part_*`), [LayoutObjects](catalog-tables/LayoutObjects.md)
(`Object_Kind`, `Bounds_*`, `Z_Order`), [StepCalculations](catalog-tables/StepCalculations.md) (`Step_Index`,
`Step_ID`, `Calc_Position`) and [VariableUsages](catalog-tables/VariableUsages.md) (`Step_Index`) — including
the SAX streamify overrides and the P2 reference tables. Sentinel values now
import verbatim (`4294967295` is stored as-is; raw = what the export said) —
with one documented semantic exception: [FieldsForTables](catalog-tables/FieldsForTables.md)
`Validation_MaxChars` normalizes the sentinel to `NULL` ("no character limit",
the same state as validation without a configured maximum), because the value
is FileMaker's encoding of "unlimited", not a real limit. Only this slot is
normalized; a new guard check (`v_check_numeric_sentinels`, phase 6) warns —
without changing data — if a future export ships an implausible value (> 10⁹)
that the normalization did not recognize.
Deliberately unchanged: the static curated maps (`ScriptStepRoleMap`,
`ScriptStepControlMap`), which are not XML-fed. Pure type widening plus the
one normalization above, no new columns or tables; the bump forces the rebuild
that renews the column types.

### 1.22.0

Calculations become first-class objects: the new [CalculationsCatalog](catalog-tables/CalculationsCatalog.md) holds one row per calculation **instance** (identity Owner × `Calc_Role` × `Calc_Index` — structural, never the content hash), as the union of the DDR calculation anchors and the structural slots the export carries even without DDR-Info. Every instance is registered in [ObjectCatalog](object-catalog/ObjectCatalog.md) as `Object_Type` [Calculation](object-types/Calculation.md) and anchored to its owner via the new containment role `has_calculation` (never counts as usage). The canonical usage layer is untouched: the owner-projected edges stay authoritative, *Calculation → target* exists only as the derived view `v_calculation_links` — no duplicate edges, no graph growth (structural links never enter the logical graph). Slot precision on the field edges: AutoEnter references now carry `Link_Subrole` `auto_enter`, the custom-message calc of a validation carries `validation_message` (both previously indistinguishable from their sibling slot). Gap closure: `ScriptTriggers` newly persists `Trigger_XML` for layout-/file-level triggers, and P2 harvests their parameter calcs — objects referenced only in a layout-/file-trigger parameter finally appear in where-used. The former analysis table `v_calc_anchors` continues as a materialized facade over the new catalog (same columns, DDR-anchored rows). New table + new column + content correction to [ObjectLinks](object-catalog/ObjectLinks.md) → version bump.

### 1.21.0

The Classic theme becomes visible: SaXML encodes it as an **empty** `<LayoutThemeReference/>` (no id/name/UUID), so `L_Theme_*` stayed NULL for every Classic layout and Classic appeared unused in every file. New resolved columns `Layouts.L_Theme_Resolved_Name`/`_UUID` (derived in P3: empty reference → `com.filemaker.theme.classic`, UUID resolved via the theme *name*, never the file-local id); the `uses_theme` link and the P6 expectation now build on the resolved UUID. Raw columns stay untouched ("raw = what the export said"). Content correction to [ObjectLinks](object-catalog/ObjectLinks.md) → version bump.

### 1.20.0

Perform Script on Server becomes visible on the graph edge: `calls_script` links created from a *Perform Script on Server* step now carry the [Link_Subrole](object-catalog/Link%20Roles%20and%20Subroles.md) `on_server` (step 164) or `on_server_callback` (step 210) — the callee runs server-side. Deliberately a **subrole, not a new role**: `calls_script` stays the one call role, so where-used queries, call chains and the graph are unaffected; the execution context is a qualifier, like the calc-slot subroles. Ordinary Perform Script calls keep `NULL`. "By name" callsites (the target script name is computed at runtime) have no static target and therefore no edge — their expression is available in `StepCalculations`. Content correction to [ObjectLinks](object-catalog/ObjectLinks.md) → version bump.

### 1.19.0

UUID healing: intra-file duplicate UUIDs — the same UUID on two different objects of one file, typically a copy-paste artifact — no longer collapse silently in the import upserts. Every duplicate twin survives with a **deterministic synthetic replacement UUID** (an md5 hash over the catalog, file, original UUID and the object's internal FileMaker ID); the twin with the smallest internal ID keeps the original UUID. The full mechanics, guarantees and limits are documented in [UUID Healing and Duplicate Census](UUID%20Healing%20and%20Duplicate%20Census.md).

Schema surface of the bump: the P2 reference tables (`XMLStepReferences`, `XMLLayoutReferences`, `XMLCalcReferences`) additionally extract `Ref_ID` — the internal `@id` of each reference element (SaXML references are `id`+`name`+`UUID` triples) — plus `TO_Ref_ID` for field references, whose `@id` is only table-local. [DuplicateAbsorptionDetails](UUID%20Healing%20and%20Duplicate%20Census.md) gains `Healed_UUID`, `Heal_Status` and `Discriminator`, turning the census into the persistent original↔replacement mapping. Healing runs in the upsert CTEs of the main catalogs and (intra-chunk plus a merge-point follow-up pass) in the sub-chunked heavy catalogs; a new cascade template `convert_xml_01b_heal_cascade.sql` propagates healed parent UUIDs into dependent extracts, and a P4 rewrite stage distributes incoming references onto the correct twin via `Ref_ID`. Replacement UUIDs are chunking-invariant; FileMaker's double-serialization and chunk-overlap duplicates still collapse (correctly); on duplicate-free corpora the build stays run-to-run bit-identical. The escape hatch `FM_UUID_HEAL=0` restores the old absorb-and-census behavior.

### 1.18.0

Clone scoping via declared data sources: importing a file *together with its clone* (same internal file name pattern, e.g. `_dev` copies) could produce phantom edges — a reference fanning out to every file that carries the target UUID. A new P4 table `DataSourceFileMap` resolves each declared external data source `(File_Name, DS_UUID)` to the imported target file (by data-source name, else by walking the declared path list in FileMaker's search order); the [ObjectLinks](object-catalog/ObjectLinks.md) build scopes base-table targets to the declared source file, and a generic *prefer-declared-source* post-pass removes edges that fan out over several files when exactly one of them is the declared data source. A new P6 check view `v_check_phantom_links` guards the result. Content correction to [ObjectLinks](object-catalog/ObjectLinks.md) → version bump; clone-free corpora stay bit-identical.

### 1.17.0

Duplicate census completed: [DuplicateAbsorptionDetails](UUID%20Healing%20and%20Duplicate%20Census.md) gains context and plain-text columns (`Parent_Name`, `Position`, `Display_Text`, `Payload_XML`) — at this stage absorbed objects were still missing from the catalog, and these columns were the only trace by which a developer could find them in the solution. Detail capture is extended to [StepsForScripts](catalog-tables/StepsForScripts.md), [Layouts](catalog-tables/Layouts.md) and [LayoutObjects](catalog-tables/LayoutObjects.md), where the census now counts genuine copy-paste duplicates (same UUID, different internal object IDs) separately from FileMaker's benign double serialization of the same object. New table `MergeAbsorptions` persists what the chunk-merge deduplicates. This monitoring layer is what [1.19.0](#1190) later builds the healing on.

### 1.16.0

Second hardening of `StepsForScripts.Calculation_Text` extraction: additionally excludes calculations inside `<Bounds>` — for window steps without a name calculation (New Window, Go to Related Record with the "New window" option) the first-calculation XPath previously grabbed a window *geometry* expression, reporting a window height as the supposed window name. The column semantics ("first calculation in document order, excluding repetition and geometry slots") are now explicit. Additionally (P3, additive): new table `StepCalculations` — *all* positioned calculations per step with their slot context (parent element: name, height, URL, typed parameters, …) and `Calc_Position` — and the derived column `StepsForScripts.Opens_Window` (New Window always, Go to Related Record when a `<WindowReference>` option is present).

### 1.15.0

[CustomFunctionsCatalog](catalog-tables/CustomFunctionsCatalog.md) gains `Folder_Type` (the raw `isFolder` value, `True` or `Marker`), `Is_Separator` and `Sequence_ID` — the same three columns [ScriptCatalog](catalog-tables/ScriptCatalog.md) and [Layouts](catalog-tables/Layouts.md) already carried. FileMaker stores the folders and separators of the Manage Custom Functions dialog as ordinary `<CustomFunction>` entries, so until now they were indistinguishable from real custom functions: they counted in every custom-function metric, and because a folder row has no parameter list it looked exactly like a parameterless function to any signature check. `Sequence_ID` is the position in XML order, not `CF_ID` (which is creation order) — the folder tree is encoded as a flat opening/closing sequence, so reconstructing it requires document order. The `FolderHierarchy` view gained its third branch accordingly, and [ObjectCatalog](object-catalog/ObjectCatalog.md) now keeps folder and separator rows out of the `CustomFunction` block and promotes the folders to `Object_Type = 'Folder'` with `Source_Table = 'CustomFunctionsCatalog'`, which gives custom functions inside a folder a `parent_folder` link like scripts and layouts have. In the reference corpus this moves 6 of 14 rows out of the `CustomFunction` count: 8 real functions remain, 3 folders become Folder objects, 3 end-of-folder markers stay bookkeeping rows.

The same bump curates 26 step types in the internal `ScriptStepRoleMap`, which assigns a [link role](object-catalog/Link%20Roles%20and%20Subroles.md) per step ID for script-to-field references: the Insert family, the data-file API, the AI steps and a handful of singles such as Cut, Check Selection and Install Plug-In File. Uncurated step types fall back to `references_field`, which preserves where-used but loses the differentiated role — a pipeline check reports the remainder, and it is now empty. Two things are worth knowing when reading that map. Five AI steps carry a source field *and* a target field in the same step (for example Insert Embedding in Found Set); the map holds one role per step ID and the reference extraction records field references without their originating option, so those five are deliberately mapped to `references_field` rather than to an invented dominant role. And the option type in the [fm-spec](../Wiki/fm-spec.md) reference describes the XML shape, not the data direction: Write to Data File carries its field as a `target` option although the field is *read* — its label is "Data source" — so its role is `reads_field`.

### 1.14.0

`ScriptStepType` entries in [ObjectCatalog](object-catalog/ObjectCatalog.md) are now also derived from `LayoutObjectSteps`, not only from [StepsForScripts](catalog-tables/StepsForScripts.md). A step type used *exclusively* by a button-embedded step previously had no catalog entry, so the step-name link in the button detail view resolved to "not found". Rows only, no new columns — the bump exists because only a version bump forces the rebuild that backfills the missing rows.

### 1.13.0

Extraction fix for `StepsForScripts.Calculation_Text`: the previous XPath took the *first* `<Calculation>` in document order, which for steps with a **calculated repetition** on the target field returned the repetition expression instead of the actual calculation. The path now excludes calculations inside `<repetition>` (affected Set Field, Replace Field Contents, Insert Calculated Result, Insert from URL and others). Content correction of an existing column.

### 1.12.1

The [ObjectCatalog](object-catalog/ObjectCatalog.md) display name for themes now uses `Theme_Display` (falling back to the internal name) — detail views, references and the graph show "Apex Blue" instead of `com.filemaker.theme.apex_blue`. Display semantics only; links are UUID-based and unaffected.

### 1.12.0

[ThemeCatalog](catalog-tables/ThemeCatalog.md) gains the `Theme_Display` column from `<Theme @Display>` — the localized display name of the theme as the FileMaker UI shows it, alongside the internal `name`.

### 1.11.0

[Layouts](catalog-tables/Layouts.md) gains five boolean columns decoded from the bit-packed `<Options>` integer: `Auto_Save_Changes`, `Show_Field_Frames`, `Frame_Current_Record_Only`, `Show_Current_Record_List`, `Quick_Find_Enabled` (the layout's "General" options). The bit decoder was verified against calibration layouts with exactly one option toggled each. Derived from `Options_Raw`; NULL for folders/separators.

### 1.10.0

Field-option coverage: [FieldsForTables](catalog-tables/FieldsForTables.md) gains 14 columns. Validation: `Validation_AlwaysValidate`, `_StrictType`, `_MaxChars`, `_Range_From/_To`, `_Calc_Text`/`_Calc_Hash` (validate by calculation), `_Message`, `_Message_Calc_Hash`. Storage: `Storage_IndexLanguage(_ID)` (default index language from `<Storage><LanguageReference>`). Summary: `Summary_RestartEachGroup`, `Summary_RepetitionMode`. New link role `validates_by_calc` (Field → Field/CustomFunction via the validation-calc chunks) — closes the where-used gap for objects referenced only inside a field validation.

### 1.9.0

Layout metadata: [Layouts](catalog-tables/Layouts.md) gains five columns — `Is_Hidden` (from `<Options @hidden>`, the inverted "Include in layout menus" switch), `L_Theme_Base` and the author metadata `Modified_By`, `Modified_At`, `Modifications` from the `<UUID>` element attributes.

### 1.8.0

Layout view options: [Layouts](catalog-tables/Layouts.md) gains `Options_Raw`, `View_Form/List/Table_Available` and `Default_View`. The available views and the default view are encoded in the bit-packed `<Options>` integer of the layout tail (no explicit XML element); the decoder was calibrated against reference layouts. `Options_Raw` is kept so later bit derivations need no re-import.

### 1.7.0

Button-embedded script steps become readable like regular steps: (a) [DDR_ScriptSteps](catalog-tables/DDR_ScriptSteps.md) no longer collapses UUID-less step-text records (button-embedded steps) onto an empty key — they fall back to a hash-based key, so the plain text resolves via the `DDRREF` hash; (b) new Phase-2 table `LayoutObjectSteps` materializes each button's embedded `action/Step` (step ID/name/enabled/text hash) so the read-only API can render it as tokens without XML parsing.

### 1.6.1

[RelationshipCatalog](catalog-tables/RelationshipCatalog.md) now captures relationships whose predicate fields live on **external** table-occurrence sides. The previous UUID-required filter discarded the *entire* relationship when a predicate field belonged to another file (empty `FieldReference/@UUID`) — 17 % of the reference corpus was missing. Resolution now runs structurally via `(Field_TO_UUID, Field_ID)`; a new P6 check view reports residuals. Extraction semantics only, no schema change — bumped to force the data-gaining rebuild.

### 1.6.0

Value-list reference coverage and import monitoring (reconstructed from the commit, no header changelog entry): custom sorts by value list are extracted from all four carriers (Sort Records step, portal sort, button-embedded sort step, relationship sort) into the new `sorts_by_valuelist` link role; external value lists (`<Source value="External">`) are resolved across files into `source_valuelist` / `data_source` links via the `External_*` columns of [OptionsForValueLists](catalog-tables/OptionsForValueLists.md). New census tables `DuplicateAbsorptions`/`DuplicateAbsorptionDetails` plus P6 checks detect silently absorbed duplicate-UUID source objects.

### 1.5.2

[FileOptionsCatalog](catalog-tables/FileOptionsCatalog.md) gains six columns from the Metadata branch: `Save_Password_Keychain`/`_RequireMobile` (stored-credentials policy — security-relevant, independent of the auto-login) and `PageSetup_Orientation`/`_Scale`/`_Width`/`_Height` (print defaults, extracted but not surfaced in the GUI).

### 1.5.1

Layout menu sets and sub-summary break fields: [Layouts](catalog-tables/Layouts.md) gains `L_MenuSet_ID/_Name/_UUID` (built-in default normalized to NULL), [LayoutParts](catalog-tables/LayoutParts.md) gains `Part_Seq` plus the `Break_Field_*`/`Break_TO_*` columns, with `Part_Seq` added to the primary key — multiple parts of the same kind no longer collapse. New link roles `uses_menuset` (Layout → CustomMenuSet) and `breaks_on_field` (LayoutPart → Field).

### 1.5.0

The first big coverage push: [FieldsForTables](catalog-tables/FieldsForTables.md) gains 18 columns (`Validation_*`, `Storage_*`, `Serial_*`, `Summary_*`), [Layouts](catalog-tables/Layouts.md) gains `L_TO_UUID`, `L_Width` and the `L_Theme_*` columns, and the new table [FileOptionsCatalog](catalog-tables/FileOptionsCatalog.md) lands (encryption, minimum version, login/auto-login, start layout, sharing visibility). New link roles: `grants_privilege`, `uses_theme`, `installs_menuset`, `parent_layout` (LayoutPart), `uses_valuelist` (validation subrole), `summarizes_field`, `default_layout`, `auto_login_account`.

### 1.4.1

[CalcsForCustomFunctions](catalog-tables/CalcsForCustomFunctions.md) extraction also handles SaXML v2.3.0.0 (FileMaker 26), where the `<Calculation>` is embedded inside each `<CustomFunction>` instead of a separate branch — a structure-tolerant dual extraction from a single parse, with no version switch (see [XML CustomFunctionsCatalog](../xml/catalogs/XML%20CustomFunctionsCatalog.md)).

### 1.4.0

Three new tables: [FileAccessAuthorizations](catalog-tables/FileAccessAuthorizations.md), [CustomMenuSetCatalog](catalog-tables/CustomMenuSetCatalog.md) and [LibraryReferences](catalog-tables/LibraryReferences.md) (additive; the existing 41 tables unchanged). Menu sets are registered in [ObjectCatalog](object-catalog/ObjectCatalog.md) and linked to their member menus (`contains_menu`).

### 1.3.0

Relationship sort definitions (reconstructed from git): [RelationshipCatalog](catalog-tables/RelationshipCatalog.md) gains the per-side `*_Sort_Enabled`/`*_Sort_Fields`/`*_Sort_Field_*` columns and the `sort_field` link role — a relationship's sort fields now appear in the field's where-used. Includes a fix for the join-predicate field resolution.

### 1.2.0

Multi-predicate relationships (reconstructed from git): relationships are stored **per join predicate** with the new `Predicate_Index` column — multi-field joins previously lost all but one predicate. [RelationshipCatalog](catalog-tables/RelationshipCatalog.md) and the `left_field`/`right_field` links have carried one pair per predicate since.

### 1.1.0

The conversion pipeline is split into six SQL phases (P1 Extract … P6 Validate) with one template per phase, together with the `--split` option for large exports (reconstructed from git; formerly a single `convert_xml.sql`). The phase architecture is what the [Katana engine](../Wiki/katana-engine.md) later builds on.

### 1.0.0

Schema versioning itself (reconstructed from git): the `SchemaInfo` table, the `@SCHEMA_VERSION` marker in the Phase-1 template and the automatic rebuild — on version mismatch the pipeline discards and rebuilds the catalog (force-rebuild), so schema drift can never produce silently inconsistent databases.
