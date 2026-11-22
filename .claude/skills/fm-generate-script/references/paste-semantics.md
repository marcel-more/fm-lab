# Paste semantics — failure catalog and delivery recipes

Why a snippet that *pastes* cleanly can still be broken: FileMaker validates
in three stages (paste, save, runtime) and fails silently in several known
patterns. The machine-readable versions of these rules live in
`fm_spec.duckdb` (`step_constraints`, `step_xml_map`) and are enforced
by `fmgen.py gate`; this file is the human-readable background. The gate
mirrors the three stages as its three layers (§Gate layers).

Sources: fm-lab corpus roundtrips (fm-spec, evidence `paired`), the andykear
FileMaker-XMLsnippet spec (CC BY 4.0, Andy Kear — vendored under
`project/inspiration/andykear/`), fmCheckMate fixtures (MIT), own findings.

## Silent failures (paste succeeds, content wrong)

| Pattern | Effect | Guard |
|---|---|---|
| Set Variable (141) `Name` element missing/mangled | variable name silently dropped; markdown/HTML layers can strip `<Name>` to `<n>` — never route the XML through a rendering layer | gate G107; construct the tag programmatically |
| Perform JavaScript in Web Viewer (175): flat `Parameter` elements | pastes cleanly, passes **no** arguments — needs `Parameters Count="N"` container with `P` children | constraint catalog |
| Install OnTimer Script (148): top-level `Calculation` | binds to the script-parameter slot, timer never fires at the intended rate — interval must be `Interval/Calculation` | constraint catalog |
| Element order wrong (e.g. Set Field `Field` before `Calculation`) | options silently dropped or misassigned | gate G106 checks order against `step_xml_map.element_order` |
| Typographic double quote (`„ “ ” ‟`) inside a calc text constant | FileMaker reads each of them as a text-constant delimiter, like `"`: the constant ends early, and on paste FileMaker comments the whole formula out (`/*"a„b“c"*/`) — the step stays active and sets an empty value. Escape them inside constants (`\„` — valid, the mask disappears in the result). As the delimiter itself any pairing of `" “ ” „` is accepted (`“abc”`, `„abc“`, `“abc"`) and shown as `"abc"` afterwards; fmgen still wants the straight `"`. `‘ ’ ‚ « »` are no delimiters. Paste probe FileMaker 26.0.3 | lint L012; gate G111 |
| LF line break in a calculation's CDATA | FileMaker writes a raw CR into a calculation's CDATA and ignores an LF on paste: a multi-line formula arrives on one line. Inside a text constant the line break disappears from the text; an LF that ends a `//` comment no longer ends it, the comment runs over the rest of the formula (both follow from the dropped LF, not probed separately). Paste observation FileMaker 22, 2026-11-18 | emitter writes CR; gate G112 |
| Wrong step id with plausible name | FileMaker trusts the id, not the name (classic: 23 = Show All Records, not New Record = 7) | gate G104/G105; ids only from the reference |

## Save-invalid (paste + roundtrip OK, file refuses to save)

| Pattern | Detail |
|---|---|
| Set Variable value `Self` | FileMaker silently drops the whole `Value` element on save → "invalid script step" |
| Commit/Revert Transaction (206/207) inside If/Else | pastes and roundtrips byte-identical, then the FILE fails to save — keep transaction closers flat, branch to a flat commit (lint L008) |
| Add Account (134) bare form | AccountName, Password and PrivilegeSet are required; PrivilegeSet resolves **by id** — name fallback invalid |
| Bare skeletons of steps with required content | a `<Step>` without its required child elements can be save-invalid even when paste accepts it |

## Runtime traps

- **Unresolved references**: FileMaker pastes unknown field/layout/script
  names as broken references (`<Field missing>`); that is why P4 resolution
  errors stop the pipeline.
- **PrivilegeSet & other by-id-strict elements**: resolved by id at paste
  time; a wrong id silently binds to the wrong privilege set.
- **Save Records as PDF (144) with stored options**: with `Restore`
  ("Specify options") on, `Pages` needs `NumberFrom` **and** either
  `AllPages="True"` or a `PageRange` — any other form pastes, saves and
  then fails with error 5 when the step runs; confirming the options dialog
  with OK does not heal it. Without `Restore` every form runs (the stored
  options are ignored). `Create PDF` (243) is not affected. Runtime probe
  FileMaker 26.0.3, 13 variants (implications in fm_spec 2.9.2, lint L009,
  gate G309).
- **Localized calc text**: German FileMaker *exports* clipboard calcs
  localized (`Hole`), SaXML stores EN. Generated snippets use canonical EN
  function names (registry convention) — if a paste test shows EN calcs
  failing in a localized client, escalate; do not silently switch locale.

## Gate layers

The three stages above are the three layers of `fmgen gate`
(`scripts/fmgen_lib/gate.py`): the paste table (§Silent failures) is layer 1,
§Save-invalid is layer 2, §Runtime traps is layer 3. Every check reports a
layer and a status.

### The layer is the moment the defect strikes

The layer answers one question: *if this check did not exist, when would
FileMaker reveal the defect?*

| Layer | Name | FileMaker reveals the defect … | Typical effect |
|---|---|---|---|
| 1 | paste validity | **while pasting** the snippet | nothing pasted, a step or element dropped, a formula commented out |
| 2 | save validity | **when saving** the script — the paste looked fine | the file refuses to save ("invalid script step"), or FileMaker's own serialization loses data |
| 3 | runtime validity | **when the script runs** — paste and save are fine | wrong object, function not available in the target version, wrong argument count, uninitialised variable, lost option |

The first digit of a check ID is its layer (`G1xx`, `G2xx`, `G3xx`), without
exception.

**The layer is a classification only.** No code reads it: the overall
PASS/FAIL, the exit code and the summary line (`n failed, n warning,
n skipped`) depend on the status alone. A `fail` in layer 3 blocks the snippet
exactly like a `fail` in layer 1. The layer tells the reader of the protocol
*when* the problem would have surfaced. That makes it easy to explain to the
user ("FileMaker would disable this step on paste" vs. "this runs, but reads
the wrong field").

Checks run in layer order. Only two of them end the run early: `G101` (the XML
does not parse) and `G103` (no `Step` element) — nothing else can be judged
then.

### Status values

| Status | Meaning | Blocks the paste? |
|---|---|---|
| `pass` | checked, nothing found | no |
| `fail` | a defect — the snippet must not be delivered | **yes** |
| `warning` | a finding the deliverer must report, the snippet stays valid | no |
| `skipped` | could not run (data missing, opt-in off, no IR, unknown target version) — reported with its reason, **never** counted as passed | no, but the delivery must name it |

### Check catalog

"Needs" names what a check depends on. Without it, the check is `skipped`.

#### Layer 1 — paste validity

| Check | What it verifies | Statuses | Needs |
|---|---|---|---|
| `G101-wellformed` | the XML parses with a real parser | pass / fail (ends the run) | — |
| `G102-wrapper` | `<fmxmlsnippet type="FMObjectList">` | pass / fail | — |
| `G103-steps` | at least one `Step` element | pass / fail (ends the run) | — |
| `G104-step-ids` | every step id exists in the reference, no legacy/reserved id | pass / fail | — |
| `G105-step-names` | the `name` attribute matches the id (canonical name or alias) — FileMaker trusts the id | pass / fail | — |
| `G106-structure` | children, nesting, attributes and element order match the target coverage's `step_xml_map` | pass / fail / skipped | grammar tables |
| `G107-setvar-name` | `Set Variable` carries its `Name` element (otherwise dropped on paste) | pass / fail | — |
| `G108-cdata` | every `Calculation` is CDATA-wrapped | pass / fail | — |
| `G109-doc-only` | enum values only documented by Claris, never round-trip verified | pass / warning / skipped | grammar tables |
| `G110-state-domains` | boolean attributes stay in their value domain (`True`/`False` or the option's `xml_true`/`xml_false`); a localized build's spelling is a warning | pass / fail / warning / skipped | grammar tables |
| `G111-calc-quotes` | no unescaped typographic double quote (`„ “ ” ‟`) inside a text constant — FileMaker ends the constant there and comments the formula out on paste. A typographic quote as the delimiter itself (`“abc”`) is valid for FileMaker and no finding here (the lint refuses it in a draft) | pass / fail | — |
| `G112-calc-line-breaks` | no LF in a calculation's CDATA — FileMaker keeps line breaks as CR and ignores an LF on paste. Between tokens: warning (layout lost); inside a text constant or at the end of a `//` comment: fail (the formula changes). Judged on the raw text, an XML parser normalizes CR to LF | pass / fail / warning | — |

#### Layer 2 — save validity

| Check | What it verifies | Statuses | Needs |
|---|---|---|---|
| `G201-save-constraints` | `step_constraints`: save-invalid nesting (Commit/Revert inside If), bare `Self` in `Set Variable`, transaction pair balance | pass / fail / skipped | `step_constraints` |
| `G202-known-fm-bugs` | steps with an entry in the known-FileMaker-bug registry (clipboard loss, version skew, save corruption, …) — the snippet is valid, FileMaker itself is the risk | pass / warning / skipped | `step_constraints` |

#### Layer 3 — runtime validity

| Check | What it verifies | Statuses | Needs |
|---|---|---|---|
| `G301-resolution` | the resolution report has no unresolved reference of severity `error` | pass / fail / skipped | resolution report |
| `G302-new-objects` | lists the objects to create before the paste (`{{NEW:…}}`); only present when there are any | pass (informational) | resolution report |
| `G303-version-gate` | every step exists in the target FileMaker version (`origin_version`) | pass / fail / skipped | target version |
| `G303b-function-versions` | every built-in function exists in the target version and is not retired by it | pass / fail / skipped | target version |
| `G304-calc-arity` | references that exist but are used wrongly (custom-function argument count); `warning` when the catalog declares no parameters | pass / fail / warning / skipped | resolution report |
| `G305-var-init` | a variable used as a step target is set beforehand (opt-in convention) | pass / warning / skipped | opt-in + IR |
| `G306-option-preservation` | every parsed option materializes in the emission, mirror elements included | pass / fail / skipped | IR (`--resolved`) |
| `G307-value-form` | the value form of every target slot (variable-only, field-only) | pass / fail / skipped | grammar tables (IR for the cross-check) |
| `G309-pdf-page-settings` | `Save Records as PDF` with `Restore` on carries complete page settings (`NumberFrom` and `AllPages="True"` or a `PageRange`) — otherwise error 5 at runtime | pass / warning | — |

### Lint rule and gate check: the same knowledge twice

Several defects are guarded twice. The **lint** stops the draft at its own
line before any XML exists, and the **gate** checks the finished snippet, which
also covers XML that was hand-authored, edited afterwards or produced
elsewhere and never saw the lint.

| Defect | Lint (draft) | Gate (snippet) |
|---|---|---|
| transaction pairing / Commit inside If | L008 | G201 |
| value form of a target slot | L010 | G307 |
| typographic quotes in a calculation | L012 | G111 |
| LF line breaks in a calculation | — (the emitter writes CR) | G112 |
| incomplete PDF page settings with stored options | L009 (`all_pages: Off` without a range); implications fill the rest | G309 |
| unresolved or misused reference | resolver findings | G301 / G304 |

The two halves share their logic where possible (`textform.typographic_quote_hits`
for L012/G111, `Reference.slot_kind` for L010/G307), so they cannot drift
apart.

### Placing a new check

1. **Pick the layer by the moment of failure**, not by the subject. Ask when
   FileMaker would reveal the defect without the check. A defect in a
   calculation is layer 1 when FileMaker already rejects or disables it on
   paste (`G111`), and layer 3 when the formula pastes and evaluates wrongly
   later (`G303b`, `G304`).
2. **Take the next free number in that layer's hundred** and a short kebab-case
   suffix (`G113-…`). The digit must match the layer argument of `res.add`.
3. **Never renumber a released check.** Generator scripts and users parse the
   IDs from the protocol. Before a release, a rename is cheap; after it, it is a
   breaking change.
4. **Choose the status classes deliberately:** `fail` only when the snippet
   must not be pasted, `warning` when the snippet is valid but the user has to
   know something, `skipped` with a reason whenever the check cannot judge.
5. **Document it** in the catalog above, add the FileMaker-side pattern to the stage tables of this file if it is new, in `SKILL.md` (P7 delivery list, if
   it can warn or fail visibly), and give it a test in
   `tools/tests/codegen/`.

## Redelivery

Pasting the same snippet twice creates a duplicate script (FileMaker appends
" 2"). Snippet paste cannot modify an existing script. For iterations: delete
the old copy first, or paste into a folder and swap manually. Say this in
every delivery.

## Delivery paths (descending preference)

1. **fmIDE present** (check like the `fm-open` skill does): set clipboard
   text, then fmp-URL `Convert Clipboard` + `Paste` — no plugin needed.
2. **MBS installed**: `MBS("Clipboard.SetMonitorEnabled"; 1)` once, then
   plain-text XML on the clipboard converts on paste; or
   `MBS("Clipboard.SetFileMakerData"; "com.filemaker.script"; $xml)`.
3. **Manual**: hand over the XML file; BaseElements plugin or the
   plugin-less pasteboard recipes are documented alternatives.

No XML declaration on the clipboard path (`fmgen.py` default); add
`--xml-decl` only for file-based tooling that requires it.

## Verify (copy-back diff)

After pasting: save, select the pasted script, copy, paste the clipboard XML
into a scratch file and diff against the generated XML. Expect normalization
noise (whitespace, attribute order); structural differences mean a real
problem. Long term this closes the loop via re-export + `convert-xml` +
catalog diff.
