# XML ValueListCatalog

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · `Structure/AddAction` branch

The value lists of the file — identity plus the source kind only. The actual definition (custom values, source fields, external source) follows in the separate [XML OptionsForValueLists](XML%20OptionsForValueLists.md) branch.

## Structure

```xml
<ValueListCatalog membercount="…">
    <ValueList id="1" name="Status">
        <UUID …>44639478-…</UUID>
        <Source value="Custom|Field|External"/>
        <TagList/>
    </ValueList>
</ValueListCatalog>
```

## Notes

- **Version difference:** from SaXML v2.3.0.0 (FileMaker 26) each `<ValueList>` additionally carries its **option details** — the `Source`, `Field`, `CustomValues` and `External` children that the separate [XML OptionsForValueLists](XML%20OptionsForValueLists.md) branch holds up to v2.2.x. The importer reads whichever form the file's profile prescribes; both fill [OptionsForValueLists](../../schema/catalog-tables/OptionsForValueLists.md).

**Extracted into:** [ValueListCatalog](../../schema/catalog-tables/ValueListCatalog.md) — column details in the [schema reference](../../schema/Schema.md).
