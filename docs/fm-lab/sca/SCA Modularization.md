# SCA Modularization

**Rubric:** [Static Code Analysis (neighboring rubric)](../Wiki/Static%20Code%20Analysis.md) · 10 inventories · `rest-api/templates/dashboards/modularization/`

Modularization dashboards map where logic leaves the solution: into other FileMaker files, onto the file system, across the network, into external processes, onto the server, into plug-ins — and where references leave the static object graph (indirections). They are **descriptive inventories with drilldown, not rules** — always "green", because an external dependency is an architectural fact, not a defect. The severity-carrying versions of some of these questions (deprecated/removed plug-in calls, platform limits, hard-coded hosts) live in the [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) rubrics.

## When to use it

- Architecture reviews and documentation: these dashboards *are* the external-interface chapter of a system handbook, generated from the code.
- Risk assessment — the plug-in dependency view answers "which modules would be dead without the plugin?", the version view derives the minimum plugin version the solution needs.
- Planning module extraction or file consolidation: the file-coupling matrix shows which files actually depend on which, complementing the Graph Atlas with a tabular audit view.
- Security and operations reviews: the server-surface, process-execution and email views enumerate every point where the solution touches infrastructure.
- Before renaming, deleting or moving an object: the indirections view lists every place that addresses objects by a computed name — the places where "unused" and "not referenced" can be wrong.

## Reading the results

Everything is Step_ID-gated and link-resolved (locale-independent — no matching on translated step names), and the URL/API classifications are deliberately generic templates: the API-family patterns ship as a broad cloud/SaaS default list, meant to be adjusted per project. Several views state their evidence kind per row (direct call, custom-function wrapper, layout usage), so a finding is always traceable to a concrete call site.

## Inventories

| Bundle | What it maps | Highlights |
|---|---|---|
| FileMaker file coupling | Cross-file dependencies as a source file × target file × link-role matrix | Plus declared external data sources and inter-file access grants |
| APIs & external interfaces | URL invocations (Open URL, Insert from URL, cURL/MBS, Web Viewer, calculated URLs) | Classified by API family, consolidated per host |
| File system access | Every file-system touchpoint: Data File API, import/export, MBS file functions | Classified by operation and API group, drilldown to the call site |
| Email integration | Send Mail steps classified by delivery path (SMTP vs. client), plus MBS SendMail | Extracted SMTP host, flag for hard-coded credentials |
| ODBC / ESS / SQL | Execute SQL steps, ODBC/ESS data sources, fmxdbc grants | Useful as a template even where no ODBC exists yet |
| Process & shell execution | Send Event, Perform AppleScript, MBS Shell/RunTask/Process calls | Where the solution hands control to the operating system |
| Server-side execution | Perform Script on Server, Execute Data API, Install OnTimer, server-relevant extended privileges | An access audit of the server surface |
| Plugin dependency | Call sites per plug-in component × file, plus Install Plug-In File steps | The "dead without the plugin" risk view |
| MBS plugin version | Minimum required plugin version, derived from per-function introduction versions | Numeric version comparison; validate against an installed version via the header select |
| Indirections | Objects addressed through a computed name, number or text — script, layout, field, layout object, SQL table, value list | Literals resolved against the catalog; chips by target type and resolution; works without DDR info |

## Indirections

An **indirection** addresses an object through a name, a number or a text that FileMaker evaluates only at run time — `Perform Script` by name, `Go to Layout` by name or number, `Set Field By Name`, `Go to Object` by name, `Evaluate`, `GetField`, `ExecuteSQL` with names in the SQL text. The object graph has no edge for such a reference, so where-used, renaming, the [unused-object rules](SCA%20Unused%20Code.md), the [Graph Explorer](../Wiki/Graph%20Explorer%20Trace%20Mode.md) and the module clustering cannot follow it. The dashboard (`modularization/indirections`) lists every such place.

**What it counts.** Script steps: `Perform Script` and `Perform Script on Server` by name; `Go to Layout` and `Go to List of Records` by name or by number; `Set Field By Name` (also without a target field — then the active field); the object name of `Go to Object`, `Refresh Object`, `Refresh Portal`, `Set Web Viewer`, `Perform JavaScript in Web Viewer` and `AVPlayer Play`; `Execute FileMaker Data API`; `Execute SQL` with a calculated SQL text. Formulas of every owner (script steps, custom functions, fields, layout objects): `Evaluate`, `GetField`, `GetLayoutObjectAttribute`, `ValueListItems` and the design functions that take an object name, `ExecuteSQL` with names in the SQL text or a statement built at run time. A plain string literal counts too — it has no edge either. Variables bound as `?` parameters of `ExecuteSQL` and `GetFieldName(TO::Field)` do **not** count: they are the remedy, not the problem.

**Resolution.** Every literal is resolved against the catalog and gets one class:

| Class | Meaning |
|---|---|
| Fixed reference possible | The literal names an existing object — a fixed reference would work |
| Target missing | No object of that name; a script call followed by a `Get(LastError)` check is marked *guarded* (an optional target on purpose) |
| File not imported | The data source of `"Source::Script"` names a file outside the imported solution |
| In another file | A layout-object name that exists only in another imported file — typical when data and interface live in separate files, because the window the step acts on may show a layout of that file |
| No formula | An indirect mode is set, but no formula was entered |
| Dynamic | Variable, field or expression — resolvable only at run time |
| No name target | Mechanisms without a single named target (`Evaluate`, a statement built at run time, introspection) |

Script literals follow FileMaker's rules: a name in the same file is case-insensitive, `"<data source>::<script>"` reaches another file and is case-sensitive. A layout name resolves to the first-created layout of that name; a layout number counts the layouts of the file in their order without folders and is marked *low confidence*. Layout-object names match any layout of the file, because the step's layout context is not known statically.

**Reading the page.** The first chip bar filters by target type, the second by resolution; both show the true totals and narrow each other. *All* leaves out introspection (`ScriptNames`, `LayoutIDs`, …) and window names — they are signals rather than indirections and have chips of their own. The carriers list groups a script that exists in several files (a developer tool, a module copy) into one row; a click filters the sites by its name. A click on a site opens the script at the step.

**Without DDR info.** Files exported without *Include details for analysis tools* carry no function-call edges. The dashboard then matches the function calls in the formula text — string literals and comments ignored, localized function names included via the [fm-spec](../Wiki/fm-spec.md) reference — and marks those rows with *low* confidence. Formulas of a few layout-object slots (button action, conditional formatting, placeholder, portal filter) have no stored text without DDR info and stay invisible.

**Not yet covered:** the single script step of a button or a custom menu item, MBS calls with a computed script or SQL, `fmp://` URLs and `FileMaker.PerformScript` in web viewers.

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Platform Compatibility](SCA%20Platform%20Compatibility.md) — whether those external touchpoints survive a platform move
- [SCA Security](SCA%20Security.md) — the credential findings hiding in the same call sites
- [plugin-spec](../schema/plugin-spec.md) — the vendor reference behind the plug-in views
- [SCA Code Style](SCA%20Code%20Style.md) — the `Set Field By Name` rule; [SCA Error-Prone](SCA%20Error-Prone.md) — broken `ExecuteSQL` references
