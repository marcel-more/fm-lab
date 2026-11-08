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

Search objects by name pattern — or by identity (UUID, numeric FileMaker ID).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | **Required.** SQL `LIKE` pattern, e.g. `%Import%` (case-insensitive), or an identity term (see [Identity search](#identity-search)) |
| `type` | enum | — | Optional type filter |
| `file` | string | — | Optional file filter |
| `limit` | integer | `100` | |
| `offset` | integer | `0` | Pagination |
| `sort` | enum | — | `modified` — newest own change stamp first (see [Change stamps](#change-stamps)); `usage` — by the usage column (see [Usage](#usage)); `name` (case-insensitive), `type`, `file` |
| `usage_dir` | enum | see [Usage](#usage) | `asc` (rarely used first) or `desc` — direction of `sort=usage` |
| `usage_min` / `usage_max` | integer ≥ 0 | — | Only objects whose usage is at least / at most this number (inclusive) |
| `modified_since` | date | — | `YYYY-MM-DD` — only objects whose own change stamp is on or after this day |

Beyond object names, the search also matches **value-list values** (hits report the matched values in `Matched_Values`), **script-step contents** (hits are `ScriptStep` rows carrying `Step_Text`, `Script_Name` and `Step_Index` for breadcrumb display) and the **localized spellings of built-in functions**. Results are ordered by name.

A built-in is catalogued under its canonical English name — that is its identity — so a solution whose formulas are written in German would otherwise be unable to find it: searching `Seitennummer` matches the node `Get(PageNumber)`, and `Matched_Values` names the spelling that matched. Every language the standard reference knows is covered, in both namespaces (function names and `Get` parameters). With `?lang=` the hit also carries `Localized_Name`, the localized form to display next to the canonical one — finding and showing belong together. Catalogs imported before schema 1.32.0 lack the lookup and simply search by name only.

`Calculation` objects are **excluded** from the generic (untyped) name search — their generated names (`<Owner> › <Role>`) would flood every owner-name query with duplicates. With an explicit `type=calculation` the type remains fully searchable and listable.

```bash
curl "http://localhost:3003/api/search?name=%25Invoice%25&type=script"
```

### Identity search

The same endpoint finds an object by its identity. An identity matches **only as the whole term** — it is compared for equality, never as a substring: `D9D61A5F` or a UUID missing its last character finds nothing by identity (it stays an ordinary name/full-text search). One outer `%…%` wrapper — the one the web client adds — is ignored; any further `%` turns identity matching off.

| Term | Matches |
|---|---|
| FileMaker UUID (`D9D61A5F-9B96-462A-8A84-1CFDD2D737BA`) | The object with that UUID. Case-insensitive; `{…}`, quotes and `urn:uuid:` are tolerated |
| 32-hex UUID (`0004a0f0c94ef720cc7a8794bee51759`) | The synthetic UUIDs fm-lab assigns to `Calculation`, `Variable`, `BuiltinFunction`, `PluginFunction`, `ScriptStepType`, … — the ones in fm-lab deep links and API responses. Found even for types the plain name search leaves out |
| Import key (`part_…`, `trig_…`, `paste_…`) | `LayoutPart`, `ScriptTrigger`, `PasteIndexObject` by their composite catalog key. `rel_<id>_<file>` (e.g. `rel_100_Adressen`) only exists for a relationship from an export without `<UUID>` — relationships otherwise carry their FileMaker UUID |
| `id:<n>` (`id:42`) | The numeric FileMaker ID (`Object_ID`). Runs **no** name search |

**Duplicated FileMaker UUIDs.** When an export carries the same UUID more than once, the import keeps it on one object and re-keys the others (`DuplicateAbsorptionDetails`). Searching the original UUID returns all of them: the object that kept it plus every re-keyed sibling.

**`id:<n>` is unique per file only.** Without `type` it searches the types whose ID is unique within a file: `Script`, `Layout`, `TableOccurrence`, `Relationship`, `BaseTable`, `ValueList`, `CustomFunction`, `CustomMenu`, `CustomMenuSet`, `PasteIndexObject`, `ExternalDataSource`, `Account`, `PrivilegeSet`, `ExtendedPrivilege`, `Theme`, `BaseDirectory` — one hit per file that uses the number. Combine it with `file` (and `type`) to pin one object. With an explicit `type`:

| `type` | `id:<n>` means |
|---|---|
| one of the types above | its FileMaker ID |
| `field` | the field ID — unique per table, so expect one hit per table; `Object_Name` (`Table::Field`) tells them apart |
| `builtinfunction` | the Function-ID of the native function (`id:338` → `Substitute`) |
| `scriptsteptype` | the Step-ID of the script step (`id:141` → `Set Variable`, plus every localized step name the solution uses) |
| `layoutobject`, `layoutpart`, `scriptstep`, `scripttrigger` and every other type | no hits — their number identifies nothing without its container (layout, menu) or is a type/event ID |

A bare number (`42`) stays a name search, so names like `Print 2` never turn into ID hits.

**Interplay with the name search.** An identity hit is added to the regular name and full-text hits — a script that contains the UUID as a literal is still found. Identity hits come first and carry `Match_Kind`; an object found both ways appears once, as identity hit. `type` and `file` filter identity hits like every other hit, and `/search/count` counts the same set.

| `Match_Kind` | Meaning |
|---|---|
| `uuid` | The term equals the object's UUID or import key |
| `healed_uuid` | The term is the original FileMaker UUID of a re-keyed duplicate |
| `object_id` · `function_id` · `step_id` | Found via `id:<n>`; `Matched_Values` holds the number |

Name and full-text hits carry no `Match_Kind`.

```bash
curl "http://localhost:3003/api/search?name=D9D61A5F-9B96-462A-8A84-1CFDD2D737BA"
curl "http://localhost:3003/api/search?name=id:42&type=script&file=Contacts"
```

In the web frontend the same terms work in the search field (`/?q=<UUID>`, `/?q=id:42`); identity hits show a *Matched by UUID* / *Matched by ID* label below the name.

### Change stamps

`sort=modified` orders the hits by the object's own change stamp, newest first ([ObjectChangeMeta](../../schema/catalog-tables/ObjectChangeMeta.md)); `modified_since=YYYY-MM-DD` keeps only hits stamped on or after that day. With either parameter every hit carries `Modified_At` (`YYYY-MM-DD HH:MM:SS`, the local time of the editing client without time zone, as text). Without them the order and the response are unchanged.

Only the object's **own** stamp counts. Script steps, layout objects, layout parts, calculations, built-ins and the other types without a stamp of their own have `Modified_At = null`: they come last when sorting and drop out of the date filter. Identity hits stay in front of the other hits. Sorting happens on the server, so it holds across pages — the same goes for every other sort option.

```bash
curl "http://localhost:3003/api/search?name=%25&type=layout&sort=modified&modified_since=2026-01-01"
```

In the web frontend: search options *Sort: Last modified* and *Modified since* (URL `?sort=modified&since=2026-01-01`).

### Usage

On a catalog built with schema 1.40.0 or later every hit carries its **usage** from the analysis table `v_object_usage` — the same definition the [unused-code rules](../../sca/SCA%20Unused%20Code.md) use, so *usage 0* in the search and a finding of the test *Unused Code* mean the same thing. Usage counts only what is visible inside the imported solution; how it is counted and what it cannot see (calls from outside, dynamic references): [Usage and References](../../schema/Usage%20and%20References.md).

| Field | Meaning |
|---|---|
| `Usage` | Number of using objects. An object on a layout counts as its layout, so a field placed 40 times on one layout counts once; script steps are already counted as their script. Built-ins, plug-in functions, plug-in components and step types carry their usage count instead |
| `Usage_Refs` · `Usage_Users` · `Usage_Files` · `Usage_Roles` | References (the incoming rows of the references tab that count as usage, ×N summed), distinct source objects, source files, link roles |
| `Usage_Class` | `used`, `unused`, `entry_point` (no usage, but in the Scripts or layout menu), `builtin` (built-in privilege set); table occurrences also `relationship_bridge`, `dead_branch`, `dead_island` |
| `Usage_Entry_Point` · `Usage_Key_Field` · `Usage_Cross_File` · `Usage_Low_Confidence` | Script / layout in its menu · match field of a relationship · used from another file · file exported without DDR info (a 0 is unverified) |

Script steps, layout objects, layout parts, calculations, relationships and the other types without a usage notion carry `Usage = null`: they come last when sorting by usage and drop out of `usage_min` / `usage_max`. `sort=usage` sorts descending by default and ascending (rarely used first) when `usage_max` is set; ties fall back to name and file.

```bash
# unused scripts of one file (entry points show 0 too, Usage_Class tells them apart)
curl "http://localhost:3003/api/search?name=%25&type=script&file=Contacts&usage_max=0"
# rarely used fields, rarest first
curl "http://localhost:3003/api/search?name=%25&type=field&usage_max=1&sort=usage"
```

On an older catalog the hits carry no usage fields, the usage parameters are ignored and `/search/count` reports `usage_available: false`.

In the web frontend: a *Usage (internal)* column as the last element of every row (fixed width, a highlighted 0 for unused objects, markers for menu entry points, match fields and use from another file, `?` for an unverified 0; a click opens the incoming references grouped by using object), the sort option *Usage (internal)* with a direction toggle and the filter *Usage ≤ / ≥ n* in the search options (URL `?sort=usage&udir=asc&umax=0`, `umin` for ≥). The references tab repeats the number in its header line.

## GET /api/search/count

Count of the same search predicate, without paging: parameters `name` (required, including [identity terms](#identity-search)), `type`, `file`, `modified_since`, `usage_min`, `usage_max`; response `[{ "count": 42, "usage_available": true }]` — `usage_available` is false on a catalog without the usage table.

---

See also: [Objects API](Objects%20API.md) (fetch a found object), [References API](References%20API.md) (where-used).
