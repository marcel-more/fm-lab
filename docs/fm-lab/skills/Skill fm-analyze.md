# Skill: fm-analyze

Derives the presumed **business purpose** of a FileMaker object from its context — call chain, trigger sources, variable and layout names, field comments of connected objects — and reports it as a narrative with facts and interpretation kept apart.

| | |
|---|---|
| **Category** | Agentic analysis |
| **Slash command** | `/fm-analyze <object> [--short]` |
| **Say it naturally** | "analyze the script X", "what is the purpose of X", "what business logic sits behind X" — understood in 11 languages |
| **Input** | an object name, a UUID, or the object under discussion |
| **Reads** | `db/fm_catalog.duckdb` (read-only) |
| **Writes** | nothing — the report is printed in the chat |
| **Prerequisites** | a converted catalog; DDR-Info in the export makes the analysis considerably stronger |
| **Under the hood** | the shared resolution contract, the per-type query templates, and the recursive call-chain queries in `_shared/scripts/call_chain.sql` (up to five hops in each direction) |
| **Skill directory** | `.claude/skills/fm-analyze/` |
| **Related** | [Skill fm-summarize](Skill%20fm-summarize.md) · [Skill fm-test](Skill%20fm-test.md) · [Skill fm-trace](Skill%20fm-trace.md) |

## What it does — and how it differs from fm-summarize

| | fm-summarize | fm-analyze |
|---|---|---|
| Question | What does the object do, technically? | Why does it exist, in business terms? |
| Depth | the object and one hop | several hops: callers of callers, sub-scripts of sub-scripts |
| Sources | steps, fields, links | plus variable names, layout names, comments of linked objects, trigger context |
| Result | structured fact list | narrative with conclusions, hedged |

Rule of thumb: *what it does* → fm-summarize; *what it means* → fm-analyze. The two are not exclusive — the analysis reuses the summary's queries and adds context hops on top.

## How the analysis works

1. **Identify** the object unambiguously (selection list on ambiguity — identical to fm-summarize).
2. **Load the core data** — for scripts also the leading comment steps, which developers often use as a header; for fields the comment, the most direct source of purpose there is.
3. **Collect semantic signals** — variables set and read ([VariableUsages](../schema/catalog-tables/VariableUsages.md)) and where else they appear; the backward call chain (who calls this, and who calls them — the business trigger) and the forward chain (what it touches); layout and object triggers ([ScriptTriggers](../schema/catalog-tables/ScriptTriggers.md)); touched fields with their table names and comments; layouts navigated to and their context tables; for custom functions, the callers.
4. **Evaluate** — recurring terms in names (invoicing? master data? permissions?), the verbs in the script name and steps, the read/write balance, the trigger heuristic (called only from a trigger → a reaction, not a workflow), the reuse pattern (many callers across modules → a utility; one caller → a workflow step), and inconsistencies between name and behaviour.
5. **Report** — presumed purpose, business context (module, role, trigger source), the signals that led there, the call chain in both directions, a table of touched objects, noteworthy observations and open questions that only the developer can answer.

Interpretations are always marked as such — *presumably*, *indicates*, *suggests* in your language — and separated from what the catalog states as fact. Honest uncertainty is preferred over a confident wrong module.

## How to use it

```
/fm-analyze "Create Invoice"
/fm-analyze Customers::Email
what is the business purpose of Accounting_PrintInvoice?
analysiere ScriptXYZ_Util_v2 kurz            # short mode via trigger word
```

Short mode (`--short` or words like *briefly*) yields one or two paragraphs with the core conclusion and the module, skipping the recursive chains and the signal inventory; hedging still applies.

## Good to know

- **Without DDR-Info** the resolved step texts and calculation chunks are missing, so the semantic signals are weaker; the report states this limitation.
- **Symptoms first.** When the question is really *"why does X hang / misbehave?"*, the skill proposes the matching [Analysis Tests](../Wiki/Analysis%20Tests.md) via [fm-test](Skill%20fm-test.md) alongside the free-form analysis — tests deliver reproducible findings the analysis can then interpret.
- **Object identity** in the report header (`UUID` + `File`) is the context token the navigation skills read; "open this in FileMaker" works directly afterwards.

## See also

- [Skill fm-summarize](Skill%20fm-summarize.md) — the technical description
- [Agentic analytics](../Wiki/How%20it%20works.md#agentic-analytics) — why context signals on a structured catalog work
- [Link Roles and Subroles](../schema/object-catalog/Link%20Roles%20and%20Subroles.md) — the link roles the call chain and touch sets are built from
- [Graph API](../rest-api/endpoints/Graph%20API.md) — call chains and subgraphs over HTTP
