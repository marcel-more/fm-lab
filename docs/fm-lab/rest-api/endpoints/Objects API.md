# Objects API

Retrieve single catalog objects: the basic catalog row (`/get`), the type-specific detail view (`/get-details`), single calculation instances (`/get-calc`), and the conditional-formatting rules of a layout object (`/conditional-formatting`).

All three are UUID/hash-addressed and clone-aware: if a bare UUID exists in more than one file (cloned/modular FileMaker files share internal UUIDs), the response is `409 AMBIGUOUS_UUID` with the list of matching files — retry with `file=<File_Name>`. Unknown identifiers yield `404 OBJECT_NOT_FOUND`. See [Clone disambiguation](../REST%20API%20Conventions.md#clone-disambiguation-file-ambiguous_uuid).

---

## GET /api/get

The `ObjectCatalog` row of a single object.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | **Required.** Object UUID |
| `file` | string | — | Clone disambiguation |
| `format` | enum | `json` | See [REST API Output Formats](../REST%20API%20Output%20Formats.md) |
| `lang` | string | — | Active UI language — see [Localized built-in names](#localized-built-in-names) |
| `meta` / `debug` | boolean | `false` | Envelope extras |

```bash
curl "http://localhost:3003/api/get?uuid=1EC24DF4-…-9AA1"
```

```json
{
  "success": true,
  "data": {
    "Object_UUID": "1EC24DF4-…-9AA1",
    "Object_Type": "Script",
    "Object_Name": "Import Data",
    "File_Name": "Contacts",
    "Object_ID": 42,
    "Source_Table": "ScriptCatalog"
  }
}
```

## GET /api/get-details

Type-specific rich detail view. The server resolves the object's type and dispatches to a dedicated detail template per type (scripts with steps, fields with options, layouts with objects, …); types without a dedicated template fall back to a generic view.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | **Required.** Object UUID |
| `file` | string | — | Clone disambiguation |
| `format` | enum | `json` | Full format enum; `tokens` has special semantics (below) |
| `enrich` | string | — | Language code — only with `format=tokens`: augments tokens with reference-database display names, signatures and help URLs |
| `lang` | string | — | Active UI language — detail templates that can show a localized spelling next to the catalog name use it (today `BuiltinFunction`); other types ignore it |
| `meta` / `debug` | boolean | `false` | `meta` reports `template_used`, `object_type`, … |

**`format=tokens`** returns the structured token payload for editor-style rendering (see [tokens](../REST%20API%20Output%20Formats.md#tokens)). Supported object types: `Script`, `ScriptStep`, `LayoutObject`, `CustomFunction`, `Field`, `CustomMenu`, `CustomMenuItem`, `Calculation`, `ScriptTrigger` — other types yield `400 VALIDATION_ERROR` listing the supported set. Reference enrichment soft-fails when the reference database is not installed (`enrich: null`, `enrich_error: "REF_NOT_ATTACHED"`).

For a `LayoutObject` the payload carries, besides the button-embedded step lines and the generic calculation slots (`calcSlots[]`), the object's structural context (parent layout, part, bounds, nesting), its direct `children[]`, its `triggers[]`, its target relations (`targets[]`) and its conditional-formatting `conditions[]`; text objects additionally get `mergeText` — the text line with merge fields, merge variables and symbols resolved as typed tokens. For a `ScriptTrigger` the payload is the structured trigger projection (event, modes, script, owner chain, parameter calculation) rather than token lines.

Detail templates whose output is a prose block automatically render as plain text for any non-JSON format.

**Layout special case:** the detail template for `Layout` objects generates a complete **SVG wireframe** of the layout (parts as bands, objects as color-coded rectangles with labels and tooltips, nested objects resolved to absolute coordinates). `format=content` returns the ready-to-use SVG document; the default `format=json` delivers the same markup line-wise as rows with a `content` column. Interactive clients that need hover/navigation on individual layout objects should use the structured layout data templates via [/query](Query%20and%20Report%20API.md) instead — see [SVG and visual output](../REST%20API%20Output%20Formats.md#a-note-on-svg-and-visual-output).

### Localized built-in names

A `BuiltinFunction` is catalogued under the **canonical English name of the standard reference** (`Length`, `Get(PageNumber)`) — that name is the node's identity and therefore language-independent, whatever language the solution's formulas are written in. For a developer working in German that alone is not the name they know, so `?lang=<code>` adds `Localized_Name` (`Hole ( Seitennummer )`) **next to** the canonical name rather than replacing it: the canonical name stays what search, deep links and the reference join run on.

Resolved by lookup — `BuiltinFunctionIdentity.Function_ID` → the reference's localized display name — never derived from the name. The field is present only when it actually differs from the canonical name, so an English UI sees no redundant duplicate. Applies to `/api/get`, `/api/list` and `/api/search` alike, so list, hit list and detail page show the same name; the graph keeps the canonical label alone, where space is tight and labels are mostly hidden.

## GET /api/get-calc

The token view of a single calculation **instance**. Since catalog schema 1.22.0 the primary address is the instance's `Calculation_UUID`; the former hash address remains as a legacy alias. A hash is *not* unique — the export dedupes formulas by content, so one hash can serve many instances; the alias picks a representative match.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | `Calculation_UUID` of the instance — **primary**; exactly one of `uuid`/`hash` is required |
| `hash` | string | — | Calculation hash (legacy alias, best-effort pick among matching instances) |
| `file` | string | — | Clone disambiguation |
| `format` | enum | `tokens` | Only `tokens` or `json` |
| `enrich` | string | — | Language code for reference enrichment |
| `meta` / `debug` | boolean | `false` | |

**Response `data`:** `{ "kind": "calculation", "object": { … }, "tokens": [ … ], "plainText": "…" }`. Unknown identifier: `404 OBJECT_NOT_FOUND`; neither `uuid` nor `hash`: `400 VALIDATION_ERROR`.

## GET /api/conditional-formatting

The conditional-formatting rules of one layout object — rule-exact, with condition formula, value operands and the applied format.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | **Required.** LayoutObject UUID |
| `file` | string | — | Clone disambiguation |
| `meta` / `debug` | boolean | `false` | |

Only `format=json` is accepted — the rule structure has no meaningful table projection. Objects without rules (including non-LayoutObjects) return `rules: []`; catalogs imported without the structured rule extraction return `unavailable: true` instead of an error.

---

## Calculation objects

Since catalog schema 1.22.0 every calculation slot of the solution — a field's auto-enter or validation, a hide condition, a conditional-formatting rule, a script-step parameter, … — is a first-class object (`Object_Type = 'Calculation'`) with its own stable `Calculation_UUID` (see [Calculation](../../schema/object-types/Calculation.md) / [CalculationsCatalog](../../schema/catalog-tables/CalculationsCatalog.md) in the schema reference). Across this API:

- `/get` and `/get-details` accept a `Calculation_UUID` like any other object. The detail view shows owner, slot role, formula and resolved targets; `format=tokens` additionally carries a `calc { role, index, owner, … }` block and the resolved `targets[]`. Layout display formulas whose formula text could be recovered are tokenized synthetically from that formula and its resolved references, flagged `tokensRecovered: true`; otherwise an instance without DDR data returns `200` with `tokens: []` and the `plainText` fallback — not a 404.
- LayoutObject token payloads list the object's generic calculation slots as `calcSlots[]` (uuid, role, plain text); trigger-parameter and conditional-formatting formulas appear in the dedicated `triggers[]` / `conditions[]` blocks instead. Each slot renders in full via `/get-calc?uuid=…`.
- **Where-used caveat:** usage edges stay on the *owner* object (a `Calculation` never counts as usage), and the calculation's own target resolution lives in the derived view `v_calculation_links`, not in `ObjectLinks`. [/api/references](References%20API.md) therefore returns no children for a `Calculation_UUID` — read the `targets[]` of `/get-details?format=tokens` instead; the containment direction is the structural `has_calculation` edge (owner → calculation).

---

See also: [Search API](Search%20API.md) (finding UUIDs), [References API](References%20API.md) (dependencies of an object), [REST API Output Formats](../REST%20API%20Output%20Formats.md).
