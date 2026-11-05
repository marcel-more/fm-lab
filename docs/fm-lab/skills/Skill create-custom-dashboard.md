# Skill: create-custom-dashboard

Builds a new custom dashboard interactively — clarifies the goal, drafts and previews the SQL, recommends the build form (a single `.sql` file or a full bundle) and an interactive pattern, agrees on a name, writes the result under `rest-api/templates/dashboards-custom/` and verifies it against the running API before declaring success.

| | |
|---|---|
| **Category** | Extending FM-Lab |
| **Slash command** | `/create-custom-dashboard [<topic>]` |
| **Say it naturally** | "create a new dashboard for X", "new dashboard", "build a dashboard that shows X", "create a custom query for X" — English and German |
| **Input** | what the dashboard should show, then your answers at three confirmation gates |
| **Reads** | `db/fm_catalog.duckdb` (read-only, preview queries), the dashboard directories (`dashboards/`, `dashboards-custom/`, `dashboards-community/`) and the internal templates (`queries/`) for id collisions, `logs/rest-api.log` during verification |
| **Writes** | single file: `rest-api/templates/dashboards-custom/[<folder>/]<id>.sql` · bundle: `rest-api/templates/dashboards-custom/[<folder>/]<id>/` — `manifest.json`, `layout.json`, `data/*.sql`, `locales/*.json` (10 languages); optionally a `folder.json` for a new folder |
| **Prerequisites** | a converted catalog; the REST API running for the full verification gate |
| **Under the hood** | six bundled references (SQL rules, patterns and build form, single-file header, primitives, localization, validation) read at the step that needs them; verification via `GET /api/dashboards/<id>`, `/api/query`, dataset probes and a direct DuckDB run |
| **Skill directory** | `.claude/skills/create-custom-dashboard/` |
| **Related** | [Skill create-custom-test](Skill%20create-custom-test.md) · [Skill fm-test](Skill%20fm-test.md) · [Skill skill-creator](Skill%20skill-creator.md) |

## What it does

Every rule and analysis in the dashboard system is a dashboard, in one of two forms ([Single-file Dashboards](../templates/Single-file%20Dashboards.md), [bundles](../templates/Dashboard%20Datasets.md)); this skill produces one from a plain-language goal without you writing headers, manifests, layouts or locale files by hand. It writes exclusively to your own directory `rest-api/templates/dashboards-custom/` — the shipped dashboards under `rest-api/templates/dashboards/` stay untouched, and git as well as updates leave your dashboards alone.

**Two build forms, one skill.** After the data is confirmed, the skill recommends the form:

| Form | Recommended when … | You get |
|---|---|---|
| **Single-file dashboard** | one list, one object type, a click opens the object — "list of all …", "which … have …", rankings, inventories, test members | `<id>.sql` with a `-- @` header: a sortable, searchable table with row click, optional chip bar and server paging, a findings value; English only |
| **Bundle** | several result lists, counts per trait as filter tiles, groups with drill-down, several panels, explanatory notes, translations | a full bundle with one of the interactive patterns and 10 locale files |

The recommendation is part of gate G2 and always offers the other form as an alternative. You decide; the skill never switches forms silently. Choosing the other form keeps the SQL you already confirmed.

**Where it lands.** A single dashboard goes directly into `dashboards-custom/` (`<id>.sql` or `<id>/`); related dashboards can be grouped in a folder (`dashboards-custom/<folder>/[<sub>/]…`, up to four levels) with an optional `folder.json` (`title`, `description`, `order`, inline `locales`) — without one, the label is the humanized directory name. The dashboard overview lists them under **Custom**, and every folder becomes one breadcrumb level: `{SOLUTION} / Dashboards / Custom / [<folder> / …] / <title>`.

**Which ids are free.** Bundles and single files share one id namespace. The skill checks before it writes:

- Ids of system and module bundles (everything under `dashboards/system/` and `dashboards/modules/`, e.g. `home`, `_generic`, `dashboards`, `tests_overview`) are reserved — a custom bundle with such an id would be ignored, so the skill picks another one.
- A single file must not be named like an internal template under `rest-api/templates/queries/` — the server would ignore it.
- The id of a shipped content dashboard (rules, inventories, change dashboards) overrides it — only when you explicitly ask for it. The original then drops out of the overview, and yours carries the badge *overrides standard*.
- An existing custom dashboard with the same id is overwritten or the new one renamed — your choice.

The conversation runs through **three gates**, each an explicit question you answer before anything is written:

| Gate | After | You confirm |
|---|---|---|
| **G1** | the SQL preview (first rows, or "first 10 of N") | that this is the data you need |
| **G2** | the recommendation | build form and presentation |
| **G3** | the name proposal | id and title |

Between the gates the skill classifies the intent (a work list? counts per trait? a two-level drill-down? lenses with thresholds?), drafts the dataset SQL under the house rules (object identity is the pair `(UUID, File_Name)`, every column qualified with its table alias as soon as a query joins tables, parameters via `getvariable`, locale-independent step ids instead of step-name literals, a plausibility check when counts look round or inflated), recommends the form and — for a bundle — one of the interactive patterns (navigator, segmented overview with KPI tiles that filter the list, aggregate plus drill-down, lens, multi-facet, static), and proposes a lowercase ASCII id and an English title.

**Interactivity is not optional.** Object rows navigate to their object; meaningful partitions become clickable filter tiles or chips; any list that typically exceeds a few rows is searchable. G2 asks *how* to present, never *whether* rows are clickable.

## How to use it

```
/create-custom-dashboard
/create-custom-dashboard list of all scripts without a comment
/create-custom-dashboard scripts without comments with KPI tiles per trait
```

A topic in the invocation skips only the opening question, never the gates.

## What you get

**Single file**

```
rest-api/templates/dashboards-custom/[<folder>/]<id>.sql
  -- @template_type / @title / @description           required
  -- @object_types / @default_result / @click_action  recommended
  -- @params / @output_format / @tags / @version …
  SQL (paging frame for long lists)
```

The verification gate checks the header, loads the dashboard through `GET /api/dashboards/<id>` (derived manifest, breadcrumb), runs it through `/api/query?template=<id>` and the dashboard data endpoint once per filter parameter, and runs the file directly with DuckDB (`.read`) — the only check that also works without a server. The closing message names the place in the overview, the link `/dashboard/<id>` and the findings value, and offers to add the dashboard to an own test with [create-custom-test](Skill%20create-custom-test.md).

**Bundle**

```
rest-api/templates/dashboards-custom/[<folder>/]<id>/
├── manifest.json     # id, title, icon, declared params, permissions
├── layout.json       # 12-column grid, one card per content unit, stable node ids
├── data/*.sql        # one file per dataset (summary KPIs and detail list share their base CTE)
└── locales/*.json    # 10 languages, generated in one pass
```

The verification gate reloads the template cache, fetches the dashboard through the API, checks the server log for validation warnings, probes every dataset with its default parameters and once per filter parameter, cross-checks KPI and detail counts, and re-checks the interactivity duties. Only after that does the closing message list the files, the pattern, the filter parameters with an example URL, the place in the overview (`Dashboards / Custom / …`) and the verification status. A dashboard that the API rejects is not announced as done — the reason is read from the log and fixed.

## Good to know

- SQL, headers, manifest and layout are English; a bundle's translations live in its locale files, a single file stays English.
- When the rows point at objects, the dashboard declares their object types (`@object_types` or `analysis.objectTypes`) — that is what the object-type filter of the dashboard overview reads (see [Object types](../templates/Dashboard%20Datasets.md#object-types)).
- A single file grows into a bundle without rewriting the SQL: the file becomes the bundle's first dataset (see [From file to bundle and back](../templates/Single-file%20Dashboards.md#from-file-to-bundle-and-back)).
- The `:param` preprocessor of the API treats every `:word` sequence as a parameter placeholder — the SQL rules reference explains how to avoid it in string literals and casts.
- Unqualified column names in a join stop working when a later catalog schema adds the same column name to a second joined table ("Ambiguous reference to column name") — the skill qualifies every column, and the same rule applies to SQL written by hand.
- Dashboards with a declared default result can be bundled into [Analysis Tests](../Wiki/Analysis%20Tests.md) with [create-custom-test](Skill%20create-custom-test.md).
- The same skill scaffolds full **rule bundles** for static code analysis; see [SCA collection](../Wiki/Static%20Code%20Analysis.md#a-curated-growing-collection).

## See also

- [Single-file Dashboards](../templates/Single-file%20Dashboards.md) — the header keys, paging and chips of the one-file form
- [Dashboard Datasets](../templates/Dashboard%20Datasets.md) — anatomy of a bundle, the manifest and the parameter caveat
- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) — how dashboards and datasets are served
- [SQL Templates](../templates/SQL%20Templates.md) — the template machinery underneath
