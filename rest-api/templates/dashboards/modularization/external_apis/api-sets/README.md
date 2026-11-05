# API filter sets

An **API set** maps URL patterns to *families* for the **APIs & external interfaces**
dashboard (`external_apis`). It is the only project-specific part of that dashboard —
all mechanics (multi-source URL collection, comment filter, host roll-up, drilldown)
are generic. Swapping the set re-classifies the family table, the URL detail list and
the consolidated host list; nothing else changes.

The active set is chosen with the **API set** dropdown at the top of the dashboard
(URL param `?api_set=<id>`, default `generic`).

## Where sets live

| Location | Purpose | Published? |
|---|---|---|
| `api-sets/generic.json` (this folder, in the bundle) | Built-in default | yes |
| `.fmlab/dashboards/api-sets/<id>.json` (repo root) | Installed, project-specific sets | **no** (stays local) |

Discovery scans both locations. On an id collision the **installed** file
(`.fmlab/…`) wins over the bundle default. To add a set, drop a `<id>.json` into
`.fmlab/dashboards/api-sets/`. To remove it, delete the file. No server restart is
needed — sets are read per query.

## File format

One JSON object per set:

```jsonc
{
  "id": "acme",                    // must equal the filename (<id>.json); [A-Za-z0-9_-]
  "label": "ACME",                 // dropdown caption (English / fallback)
  "locales": {                     // optional localized captions
    "de": "ACME", "ja": "アクメ"
  },
  "description": "…",              // optional, for humans
  "rules": [                       // ORDER = PRIORITY (first match wins)
    { "family": "Payment",  "ilike": ["%stripe.com%", "%paypal%"] },
    { "family": "Internal", "regex": "https?://(10\\.|192\\.168)" }
  ]
}
```

### Rules

Each rule assigns a `family` when its predicate matches. A rule may combine any of
the following fields; they are **AND-ed** together:

- `ilike`: array of SQL `ILIKE` patterns (`%` = wildcard) on the URL. Matches if **any**
  pattern matches (`url ILIKE p1 OR url ILIKE p2 …`). Case-insensitive.
- `regex`: a single DuckDB/RE2 regular expression on the URL (`regexp_matches(url, …)`).
  Escape backslashes for JSON (`\\.` for a literal dot).
- `source_type`: exact match on where the URL was found — one of `Custom Function`,
  `Field`, `Layout Object`, `Script (URL Step)`, `Script (Import)`, `Script (Calc Step)`.
- `in_comment`: `true` matches only URLs inside a `/* */` or `//` comment; `false` only
  URLs in active code.

(If both `ilike` and `regex` are given, `ilike` wins.) A rule needs at least one field.
Rules are evaluated top-to-bottom; the **first** matching rule sets the family, so put
specific rules first and semantic defaults last.

**Semantic default — external custom functions.** A URL inside a Custom Function's
**comment** is almost always an author / download-source reference for an externally
authored function, not a live integration. A good low-priority catch-all (placed after
the specific url-pattern rules) is:

```json
{ "family": "FileMaker Community", "source_type": "Custom Function", "in_comment": true }
```

Any project-specific supplier/API that is a *real* integration should get its own
url-pattern rule **above** this default so it wins.

### Fixed tail (added automatically — do not include)

Every generated classification ends with:

1. `Local Import` — for `Import Records` steps that carry no `http` URL.
2. `Other` — the fallback for URLs no rule matched.

You only list the URL → family rules; the tail is appended by the dashboard.

## Rules of thumb

- **First match wins** — order from specific to generic.
- **Host + port is fine** — patterns like `%localhost:3000%` work; classification runs
  on the full URL and is applied after parameter interpolation, so a `:` in a pattern is
  safe (unlike raw dashboard SQL, where a bare `:word` is a template-engine pitfall).
- Keep families **short and stable** — they show up as badges and as filter values in the
  URL (`?api_family=<family>`).
- `generic.json` is the reference — copy it as a starting point.

## Example: a minimal project set

`.fmlab/dashboards/api-sets/acme.json`:

```json
{
  "id": "acme",
  "label": "ACME",
  "rules": [
    { "family": "ACME Internal", "ilike": ["%acme.internal%", "%.acme.local%"] },
    { "family": "Payment",       "ilike": ["%stripe.com%"] },
    { "family": "Maps",          "ilike": ["%maps.googleapis%"] },
    { "family": "Internal LAN",  "regex": "https?://(192\\.168|127\\.0|10\\.)" }
  ]
}
```

Then open the dashboard and pick **ACME** from the API-set dropdown (or append
`?api_set=acme` to the URL).
