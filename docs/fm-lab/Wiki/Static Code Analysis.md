# Static Code Analysis

- [Rule categories](#rule-categories)
- [Why query-based analysis on the object catalog works](#why-query-based-analysis-on-the-object-catalog-works)
- [Expressive power SQL on DuckDB](#expressive-power-sql-on-duckdb)
- [The three delivery forms](#the-three-delivery-forms)
- [How to access test results across different scopes](#how-to-access-test-results-across-different-scopes)
- [A curated, growing collection](#a-curated-growing-collection)
- [Standing on prior art](#standing-on-prior-art)

**Static code analysis (SCA)** examines a program **without running it**: instead of observing behavior at runtime, it inspects the code and structure themselves and reports patterns that are known to be defects, risks or maintenance debt.

For FileMaker this is a particularly good fit — much of a solution *is* structure (schema, relationships, layouts, references between objects), and a lot of what goes wrong (broken references, dead code, untidy layouts, unindexed fields) is visible in that structure long before it bites at runtime.

In FM-Lab, static code analysis runs as **SQL over the [Object Catalog](Architecture.md#duckdb-powered-object-catalog)**: the solution is exported once via `Save a Copy as XML` and converted into a DuckDB database in which every object — scripts, steps, fields, layouts, relationships, value lists, accounts — is a row, and every reference between objects is a resolved link. Rules are queries against these tables. This page explains why that model is so effective, where the rules come from, and how the three delivery forms — [rule dashboards](#rule-dashboards), [single-file dashboards](#single-file-dashboards) and [tests](#analysis-tests) — fit together.

---

## Rule categories

The rules are organized into rubrics — each has its own page with use cases, interpretation guidance and the full rule list:

**Static code analysis** (severity-carrying rules):

- [Performance](../sca/SCA%20Performance.md) — loop anti-patterns, WAN step patterns, unstored calculations, index traps
- [Error-prone](../sca/SCA%20Error-Prone.md) — patterns that hide real defects: broken lookups, dead code, unbalanced blocks, window leaks
- [Security](../sca/SCA%20Security.md) — credentials in code, plaintext password fields, full-access accounts
- [Unused code](../sca/SCA%20Unused%20Code.md) — dead scripts, fields, layouts, value lists, table occurrences
- [Code style](../sca/SCA%20Code%20Style.md) — size and naming smells: long scripts, wide tables, copied names
- [Documentation](../sca/SCA%20Documentation.md) — undocumented scripts, functions and calculated fields
- [Best practices](../sca/SCA%20Best%20Practices.md) — risky settings and constructs worth a second look
- [Layout quality](../sca/SCA%20Layout%20Quality.md) — broken references, lost and occluded objects, Classic theme, geometry defects
- [Platform compatibility](../sca/SCA%20Platform%20Compatibility.md) — can this run on Server / Go / WebDirect / Linux, and what was it built for?

**Neighboring rubrics** (same machinery, different intent):

- [Developer workflow](../sca/SCA%20Developer%20Workflow.md) — TODO/FIXME markers in scripts, layouts and calculations
- [Metadata integrity](../sca/SCA%20Metadata%20Integrity.md) — duplicate UUIDs and export artifacts that disturb tooling
- [Modularization](../sca/SCA%20Modularization.md) — inventory dashboards for module boundaries: files, plugins, APIs, server surface

---

## Why query-based analysis on the object catalog works

Classic FileMaker code analysis means reading a DDR export with XSLT or stepping through Script texts by hand — text processing over a serialization format. FM-Lab's ingestion pipeline does that parsing **once**, at import time, and materializes the result as a relational model (see [Schema](../schema/Schema.md)):

- **References are already resolved.** Which scripts call which scripts, which layout objects show which fields, which relationship uses which table occurrence — all of it sits in [ObjectLinks](../schema/object-catalog/ObjectLinks.md) as typed edges with [roles](../schema/object-catalog/Link%20Roles%20and%20Subroles.md). A "where used" that would take an XSLT author a day is a two-table join.
- **Rules are declarative.** A rule states *what* a finding looks like, not *how* to walk the XML tree to find it. That makes rules short, reviewable and easy to fix when they misfire.
- **Coverage is exhaustive and repeatable.** A query sees every object in every file, every time. Re-import the solution and the same rules produce comparable results — which is what turns findings into a trend you can manage.
- **Findings stay connected.** Every result row carries the object's identity, so a finding links straight into the detail views, the reference browser and the graph — and, via fmIDE, into FileMaker itself.

Since schema 1.22.0 this reach includes every calculation formula: the calculation-based rules run on the [CalculationsCatalog](../schema/catalog-tables/CalculationsCatalog.md) instances and no longer depend on the export's optional DDR-Info sections.

## Expressive power: SQL on DuckDB

The rules engine is [DuckDB](https://duckdb.org) — a fast analytical SQL database with a modern dialect: window functions, recursive CTEs, list and struct types, regular expressions, aggregation over everything. That expressiveness is what lets a single `.sql` file state things like:

- *steps nested five or more `If` levels deep* (control-flow depth from [per-step nesting](../schema/catalog-tables/StepsForScripts.md)),
- *a `Close Window` whose window name is never produced by any `New Window` in the whole solution* (cross-file set difference),
- *sibling layout objects of the same type with exactly identical bounds* (self-join over geometry),
- *the minimum plugin version this solution needs* (max over per-function introduction versions from the vendor docs).

None of these need a parser, a plugin or procedural code — they are joins, aggregates and predicates over catalog tables. And because the catalog is just a database, **any statement you can make about your objects and code can be codified as a query** — and once codified, it runs forever, on every import, on every solution.

---

## The three delivery forms

The same SQL-template machinery ([SQL Templates](../templates/SQL%20Templates.md)) delivers analysis in three forms, from interactive to declarative:

### Rule dashboards

Each rule is a self-contained [dashboard bundle](../templates/Dashboard%20Datasets.md): a manifest with the rule metadata (severity, rationale, remediation, prior-art source), a summary dataset (the finding count that feeds health checks and tests) and a findings dataset (the table you actually work through). Dashboards are interactive — many rules expose their thresholds as sliders (what counts as a "long" script?), offer filter chips to slice findings, and every row navigates to the object it describes. The **[Healthchecks](../sca/SCA%20Healthchecks.md)** dashboard sits on top as a pure consumer: one page with the per-rule counts and states across all rubrics, without re-running any SQL.

Severity is part of the rule declaration: `critical`/`error` findings are defects, `warning` deserves review, `info` marks inventories and style observations that count but never turn a traffic light red. Some bundles are deliberately **explorers** with no severity at all — inventories like the layout geometry explorer that describe rather than judge.

### Single-file dashboards

A [single-file dashboard](../templates/Single-file%20Dashboards.md) is the lightweight form: one `.sql` file with a metadata header in a dashboard folder, hot-reloaded, listed in the dashboard overview next to the rule bundles and callable by name through the [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md). This is the fastest path from "I wonder…" to a permanent, shareable analysis — the shipped examples include a script complexity ranking (cyclomatic complexity), a layout-overlap explorer and a theme/style usage map. With a declared default result it shows a value in the overview and can be a test member; when it wants severity, tiles and several panels, it grows into a bundle without rewriting the SQL.

### Analysis Tests

[Analysis Tests](Analysis%20Tests.md) make rule results **consumable as verdicts**: a test is a declared collection of dashboards — rule bundles and single-file dashboards — with a result model on top — pass/fail states, severity aggregation, scopes (solution, file, single object, object list, graph cluster) and profiles. Tests are what you run when the question is not "show me the findings" but "is anything wrong with this script?" — from the web frontend, the [REST API](../rest-api/endpoints/Tests%20API.md) or the `fm-test` agent skill, with identical results in all three.

---

## How to access test results across different scopes

There are different ways to use the SCA tools, depending on the workflow and the scope you want to examine:

#### Dashboard navigation

Each **rule dashboard** and **single-file dashboard** is represented by its own dashboard card, accessible and discoverable from the start page of the FM-Lab web frontend. Navigate through the folder hierarchy or enter a search term on the overview page of each section. The dashboard overview also offers a hierarchical list with status and findings columns per folder, and a favorites view for the rules you check regularly (see [Dashboard overview](Components.md#dashboard-overview)).

Dashboard cards are designed to run at **global scope**, making it easy to explore and discover issues across the entire solution.

#### Object panel

When examining a specific object in the solution catalog, you can run all tests that apply to that object type directly within the object’s scope. Switch to the **Tests panel** and select from the available test categories or individual test profiles, or run all applicable tests at once with a single click.

Results are displayed in place and can be filtered or sorted by class or severity. Clicking a result navigates directly to the associated context.

#### Agentic analysis

Agents are aware of specific test profiles and their use cases through guidance in the system prompt and a collection of common analysis patterns. This allows them to use SCA tests as part of a broader analysis and obtain a structured overview of typical pitfalls that might otherwise remain hidden within the FileMaker solution.

For a more explicit and targeted entry point, the `fm-test` skill can be used to run tests across different scopes, including **files, individual objects, object lists, and graph clusters**.


---

## A curated, growing collection

The rule library is a **curated collection of community experience**: each rule encodes something developers have learned to watch out for — sourced from PMD, from fmCheckMate, from vendor documentation and from practice — expressed once as a reviewable query and then applied consistently to every solution.

The collection is designed to be extended continuously: new rules ship with FM-Lab releases, and your own installation can add rules and queries at any time (the `create-custom-dashboard` skill builds a single-file dashboard or a full rule bundle, `create-custom-test` bundles them into a test). Because custom bundles override built-ins by id, you can also tune a shipped rule's thresholds or exclusions locally without forking anything.


## Standing on prior art

Many of the shipped rules are FileMaker translations of established analysis rules, and each rule dashboard links to its prior-art reference where one exists:

- **[PMD](https://pmd.github.io)** — the long-standing open-source static analyzer for Java and friends. Rules like *Long Script* (ExcessiveMethodLength), *Deep If nesting* (AvoidDeeplyNestedIfStmts), *Unused Field/Script* (UnusedPrivateField/-Method), *Empty If branch* (EmptyControlStatement) or *Hard-coded IP address* (AvoidUsingHardCodedIP) carry their PMD ancestry in the rule metadata, with a link to the original rule documentation at [docs.pmd-code.org](https://docs.pmd-code.org).
- **[fmCheckMate-XSLT](https://github.com/mrwatson-de/fmCheckMate-XSLT)** — Russell Watson's open-source XSLT check library for FileMaker, the richest public collection of FileMaker-specific checks. Rules like *Broken lookup*, *Commented-out calculation*, *Quoted object name*, *Popover in popover* or *Variable read but never set* are re-implementations of fmCheckMate checks as catalog queries, each citing the original check by name.
- **Claris & community performance practice** — the WAN pattern family in [SCA Performance](../sca/SCA%20Performance.md) (*Enter Find Mode after Go to Layout*, join-cache flushes, freeze/pause interplay, host-round-trip calculations) translates published remote-performance guidance: the Claris knowledge base and help, long-standing community write-ups and conference material. Each rule cites its published sources in the metadata.
- **fm-lab** — rules without a direct ancestor (window lifecycle, plugin deprecation, platform compatibility, UUID integrity) are curated from FileMaker community experience and the Claris/vendor reference data shipped with FM-Lab ([fm-spec](fm-spec.md), [plugin-spec](../schema/plugin-spec.md)).

---

## See also

- [4 Code Analysis Approaches](4%20Code%20Analysis%20Approaches.md) — where SCA sits among FM-Lab's analysis modes
- [Analysis Tests](Analysis%20Tests.md) — the declarative layer on top of the rules
- [Dashboard Datasets](../templates/Dashboard%20Datasets.md) · [Single-file Dashboards](../templates/Single-file%20Dashboards.md) · [SQL Templates](../templates/SQL%20Templates.md) — the template machinery
- [Schema](../schema/Schema.md) — the catalog tables the rules query
