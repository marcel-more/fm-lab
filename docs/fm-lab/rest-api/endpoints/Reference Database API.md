# Reference Database API

Endpoints under `/api/reference/*` expose the **[fm-spec](../../Wiki/fm-spec.md) reference database** (script steps, calculation functions, categories, XML grammar) and the local **Claris Help mirror**. Unlike the catalog endpoints, they do not read the imported solution — they describe FileMaker itself.

Two data sources back this group:

- `reference/fm_spec.duckdb` — structured step/function/category/grammar data. If it is not installed, data routes fail with `503 REF_NOT_ATTACHED`.
- Claris Help mirror (`docs/claris-help/`, installed via the `install-claris-docs` skill) — rendered help HTML. Routes that serve HTML fall back to the mirror's fallback language (default `en`) and report the actual source in the `X-Help-Source` response header.

**Languages.** Steps are localized in 11 languages (`en, de, es, fr, it, nl, pt, sv, ja, ko, zh-Hans`), functions in 10 (no `zh-Hans`; for `en` the canonical name doubles as display name). `lang` resolution is forgiving: `en-US` → `en`, unknown languages soft-fall back to `en` — no error. The mirror directory for `zh-Hans` is `zh`.

All routes are `GET`. Errors follow [Error responses](../REST%20API%20Conventions.md#error-responses); 404s for unknown steps/functions include up to five `data.suggestions` (nearest names).

---

## GET /api/reference/meta

Summary block for the reference database: schema version, FileMaker coverage, entity counts, per-locale coverage matrix, and whether XML grammar data is available.

```json
{
  "success": true,
  "data": {
    "referenceMeta": { "schema_version": "2.3.0", "filemaker_coverage": "22", "shape_coverages": "22,26", "doc_coverage": "26", "built_at": "…", "source_commit": "…" },
    "coverages": [ { "coverage": "22", "pairedVersion": "22.0.6", "saxmlVersion": "2.2.3.0", "isBase": true }, { "coverage": "26", "pairedVersion": "26.0.2", "saxmlVersion": "2.3.0.0", "isBase": false } ],
    "counts": { "scriptSteps": 216, "functions": 375, "stepLocales": 11, "functionLocales": 10, "grammarSteps": 216 },
    "locales": [ { "code": "de", "steps": 206, "functions": 367, "stepParameters": 690 } ],
    "grammarAvailable": true
  }
}
```

`coverages[]` lists the shape coverages of the build, base first ([coverages](../../schema/fm-spec-tables/coverages.md), fm-spec ≥ 2.0.0; empty on older builds). Older reference builds without grammar tables degrade gracefully (`grammarAvailable: false`). The same tolerance applies inside the grammar payload: blocks added by newer fm-spec schema versions simply come back empty/`null` on older builds (see the grammar endpoint below).

## GET /api/reference/categories

Script-step **and** function categories for one language in a single call.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lang` | string | `en` | Language for category names |

Response: `data.scriptSteps[]` and `data.functions[]`, each `{ id, slug, name, url }`. When `lang` is not a valid function language, functions fall back to the default; `meta.functionLang` reports the language actually used.

## GET /api/reference/trigger-events

Localized display labels of the script-trigger events, as FileMaker's trigger dialogs write them.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lang` | string | `en` | Label language |

Response: `data` = `{ "lang": "de", "labels": { "OnObjectEnter": "BeiObjektBetreten", … } }` — a map from canonical event name to localized label, backed by the [script_triggers_lang](../../schema/fm-spec-tables/script_triggers_lang.md) reference table. Graceful degradation: a reference database without the trigger tables yields an empty `labels` object (no `503`), and clients fall back to the canonical event names.

## GET /api/reference/lookup

Universal reverse lookup: resolve a raw code token (step name, function name, or `Get(…)` parameter) to matching reference entries.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `token` | string | — | **Required.** The token to resolve |
| `lang` | string | `en` | Language for display fields |
| `all` | boolean | `false` | Return all matches instead of primary matches only |

Response: `data.matches[]`, each either `kind: "script_step"` (`stepId`, `canonical`, `displayName`, `helpUrl`, `localHelpUrl`, …) or `kind: "function"` (`functionId`, `canonical`, `subParameter` for Get parameters, `signature`, `purpose`, …).

## GET /api/reference/steps

Complete script-step list for one language, including categories, aliases and build metadata.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lang` | string | `en` | Step display language |

Response: `data.meta` (language, count, sourceVersion), `data.categories[]`, `data.steps[]` with `stepId`, `name` (canonical), `xmlName`, `displayName`, `description`, `hasGrammar`, `aliases[]`, `compat`, `helpUrl`, `localHelpUrl`. `compat` carries the seven [step_compat](../../schema/fm-spec-tables/step_compat.md) platform flags as a tri-state object (`true` = yes, `false` = no, `null` = **Partial**, i.e. conditionally supported — never "undocumented"); the field is `null` on reference builds without the table.

## GET /api/reference/steps/:idOrSlug

Detail view of a single step. `idOrSlug` accepts the numeric `step_id`, the URL slug, or the canonical name.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lang` | string | `en` | Display language |
| `content` | enum | `meta` | `meta` (DB only) · `summary` (adds help lookup) · `full` (adds `embedHtml` fragment) |

Response includes localized name/description, `parameters[]` (`index`, `name`, `description`), category, `compat` (same tri-state platform object as in the list route), `osAffinity[]` — the curated [step_os_affinity](../../schema/fm-spec-tables/step_os_affinity.md) entries (`os`, `affinity`, `provenance`, `note`; empty on reference builds older than fm-spec schema 1.13.0) — help URLs and `docsEntry`. `docsEntry` is the step's page in the docs browser (`{ set: "claris-help", category: "ss:<categoryId>", entry: "ss:<stepId>" }`, i.e. `/docs/claris-help/ss:4/ss:160`); it is `null` unless the [Doc Set claris-help](../../docsets/Doc%20Set%20claris-help.md) is installed **and** the help mirror holds the page in at least one language, so a client can render the cross-link only when the target exists. `meta.source` reports where content came from (`db`, `html-cache:<lang>`, `html-cache:fallback:<lang>`, `db-only`).

Errors: `404 REF_STEP_NOT_FOUND` (with suggestions), `400 VALIDATION_ERROR` for an invalid `content` value.

## GET /api/reference/steps/:idOrSlug/langs

All localized variants of one step across every available language, each with its localized parameter list, plus the language-neutral `compat` object, `osAffinity[]` and `docsEntry` (see the detail route). No `lang` parameter — always returns everything.

## GET /api/reference/steps/:idOrSlug/grammar

XML grammar for snippet generation: snippet template, SaXML example, element order, options with allowed values, and constraints. Newer reference builds add further grammar blocks — `repeatGroups[]` (fm-spec ≥ 1.15.0), `skeletonElements[]`, `elementBindings[]`, `optionImplications[]` and per-constraint consumer notes (≥ 1.17.0), `mirrorElements[]` and the `pasteDropped` flag on option rows (≥ 2.6.0); on older builds these degrade to empty arrays / `null` / `false` instead of erroring. Details of the underlying tables: [step_repeat_groups](../../schema/fm-spec-tables/step_repeat_groups.md), [step_skeleton_elements](../../schema/fm-spec-tables/step_skeleton_elements.md), [step_option_element_bindings](../../schema/fm-spec-tables/step_option_element_bindings.md), [step_option_implications](../../schema/fm-spec-tables/step_option_implications.md), [step_mirror_elements](../../schema/fm-spec-tables/step_mirror_elements.md), [constraint_kinds](../../schema/fm-spec-tables/constraint_kinds.md).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `coverage` | string | base coverage | Shape coverage to resolve the grammar for (fm-spec ≥ 2.0.0, e.g. `26`). Must be one of the build's coverages; an unknown value is `400 REF_COVERAGE_INVALID` with `details.known[]`. Ignored (and refused when given) on builds without shape coverages. |

The grammar is **resolved** for one coverage ([Coverage resolution](../../schema/Coverage%20resolution.md)): rows of the requested coverage replace the standard rows of the same key, everything else is the standard shape. `data.coverage` and `meta.coverage` name the resolved coverage, `coverageSource` how it was chosen (`query`, `base`, or `none` on an unversioned build), `coverages[]` the build's coverages and `overrideCoverages[]` the coverages that carry override rows for this step. Every row of `xmlMap`, `options[]` (and their `values[]`), `repeatGroups[]`, `skeletonElements[]` and `elementBindings[]` carries `coverage` — `"*"` for a standard row, the coverage for an override.

Option rows also carry `slotKind` (value form of a target slot: `field_only`, `field_or_var`, `variable_only`; fm-spec ≥ 2.2.0, `null` when not curated per option) and `xmlTrue`/`xmlFalse` (the XML spellings of a boolean attribute when they are not `True`/`False`; `null` otherwise); `xmlMap.targetSlotKind` is the step-level classification.

A valid step **without** grammar data returns `200` with `data: null` and `meta.grammarAvailable: false` — not a 404. Language-neutral.

## GET /api/reference/steps/:idOrSlug/embed

Embeddable HTML fragment of the step's help page (body only, links and assets rewritten, no page chrome). Returns `text/html`; source is reported via `X-Help-Source`. `404 REF_HELP_NOT_FOUND` when the step exists but no mirror HTML is available in the requested or fallback language.

## GET /api/reference/functions

Complete function list for one language.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lang` | string | `en` | Function display language |

Response: `data.functions[]` with `functionId`, `name` (canonical), `opcode`, `returnType`, `originVersion`, `removedInVersion` (first FileMaker version that no longer resolves the function — [functions](../../schema/fm-spec-tables/functions.md) `removed_in_version`, fm-spec ≥ 2.2.0; `null` otherwise), `isGetFunction`, `displayName`, `signature`, `purpose`, `platformAffinity[]`, category and help URLs. `platformAffinity` lists the curated [function_platform_affinity](../../schema/fm-spec-tables/function_platform_affinity.md) entries (`platform`, `affinity`) — platform *binding*, not compatibility; empty for most functions and on reference builds without the table.

## GET /api/reference/functions/:nameOrId

Detail view of a single function. `nameOrId` accepts the numeric `function_id`, the canonical name, or the URL slug. Same `lang`/`content` semantics as the step detail route; response additionally includes `notes`, `example1`, `parameters[]` with `optional`/`variadic` flags, `platformAffinity[]` (here with `provenance` and the evidence `note` per entry) and `osAffinity[]` — the curated [function_os_affinity](../../schema/fm-spec-tables/function_os_affinity.md) entries (`os`, `affinity`, `provenance`, `note`; `os` is `null` on `os_probe` rows). `osAffinity` is empty for most functions and on reference builds older than fm-spec schema 1.13.0. `docsEntry` names the function's docs-browser page (`fn:<categoryId>` / `fn:<functionId>`) under the same existence rule as for steps. Errors: `404 REF_FUNCTION_NOT_FOUND` (with suggestions).

## GET /api/reference/functions/:nameOrId/embed

Embeddable help HTML fragment for one function — same behavior as the step embed route.

## Help mirror routes

### GET /api/reference/help/status

Inventory of the local Claris Help mirror: available languages with page/asset counts and fetch timestamps. Never fails — reports `available: false` when no mirror is installed.

### GET /api/reference/help/:lang/:slug

A single Claris Help page as a fully rendered standalone HTML document (theme toggle and language switcher injected, navigation stripped, links rewritten to stay inside the API). Falls back to the mirror's fallback language; `404 REF_HELP_NOT_FOUND` when the page exists in neither. Cached client-side for 24 h.

### GET /api/reference/_static/:lang/*

Static mirror assets (images, stylesheets) referenced by the rewritten help HTML. Served with a 7-day cache header. Not meant to be called directly.

---

See also: [Codegen API](Codegen%20API.md) (uses the same reference database for emission), [REST API Output Formats](../REST%20API%20Output%20Formats.md).
