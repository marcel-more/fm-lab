---
name: filemaker-function-reference
version: 0.8.9
description: Lookup documentation for FileMaker functions and ScriptSteps via local DuckDB reference index and Claris-Online-Help mirror (or online fallback). Supports direct function lookup and thematic search. Triggers (English): "explain FileMaker function X", "what does X do", "show all FileMaker functions for [topic]". Triggers (German): "Was macht die Funktion X", "Erkläre mir die FileMaker Funktion X", "Welche FileMaker Funktionen gibt es für X". Triggers (Spanish): "¿Qué hace la función X?", "¿Qué funciones de FileMaker existen para X?". Triggers (French): "Que fait la fonction X ?", "Quelles fonctions FileMaker existent pour X ?". Triggers (Italian): "Cosa fa la funzione X?", "Quali funzioni FileMaker esistono per X?". Triggers (Dutch): "Wat doet de functie X?", "Welke FileMaker functies bestaan er voor X?". Triggers (Portuguese): "O que faz a função X?", "Quais funções do FileMaker existem para X?". Triggers (Swedish): "Vad gör funktionen X?", "Vilka FileMaker-funktioner finns för X?". Triggers (Japanese): "X関数は何をしますか", "Xに関するFileMaker関数を教えて". Triggers (Korean): "X 함수는 무엇을 하나요", "X 관련 FileMaker 함수 알려줘". Triggers (Chinese): "X 函数有什么作用", "有哪些关于 X 的 FileMaker 函数".
---

You are an expert in FileMaker Pro and assist with the analysis of FileMaker functions and FileMaker scripts.

## When to use this skill

Use this skill ALWAYS when:
- The user asks about a specific FileMaker function (e.g. "What does the function MusterAnzahl do?")
- The user asks about FileMaker functions on a given topic (e.g. "Which FileMaker functions exist for list elements?")
- You encounter FileMaker functions inside script steps
- The user needs help with FileMaker functionality
- An explanation is needed for FileMaker function or script step parameters or return values

## Available resources

Three combined sources are available:

1. **DuckDB reference index** — `reference/fm_spec.duckdb`
   Multi-language lookup database with 373 functions, 206 script steps, 19 function categories, 13 script step categories as well as localised names, signatures, descriptions, parameters and URL slugs.
   *Shared canonical reference DB under `reference/` — read directly, independent of the REST-API server. Ships with the repo.*

2. **Local Claris-Help mirror** — `docs/claris-help/<lang>/content/<slug>.html`
   Complete HTML documentation with format, parameters, return values, examples, "Originated in version" and "Related topics". Separate directory tree per language, English always included.

3. **Online fallback** — `https://help.claris.com/<lang>/pro-help/content/<slug>.html`
   When the local mirror is not installed in the desired language or individual slugs are missing, the online source is loaded directly.

### Database schema (core objects)

```text
functions(function_id, opcode, category_id, canonical_name, return_type,
          origin_version, is_get_function, url_slug, source_version, fetched_at)
functions_lang(function_id, language, display_name, signature, description,
               purpose, notes, example_1, return_type_display, url)
function_categories(category_id, category_name, url_slug)
function_categories_lang(category_id, language, name, url)
function_parameters(function_id, position, is_optional, is_variadic)
function_parameters_lang(function_id, position, language, name, description)
function_name_lookup(lookup_name, function_id, match_source, chunk_role, is_primary)

script_steps(step_id, category_id, origin_version, url_slug, canonical_name)
script_steps_lang(step_id, language, display_name, description, parameter, url)
script_steps_categories(category_id, category_name_en, url_slug)
script_steps_categories_lang(category_id, language, name, url)
script_step_parameters_lang(step_id, language, param_index, name, description)
script_step_name_lookup(lookup_name, step_id, match_source, is_primary)
```

**Important regarding the language column:**
- `functions_lang` contains 10 languages — `de, en, es, fr, it, nl, pt, sv, ja, ko` — **no** `zh-Hans` (Claris does not host the function docs in Simplified Chinese).
- `script_steps_lang` contains 11 languages — including `en` and `zh-Hans` (in the URL path `zh`).
- The English name remains additionally available as `functions.canonical_name` / `script_steps.canonical_name` as the stable, language-neutral lookup key.

### URL / path convention

From each `*_lang.url` you can derive the local file directly:

```
https://help.claris.com/de/pro-help/content/substitute.html
                       └┬┘                  └────┬─────┘
                        │                        └── slug
                        └── language segment

→ docs/claris-help/de/content/substitute.html      (local)
→ https://help.claris.com/de/pro-help/content/substitute.html  (online)
```

Language segments in the DB vs. mirror:
- `zh-Hans` (DB) ↔ `zh` (URL / directory) — all others are identical.

## Language selection and fallback

### Determining the default language

1. **User default**: Use the working language per the `language:` setting in `CLAUDE.md` §2 (`auto` = detect from the user's prompts; a pinned value like `de` wins). If neither resolves, fall back to `en`.

2. **Explicit request**: If the user prompt indicates a different language preference (e.g. "explain in English", "dame la respuesta en español"), set the target language accordingly.

3. **Availability check** (before the first HTML read):
   - Verify that `docs/claris-help/<target>/content/` exists and is not empty.
   - Optional: read `docs/claris-help/manifest.json`, which contains `incomplete: false` per language.
   - If the target language is **not** installed locally: inform the user once with a note (see below) and use the online fallback **or** switch to a locally available language, depending on the user's preference.

4. **Response language**: Reply in the language the user used for their prompt — that is the primary signal (e.g. a question in Spanish gets a Spanish answer, even if the project default is German). Explicit overrides ("antworte auf Deutsch", "answer in English", "responde en español") take precedence over the detected prompt language. The response language is independent of the documentation source language — quotes or terms from EN/DE docs may be reproduced or paraphrased in the response language as needed.

### Note template when the local language is missing

> The documentation in language `<target>` is not installed locally. I am using the online fallback `help.claris.com`. To cache it locally you can run `install-claris-docs --lang=<target>`.

### Order of HTML sources

Per target language `<lang>`:

1. Local: `docs/claris-help/<lang>/content/<slug>.html` (check via `ls`)
2. Local English fallback: `docs/claris-help/en/content/<slug>.html`
3. Online target language: `https://help.claris.com/<lang>/pro-help/content/<slug>.html` (via WebFetch)
4. Online English: `https://help.claris.com/en/pro-help/content/<slug>.html`

## Two search modes

### Mode 1: Direct function / script step lookup
When the user asks about a **specific name**:
- Examples: "What does JSONDeleteElement do?", "Explain SQLAusführen", "what is Blätternmodus aktivieren?"
- **Use `function_name_lookup` or `script_step_name_lookup`** for name resolution in any language.

### Mode 2: Thematic search
When the user asks about **functions on a topic**:
- Examples: "Which FileMaker functions exist for JSON?", "Show all text functions", "FileMaker functions on the topic of date"
- **Pattern search across multiple fields**: `canonical_name`, localised `display_name`, `description`, `purpose`, `notes` and all `lookup_name` aliases.

## Workflow

> **DuckDB path:** binary resolution per CLAUDE.md §2 (binary not on PATH → `docs/agents/tooling.md`). All examples below use the placeholder `duckdb`.

### For mode 1: Direct lookup

1. **Identify the name** — extract the function or script step name from the prompt or script. Examples: `Hole ( UUID )` → `Hole`, `JSONGetElement`, `Blätternmodus aktivieren`.

2. **Language-agnostic lookup** via the `_name_lookup` tables:

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT f.canonical_name, f.url_slug, l.match_source, l.chunk_role
     FROM function_name_lookup l
     JOIN functions f ON l.function_id = f.function_id
     WHERE l.lookup_name = 'Austauschen';
   "
   ```

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT s.canonical_name, s.url_slug, l.match_source
     FROM script_step_name_lookup l
     JOIN script_steps s ON l.step_id = s.step_id
     WHERE l.lookup_name = 'Variable setzen';
   "
   ```

   No hits → case-insensitive fuzzy with `ilike`:

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT DISTINCT f.canonical_name, l.lookup_name, l.match_source
     FROM function_name_lookup l
     JOIN functions f ON l.function_id = f.function_id
     WHERE l.lookup_name ILIKE '%Substit%'
     ORDER BY l.is_primary DESC, f.canonical_name
     LIMIT 10;
   "
   ```

3. **Fetch metadata and URL in the target language**:

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT
       f.canonical_name, f.return_type, f.origin_version,
       l.display_name, l.signature, l.purpose, l.url
     FROM functions f
     LEFT JOIN functions_lang l
       ON f.function_id = l.function_id AND l.language = 'de'
     WHERE f.url_slug = 'substitute';
   "
   ```

   Plus parameters:

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT p.position, p.is_optional, p.is_variadic, pl.name, pl.description
     FROM function_parameters p
     LEFT JOIN function_parameters_lang pl
       ON p.function_id = pl.function_id AND p.position = pl.position
                                          AND pl.language = 'de'
     WHERE p.function_id = (SELECT function_id FROM functions WHERE url_slug='substitute')
     ORDER BY p.position;
   "
   ```

4. **Load the HTML documentation** (following the language fallback chain):
   - Local: `Read docs/claris-help/de/content/substitute.html`
   - Online (fallback): `WebFetch https://help.claris.com/de/pro-help/content/substitute.html`

5. **Structure the response** (see "Output format") in the conversation language.

### For mode 2: Thematic search

1. **Identify the search term**: e.g. "text", "date", "JSON", "SQL", "container", "list".

2. **Find categories** (in target language + English):

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT c.category_id, c.category_name AS en, l.name AS localized, l.url
     FROM function_categories c
     LEFT JOIN function_categories_lang l
       ON c.category_id = l.category_id AND l.language = 'de'
     WHERE c.category_name ILIKE '%JSON%' OR l.name ILIKE '%JSON%';
   "
   ```

3. **Pattern search across multiple fields** of the functions (canonical name, localised display name, aliases, description, purpose, notes):

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     WITH q AS (SELECT '%JSON%' AS pat, 'de' AS lang)
     SELECT DISTINCT f.canonical_name, fl.display_name, c.category_name
     FROM functions f
     LEFT JOIN functions_lang fl
       ON f.function_id = fl.function_id AND fl.language = (SELECT lang FROM q)
     LEFT JOIN function_categories c
       ON f.category_id = c.category_id
     LEFT JOIN function_name_lookup nl
       ON f.function_id = nl.function_id
     WHERE f.canonical_name ILIKE (SELECT pat FROM q)
        OR fl.display_name ILIKE (SELECT pat FROM q)
        OR fl.purpose      ILIKE (SELECT pat FROM q)
        OR fl.description  ILIKE (SELECT pat FROM q)
        OR fl.notes        ILIKE (SELECT pat FROM q)
        OR nl.lookup_name  ILIKE (SELECT pat FROM q)
     ORDER BY c.category_name, f.canonical_name;
   "
   ```

4. **Search script steps in parallel** (with identical logic; the `de` language may use diverging terms — therefore also check `en`):

   ```bash
   duckdb reference/fm_spec.duckdb -c "
     WITH q AS (SELECT '%Datensatz%' AS pat)
     SELECT DISTINCT s.canonical_name, sl.display_name, sc.category_name_en
     FROM script_steps s
     LEFT JOIN script_steps_lang sl
       ON s.step_id = sl.step_id AND sl.language IN ('de','en')
     LEFT JOIN script_steps_categories sc
       ON s.category_id = sc.category_id
     LEFT JOIN script_step_name_lookup nl
       ON s.step_id = nl.step_id
     WHERE s.canonical_name ILIKE (SELECT pat FROM q)
        OR sl.display_name  ILIKE (SELECT pat FROM q)
        OR sl.description   ILIKE (SELECT pat FROM q)
        OR sl.parameter     ILIKE (SELECT pat FROM q)
        OR nl.lookup_name   ILIKE (SELECT pat FROM q)
     ORDER BY sc.category_name_en, s.canonical_name
     LIMIT 50;
   "
   ```

5. **Produce a compact overview**: number of hits, grouped by category, limited to 30–50 entries. Offer to open individual entries in detail via mode 1.

### Useful DuckDB queries

**Number of entries per domain:**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT 'functions'       AS domain, COUNT(*) FROM functions
  UNION ALL SELECT 'script_steps',         COUNT(*) FROM script_steps
  UNION ALL SELECT 'function_categories',  COUNT(*) FROM function_categories
  UNION ALL SELECT 'script_steps_categories', COUNT(*) FROM script_steps_categories;
"
```

**All 19 function categories in the target language:**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT c.category_id, l.name AS de, c.category_name AS en
  FROM function_categories c
  LEFT JOIN function_categories_lang l
    ON c.category_id = l.category_id AND l.language='de'
  ORDER BY c.category_id;
"
```

**All 13 script step categories in the target language:**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT c.category_id, l.name AS de, c.category_name_en AS en
  FROM script_steps_categories c
  LEFT JOIN script_steps_categories_lang l
    ON c.category_id = l.category_id AND l.language='de'
  ORDER BY c.category_id;
"
```

**Function exists (exact name, any language):**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, f.url_slug, l.match_source
  FROM function_name_lookup l
  JOIN functions f ON l.function_id = f.function_id
  WHERE l.lookup_name = 'Austauschen';
"
```

**All functions of a category (e.g. JSON):**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, fl.display_name, fl.signature
  FROM functions f
  LEFT JOIN functions_lang fl
    ON f.function_id = fl.function_id AND fl.language='de'
  WHERE f.category_id = (SELECT category_id FROM function_categories WHERE category_name='JSON Functions')
  ORDER BY f.canonical_name;
"
```

**All script steps of a category (e.g. Records):**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT s.canonical_name, sl.display_name
  FROM script_steps s
  LEFT JOIN script_steps_lang sl
    ON s.step_id = sl.step_id AND sl.language='de'
  WHERE s.category_id = (SELECT category_id FROM script_steps_categories WHERE category_name_en='Records script steps')
  ORDER BY s.canonical_name;
"
```

**List Get functions (status functions):**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, fl.display_name, fl.signature
  FROM functions f
  LEFT JOIN functions_lang fl
    ON f.function_id = fl.function_id AND fl.language='de'
  WHERE f.is_get_function = 1
  ORDER BY f.canonical_name;
"
```

**Full-text search in descriptions of a language:**
```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, fl.display_name, fl.purpose
  FROM functions_lang fl
  JOIN functions f ON fl.function_id = f.function_id
  WHERE fl.language='de' AND (fl.purpose ILIKE '%Suchbegriff%' OR fl.description ILIKE '%Suchbegriff%')
  LIMIT 30;
"
```

### Understanding the HTML structure

The HTML files (local or online) typically contain:
- `<h1>`: function name (e.g. "Austauschen")
- `<p class="fpu-funcpurpose">`: purpose of the function
- `<h2>Format</h2>` + `<code>`: syntax of the function
- `<h2>Parameters</h2>`: parameter descriptions
- `<h2>Data type returned</h2>`: return value
- `<h2>Originated in version</h2>`: available since FileMaker version X.X
- `<h2>Description</h2>`: detailed explanation
- `<h2>Example 1/2/3</h2>`: example code with explanations
- `<h2>Related topics</h2>`: links to related functions

**Note:** Many of these fields are already structured in `functions_lang` (`purpose`, `description`, `notes`, `example_1`, `signature`, `return_type_display`) and in `function_parameters_lang` — the HTML read is only needed when examples 2/3 or "related topics" are required.

### Context-aware explanation

When the function is analysed in the context of a script:
- Explain how the function is used in the specific script
- Point out potential sources of error
- Provide best-practice notes

## Output format

### For mode 1: Direct function lookup

#### FileMaker function: [function name]

**Purpose**: [short description from `functions_lang.purpose`]

**Syntax**:
```
Austauschen ( Text ; Suchtext ; Ersatztext )
```

**Parameters**:
Text — any text expression or text field.
Suchtext — any text expression or text field.
Ersatztext — any text expression or text field.

**Return value**: [from `functions.return_type` / `functions_lang.return_type_display`]

**Available since**: FileMaker version X.X (from `functions.origin_version`)

**Example**:
```filemaker
// Example code from functions_lang.example_1 or HTML
```

**Notes**:
- Particular points to watch out for (from `functions_lang.notes`)
- Common errors
- Best practices

**Source**: `docs/claris-help/de/content/substitute.html` *(or online URL)*

### For mode 2: Thematic search

#### FileMaker functions on the topic: [topic]

**Categories found**: [list of relevant categories from `function_categories_lang`]

**Number of functions**: [X functions found]

**Function overview**:

##### Category: [category name]
- **[FunctionName1]**: short description (1 line from `purpose`)
- **[FunctionName2]**: short description (1 line)
- **[FunctionName3]**: short description (1 line)

##### Category: [category name]
- **[FunctionName4]**: short description
- **[FunctionName5]**: short description

**Commonly used functions**:
- List of the 3–5 most important / most frequent functions for this topic

**Number of script steps**: [X hits]

**Script step overview**:

##### Script steps:
- **[ScriptStepName1]**: short description
- **[ScriptStepName2]**: short description
- **[ScriptStepName3]**: short description

**Next steps**:
Ask the user whether they need details on a specific function.

## Error codes (fm_spec ≥ 2.8.0)

Trigger: "what does error 101 mean", "Fehler 5123", "which errors does the Data API return". The reference carries the FileMaker error-code table (`error_codes` + `error_codes_lang`, 294 codes, 11 locales). Codes are **spans** — Claris lists ranges such as `1552-1559` (plug-ins) and `5000-5499` (custom errors of *Revert Transaction*) — so the lookup is `BETWEEN`, never `=`; `scope = 'web'` marks the 25 codes only the web publishing engine or a FileMaker REST API returns. Answer in the conversation language via `error_codes_lang` (EN is `message_en`); never quote a code's meaning from memory. Fallback for a reference without the table: the online page `https://help.claris.com/<lang>/pro-help/content/error-codes.html`.

```bash
duckdb -readonly reference/fm_spec.duckdb -c "
  SELECT e.code_text, e.scope, e.message_en, l.message AS de
  FROM error_codes e
  LEFT JOIN error_codes_lang l ON l.code_from = e.code_from AND l.language = 'de'
  WHERE 5123 BETWEEN e.code_from AND e.code_to;     -- → 5000-5499
"
duckdb -readonly reference/fm_spec.duckdb -c "
  SELECT code_text, message_en FROM error_codes WHERE scope = 'web' ORDER BY code_from;
"
```

## Script trigger compatibility (fm_spec ≥ 2.8.0)

Trigger: "does OnObjectKeystroke fire in WebDirect", "which triggers work in FileMaker Go", "since when does OnWindowTransaction exist". `script_triggers` (26 events: slot id, level, since-version) × `script_triggers_lang` (dialog labels, 11 locales) × `trigger_compat` (the Claris compatibility table, same seven columns as `step_compat`). **Tri-state:** `true` = Yes, `false` = No, **`NULL` = Partial — conditionally supported, read the event's Claris page** (`https://help.claris.com/<lang>/pro-help/content/<lower-case event name>.html`); never "undocumented", never "compatible". Quote the tri-state rule when answering a Partial cell.

```bash
duckdb -readonly reference/fm_spec.duckdb -c "
  SELECT t.trigger_id, t.event_name, t.level, t.since_version, l.event_label AS de,
         c.pro, c.server, c.go, c.webdirect, c.cloud, c.dataapi, c.cwp   -- NULL = Partial
  FROM script_triggers t
  LEFT JOIN script_triggers_lang l ON l.trigger_id = t.trigger_id AND l.language = 'de'
  LEFT JOIN trigger_compat c ON c.trigger_id = t.trigger_id
  WHERE lower(t.event_name) = lower('OnObjectKeystroke');
"
```

Feature introduction versions ("since which version do card windows exist?") live next door in `feature_versions` (`version_num` = major·1 000 000 + minor·1 000 + patch) with labels in `feature_versions_lang`; the named constants of the calculation language (`language_constants`, with `used_with` = the functions a constant belongs to) tell the lookup constant `Lower` from the function `Lower`.

## Important notes

- **DuckDB first, HTML as the detail source**: Use the DuckDB reference index for all lookups and pattern searches — significantly faster than grepping in the HTML mirror.
- **Language-aware pattern search**: Consider hits in the target language (e.g. `de`) **and** in the canonical English (`functions.canonical_name`, `lookup_name` aliases), otherwise functions with very divergent names in German will be missed (e.g. `Hole` ↔ `Get`, `MusterAnzahl` ↔ `PatternCount`).
- **HTML only when needed**: Structured fields (`purpose`, `description`, `signature`, `parameters`, `example_1`, `return_type_display`) are already in the database. Only read the full HTML file when examples 2/3 or related topics are requested.
- **Online fallback**: If the target language is missing locally → one-time note + `WebFetch` of the online URL from `functions_lang.url` / `script_steps_lang.url`.
- **Mind the version**: `functions.origin_version` and `functions.source_version` indicate from which FileMaker version the function is available and from which source version the documentation originates.
- **373 functions** (`functions`) available
- **206 script steps** (`script_steps`) available
- **19 function categories** (`function_categories`) e.g. Text functions, Date functions, JSON functions, Container functions, Aggregate functions, Get functions, Artificial intelligence functions
- **13 script step categories** (`script_steps_categories`) e.g. Control, Navigation, Editing, Fields, Records, Found sets, Windows, Files, Accounts, AI, Spelling, Open menu item, Miscellaneous
- **10 languages for functions**: de, en, es, fr, it, ja, ko, nl, pt, sv (no `zh-Hans`; English additionally available as `functions.canonical_name`)
- **11 languages for script steps**: de, en, es, fr, it, ja, ko, nl, pt, sv, zh-Hans
- Native FileMaker functions have **no dot notation** (in contrast to MBS plugin functions)
- **Error codes and trigger compatibility** (fm_spec ≥ 2.8.0): `error_codes` spans (`BETWEEN`), `trigger_compat` tri-state (NULL = Partial) — sections above; on an older reference the tables are absent → say so and fall back to the online Claris pages

## Error handling

### Mode 1: Direct lookup returns nothing

1. **Exact match in `_name_lookup`** (already done — step 2 above).
2. **Fuzzy / ILIKE match**:
   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT DISTINCT f.canonical_name, l.lookup_name, l.match_source
     FROM function_name_lookup l JOIN functions f ON l.function_id = f.function_id
     WHERE l.lookup_name ILIKE '%partialname%'
     ORDER BY l.is_primary DESC, length(l.lookup_name)
     LIMIT 10;
   "
   ```
3. **Run the script step counterpart** if the function is not found — it may be a script step.
4. **Last fallback (grep in HTML)** — only when the DB finds nothing:
   ```
   Grep: pattern="<h1>.*partialname" path="docs/claris-help/de/content/" -i
   ```
5. **Inform the user**: show the top hits from the fuzzy search, point out spelling variants, and recommend the online search at `https://help.claris.com/<lang>/pro-help/content/index.html` if applicable.

### Mode 2: Thematic search with no hits

1. **Broaden the search term** — pattern search with synonyms (`list` ↔ `values` ↔ `elements`, `date` ↔ `day` ↔ `month` ↔ `year`, `container` ↔ `media` ↔ `image` ↔ `Base64`):
   ```bash
   duckdb reference/fm_spec.duckdb -c "
     SELECT DISTINCT f.canonical_name, fl.display_name
     FROM functions f
     LEFT JOIN functions_lang fl
       ON f.function_id = fl.function_id AND fl.language='de'
     LEFT JOIN function_name_lookup nl
       ON f.function_id = nl.function_id
     WHERE  fl.display_name ILIKE '%Liste%' OR fl.display_name ILIKE '%Werte%'
         OR fl.purpose      ILIKE '%Liste%' OR fl.purpose      ILIKE '%Werte%'
         OR nl.lookup_name  ILIKE '%Liste%' OR nl.lookup_name  ILIKE '%Werte%'
     ORDER BY f.canonical_name;
   "
   ```
2. **Show available categories** (often enough to let the user pick the right topic).
3. **Fallback grep**:
   ```
   Grep: pattern="search term" path="docs/claris-help/de/content/" -i output_mode="files_with_matches" head_limit=20
   ```
4. **Inform the user**: which search terms were used, plus a list of all 19 function categories + 13 script step categories.

## Practical examples

### Example 1: Direct function lookup
**The user asks**: "What does the function Austauschen do?"

```bash
# 1) Resolve the name
duckdb reference/fm_spec.duckdb -c "
  SELECT f.url_slug, f.canonical_name
  FROM function_name_lookup l JOIN functions f ON l.function_id = f.function_id
  WHERE l.lookup_name='Austauschen';
"
# → substitute | Substitute

# 2) Metadata in the target language
duckdb reference/fm_spec.duckdb -c "
  SELECT l.display_name, l.signature, l.purpose, l.url
  FROM functions f JOIN functions_lang l ON f.function_id = l.function_id
  WHERE f.url_slug='substitute' AND l.language='de';
"

# 3) Load HTML (local preferred)
# Read: docs/claris-help/de/content/substitute.html
```

### Example 2: Thematic search for JSON functions
**The user asks**: "Show me all JSON functions"

```bash
# Category + all functions of a category
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, fl.display_name, fl.signature
  FROM functions f
  LEFT JOIN functions_lang fl ON f.function_id=fl.function_id AND fl.language='de'
  WHERE f.category_id = (SELECT category_id FROM function_categories WHERE category_name='JSON Functions')
  ORDER BY f.canonical_name;
"
```

### Example 3: Pattern search with description fields
**The user asks**: "Which functions exist for value lists?"

```bash
duckdb reference/fm_spec.duckdb -c "
  WITH q AS (SELECT '%Werteliste%' AS pat)
  SELECT DISTINCT f.canonical_name, fl.display_name, fl.purpose
  FROM functions f
  LEFT JOIN functions_lang fl ON f.function_id=fl.function_id AND fl.language='de'
  LEFT JOIN function_name_lookup nl ON f.function_id = nl.function_id
  WHERE fl.display_name ILIKE (SELECT pat FROM q)
     OR fl.purpose      ILIKE (SELECT pat FROM q)
     OR fl.description  ILIKE (SELECT pat FROM q)
     OR nl.lookup_name  ILIKE (SELECT pat FROM q)
  ORDER BY f.canonical_name;
"
```

### Example 4: Script steps for records
**The user asks**: "Which script steps exist for records?"

```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT s.canonical_name, sl.display_name
  FROM script_steps s
  LEFT JOIN script_steps_lang sl ON s.step_id=sl.step_id AND sl.language='de'
  WHERE s.category_id = (SELECT category_id FROM script_steps_categories WHERE category_name_en='Records script steps')
  ORDER BY s.canonical_name;
"
```

### Example 5: List all categories
**The user asks**: "Which function categories exist?"

```bash
duckdb reference/fm_spec.duckdb -c "
  SELECT c.category_id, l.name AS de, c.category_name AS en
  FROM function_categories c
  LEFT JOIN function_categories_lang l ON c.category_id=l.category_id AND l.language='de'
  ORDER BY c.category_id;
"
```

Returns all **19 function categories**: Aggregate functions, Artificial intelligence functions, Container functions, Date functions, Design functions, Financial functions, Get functions, Japanese functions, JSON functions, Logical functions, Miscellaneous functions, Mobile functions, Number functions, Repeating functions, Text formatting functions, Text functions, Time functions, Timestamp functions, Trigonometric functions.

### Example 6: Multilingual lookup
**The user asks** (in English): "What does PatternCount do?"

```bash
# function_name_lookup contains both 'PatternCount' (canonical_en) and 'MusterAnzahl' (fmstrs_eid)
duckdb reference/fm_spec.duckdb -c "
  SELECT f.canonical_name, l.lookup_name, l.match_source
  FROM function_name_lookup l JOIN functions f ON l.function_id = f.function_id
  WHERE l.lookup_name IN ('PatternCount','MusterAnzahl');
"
```

Reply to the user in their conversation language (here: English), the source is `docs/claris-help/en/content/patterncount.html`.
