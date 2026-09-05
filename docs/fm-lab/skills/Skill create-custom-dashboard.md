# Skill: create-custom-dashboard

Builds a new custom dashboard bundle interactively — clarifies the goal, drafts and previews the SQL, recommends an interactive pattern, agrees on a name, generates the complete bundle under `rest-api/templates/dashboards-custom/<id>/` and verifies it against the running API before declaring success.

| | |
|---|---|
| **Category** | Extending FM-Lab |
| **Slash command** | `/create-custom-dashboard [<topic>]` |
| **Say it naturally** | "create a new dashboard for X", "new dashboard", "build a dashboard that shows X" — English and German |
| **Input** | what the dashboard should show, then your answers at three confirmation gates |
| **Reads** | `db/fm_catalog.duckdb` (read-only, preview queries), the existing bundle directories for id collisions, `logs/rest-api.log` during verification |
| **Writes** | `rest-api/templates/dashboards-custom/<id>/` — `manifest.json`, `layout.json`, `data/*.sql`, `locales/*.json` (10 languages) |
| **Prerequisites** | a converted catalog; the REST API running for the verification gate |
| **Under the hood** | five bundled references (SQL rules, patterns, primitives, localization, validation) read at the step that needs them; verification via `GET /api/dashboards/<id>` and dataset probes |
| **Skill directory** | `.claude/skills/create-custom-dashboard/` |
| **Related** | [Skill fm-test](Skill%20fm-test.md) · [Skill skill-creator](Skill%20skill-creator.md) |

## What it does

A dashboard bundle is the delivery form of every rule and analysis in the dashboard system ([Dashboard Datasets](../templates/Dashboard%20Datasets.md)); this skill produces one from a plain-language goal without you writing manifest, layout or locale files by hand. It writes exclusively to the custom directory — the system bundles under `rest-api/templates/dashboards/` stay untouched — and a custom bundle with the same id as a built-in one takes precedence.

The conversation runs through **three gates**, each an explicit question you answer before anything is written:

| Gate | After | You confirm |
|---|---|---|
| **G1** | the SQL preview (first rows, or "first 10 of N") | that this is the data you need |
| **G2** | the pattern recommendation | how it is presented |
| **G3** | the name proposal | id and title |

Between the gates the skill classifies the intent (a work list? counts per trait? a two-level drill-down? lenses with thresholds?), drafts the dataset SQL under the house rules (object identity is the pair `(UUID, File_Name)`, parameters via `getvariable`, locale-independent step ids instead of step-name literals, a plausibility check when counts look round or inflated), recommends one of the interactive patterns — navigator, segmented overview with KPI tiles that filter the list, aggregate plus drill-down, lens, multi-facet, static — and proposes a lowercase ASCII id and an English title.

**Interactivity is not optional.** Object rows navigate to their object; meaningful partitions become clickable filter tiles or chips; any list that typically exceeds a few rows is searchable. G2 asks *how* to present, never *whether* rows are clickable.

## How to use it

```
/create-custom-dashboard
/create-custom-dashboard scripts without comments
/create-custom-dashboard variable analysis
```

A topic in the invocation skips only the opening question, never the gates.

## What you get

```
rest-api/templates/dashboards-custom/<id>/
├── manifest.json     # id, title, icon, declared params, permissions
├── layout.json       # 12-column grid, one card per content unit, stable node ids
├── data/*.sql        # one file per dataset (summary KPIs and detail list share their base CTE)
└── locales/*.json    # 10 languages, generated in one pass
```

The **verification gate** then reloads the template cache, fetches the dashboard through the API, checks the server log for validation warnings, probes every dataset with its default parameters and once per filter parameter, cross-checks KPI and detail counts, and re-checks the interactivity duties. Only after that does the closing message list the files, the pattern, the filter parameters with an example URL and the verification status. A bundle that the API rejects is not announced as done — the reason is read from the log and fixed.

## Good to know

- The bundle's SQL, manifest and layout are English; translations live in the locale files.
- The `:param` preprocessor of the API treats every `:word` sequence as a parameter placeholder — the SQL rules reference explains how to avoid it in string literals and casts.
- Rule dashboards created this way can be promoted into [Analysis Tests](../Wiki/Analysis%20Tests.md) by referencing them from a `test.json`.
- The same skill scaffolds full **rule bundles** for static code analysis; see [SCA collection](../Wiki/Static%20Code%20Analysis.md#a-curated-growing-collection).

## See also

- [Dashboard Datasets](../templates/Dashboard%20Datasets.md) — anatomy of a bundle, the manifest and the parameter caveat
- [Custom Query Templates](../templates/Custom%20Query%20Templates.md) — the lighter one-file alternative
- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) — how dashboards and datasets are served
- [SQL Templates](../templates/SQL%20Templates.md) — the template machinery underneath
