# Analysis Tests for the findings section (R3)

Run through the `fm-test` skill in **solution scope** (`/fm-test <id>`); when no REST server
answers, `fm-test` falls back to its direct path. Default set = the 12 ids below; `--no-tests`
skips the block and Appendix B says so. Report per test: the **counters** (summary per
member — they carry the statement), then severity-sorted findings capped at **5 rows per
member** (say how many were cut); tests with 0 findings are listed in one line. Before any row
enters the context, drop findings that belong to tooling add-ons (scripts or folders named
after an IDE plugin or a development helper) — they describe the tooling, not the solution;
count them in one line instead.

| Test id | Type | Feeds |
|---|---|---|
| `script-error-checks` | error-check | F 5.1 — correctness risks in scripts |
| `calc-variable-hygiene` | error-check | F 5.1 — calculation/variable defects |
| `field-integrity` | error-check | F 5.1 — schema defects |
| `uuid-integrity` | error-check | F 5.1 — catalog integrity (also a caveat for the report itself) |
| `script-code-quality` | code-quality | §4 conventions, F 5.2 |
| `naming-hygiene` | code-quality | §4 conventions |
| `unfinished-work` | code-quality | §7 open questions, F 5.2 |
| `script-plugin-maintenance` | code-quality | §4 APIs/plugins |
| `script-performance-checks` | performance | §6 performance |
| `schema-performance` | performance | §6 performance |
| `sql-performance-checks` | performance | §6 performance (ExecuteSQL) |
| `layout-render-performance` | performance | §4 UI, §6 |

On demand (not default — they need a stated target platform): `platform-server`,
`platform-webdirect`, `platform-ios`, `platform-cloud`, `platform-dataapi`, `platform-odata`,
`platform-cwp`, `platform-os-binding`; also `layout-error-checks`, `layout-hygiene`,
`script-todos`, `wan-script-patterns` when the solution is layout-heavy / WAN-hosted.
Discovery of newer tests: `/fm-test --find "<keyword>"`.
