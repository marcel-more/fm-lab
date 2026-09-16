# language_constants

Part of the [FM-Lab schema](../Schema.md) · Language layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Canonical spellings of the language-level constant tokens a calculation may contain: the text-style constants (`Bold`, `HighlightYellow`, `AllStyles`), the JSON types (`JSONString`, `JSONStringRanges`), the boolean literals `True`/`False` and operators `and`/`or`/`not`/`xor`, the `Get` keyword and its German form `Hole`, and — since fm-spec 2.8.0, from the Claris page *Named constants and other special keywords* — the character-set constants of `TextFont` (`Roman`, `Cyrillic`, `ShiftJIS`, …), the lookup directions `Higher`/`Lower` of `LookupNext`, the path types `PosixPath`/`WinPath`/`URLPath`, the record metadata keywords `ROWID`/`ROWMODID` and the value-list types of `GetRecordIDsFromFoundSet`. 52 rows.

**`used_with` is the point of the table.** Several constants are ordinary words or collide with function names: `Lower` is the lookup constant of `LookupNext` *and* the text function `Lower`, `Symbol` and `Other` are character sets, `Higher` is a plain English word. A free token can therefore never be classified by name alone — only in the parameter position of a function listed in `used_with` (a comma list of canonical function names; Get functions by their canonical name, e.g. `ROWID` → `RecordID`). `NULL` marks constants for general use (`True`, `and`).

`constant_type` is the category: `style`, `json_type`, `boolean_literal`, `boolean_op`, `get_keyword`, `character_set`, `lookup`, `path_type`, `record_metadata`, `value_type`. `source` says whether the row is on the Claris page (`claris-doc`) or fm-spec's own (`fm-spec`: the boolean operators, `Get`, `Hole`).

**Canonical EN only.** The localized Claris pages translate the constant names as prose, not as tokens (a Spanish `Sin formato` with a space, a Swedish `CentralEurope (centraleuropeisk)` with an explanatory parenthesis, a German `Lower` rendered as the name of the *function* `Lower`) — they are no source for localized constants. The only localized row is the Get keyword (`Hole` → `Get`).

## Columns

| Column | Type |
|---|---|
| `name` | `VARCHAR` |
| `constant_type` | `VARCHAR` |
| `canonical_name` | `VARCHAR` |
| `used_with` | `VARCHAR` |
| `source` | `VARCHAR` |

**See also:** [functions](functions.md) · [function_name_lookup](function_name_lookup.md)
