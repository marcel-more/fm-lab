# ObjectCatalog

Part of the [FM-Lab schema](../Schema.md) · Object catalog · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** derived in phase P4 from all branches of the [FileMaker XML](../../xml/XML.md)

The central object registry of the solution catalog. Every [object](Object%20Types.md) of every imported FileMaker file — base tables, fields, scripts, script steps, layouts, layout objects, custom functions, value lists, accounts, themes, triggers, variables, plugin functions and more (25+ object types) — is registered here with one row per object. It is the starting point for every existence and where-used question: find the object here first, then follow its `Object_UUID` into [ObjectLinks](ObjectLinks.md) or into the type-specific detail table named in `Source_Table`.

## Columns

| Column         | Type      |                               |
| -------------- | --------- | ----------------------------- |
| `Object_UUID`  | `VARCHAR` |                               |
| `Object_Type`  | `VARCHAR` | [Object Types](Object%20Types.md)              |
| `Object_Name`  | `VARCHAR` |                               |
| `File_Name`    | `VARCHAR` |                               |
| `Source_Table` | `VARCHAR` |                               |
| `Object_ID`    | `BIGINT`  |                               |

## Notes

- `Object_UUID` is the primary key and the only globally unique identifier. Numeric `Object_ID` values are only unique per file (and per type) — always join them together with `File_Name`.
- `Source_Table` names the type-specific table that holds the object's details (e.g. `FieldsForTables` for a `Field`).
- Synthetic object types without an XML catalog of their own (e.g. `Variable`, `PluginFunction`, `File`) are registered here as well, so the link graph can reference them uniformly.
- If the export carries the same UUID on two objects of one file (copy-paste duplicates), both are kept: the twin with the smallest internal FileMaker ID keeps the original UUID, every other twin gets a deterministic synthetic replacement UUID (md5 hex, 32 characters without dashes — formally distinguishable from a native UUID). The original↔replacement mapping lives in the [duplicate census](../UUID%20Healing%20and%20Duplicate%20Census.md).

**See also:** [ObjectLinks](ObjectLinks.md) · [FilesCatalog](FilesCatalog.md) · [Object Types](Object%20Types.md) (all object types enumerated)
