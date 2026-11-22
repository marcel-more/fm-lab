# REST API Output Formats

Most read endpoints accept a `format` query parameter that controls how results are rendered. Eleven formats are supported; names are case-insensitive. The default is `json` everywhere except `/report` (default `html`) and `/get-calc` (default `tokens`).

**Envelope rule:** `json` and `tokens` are structured formats — they are wrapped in the standard `{ success, data, meta }` envelope and served as `application/json`. Every other format returns the rendered payload **directly** (no envelope) with its own content type; when `meta=true` or `debug=true` is set, the metadata is appended as a trailing comment (`<!-- … -->` in HTML/Markdown, `# …` in text formats).

**Validation:** a format outside the enum is rejected with `400 VALIDATION_ERROR` before the endpoint runs. A *valid* format applied to data it cannot render either degrades gracefully (the text formats) or fails (`mermaid`, `mermaid-raw` and `svg` on data without a diagram shape answer `422 DIAGRAM_ERROR`; `tokens` outside its two endpoints).

| Format        | Content type       | Best for                                                        |
| ------------- | ------------------ | --------------------------------------------------------------- |
| `json`        | `application/json` | Programmatic access (default)                                   |
| `raw`         | `text/csv`         | Spreadsheet import, piping                                      |
| `text`        | `text/plain`       | Quick `UUID \| Name` lists                                      |
| `short`       | `text/plain`       | Names only                                                      |
| `detailed`    | `text/plain`       | One-line summaries with file/type/refcount                      |
| `html`        | `text/html`        | Browsable result table                                          |
| `markdown`    | `text/markdown`    | Pasting into docs/issues                                        |
| `content`     | `text/plain`       | Prose output of content templates                               |
| `mermaid`     | `text/html`        | Rendered dependency diagram                                     |
| `mermaid-raw` | `text/plain`       | Mermaid source for further processing                           |
| `svg`         | `image/svg+xml`    | Diagram as a standalone SVG file, drawn on the server           |
| `tokens`      | `application/json` | Editor-style token rendering (`/get-details`, `/get-calc` only) |

---

## json (default)

The result rows unchanged, inside the standard envelope. Single-object endpoints (`/get`) return an object, list endpoints an array.

```json
{ "success": true, "data": [ { "Object_UUID": "ABC-123", "Object_Type": "Script", "Object_Name": "Import Data", "File_Name": "Contacts" } ] }
```

## raw

CSV: header row from the union of all row keys, one line per row. Values containing commas, quotes or newlines are quoted with `"` doubling. Suited to any tabular result.

```
Object_UUID,Object_Type,Object_Name,File_Name
ABC-123,Script,Import Data,Contacts
DEF-456,Field,"Name, full",Contacts
```

## text

One line per row: `UUID | Name`. The formatter resolves UUID/name across common column variants (`Object_UUID`, `Source_UUID`, `Target_UUID`, …) and falls back to `N/A` / `Unnamed`.

```
ABC-123-DEF | Import Data
DEF-456-GHI | Validate Order
```

## short

Object names only, one per line — the piping-friendly minimal form.

```
Import Data
Validate Order
```

## detailed

One line per row: `UUID | File | Type | Name | RefCount`. The last column is populated when the result carries a count/depth field (e.g. `/references`, grouped `/count`), otherwise `-`.

```
ABC-123-DEF | Contacts | Script | Import Data | 3
DEF-456-GHI | Contacts | Field  | Order_Total | -
```

## html

A standalone HTML document with a styled table (header row from the union of all keys, escaped cells, row-count footer). Renders any tabular result browsable; empty results produce a "No data available" page.

## markdown

A Markdown table with heading and `_Total rows: N_` footer; pipes and backslashes escaped, newlines collapsed. Ready to paste into issues or documentation.

```markdown
| Object_UUID | Object_Name |
| --- | --- |
| ABC-123 | Import Data |
```

## content

Emits only the `content` column of each row, joined by newlines — everything else is dropped. Designed for templates that pre-render their output *inside SQL*: the rows form a text artifact line by line, and `format=content` concatenates them. On results without a `content` column the output is empty. Detail templates marked as content templates render as `content` automatically for any non-JSON format.

The artifact does not have to be prose. Content templates are the generic escape hatch for any text-based output format the SQL can assemble — narrative summaries, Mermaid source (see below), or complete **SVG markup** such as a layout wireframe whose `<svg>`/`<rect>`/`<text>` elements are built row-wise from `LayoutObjects` geometry:

```
Script: Import Data (Contacts)
Steps: 12 · References: 3
This routine imports the daily customer feed …
```

## mermaid · mermaid-raw · svg

Diagram rendering with two auto-detected input modes:

1. **Graph mode** — result rows carry `source_uuid` and `target_uuid` (any case), plus optional columns: `source_name`/`target_name` (box text), `source_type`/`target_type` (object type → border colour), `source_file`/`target_file` (keeps objects with the same UUID in different files apart) and `edge_label` or `edge_kind` (edge text). Rendered as a `flowchart` with one node per unique object; nodes are numbered `n0, n1, …` in a stable order (by name), so the same result always yields the same source. `direction=TD|LR|BT|RL` sets the layout (default: the template's `mermaid_direction`, else `TD` on `/query` and `/report`, `LR` elsewhere), `title` the heading. Above 500 nodes or 200 000 characters the diagram is cut and a `%% truncated: …` comment line says how much is shown.
2. **Content mode** — rows carry a `content` column with ready-made Mermaid source: the lines are joined unchanged (also for content templates).

Names are data: the graph mode escapes them with Mermaid entity codes (`#quot;` `#lt;` `#gt;` `#amp;` `#96;` `#35;` `#124;`, line breaks as `<br/>`), so a quote, bracket or pipe in a name can neither break the diagram nor inject anything.

- `mermaid` — a self-contained HTML page; the diagram is drawn in the browser with [pele](https://github.com/obsidianmd/pele), which the API serves itself (`GET /api/assets/pele.js`, no CDN). Links, images and HTML in diagram text are off; the source sits HTML-escaped in the page. `theme=dark` forces the dark colours, `default` follows the system setting, `forest`/`neutral` are light. A source pele cannot draw shows the error with its line below the source text.
- `mermaid-raw` — only the diagram source:

```
flowchart TD
  classDef k_Script stroke:#0ea5e9,stroke-width:2px
  n0["Import Data"]:::k_Script
  n1["Validate Order"]:::k_Script
  n0 -->|"calls_script"| n1
```

- `svg` — the diagram drawn on the server with the same renderer: a standalone SVG file with XML header and a white background, light colours. A source pele rejects answers `422 DIAGRAM_ERROR` with `details.reason` (`syntax`, …), `line` and `column`.

With `meta=true`/`debug=true` the trailing comment is a `%%` line in `mermaid-raw` and an XML comment in `mermaid` and `svg`.

Only meaningful for edge-shaped `/query`/`/report` templates or content templates with Mermaid source — other data answers `422 DIAGRAM_ERROR` (`details.reason`: `empty` or `shape`). The rows of [/references](endpoints/References%20API.md) carry no `source_uuid`/`target_uuid` and therefore cannot be drawn.

## tokens

A structured JSON payload that tokenizes FileMaker script and calculation content into typed spans for editor-style rendering — the format behind the FM-Lab detail views and the VS Code extension.

Available **only** on `/api/get-details` (object types `Script`, `ScriptStep`, `LayoutObject`, `CustomFunction`, `Field`, `CustomMenu`, `CustomMenuItem`, `Calculation`, `ScriptTrigger`) and `/api/get-calc`; other endpoints and types reject it. Token types: `text`, `function`, `customFunction`, `pluginFunction`, `variable` (with `scope: local|global`), `field` (with resolved `TO::Field` and UUID), `comment`. Field references, find requests and sort orders are parsed out of the step definitions; function tokens carry stable synthetic UUIDs for cross-navigation.

With `enrich=<lang>`, step and function tokens are augmented with localized display names, signatures and help links from the [reference database](endpoints/Reference%20Database%20API.md) (soft-fails with `enrich_error` when it is not installed).

Abbreviated example (`kind: "script"`):

```json
{
  "kind": "script",
  "object": { "uuid": "ABC-123", "name": "Import Data", "file": "Contacts" },
  "lines": [
    { "kind": "step", "indent": 0, "stepId": 141, "stepName": "Set Variable",
      "text": "Set Variable [ $count ; Value: Count ( Orders::ID ) ]",
      "refs": [ { "type": "function", "name": "Count" }, { "type": "field", "name": "Orders::ID" } ] },
    { "kind": "comment", "indent": 0, "text": "loop over rows" }
  ],
  "plainText": "Set Variable [ … ]\n# loop over rows"
}
```

Other kinds follow the same pattern: `customfunction` (parameters + token stream), `field` (storage/auto-enter context + calc tokens), `calculation` (addressed by `Calculation_UUID`, hash as legacy alias — carries a `calc { role, index, owner, … }` block and resolved `targets[]`, see [GET /api/get-calc](endpoints/Objects%20API.md#get-apiget-calc)), `custommenu` (one token stream per attached calculation), `scripttrigger` (no token lines — the structured trigger projection: event, modes, script, owner chain, parameter calculation).

---

## A note on SVG and visual output

Visual output takes three distinct routes, and the distinction matters when choosing an endpoint:

1. **Tabular rendering** (`html`, `markdown`, `raw`) — generic formatters that render any result rows as a table. Data-shape-agnostic.
2. **Graph rendering** (`mermaid`, `mermaid-raw`, `svg`) — for *edge-shaped* data (`source_uuid`/`target_uuid` rows from graph-shaped `/query` templates). The API emits Mermaid source, an HTML page that draws it in the browser, or the finished SVG drawn on the server; both use pele. The relationship diagram ([GET /api/relationship-graph/](endpoints/Graph%20API.md#get-apirelationship-graphfilename)) likewise ships structured JSON geometry for the client to draw.
3. **Layout rendering (wireframe)** — for *geometry-shaped* data (`LayoutObjects` bounds). Both variants are production paths, serving different client types:
   - **Structured data + client-side drawing** — for interactive clients: the layout data templates (via [/query](endpoints/Query%20and%20Report%20API.md)) return one JSON row per layout object with absolute coordinates, part assignment, nesting and colors; the client draws the wireframe itself and owns hover, tooltips, cross-navigation and filtering. This is how the FM-Lab web frontend renders its layout view.
   - **Server-generated SVG** — for lightweight clients: the Layout detail template of [GET /api/get-details](endpoints/Objects%20API.md#get-apiget-details) *is* a content template that assembles the complete `<svg>` document row-wise (parts as bands, objects as color-coded rectangles with tooltips and labels, nesting resolved recursively). `GET /api/get-details?uuid=<layout>&format=content` returns the ready-to-use SVG file (served as `text/plain`; save as `.svg`, embed in HTML, or inline as a `data:image/svg+xml` URI). With the default `format=json` the same markup arrives line-wise as `content` rows — join them with newlines to reconstruct the document.
