# SCA Modularization

**Rubric:** [Static Code Analysis (neighboring rubric)](../Wiki/Static%20Code%20Analysis.md) · 9 inventories · `rest-api/templates/dashboards/modularization/`

Modularization dashboards map where logic leaves the solution: into other FileMaker files, onto the file system, across the network, into external processes, onto the server, into plug-ins. They are **descriptive inventories with drilldown, not rules** — always "green", because an external dependency is an architectural fact, not a defect. The severity-carrying versions of some of these questions (deprecated/removed plug-in calls, platform limits, hard-coded hosts) live in the [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) rubrics.

## When to use it

- Architecture reviews and documentation: these dashboards *are* the external-interface chapter of a system handbook, generated from the code.
- Risk assessment — the plug-in dependency view answers "which modules would be dead without the plugin?", the version view derives the minimum plugin version the solution needs.
- Planning module extraction or file consolidation: the file-coupling matrix shows which files actually depend on which, complementing the Graph Atlas with a tabular audit view.
- Security and operations reviews: the server-surface, process-execution and email views enumerate every point where the solution touches infrastructure.

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

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Platform Compatibility](SCA%20Platform%20Compatibility.md) — whether those external touchpoints survive a platform move
- [SCA Security](SCA%20Security.md) — the credential findings hiding in the same call sites
- [plugin-spec](../schema/plugin-spec.md) — the vendor reference behind the plug-in views
