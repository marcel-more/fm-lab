# XML OptionsForValueLists

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · `Structure/AddAction` branch

The definition details of every value list. Each entry re-identifies its list via `<ValueListReference>` and then branches by source kind: literal custom values, field-based definitions with primary/secondary field, or an external wrapper pointing to a value list in another file.

## Structure

```xml
<OptionsForValueLists membercount="…">
    <ValueList>
        <ValueListReference id="7" name="Lieferbedingung" UUID="44639478-…"/>
        <Source value="Custom"/>
        <CustomValues><Text><![CDATA[Value 1
Value 2]]></Text></CustomValues>
    </ValueList>
    <ValueList>
        <ValueListReference …/>
        <Source value="Field"/>
        <Field>
            <PrimaryField show="…" sort="…">
                <FieldReference id="…" name="…" UUID="…">
                    <TableOccurrenceReference id="…" name="…" UUID="…"/>
                </FieldReference>
            </PrimaryField>
            <SecondaryField show="…" sort="…">…</SecondaryField>
            <ShowRelated value="…">…</ShowRelated>
        </Field>
    </ValueList>
    <ValueList>
        <ValueListReference …/>
        <Source value="External"/>
        <External>
            <DataSourceReference id="64" name="Gruppen" UUID="AFA2D47E-…">
                <UniversalPathList>file:Gruppen</UniversalPathList>
            </DataSourceReference>
            <ValueListReference id="9" name="Lieferbedingungen" UUID=""/>  <!-- UUID EMPTY -->
        </External>
    </ValueList>
</OptionsForValueLists>
```

## Notes

- The external target `ValueListReference` carries an **empty UUID** — the importer resolves it via the data source (target file) plus the list ID, with the name as fallback.

- **Version difference:** this branch exists only up to SaXML v2.2.x (FileMaker ≤ 22). From v2.3.0.0 (FileMaker 26) the option details are embedded in the value-list node itself — see [XML ValueListCatalog](XML%20ValueListCatalog.md). Both forms fill the same [OptionsForValueLists](../../schema/catalog-tables/OptionsForValueLists.md) table.

**Extracted into:** [OptionsForValueLists](../../schema/catalog-tables/OptionsForValueLists.md) — column details in the [schema reference](../../schema/Schema.md).
