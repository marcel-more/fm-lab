# Healthchecks

**Dashboard:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · consumer, carries no rules of its own · `rest-api/templates/dashboards-custom/health_hints/`

The **Healthchecks** dashboard is the one page that answers *"how is this solution doing?"* in a single view: a KPI strip over every rule result, and one card per rubric listing the rules with their current state and finding count. It is a **pure consumer of the results layer** — it never executes rule SQL on page load, it reads the server-side result cache. That is what makes it instant on a 30 k-object catalog, and it is also the one thing to understand before trusting a green light: an empty cache is not an all-clear, it is *unknown*.

Open it at `/dashboard/health_hints`, or from the dashboards overview.

## What the page shows

**The hero KPI strip** is one aggregate over the three rule subtrees — `static-code-analysis`, `metadata-integrity`, `developer-workflow` — currently **148 declared rule dashboards** (137 + 5 + 6). It counts rules, not findings:

| KPI | Meaning |
|---|---|
| Rules | Declared rule dashboards in scope — the denominator for everything else |
| Errors · Warnings · OK · Neutral | Rules by result state (see below) |
| Pending | Rules not yet run against the current catalog |
| Failed | Rules whose run raised an error (broken SQL, timeout) |
| Findings | Sum of the finding counts — only over rules whose result is declared in the unit *findings*, never mixing metrics |
| Executed | Coverage as `covered/total`, e.g. `3/136` |

Every KPI is a **filter**: clicking *Errors* re-renders the rubric cards with only the error rules, *Rules* clears the filter. The KPI numbers themselves stay on the unfiltered basis, so the strip never filters itself out of view.

**The rubric cards** — Performance, Error-prone, Security, Unused code, Code style, Layout quality, Documentation, Best practices, Platform compatibility, Metadata integrity, Developer workflow — each list their rules worst state first, with the finding count as the secondary line and the state as a badge. A row navigates straight into that rule's dashboard, where the actual findings, thresholds and filter chips live. A card that shows *"Nothing to report."* under an active filter simply has no rule in that state.

## The six states

| State | When | Reading |
|---|---|---|
| `error` | The rule hit, and its worst finding is `critical` or `error` | A defect — fix or explicitly accept |
| `warning` | The rule hit, worst finding is `warning` | Review-worthy |
| `neutral` | The rule hit, but its findings carry no judging severity (`info`, inventories) | Information, never a red light |
| `ok` | The rule ran and found nothing | Clean under the current catalog |
| `pending` | Not yet run against this catalog | **Unknown** — no statement either way |
| `failed` | The run itself errored out | Broken rule or timeout, not a solution defect |

Severity comes from the rule declaration, and the state is derived from the *worst* finding row where findings were fetched — a platform rule mixing "No" (error) and "Partial" (warning) rows lands on `error`, not on the rule's blanket severity.

## Running the rules

Results are computed on demand and cached per solution **and catalog fingerprint** (mtime + size of the read copy). Practical consequences:

- **A new XML import invalidates everything implicitly.** No bookkeeping, no stale results — after re-importing, all rules are `pending` again.
- **The cache is in-memory.** Restarting the API server empties it, and the page goes back to `pending`. Nothing is lost, only recomputed.
- **Runs are shared.** A solution-scope [test](../Wiki/Analysis%20Tests.md) run writes its envelopes through into the same cache, so tests warm the Healthchecks page and vice versa.

The **Run all rules** button next to the KPI strip triggers the run explicitly, in `missing` mode: only rules without a cached result are executed, so pressing it twice is cheap and idempotent. It covers the same three rule subtrees the KPI strip counts, so a completed run leaves nothing pending behind. To force a recomputation of already-cached rules, use `mode: "refresh"` on the [run endpoint](../rest-api/endpoints/Results%20API.md#post-apiresultsrun).

## Reading it honestly

- **Coverage before color.** *Executed 3/136* with zero errors says almost nothing. The page deliberately shows `covered/total` next to the traffic lights instead of hiding partial coverage behind a green KPI.
- **`neutral` is not `ok`.** Inventory and `info` rules count as hits — they have findings — but they never turn anything red. A rubric whose card is full of neutral rows is fully analyzed and has nothing to fix.
- **Findings sums are unit-pure.** Only rules declaring their result in the *findings* unit enter the sum; a rule counting scripts or a version number never inflates it.
- **The page is a launcher, not a verdict.** Rule thresholds (what counts as a "long" script) live in the rule dashboards and are adjustable there; the Healthchecks number always reflects the shipped defaults. For pass/fail semantics on a defined scope — a file, one script, a graph cluster — use [Analysis Tests](../Wiki/Analysis%20Tests.md).

## What is and isn't counted

Only **result-capable** units enter the aggregate: a rule dashboard qualifies when its manifest declares `analysis.defaultResult`, or when it follows the summary convention (a `summary` dataset whose SQL emits `finding_count`). Bundles without such a declaration are **chipless by design** — the platform profile and the layout geometry explorer describe rather than judge, and would only add noise to a health count. The [Modularization](SCA%20Modularization.md) inventories sit outside the aggregate for the same reason.

The dashboard is restricted to `kinds: dashboard` — [custom queries](../templates/Custom%20Query%20Templates.md) and tests do carry result envelopes, but Healthchecks is about the rule library. And Healthchecks itself declares **no** result: a consumer that scored itself would appear in its own count.

Both halves of the page — the aggregate roots and the per-rubric cards — are hand-declared in the manifest, which means a newly added rubric folder would raise the KPI total while staying invisible in the cards. A guard test in the API test suite enforces that every rubric contributing rules has a card bound to it, and that no card points at a rubric that no longer exists.

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rule model, the three delivery forms and where the rules come from
- [Results API](../rest-api/endpoints/Results%20API.md) — the endpoints behind the page: `summary`, `aggregate`, `registry`, `run`
- [Analysis Tests](../Wiki/Analysis%20Tests.md) — the declarative layer when you need a verdict on a defined scope
- [Dashboard Datasets](../templates/Dashboard%20Datasets.md) — how a rule bundle declares its summary and findings datasets
