---
name: create-custom-test
description: >-
  Interactively creates an own Analysis Test for fm-lab — a `test.json` that bundles existing
  dashboards (bundles and single-file dashboards with a default result) into one runnable check
  with test type, object types, scopes and outputs. Clarifies the goal, checks existing tests
  first, proposes member dashboards, validates the definition through the REST API (rules M1–M8),
  runs it once and writes it under `rest-api/templates/tests-custom/`. Triggers (English):
  "/create-custom-test", "create a test for X", "new analysis test", "bundle these checks into a
  test", "make a test from these dashboards". Triggers (German): "erstelle einen Test für X",
  "neuer Analyse-Test", "fasse diese Prüfungen zu einem Test zusammen", "mach einen Test aus diesen
  Dashboards". Also responds to equivalent requests in other languages.
metadata:
  version: "0.9.17"
---

# Create a custom Analysis Test

Guide the user interactively through the creation of an own **Analysis Test**:
a declared collection of dashboards with one default result per member,
runnable in the test overview (`/tests/<id>`), in the object tab **Tests** and
via `/fm-test <id>`. The result is one file,
`rest-api/templates/tests-custom/[<folder>/…]<id>/test.json`.

A test **references** dashboards — it contains no SQL. When a needed check
does not exist yet, it is built first with `/create-custom-dashboard`
(single-file form with `@default_result`), then added here.

## Reference files (read at the step that needs them)

| File | Content | Read before |
|---|---|---|
| `references/members.md` | what makes a dashboard test-capable, finding candidates (API and direct path), scope conventions, member ↔ test consistency | step 3 |
| `references/test-json.md` | `test.json` fields, vocabularies, profiles, locales, folders, overrides | step 5 |
| `references/validation.md` | verification gate T1–T5 (load, validation block M1–M8, run, overview), auto-heal, closing message | step 6 |

Background: `docs/agents/analysis-tests.md` (concept, storage, API).

## Directory split

| Directory | Content | Who writes? |
|---|---|---|
| `rest-api/templates/tests/` | shipped tests (`layout/`, `platform/`, `script/`, `solution/`) | core team only |
| `rest-api/templates/tests-custom/` | the user's own tests — gitignored, never touched by updates; listed under **Tests / Custom** | this skill, the user |
| `rest-api/templates/tests-community/` | installed community packages | — |

This skill writes **exclusively** to `tests-custom/` — directly
(`tests-custom/<id>/test.json`) or grouped (`tests-custom/<folder>/[<sub>/]<id>/test.json`,
up to four levels, optional `folder.json`). The breadcrumb reads
`{SOLUTION} / Tests / Custom / [<folder> / …] / <title>`. It never edits a
dashboard; member dashboards come from `/create-custom-dashboard`.

## Ground rules

- **Language**: dialogue in the user's input language. `test.json` texts
  (`title`, `description`, `keywords`, profile titles): English; translations
  go to the inline `locales` block (step 5).
- **Database**: read-only, `duckdb -readonly db/fm_catalog.duckdb -c "…"`
  (CLAUDE.md §2); with a session pin the literal bundle path. Never install
  DuckDB.
- **Vocabularies come from the server** (`GET /api/tests` → `meta`, single
  source `rest-api/src/services/tests-schemas.js`) — never invent a
  `testType`, scope or output value.
- **Members are dashboards**: `{ "kind": "dashboard", "ref": "<dashboard id>" }`
  for bundles and single-file dashboards alike. Never write `kind: "query"` —
  it is only accepted as a read alias of older files.

## The three gates (non-negotiable)

| Gate | After | Confirms |
|---|---|---|
| **G1** | step 2 | no existing test fits — build a new one (or extend/override) |
| **G2** | step 3 | the member list |
| **G3** | step 4 | id, title, test type, object types, scopes, folder |

**Every gate is an AskUserQuestion tool call** — never a prose question at the
end of a working turn, never answered by yourself. Without the tool (headless
run) ask as the **last line of your reply and end the turn**.

---

## Workflow

### Step 1 — Clarify the goal

Without a topic ask one short question (AskUserQuestion, "Other" for free
text): *"What should the test check?"* — with 2–3 examples from the catalog
domain (e.g. "script error handling", "layout hygiene of one module",
"documentation coverage of fields"). Silently note: object types concerned,
whether it should run on one object (object scope) or only on the whole
solution, and whether the members find defects or only inventory things.

### Step 2 — Check what exists

Existing tests first — a new test that duplicates a shipped one is noise:

```bash
curl -s "http://localhost:3003/api/tests?q=<keyword>" | python3 -c "import json,sys; [print(t['id'], '|', t['title'], '|', t['testType'], '|', t['objectTypes'], '|', t['memberCount']) for t in json.load(sys.stdin)['data']]"
curl -s "http://localhost:3003/api/tests?objectType=<Type>" | python3 -c "…same…"
```

Without a server: the discovery query of `.claude/skills/fm-test/references/direct-path.md` §1
(same as `/fm-test --find "<keyword>"`).

### Gate G1 — New or existing (AskUserQuestion)

Show the 1–5 closest tests (id, title, members). Options: **"Build a new test"
(Recommended when nothing fits)** · "Run `<closest test>` instead" (ends the
skill — hand over to `/fm-test <id>`) · "Copy `<closest test>` and adapt it"
(new id) · "Override `<shipped test>`" (same id in `tests-custom/`, only on
explicit request). With an exact fit, recommend running it instead.

### Step 3 — Choose members

**Read `references/members.md` now.** List the test-capable candidates for the
goal (object type, keywords, folder), each with id, title, form
(bundle/file), default result (`name`, `meaning`), supported scopes and — for
rules — severity. Mark what fits the goal; keep the list short (2–12 members
is the normal range).

When a needed check is missing: offer `/create-custom-dashboard` (single-file
form with `@default_result`, `_message` column and — for object scope — the
S-Block), then return here with the new id. Do not write SQL in this skill.

### Gate G2 — Confirm the members (AskUserQuestion, multiSelect)

Question: *"Which dashboards should the test contain?"* — one option per
candidate (label = title, description = default result + scopes), the
recommended ones marked "(Recommended)". With more than four candidates,
group them (e.g. "the 5 error-prone rules") or ask in two questions. Flag
before confirming: members without object-like scope support (the test
cannot run on one object), members of other object types.

### Step 4 — Propose the definition

From the confirmed members derive (references/test-json.md):

- **id**: lowercase, `a-z0-9-` (dashes, as the shipped tests), max 40 chars;
  must not collide with a shipped test unless G1 chose "override".
- **title** (English, ≤ 60 chars) and one-paragraph **description** (what is
  checked, what a finding means).
- **testType** from the vocabulary — `error-check` for defect rules,
  `code-quality`/`performance`/`security`/`platform` by topic, `inventory`
  for neutral inventories, `exploration` for mixed overviews.
- **objectTypes**: the types the test is about — each must be declared by at
  least one member (M3).
- **scopes**: the intersection the members support; `solution, file` when any
  member lacks the S-Block and the user does not want object runs to skip it.
- **outputs**: the union of the members' output types the test should promise
  (M4 warns otherwise) — usually `count` (+ `findings-table`).
- **keywords** (lowercase), optional **folder** in `tests-custom/`, optional
  **profiles** (named member subsets, e.g. `quick`).

### Gate G3 — Confirm the definition (AskUserQuestion)

Question: *"Create the test like this?"* — option **"`<id>` — <title> ·
<testType> · <objectTypes> · <scopes>" (Recommended)** with the folder in the
description · one alternative (e.g. different test type or narrower scopes) ·
"Other" for free-form changes.

### Write-gate (self-check — not a user question)

Do G1, G2 and G3 each have an explicit answer in this conversation? If not,
ask the missing gate **now**. Then check the id:

```bash
find rest-api/templates/tests rest-api/templates/tests-custom rest-api/templates/tests-community -path '*/<id>/test.json'
```

- hit in `tests/` → only allowed when G1 chose "override"; otherwise pick
  another id;
- hit in `tests-custom/` → ask: overwrite or rename;
- hit in `tests-community/` → rename (a community test is never overridden,
  the custom one would hide it).

### Step 5 — Write `test.json`

**Read `references/test-json.md` now.** Write
`rest-api/templates/tests-custom/[<folder>/…]<id>/test.json` — the directory
name equals `id`. Members in the confirmed order, `kind: "dashboard"`. Add a
`locales` block with `title` and `description` (and profile texts) for the
user's language when it is not English; offer all ten languages. When a new
folder is created, give it a `folder.json` (`title`, optional `order`,
`locales`).

### Step 6 — Verification gate (BLOCKING — never skip)

**Read `references/validation.md` and run T1–T5**: reload
(`POST /api/admin/reload` — test discovery has no time-based refresh),
`GET /api/tests/<id>` (loaded, `area: custom`, folder), the `validation`
block (errors M1/M2/M3/M6/M7 block the run; warnings M4/M5*/M8 are reported),
one run `GET /api/tests/<id>/run?include=findings&findingsLimit=5` (solution
scope, plus one object-scope run when the test declares `object`), and the
listing under **Tests / Custom**.

### Step 7 — Closing message

Template in `references/validation.md`: path, breadcrumb
`Tests / Custom / [<folder> / …] <title>`, link `/tests/<id>`, member table
with the run's values, validation status, how to run it (`/fm-test <id>`,
object tab **Tests**). Mention that the status column of the overview fills
after the first solution-scope run.

---

## Example run (compressed)

**User**: `/create-custom-test error handling in scripts`

1. Topic given → Script, defects + inventory, object scope wanted.
2. `GET /api/tests?q=error` → `script-error-checks` (15 members) is broader
   than wanted. **G1** → *Build a new test.*
3. Read members.md → candidates: `error_code_unknown_literal`,
   `error_code_web_only` (bundles, `finding_count`), `error_code_inventory`
   (single file, `error_code_comparisons`, inventory). **G2** → all three.
4. Definition: `script-error-handling` / "Script error handling" ·
   `error-check` · `Script` · all five scopes · `count, findings-table,
   inventory-table`. **G3** → *Yes.*
5. Write-gate ✓ → `tests-custom/script-error-handling/test.json` with a German
   `locales` block.
6. T1–T5: loaded, `validation.status: ok`, run 3/3 ran → closing message with
   `/tests/script-error-handling` and `/fm-test script-error-handling`.

## Triggers in other languages

The frontmatter `description` carries the English and German trigger phrases.
Equivalent phrases in further languages:

- **Spanish:** "crea una prueba para X", "nueva prueba de análisis", "agrupa estas comprobaciones en una prueba".
- **French:** "crée un test pour X", "nouveau test d'analyse", "regroupe ces contrôles dans un test".
- **Italian:** "crea un test per X", "nuovo test di analisi", "raggruppa questi controlli in un test".
- **Dutch:** "maak een test voor X", "nieuwe analysetest", "bundel deze controles in een test".
- **Portuguese:** "crie um teste para X", "novo teste de análise", "agrupe estas verificações num teste".
- **Swedish:** "skapa ett test för X", "nytt analystest", "samla dessa kontroller i ett test".
- **Japanese:** "Xのテストを作成して", "新しい分析テスト", "これらのチェックを1つのテストにまとめて".
- **Korean:** "X용 테스트 만들어 줘", "새 분석 테스트", "이 검사들을 하나의 테스트로 묶어 줘".
- **Chinese:** "为 X 创建一个测试", "新的分析测试", "把这些检查合并成一个测试".
