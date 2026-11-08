---
name: create-custom-dashboard
description: >-
  Interactively creates a new custom dashboard for the fm-lab dashboard system — as a
  single-file dashboard (one `.sql` file with a `-- @` header) or as a full bundle (manifest,
  layout, datasets, locales). Clarifies the goal, drafts SQL, confirms sample results with the
  user, recommends the build form and an interactive pattern (navigation, KPI filters, search),
  asks for a name, and writes the result under `rest-api/templates/dashboards-custom/`. Triggers
  (English): "/create-custom-dashboard", "create a new dashboard for X", "new dashboard", "build a
  dashboard that shows X", "create a custom query for X". Triggers (German): "erstelle ein neues
  Dashboard für X", "neues Dashboard", "baue ein Dashboard das X zeigt", "erstelle eine eigene
  Query für X". Also responds to equivalent requests in other languages.
metadata:
  version: "0.9.18"
---

# Create a custom dashboard

Guide the user interactively through the creation of a new dashboard. One
skill, two build forms:

- **Single-file dashboard** — `rest-api/templates/dashboards-custom/[<folder>/]<id>.sql`:
  one query with a `-- @` header; the server derives the manifest and renders
  a title card above a sortable, searchable table.
- **Bundle** — `rest-api/templates/dashboards-custom/[<folder>/]<id>/` with
  `manifest.json`, `layout.json`, at least one SQL file under `data/`, and 10
  locale files.

Step 3 recommends the form; the user decides in gate G2.

## Reference files (read at the step that needs them)

| File | Content | Read before |
|---|---|---|
| `references/sql-rules.md` | join matrix (UUID+file), qualified columns in joins, params, `:word` trap, locale independence, count consistency | step 2 (first SQL draft) |
| `references/patterns.md` | build form (single file or bundle), patterns P1–P6, intent matrix, interactivity duties in full | step 3 (recommendation) |
| `references/single-file.md` | header keys, `@default_result`, paging and chip header, moving between the forms | step 5B (single file) |
| `references/primitives.md` | all primitives/props, actions, tokens, formats, manifest schema | step 5A (bundle) |
| `references/localization.md` | locale files, ID-form overrides | step 5A.4 |
| `references/validation.md` | verification gates V1–V6 (bundle) and F1–F5 (single file), auto-heal, closing messages | step 5.6 |

## Directory split

| Directory | Content | Who writes? |
|---|---|---|
| `rest-api/templates/dashboards/` | shipped dashboards: `system/` (`home`, `_generic`, `file`, `xml_convert`), `modules/` (`dashboards`, `docs/…`, `tests/…`) and the content folders (`static-code-analysis/`, `modularization/`, `changelog/`, `layouts/`, `scripts/`, …) with bundles and single-file dashboards | core team only |
| `rest-api/templates/dashboards-custom/` | the user's own dashboards — gitignored, never touched by updates | this skill, the user |
| `rest-api/templates/dashboards-community/` | reserved for community packages | — |
| `rest-api/templates/queries/` | internal templates the server calls by name (`system/`, `modules/`) — never a target | core team only |

This skill writes **exclusively** to `dashboards-custom/` — either directly
(`dashboards-custom/<id>/`, `dashboards-custom/<id>.sql`) or grouped in
sub-folders (`dashboards-custom/<folder>/[<sub>/]…`, up to four levels, see
`references/patterns.md` §Folder placement). The overview lists them under
**Custom**; the breadcrumb reads
`{SOLUTION} / Dashboards / Custom / [<folder> / …] / <title>`.

ID rules (bundles and single-file dashboards share one namespace across all
three dashboard directories):

- IDs of system and module bundles (everything under `dashboards/system/` and
  `dashboards/modules/`) are **reserved** — a custom bundle with such an ID is
  ignored. Never use one.
- A single-file dashboard must not be named like an internal template
  (`queries/system/**`, `queries/modules/**`) — the file is discarded.
- The ID of a shipped content dashboard (bundle or file) **overrides** it: the
  original disappears from the overview, the custom one is marked as
  overriding the default. Only on the user's explicit request.

## Ground rules

- **Language**: dialogue in the user's input language. SQL files and headers,
  `manifest.json`, `layout.json`: English only (filenames, params, aliases,
  labels, comments). Translations go to `locales/<lang>.json` (bundle step
  5A.4); a single-file dashboard stays English.
- **Database**: `db/fm_catalog.duckdb` (master — NOT `rest-api/db/`); with an
  active session pin (`FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2) run
  draft/sample queries against the literal bundle path
  `solutions/<id>/db/fm_catalog.duckdb`.
- **DuckDB invocation**: bare `duckdb -readonly db/fm_catalog.duckdb -c "…"` per
  CLAUDE.md §2; never install DuckDB yourself.
- **Read-only**: never UPDATE/INSERT/DELETE on the database.
- **Identity rule (memorise):** an object's identity is **(UUID, File_Name)** —
  numeric FileMaker IDs are file-scoped, and UUIDs can be duplicated by cloned
  files. Join and GROUP BY on the pair. Details: `references/sql-rules.md`.
- **Interactivity duties (memorise):**
  - **I1** object rows are always navigable (`openObject` with `uuid`+`type`+`file`);
  - **I2** meaningful partitions become clickable filters (KPI hero tiles /
    FilterChips — server-side via URL param → `getvariable`);
  - **I3** every List/Table/TileGrid that typically exceeds 3 rows gets
    `"searchable": "auto", "searchAutoThreshold": 3`.

  In the single-file form I1 is `@click_action`/`@click_args`, I2 is the chip
  bar over one column (`@chip_filter`/`@chip_param`), I3 is built in.

## The three gates (non-negotiable)

Files are written **only after all three gates have an explicit user answer**:

| Gate | After | Confirms |
|---|---|---|
| **G1** | step 2 preview | the data is what the user needs |
| **G2** | step 3 | build form, pattern & presentation |
| **G3** | step 4 | ID & title |

**Every gate is an AskUserQuestion tool call** — never a question typed as prose
at the end of a working turn, and never answered by yourself because the choice
"seems obvious". If the AskUserQuestion tool is unavailable in this session
(headless run), ask the question as the **last line of your reply and end the
turn** — do not continue working past an unanswered gate.

A topic passed with the invocation (e.g. `/create-custom-dashboard variable
analysis`) skips only the step-1 topic question — never G1–G3.

---

## Workflow

### Step 1 — Clarify the goal

If no topic was provided, ask one short question (AskUserQuestion, free-form via
"Other" is fine): *"What should the dashboard show?"* with 2–3 example options
drawn from the catalog domain (e.g. variable overview, scripts without comments,
lookup fields).

With the topic in hand, silently classify the **intent** using the matrix in
`references/patterns.md` (worklist? counts-per-trait? two-level drilldown?
lenses/thresholds? multi-facet? static?). The intent drives steps 2–3: a P2/P3
intent needs a summary dataset and a filter param from the start.

### Step 2 — Draft the SQL, execute, preview

**Read `references/sql-rules.md` now.** Draft the dataset SQL accordingly
(identity rule, every column alias-qualified once a statement joins tables,
result contract with `uuid`/`file`/`name`, `getvariable` params, no `:word`
sequences, `Step_ID` instead of step-name literals).

Execute with a preview limit:

```bash
duckdb -readonly db/fm_catalog.duckdb -c "<SQL with LIMIT 10>"
```

On error: correct once and re-run. After two failures, take the error to the user
via AskUserQuestion (options: alternative interpretation / different data source /
abort).

Run the **fan-out plausibility check** from sql-rules.md §1 when top counts look
identical, round, or too high.

Present the result: ≤10 rows fully; >10 rows as "first 10 of N"; >8 columns the
most important ones; 0 rows → say so and propose an alternative query.

### Gate G1 — Confirm the data (AskUserQuestion)

Question: *"Does this preview show what you need?"*
Options (adapt): **"Yes, continue" (Recommended)** · "Adjust columns/filters" ·
"Different data entirely". On 0 rows or implausible counts, replace the first
option with your best alternative hypothesis. Iterate step 2 until G1 passes.

### Step 3 — Recommend build form, pattern & presentation

**Read `references/patterns.md` now.** Three stages:

0. **Build form** from the signal table (§Build form): single-file dashboard
   (one query, one object type, a table with sort/search/row click, optional
   chip bar over one column and server paging) or bundle (several datasets,
   KPI tiles, filter menus, drilldown, several panels, notes, translations).
1. **Pattern** (bundle form) from the intent matrix (P1 navigator, P2
   segmented overview, P3 aggregate+drilldown, P4 lens, P5 multi-facet, P6
   static; combinations allowed — P2+P3 is the normal case for real analyses).
   The single-file form is always a P1 table.
2. **Primitives** (bundle form) from the shape table (List vs Table vs
   AutoTable vs TileGrid …).

The recommendation **already includes** the interactivity duties — G2 asks *how*
to present, never *whether* rows are clickable or searchable. If the data has a
partition dimension (I2), name the concrete KPI tiles the user will get (e.g.
"Total / with trait / without trait — each tile filters the list") and, when the
partition dimension is ambiguous, ask for it **in the same** AskUserQuestion
(second question in the call, multiSelect where traits combine). A partition
that needs tiles is a bundle signal; value chips over one column fit the
single file.

### Gate G2 — Confirm form and presentation (AskUserQuestion)

Question: *"Which presentation should I build?"*
Options: **the recommendation (Recommended)** — e.g. *"Single-file dashboard
(Recommended)"* with the description "one table: sort, search, click opens the
script; chips by file", or *"Bundle — P2 overview (Recommended)"* with its
tiles/filters/search — · the other build form as an alternative (always
offered) · at most one further pattern variant · (optional second question:
partition dimension). Keep option labels short; put the tile/filter/search
summary in the description.

The user decides the form — never switch it silently later. When the user
picks the other form, continue with the SQL confirmed in G1 (a bundle may add
a summary dataset for its tiles; run its preview before writing).

### Step 4 — Propose ID and title

- **ID** (= bundle directory basename, or file name without `.sql`): lowercase
  ASCII `a-z0-9_`, max 30 chars; avoid reserved IDs (`home`, `_generic`,
  `file`, `xml_convert`, `dashboards`, `docs`, `tests_overview`,
  `test_detail`, … — everything under `dashboards/system/` and
  `dashboards/modules/`; for the single-file form also the names of
  `queries/system/**` and `queries/modules/**`). Transliterate user-language
  names (ä→ae, ö→oe, ü→ue, ß→ss, é→e, …).
- **Title**: English, max 50 chars, human-readable. Bundle form: if the user's
  language ≠ English, also show the localized title that will land in
  `locales/<lang>.json`. Single-file form: the title stays English.

### Gate G3 — Confirm the name (AskUserQuestion)

Question: *"Use this name?"* Options: **"`<id>` / \"<title>\"" (Recommended)** ·
1 alternative naming · ("Other" catches free-form names — derive ID and English
title from whatever the user supplies).

### Write-gate (self-check — not a user question)

Immediately before writing: **do G1, G2 and G3 each have an explicit user answer
in this conversation?** If any is missing (e.g. after a compaction or a detour),
ask that gate **now**. Never write files on inferred consent.

Then check for collisions (one namespace for bundles and files):

```bash
find rest-api/templates/dashboards rest-api/templates/dashboards-custom rest-api/templates/dashboards-community rest-api/templates/queries \( -path '*/<id>/manifest.json' -o -name '<id>.sql' \) -not -path '*/data/*'
```

- Hit under `dashboards/system/` or `dashboards/modules/` → reserved ID: pick
  another one (no question needed).
- Hit under `queries/` (single-file form) → internal template: pick another
  one (no question needed).
- Hit elsewhere under `dashboards/` → ask (AskUserQuestion): rename
  (Recommended) or deliberately override the shipped dashboard.
- Hit in `dashboards-custom/` → ask whether to overwrite or rename; never
  leave a bundle **and** a file with the same ID there.
- Hit in `dashboards-community/` → rename (a custom dashboard would hide it).

With the server up, `GET /api/dashboards/<id>` (200 = taken; `area`,
`overrides` in the response) confirms the result.

### Step 5A — Generate the bundle

**Read `references/primitives.md` now** (node shape, `id` convention, props,
actions, manifest schema constraints) and keep `references/patterns.md`'s skeleton
for the chosen pattern at hand.

1. **`data/<dataset>.sql`** — final SQL per sql-rules.md (`@template_type` /
   `@description` / `@params` header; lists end in the server-paging frame
   instead of the preview LIMIT — a parameterised LIMIT only for Top-N rankings
   and short group lists). Separate files for logically separate datasets (summary KPI + detail
   list). Shared base population = shared CTE text in both files (sql-rules §5).
2. **`manifest.json`** — schema constraints per primitives.md §Manifest.
   Declare every `getvariable` param under `params`; icon from the Lucide list;
   `"permissions": { "read_only": true, "allow_navigation": true }`. When the
   rows point at objects (`AS nav_uuid`), declare their object types in
   `"analysis": { "objectTypes": [...] }` (ObjectCatalog.Object_Type values,
   e.g. `["Script"]`) — the overview's object-type filter reads only this
   declaration.
3. **`layout.json`** — `Grid(columns:12)` root, every content unit in a `Card`,
   **every node with a stable `id`**. First card without `title` (the entry title
   comes from `manifest.title`); only genuine section labels on follow-up cards.
   Apply I1–I3 exactly as confirmed in G2.
4. **`locales/*.json`** — **read `references/localization.md`**, generate all 10
   languages with ID-form keys in one pass.

### Step 5B — Generate the single-file dashboard

**Read `references/single-file.md` now.** Write one file,
`rest-api/templates/dashboards-custom/[<folder>/]<id>.sql`:

1. **Header** — required `@template_type: report`, `@title`, `@description`;
   recommended `@object_types`, `@default_result` (findings value, test
   membership), `@click_action`/`@click_args` (I1), `@params`,
   `@output_format`, `@icon`, `@tags`, `@author`, `@version`; optional
   `@scope`, `@output_types`, `@row_action*`, `@chip_filter`/`@chip_param`,
   paging keys. Never `@category` — the folder places the file.
2. **Body** — the SQL confirmed in G1 without the preview LIMIT: lists that
   can outgrow one page get the paging frame (header keys + frame), Top-N
   rankings a parameterised LIMIT. Object rows return `uuid`/`_nav_uuid`,
   `name`, `file`; test members a `_message` column.
3. **Folder** (only when grouped) — an optional `folder.json` in the folder
   (`references/patterns.md` §Folder placement).

### Step 5.6 — Verification gate (BLOCKING — never skip)

**Read `references/validation.md`.**

- **Bundle:** run V1–V6 — cache reload, `GET /api/dashboards/<id>`, log check
  (incl. `[dashboard-i18n]` warnings), one auto-heal retry for the known
  manifest failures, dataset probes (default run **and one run per filter
  param** via `SET VARIABLE`), KPI/detail count consistency, interactivity
  self-check I1–I3.
- **Single file:** run F1–F5 — header self-check, `GET /api/dashboards/<id>`
  (derived manifest, crumbs), `GET /api/query?template=<id>&format=json` and
  `/api/dashboards/<id>/data` per filter param, the direct `duckdb … .read`
  run (the only check without a server), findings value.

Writing the files and announcing success without this gate has hit us
repeatedly — Joi rejects silently and the API only says "not found or invalid";
the real reason is always in `logs/rest-api.log` with prefix `[dashboard:<id>]`.

### Step 5.7 — Closing message

Use the template for the chosen form in `references/validation.md`. Bundle:
files tree, pattern, filter params with an example URL, verification status,
interactivity waivers. Single file: path, breadcrumb
`Dashboards / Custom / [<folder> / …] <title>`, link `/dashboard/<id>`,
findings value, verification status — then offer a test membership via
`/create-custom-test` (with `@default_result`) and the later move to a bundle
(the file becomes its first dataset, see `references/single-file.md`).

---

## Example runs (compressed)

**User**: `/create-custom-dashboard list of all scripts without a comment`

1. Topic given → intent: worklist, one object type (P1).
2. Read sql-rules.md → draft (note `Step_ID = 89 -- "# (comment)"`, identity-pair
   joins, `file` param) → preview 10 of 47 rows.
3. **G1**: "47 scripts, columns name/file/steps — is this the data you need?"
   → *Yes.*
4. Read patterns.md → one list, one type, click opens the script → recommend
   *Single-file dashboard*; alternative *Bundle — P2 overview*. **G2** →
   *Single-file.*
5. **G3**: `scripts_without_comment` / "Scripts without comment" → *Yes.*
6. Write-gate: G1 ✓ G2 ✓ G3 ✓ → collision check → read single-file.md →
   write `dashboards-custom/scripts_without_comment.sql` (header with
   `@object_types: Script`, `@click_args: uuid={{uuid}}&type=Script&file={{file}}`,
   `@default_result` row count, paging frame).
7. Gate F1–F5 → closing message with `/dashboard/scripts_without_comment`,
   offer `/create-custom-test`.

**User**: `/create-custom-dashboard scripts without comments, with counts per file and KPI tiles`

Same steps 1–3; step 4 recommends *Bundle — P2* (KPI heroes "Total / without
comment / with comment" filtering a searchable, clickable list), alternative
*Single-file dashboard*. **G2** → *P2*. **G3** → bundle `data/` (summary.sql +
scripts.sql sharing the base CTE), manifest, layout (ids everywhere,
`searchAutoThreshold: 3`, `openObject` with uuid+file), 10 locales → gate V1–V6
→ closing message with `/dashboard/scripts_without_comment?pattern=without`.

## Triggers in other languages

The frontmatter `description` carries the English and German trigger phrases.
Equivalent phrases in further languages:

- **Spanish:** "crea un nuevo dashboard para X", "nuevo dashboard", "construye un dashboard que muestre X".
- **French:** "crée un nouveau tableau de bord pour X", "nouveau tableau de bord", "construis un tableau de bord qui affiche X".
- **Italian:** "crea una nuova dashboard per X", "nuova dashboard", "costruisci una dashboard che mostri X".
- **Dutch:** "maak een nieuw dashboard voor X", "nieuw dashboard", "bouw een dashboard dat X toont".
- **Portuguese:** "crie um novo dashboard para X", "novo dashboard", "construa um dashboard que mostre X".
- **Swedish:** "skapa en ny instrumentpanel för X", "ny instrumentpanel", "bygg en instrumentpanel som visar X".
- **Japanese:** "Xのための新しいダッシュボードを作成して", "新しいダッシュボード", "Xを表示するダッシュボードを作って".
- **Korean:** "X용 새 대시보드 만들어 줘", "새 대시보드", "X를 보여 주는 대시보드 만들어 줘".
- **Chinese:** "为 X 创建一个新仪表板", "新仪表板", "构建一个显示 X 的仪表板".
