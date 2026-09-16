# XML StepsForScripts

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · `Structure/AddAction` branch

The script steps, grouped per script: one `<Script>` wrapper with a `<ScriptReference>` back to the catalog entry, containing one `<Step>` per step in execution order. `Step/@id` is the numeric, locale-independent step type; `Step/@name` is the localized display name of the exporting client. Parameters are typed `<Parameter>` children; object references appear as `*Reference` elements inside them.

## Structure

```xml
<StepsForScripts membercount="…">
    <Script>
        <ScriptReference id="27" name="Startup" UUID="0164…"/>
        <ObjectList membercount="…">
            <Step id="141" index="1" name="Variable setzen" enable="True" breakpoint="False" hash="…">
                <UUID>…</UUID>
                <Options/>
                <ParameterValues membercount="…">
                    <Parameter type="Variable" value="…">…</Parameter>
                    <Parameter type="Calculation">
                        <Calculation>
                            <DDRREF kind="ChunkList" hash="…">_0164…_1</DDRREF>
                            <Text><![CDATA[Get ( SystemPlatform )]]></Text>
                        </Calculation>
                    </Parameter>
                    <!-- reference parameters: FieldReference, LayoutReference,
                         ScriptReference, TableOccurrenceReference, … -->
                </ParameterValues>
                <DDRREF kind="StepText" hash="…">_0164…</DDRREF>
            </Step>
        </ObjectList>
    </Script>
</StepsForScripts>
```

## Notes

- `Step/@name` is written in the UI language of the exporting client — every robust consumer keys on `Step/@id`.
- The step-level `DDRREF` hash joins to the human-readable step text in [XML DDR_INFO](XML%20DDR_INFO.md).
- The catalog keeps the raw fragment (`Step_XML`) but resolves all references into [ObjectLinks](../../schema/object-catalog/ObjectLinks.md) at import.
- A step can carry **several** `<Calculation>` elements (window name vs. geometry, dialog message vs. input fields, …), distinguished by a positional attribute; inside a Data-File parameter container the numbering restarts. Each positional calc becomes one [StepCalculations](../../schema/catalog-tables/StepCalculations.md) row and one `step_parameter` instance in [CalculationsCatalog](../../schema/catalog-tables/CalculationsCatalog.md).

- **Version difference:** the nine script steps FileMaker 26 introduced (`id` 238 and 240–246: Configure Persistent Data, Insert Image Caption(s), Print/Create/Append/Close/Open PDF) appear in a FileMaker 22 export too, but **bare** — `id`, `name`, `Options` and the DDR anchor, without `ParameterValues`; only SaXML v2.3.0.0 carries their parameters. v2.3.0.0 also changes existing steps: `Save Records as PDF` (144) reorders its boolean options and adds `Create folders` and `SaveResult` (saving into a container uses a `Target` field reference instead of the legacy path form), `Re-Login` (138) always writes a `DataSourceReference`, `Export Records` (36) exports its XSLT calculation, `Show Custom Dialog` (87) gains the dialog geometry calculations, `Save a Copy as Add-on Package` (96) gains parameters, and the LLM steps (215, 218, 219) gain `LLMParameters` and the RAG slots.

**Extracted into:** [StepsForScripts](../../schema/catalog-tables/StepsForScripts.md) · [StepCalculations](../../schema/catalog-tables/StepCalculations.md) · [DDR_ScriptSteps](../../schema/catalog-tables/DDR_ScriptSteps.md) — column details in the [schema reference](../../schema/Schema.md).
