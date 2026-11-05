# SCA Security

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 7 rules · `rest-api/templates/dashboards/static-code-analysis/security/`

Security rules look for secrets and access-control weaknesses that are visible in the solution's structure: credentials embedded in scripts, password fields stored or displayed in plain text, secrets parked in global variables, and the size of the full-access surface. They cover what a catalog can honestly see — configuration and code, not server hardening or network posture.

## When to use it

- Before handing a file to an external developer, or before publishing any part of the solution — embedded credentials travel with the file.
- As part of a security review together with the accounts/privilege model (the catalog's `PrivilegeSet*` tables).
- After incidents or personnel changes: hard-coded hosts and credentials are exactly what doesn't get rotated.

## Reading the results

`credentials_in_scripts` is the one `critical` rule in the library — and it is deliberately safe to use: matched values are masked with `*****` in the dashboard, so reviewing findings never re-leaks the secret. The two password-field rules are complementary: one checks **storage** (a stored field named like a password, with the file's Encryption-at-rest status alongside), the other checks **display** (a layout object rendering such a field without the concealed edit style). Name-based rules (password fields, secret globals) are heuristics — expect the occasional false positive from fields that merely sound sensitive, and treat absence of findings as "nothing name-detectable", not "secure".

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Credentials in scripts | critical | Script steps referencing credential keywords (password, secret, apikey, token, …) — values masked in the output | fm-lab |
| Account with [Full Access] | warning | Every account holding the unrestricted privilege set | fm-lab |
| Password field stored as plain text | warning | Stored fields named like passwords/PINs, with each file's Encryption-at-rest status | fm-lab |
| Password field displayed as plain text | warning | Layout objects rendering a password field without concealment | fm-lab |
| Secret in global variable | warning | Global/superglobal variables named like secrets — globals persist for the whole session | PMD |
| Hard-coded IP address in Calculation | warning | Literal IPv4 addresses in formulas — brittle and infrastructure-leaking | PMD |
| Hard-coded URL in Calculation | warning | Literal `http(s)://` endpoints in formulas | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Modularization](SCA%20Modularization.md) — where the solution talks to the outside world (APIs, email, shell)
- [SCA Unused Code](SCA%20Unused%20Code.md) — disabled accounts and unused privilege sets
