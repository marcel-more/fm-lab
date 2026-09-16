# XML ExternalDataSourceCatalog

Part of the [FileMaker XML reference](../XML.md) · SaXML v2.2 (FileMaker 22) · `Structure/AddAction` branch

The external data sources of the file (*Manage External Data Sources*): each entry names another FileMaker file (or ODBC source) with its path list. Table occurrences and external value lists point at these entries by `DataSourceReference`.

## Structure

```xml
<ExternalDataSourceCatalog membercount="…">
    <ExternalDataSource id="1" name="Gruppen" type="FileMaker">
        <UUID …>AFA2D47E-…</UUID>
        <File>
            <UniversalPathList>file:Gruppen</UniversalPathList>
        </File>
        <TagList/>
    </ExternalDataSource>
</ExternalDataSourceCatalog>
```

## Notes

- **Version difference:** SaXML v2.3.0.0 (FileMaker 26) additionally writes a `<SortOrder>` per external data source. The attribute is read transparently and changes no existing extraction.

**Extracted into:** [ExternalDataSourceCatalog](../../schema/catalog-tables/ExternalDataSourceCatalog.md) — column details in the [schema reference](../../schema/Schema.md).
