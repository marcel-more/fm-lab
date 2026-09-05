# XML DDR_INFO

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · top-level `DDR_INFO` branch

The analysis block written by the FileMaker 21+ export option **“Include details for analysis tools”** — a top-level `<DDR_INFO>` branch with two sub-branches. `<Calculation>` holds every formula of the file as a tokenized chunk list under a synthetic anchor element named `_<OwnerUUID>_<kind>`; `<Script>` holds the human-readable text of every script under `_<ScriptUUID>` anchors. The `hash` attributes are the join keys the `DDRREF` elements all over the export point to.

## Structure

```xml
<DDR_INFO>
    <Calculation>
        <ObjectList>
            <_3082C86A-…_0 datatype="…" hash="5754CB6D…">
                <TableOccurrenceReference id="…" name="…" UUID="…"/>  <!-- evaluation context -->
                <ChunkList>
                    <Chunk type="NoRef">If ( </Chunk>
                    <Chunk type="FieldRef"><FieldReference id="…" name="…" UUID="…"/></Chunk>
                    <Chunk type="VariableReference">$$MODE</Chunk>
                    <Chunk type="FunctionRef">Get ( SystemPlatform )</Chunk>
                    <Chunk type="CustomFunctionRef">MyFunction</Chunk>
                    <Chunk type="Comment">/* … */</Chunk>
                </ChunkList>
            </_3082C86A-…_0>
        </ObjectList>
    </Calculation>
    <Script>
        <ObjectList>
            <_0164… datatype="…" hash="…">…human-readable step text…</_0164…>
        </ObjectList>
    </Script>
</DDR_INFO>
```

## Notes

- The anchor suffix (`_0`, `_10`, `_Filter_0`, `_Tooltip`, `_ScriptTrigger_103`, `_Condition_2`, `_DisplayCalculations_1`, `_Install`, `_XML`, …) encodes which calculation of the owner the chunk list belongs to (step index, filter, tooltip, trigger parameter, conditional-formatting rule, merge/layout calculation, …).
- The anchor's direct `<TableOccurrenceReference>` child names the formula's evaluation context; it is extracted into [DDR_ChunkListContexts](../../schema/catalog-tables/DDR_ChunkListContexts.md) together with the chunk count.
- Chunk types observed in v22 exports: `NoRef` (plain text), `VariableReference`, `FunctionRef`, `CustomFunctionRef`, `PluginFunctionRef`, `FieldRef` (with a nested `FieldReference`), `Comment`.
- `PluginFunctionRef` means "external or unresolvable", not "plug-in". Besides plug-in calls (`MBS`, followed by the quoted function name in the next `NoRef` chunk) it carries FileMaker's **design functions** — `WindowNames`, `DatabaseNames`, `LayoutIDs`, `ValueListItems`, … — in the language of the client that wrote the formula (`Fensternamen`), whereas every other built-in function is normalized to its English name as `FunctionRef`; and it carries unresolvable identifiers such as deleted custom functions. The importer re-types the design functions to `FunctionRef` (positive name list [DesignFunctionNames](../../schema/catalog-tables/DesignFunctionNames.md)) before resolving references, so they become built-in functions, not plug-ins.
- Two documented FileMaker defects affect `DisplayCalculations` anchors (layout formulas with a `%X:` result-type prefix). Some carry an **empty** `<ChunkList>` — the token stream is simply missing, all such anchors share the file-wide hash `md5('')`, and without compensation their references would silently vanish from where-used; the importer recovers the formula and its field references from the layout text instead. And some mis-chunk a field reference as `<Chunk type="VariableReference">%N:FieldName</Chunk>` instead of a `FieldRef` — the importer rescues the field reference against the anchor's context TO rather than creating a phantom variable.
- Without DDR-Info the branch is absent; the catalog tables [DDR_Calculations](../../schema/catalog-tables/DDR_Calculations.md) and [DDR_ScriptSteps](../../schema/catalog-tables/DDR_ScriptSteps.md) then stay empty and dependency analysis falls back to the structural sources.

**Extracted into:** [DDR_Calculations](../../schema/catalog-tables/DDR_Calculations.md) · [DDR_ChunkListContexts](../../schema/catalog-tables/DDR_ChunkListContexts.md) · [DDR_ScriptSteps](../../schema/catalog-tables/DDR_ScriptSteps.md) — column details in the [schema reference](../../schema/Schema.md).
