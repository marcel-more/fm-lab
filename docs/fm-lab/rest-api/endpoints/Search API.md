# Search API

Listing, counting and name search across the object catalog: `/list`, `/list/categories`, `/list-with-folders`, `/count`, `/search`, `/search/count`.

All endpoints accept the standard `format` / `meta` / `debug` parameters and the `file` filter ([REST API Conventions](../REST%20API%20Conventions.md)). Object type values are case-insensitive; the full list is in [Object types](../REST%20API%20Conventions.md#object-types).

---

## GET /api/list

List all objects of one type.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `type` | enum | — | **Required.** Object type |
| `file` | string | — | Restrict to one FileMaker file |
| `limit` | integer | `100` | `0` = all, cap 10 000 |
| `with_usage` | boolean | `false` | Pseudo-token types only: include usage counts |
| `with_category` | boolean | `false` | Pseudo-token types only: include the category |
| `category` | string (CSV) | — | Pseudo-token types only: filter by categories |
| `sort` | enum | — | `usage` · `name` · `category` |
| `lang` | string | — | Active UI language: `BuiltinFunction` rows additionally carry `Localized_Name` |

The pseudo-token parameters (`with_usage`, `with_category`, `category`, `sort`) apply to the aggregate types `ScriptStepType`, `BuiltinFunction`, `PluginFunction` (usage/sort also to `PluginComponent`); on other types they are ignored. `category`/`with_category` on `PluginComponent` yields `400 VALIDATION_ERROR`.

```bash
curl "http://localhost:3003/api/list?type=script&file=Contacts&limit=0"
```

## GET /api/list/categories

Category summary for a pseudo-token type — the data behind category filter pills.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `type` | enum | — | **Required.** One of `ScriptStepType`, `BuiltinFunction`, `PluginFunction` |
| `file` | string | — | Optional file filter |

**Response `data`:** `[ { "category": "…", "token_count": 12, "total_usage": 480 } ]`, sorted by usage. Other object types yield `400 VALIDATION_ERROR`.

## GET /api/list-with-folders

Hierarchical list of scripts, layouts or custom functions **including folders and separators** in original order — the source for tree/outline views.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `type` | enum | — | **Required.** `script` · `layout` · `customfunction` |
| `file` | string | — | Optional file filter |

Rows appear in catalog order and carry a `nesting_level` plus a row kind (folder / separator / item) so clients can reconstruct the tree. No `limit` — the tree is always delivered completely (a partial tree would break folder nesting).

## GET /api/count

Count objects, optionally grouped.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `type` | enum | — | Optional type filter |
| `file` | string | — | Optional file filter |
| `group_by` | string | — | `type`, `file` or `type,file` |

**Response `data`:** `{ "count": 1234 }`, or with `group_by` an array of `{ Object_Type?, File_Name?, count }`. DDR-internal helper types are always excluded from counts.

## GET /api/search

Search objects by name pattern.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | **Required.** SQL `LIKE` pattern, e.g. `%Import%` (case-insensitive) |
| `type` | enum | — | Optional type filter |
| `file` | string | — | Optional file filter |
| `limit` | integer | `100` | |
| `offset` | integer | `0` | Pagination |

Beyond object names, the search also matches **value-list values** (hits report the matched values in `Matched_Values`), **script-step contents** (hits are `ScriptStep` rows carrying `Step_Text`, `Script_Name` and `Step_Index` for breadcrumb display) and the **localized spellings of built-in functions**. Results are ordered by name.

A built-in is catalogued under its canonical English name — that is its identity — so a solution whose formulas are written in German would otherwise be unable to find it: searching `Seitennummer` matches the node `Get(PageNumber)`, and `Matched_Values` names the spelling that matched. Every language the standard reference knows is covered, in both namespaces (function names and `Get` parameters). With `?lang=` the hit also carries `Localized_Name`, the localized form to display next to the canonical one — finding and showing belong together. Catalogs imported before schema 1.32.0 lack the lookup and simply search by name only.

`Calculation` objects are **excluded** from the generic (untyped) name search — their generated names (`<Owner> › <Role>`) would flood every owner-name query with duplicates. With an explicit `type=calculation` the type remains fully searchable and listable.

```bash
curl "http://localhost:3003/api/search?name=%25Invoice%25&type=script"
```

## GET /api/search/count

Count of the same search predicate, without paging: parameters `name` (required), `type`, `file`; response `{ "count": 42 }`.

---

See also: [Objects API](Objects%20API.md) (fetch a found object), [References API](References%20API.md) (where-used).
