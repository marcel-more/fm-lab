---
name: fm-generate-script
version: 0.9.12
description: Generates FileMaker scripts as paste-ready fmxmlsnippet XML through a reference-driven pipeline - canonical text draft, deterministic lint, object-reference resolution against the DuckDB catalog (real IDs, machine-readable resolution report), table-driven XML emission from fm_spec.duckdb, and a three-layer validation gate. Successor of filemaker-script-erzeugen. Triggers (English) - "create a FileMaker script", "generate a script for X", "build an fmxmlsnippet". Triggers (German) - "erstelle ein FileMaker-Script", "generiere ein Script fuer X", "baue ein Script-Snippet".
---

# fm-generate-script — reference-driven FileMaker script generation

Every artifact goes through this pipeline. Never hand-write snippet XML from
memory: the XML shape comes from `fm_spec.duckdb` (table-driven), the
object IDs come from `db/fm_catalog.duckdb` (resolved, not guessed).

## Pipeline (mandatory)

```
P0 CONTEXT   conventions + target objects from catalog/registry
P1 DRAFT     script in canonical text form (one step per line)
P2-P6        scripts/fmgen.py run  (normalize -> lint -> resolve -> emit -> gate)
P7 DELIVER   snippet + resolution report + gate protocol + redelivery warning
```

A failure in lint/resolve/gate goes back to P1 with the findings — never
"continue with warning" unless the user explicitly decides to.

### P0 — Context

1. Read the conventions block in `docs/agents/codegen-registry.md`
   (function-name locale, naming language). Fill gaps by inspecting the
   catalog (existing script names, comments) — never from the conversation
   language. If `variable_init_check` is `on` there, pass `--check-var-init`
   to `fmgen.py` (or export `FMGEN_CHECK_VAR_INIT=1`) — it is a house
   convention and is off by default.
2. Identify the target file and every object the script will touch (layouts,
   fields, scripts, value lists) and verify them in `ObjectCatalog` **before**
   drafting. Ask the user which file is the target if ambiguous.

### P1 — Draft (canonical text form)

Write the draft to a `.fmscript` file (scratchpad or `output/codegen/`).
Rules (fm-spec `script-text-notation.md` v0.2, condensed):

- One step per line, step name first — any of the 11 locales works, it is
  canonicalized by lookup. Multi-line calculations are fine.
- One bracket group: `Step Name [ param ; Label: value ; ... ]`.
- Fields `TO::Field`, layouts `"Name" (TO)`, scripts `"Name"`,
  variables `$x` / `$$x`. Comments `# text`, disabled steps `// ` prefix.
- **Calculations use canonical EN function names** (`Get`, not `Hole`) —
  see the conventions block in `codegen-registry.md`. The lint warns on
  localized names (L007).
- References to objects the script itself creates or that must be created
  first: `{{NEW:Field:TO::Name}}` — they surface in the report as
  "create before paste".
- The same declaration works **inside a calculation**, but only for custom
  functions: `{{NEW:CustomFunction:CleanTags}} ( $x )` marks a function that
  is not in the catalog yet. It is stripped before emission (the snippet
  contains `CleanTags ( $x )`), listed as "create before paste", and exempt
  from the existence and arity checks — snippet-wide, so declaring it once
  covers every use in the draft. **Unmarked** calls stay fully checked; a typo
  like `Substitue (` remains a hard error. Creating the function before the
  paste is on you.
- Dialog-only options use extension labels: `Button1: "OK"`,
  `Input1: TO::Field`, `Input1Label: "..."`.
- **Field-or-variable targets** (`Target: TO::Field` vs `Target: $var`):
  the emitter picks the XML form from the value — a field becomes the
  attribute form `<Field table id name/>`, a variable the text form
  `<Field>$var</Field>` with FileMaker's `<Text/>` marker in front, an
  unset target emits neither (paired 22.0.6). Never write a field name into
  a variable slot by hand: pasted as text it would become a variable.
- **Text values** that carry `;`, `[`, `]`, `//` or `/*` (find criteria
  such as `// *:*:*`) are written in double quotes — `text: "// *:*:*"` —
  and unwrapped on parse; unquoted, `//` reads as a calculation comment and
  swallows the following steps. `fmgen decompile` quotes them for you.
- **Repeat groups** (T9, fm_spec 1.15.0): list-carrying steps repeat a group
  label, one item per occurrence. Bracketed items for sort/find/filter —
  `sort: [ field: TO::Name ; type: Descending ]`,
  `request: [ operation: Omit Records ; criteria: [ field: TO::F ; text: * ] ]`,
  `filter: [ name: "Bilder" ; extensions: "png; jpg" ]` — and plain scalar
  repetition where the item is a single value: `Tables: "A" ; Tables: "B"`,
  `web_script_parameters: $P1 ; web_script_parameters: $P2` (the `@Count`
  attribute is derived; never author it). The old flat keys (`sort_field:` …)
  still parse and fill item 1, but the canonical form is the group form.

### P2–P6 — Run the pipeline

```bash
python3 .claude/skills/fm-generate-script/scripts/fmgen.py run \
    draft.fmscript --file "<TargetFile>" --out-dir output/codegen/<name>
```

Produces `<name>.xml` (snippet), `.ir.json` (parsed IR + lint findings),
`.resolved.json` (IR with real IDs + resolution report), `.gate.json`
(check-by-check protocol). Exit 2 = errors, fix the draft and re-run;
exit 3 = environment problem (databases missing).

`--target-version 22|26.0.2` sets the FileMaker version for the version gate
(G303); without it the version is the `FilesCatalog.FileMaker_Version` of
`--file`, taken from the resolution report. The gate protocol records both
(`target_version`, `target_version_source` = `option` | `catalog`); when
neither is known G303 is `skipped`, never passed.

Object references resolve File_Name-scoped against the catalog: fields,
layouts, scripts (also in external files via the declared data source),
value lists, table occurrences, base tables (`Truncate Table`), custom
menu sets (`Install Menu Set`), privilege sets, and the bare file
references of `Open File`/`Close File` (id + declared path from
`ExternalDataSourceCatalog`).

Individual phases for debugging: `fmgen.py parse|resolve|emit|gate` (see
`--help`). Databases resolve to `reference/fm_spec.duckdb` and
`db/fm_catalog.duckdb` from the repo root; override with `--reference-db` /
`--catalog-db` or `FMGEN_REFERENCE_DB` / `FMGEN_CATALOG_DB`. With an active
session pin (`FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2) pass
`--catalog-db solutions/<id>/db/fm_catalog.duckdb` so references resolve
against the pinned solution.

**When the emitter reports "not supported by the table-driven emitter"**
(exotic steps without a template placeholder for the option): author that
step's XML manually against the reference —
`SELECT snippet_template, saxml_example FROM step_xml_map WHERE step_id = ?`
— splice it in, and ALWAYS run `fmgen.py gate` on the final XML. Say in the
delivery that this step was hand-authored.

**Degradation:** if `fm_catalog.duckdb` has no data for the target file,
resolution falls back to name-only placeholders (`id="1"`) and says so in the
report — deliver only with an explicit caveat. If the reference DB is missing
entirely, stop and offer `install-claris-docs`.

### P7 — Delivery

Always include, in this order:

1. The snippet file path (and the XML inline if short).
2. The resolution report: resolved refs (real IDs), new objects to create
   before paste, assumptions.
3. Gate protocol summary — each failed/skipped check by name; never claim
   "validated" when a check was skipped. Report `warning` checks explicitly,
   they are findings the user has to act on:
   - `G109-doc-only` — enum values documented by Claris but not
     roundtrip-verified; never present them as verified.
   - `G304-calc-arity` — a custom function is called with the wrong number of
     arguments. `warning` means the catalog declares no parameters for it (it
     may be a custom-function folder, which the catalog cannot distinguish);
     `fail` means a genuine count mismatch.
   - `G305-var-init` — a variable is written as a step target without a
     preceding `Set Variable`. Opt-in convention (P0); `skipped` when it is off
     or when the gate ran without the IR.
   - `G202-known-fm-bugs` — a step in the snippet carries an entry in the
     known-FM-bug registry (`step_constraints`, kinds `clipboard_loss`,
     `version_skew`, `save_corruption`, `serialization_unstable`,
     `localized_build_defect`, `paste_validator_warning`; the export-gap
     kind `saxml_omission` is NOT a gate finding — it is a decompile note,
     see "Read residues"). Always a warning,
     never a fail: the snippet is valid; FileMaker itself may lose or skew
     the marked data (e.g. 221 drops `TemplateName` on copy) — except
     `paste_validator_warning`, which is benign (a paste-time dialog may
     appear in some environments, nothing is lost) and gets its own softer
     lead text. Pass the caveat on with the artifact.
   - `G110-state-domains` (fail class) — an attribute a boolean option maps
     to carries something outside its value domain: `True`/`False`, or the
     option's own `xml_true`/`xml_false` (the window-style attributes of
     `Go to Related Record`/`New Window` take `Yes`/`No`, fm_spec 2.2.0).
     Domain is derived from the reference (`option_type='boolean'` +
     attribute `xml_path`), no hardcoded attribute names. A localized
     build's spelling of the same state (`Ja`/`Nein`, registered as
     `localized_build_defect`) is a warning, not a failure — it is
     FileMaker's own output and pastes into a build of that language.
   - `G306-option-preservation` (fail class) — a parsed option did not
     materialize in the emission and no reference rule (element binding —
     an element, the n-th same-named child `Field[2]` or an attribute
     `SerialNumbers/@increment`, fm_spec 2.5.0 —, `omit_when_false`
     presence boolean, `paste_dropped` option FileMaker discards anyway,
     fm_spec 2.6.0) explains the absence. The mirror rules sharpen it the
     other way round: a set source (144 `Title`) whose copy is missing or
     different at its mirror path (the Step-level `Calculation`) is a fail —
     FileMaker writes the title there on paste (`step_mirror_elements`).
     Runs on the IR (`--resolved`); `skipped` without it. Presence-only —
     value fidelity stays with G109/G110.
   - `G307-value-form` (fail class) — the VALUE FORM of every target slot,
     judged on the emitted snippet alone, no IR (the parsed step structure)
     needed (fm_spec 2.2.0 `step_options.slot_kind`): bare text
     that is no variable (FileMaker would store it as a variable name), the
     attribute form in a variable-only slot (discarded on paste without a
     word), a variable in a field-only slot. With `--resolved` one more
     cross-check: a resolved field reference must have reached the XML as
     `table`/`id`/`name` attributes.

**Known FM bugs — direction matters.** The registry warns on the READ side:
`fmgen decompile` attaches a `note` (never an `issue`) to steps with a
`clipboard_loss` or `serialization_unstable` entry, because a clipboard
snippet may already have lost a slot before fmgen saw it — an empty slot
there does not prove it was never set. The EMIT side deliberately does not
warn: fmgen's own emission writes the full form (the snippet carries the
slot) and pastes intact, so a warning there would point the wrong way.

**Shape coverages (fm_spec 2.0.0).** FileMaker 22 and 26 write different
clipboard forms for some steps; the reference carries both as _coverages_
(`22` = base, `26` = override rows). fmgen resolves every shape read against
one **target coverage**: `--coverage 22|26` (global option, before the
subcommand) wins, otherwise the `FileMaker_Version` of `--file` in the
catalog decides (22.x → 22, 26.x → 26). A target file that is not in the
catalog, or a version the reference has no coverage for, is a hard error for
`run`/`resolve` — pass `--coverage`. `gate`/`decompile` on a bare snippet take
the major of `--target-version`, else the base coverage. The IR and the gate
protocol record `coverage` and `coverage_source`.

- **Emit:** the target coverage's template and options are used — the text
  form is one notation for both versions (`Sort Records [ … ; Blanks last: On ]`,
  `Set Zoom Level [ 123 ]` with a calculated zoom, `Configure AI Account` with
  the corrected element spelling). An option that exists only in the FM 26
  form is refused for a 22 target with the hint "exists only in the FileMaker
  26 form" (lint).
- **Lint — transaction constraints (L008):** `Commit Transaction`/`Revert
Transaction` inside an If block, an `Open Transaction` without its
  `Commit Transaction` in the same script, a Commit without a preceding Open,
  a Revert outside the pair, or a nested Open are errors at the draft line —
  each pastes cleanly and then the **file fails to save**. The rules are
  reference rows (`step_constraints`, kinds `save_invalid_nesting`,
  `requires_pair`, `requires_parent`, fm_spec 2.2.0): the step ids come from
  the rows (the partner is the step a row names by `Name (id)`), the pair's
  opener is its lower id; the If/Loop pairs the reference declares the same
  way stay with L002.
- **Lint — option couplings (L009):** a flag or mode that is worthless without
  its counterpart is an error before emission, because FileMaker drops it
  silently on paste: `Print PDF` `Save print options to` / `Use print options
from` / `Password` flags need their target, source or password calculation
  (`Save print options to: <field>` next to the bare flag); `Append PDF` /
  `Open PDF` `From: Target` need `Source: …`; `Close PDF` `Save to: Target`
  needs `Target: …`. The couplings are reference rows
  (`step_option_implications`, kind `requires_option`, fm_spec 2.1.0) — the
  message names the missing option and the label to add.
- **Mirrored values and options FileMaker discards (fm_spec 2.6.0):** two
  parse-side canonicalizations, both reported as warnings, never silent.
  `Save Records as PDF` writes the document title twice (the `Title` option
  and a bare Step-level `Calculation`); the reference declares the copy
  (`step_mirror_elements`), so a draft writes **`Title: …` alone** — the
  emitter copies it into the mirror, the decompiler reads the mirror as
  redundancy. The legacy notation `title_mirror: …` stays readable: a pure
  mirror is read as the title (FileMaker heals the title in on paste), an
  equal mirror is dropped, a divergent mirror loses (the title wins on paste,
  paste-verified 22.0.6 + 26.0.2). `appearance` of the same step is
  `paste_dropped`: FileMaker discards it whatever the value (`as formatted`
  and `with boxes` alike), so a draft that sets it gets a warning and the
  canonical text and the emission leave it out. A minimal
  `Save Records as PDF [ file:x.pdf ]` now emits FileMaker's own zero-state
  PDF options (all pages, printing and copying allowed — runtime-verified);
  the dialog defaults of older drafts (`allow_screen_reader: On`,
  `control_printing: High Resolution`, `view_show: Pages Panel and Page`, …)
  are explicit options.
- **Lint — error-code literal (L011, fm_spec ≥ 2.8.0):** a numeric literal compared with `Get ( LastError )` is checked against the reference's error-code table (`error_codes`, spans — `5123` lies in `5000-5499`): a code the table does not list is a **warning** (a typo, a plug-in code or a custom code outside `5000-5499` — the branch can never match a FileMaker error), a code only the web publishing engine / REST API returns is an **info**. No gate, no emission change; on a reference without the table the rule skips with one note.
- **Lint — value form of a target slot (L010):** a target slot has a form it
  accepts, and writing the other one loses data without FileMaker saying so.
  `Generate Response from Model` `Save Message History To` takes a **variable**
  (`$x`/`$$x`) — the options dialog offers no field picker there; a field
  reference written into it is an error at the draft line, because FileMaker
  would take the bare field name over as a variable name on paste. The reverse
  (a variable in a field-only slot) is an error where the option row itself
  classifies the slot (`step_options.slot_kind`, fm_spec 2.2.0) and a warning
  where the classification is only derived from the step aggregate. The same
  knowledge runs through every later phase: the resolver refuses the case as
  finding `R010-slot-form` (nothing is looked up for a variable-only slot; a
  slot without a catalog element that holds a field reference resolves as a
  Field, any other form is warned as unverified — `R011`), the emitter refuses
  a field reference rendered into a text slot, the gate checks the value form
  of every target slot in the XML (`G307-value-form`), and the decompiler marks
  bare text in a target slot as lossy instead of "0 lossy".
- **Decompile:** chrome (`DisableStepCollapsed`, `Restore` on comments) is
  always stripped and noted; editor state (`HiddenStepsCount`, a collapsed
  disabled block) is stripped for the match but reported as a note — the
  emitter never writes it. Under target 26 the 26 form is read as is. Under
  target 22 the 26 form is translated to the 22 form (renames, default
  options) and every **non-default 26 option is lossy** — FileMaker 22 drops
  it on paste. When the target shape does not match, the other coverage's
  shape is tried and the source is reported ("read as FM 22 shape"); values
  that exist only in the other coverage are lossy for the target. A
  localized build writes the `Yes`/`No` window-style attributes of `Go to
Related Record`/`New Window`/`Go to List of Records` in its own language
  (`Ja`/`Nein`, corpus 07 = German 22.0.6/26.0.2): the decompiler reads them
  as the reference state and notes it (`step_constraints`
  `localized_build_defect`; the spellings live in
  `fmgen_lib/read_tolerance.py`, evidence-bound — an unknown spelling stays
  lossy). The FileMaker 26 element/value spellings and the 202 operation
  hoist the decompiler translates for a 22 target are reference rows
  (`coverage_renames`, fm_spec 2.7.0; the module constants remain the
  fallback for an older reference and are kept identical by
  `coverage_resolution_test`). Import Records target fields (`import_field` items) are qualified
  with the step's table occurrence (`Coverage::ID`) so the text form
  resolves on the way back; the resolver applies the same rule to a bare
  item name. A label shared by a mode and a reference (`Using layout:
<Current Layout>` vs `Using layout: "Name" (TO)`) binds by value on
  re-parse. Localized calculations are canonicalized to EN — function
  tokens (`Falls` → `Case`), the Get family as whole forms (`Hole (
Kontoname )` → `Get ( AccountName )`, localized head plus keyword) —
  outside string literals and comments. The text form never drops state:
  an enum whose display is a placeholder of an absent companion
  (`LayoutNameByCalc` without a calc, `ByCalculation` without a calc,
  `SelectedLayout` without a layout) renders explicitly as `destination:
LayoutNameByCalc`, a flag-style boolean in a non-default OFF state as
  `select_all: Off`, a display label the label grammar cannot read (longer
  than 40 characters) as the option key. The decompiler re-parses its own
  rendering; when the positional form would bind a value elsewhere (three
  unlabeled text options behind two positional slots, a label several
  options share) it emits the labeled form (`option_key: value`) and says
  so in a note.
- **Gate:** G106 checks the snippet against the resolved shape of the target
  coverage, including nested elements and attributes (`BlanksLast`,
  `PDFSaveType`, `LightMode`); chrome is tolerated in input. G303b flags
  built-in functions in both directions: younger than the target version
  (`Get ( WindowUUID )` in a 22 file, `functions.origin_version`) and
  retired by it (`SetPersistentData`/`FindPersistentData` against a 26
  target — FileMaker 26 writes `<function missing>`;
  `functions.removed_in_version`, fm_spec 2.2.0; on an older reference the
  retired direction stands down and the message says so).
- **Read residues** (documented, never silent): the FM-generated
  `SaXML/JSONOptions` default formula of `Save a Copy as XML`, `PlatformData`
  of `Print PDF`, a `<Text/>` marker next to a field target, the Step-level
  `Password` of `Print PDF`. Options the SaXML export never carries are
  reference data (`step_constraints` kind `saxml_omission`, scoped per
  coverage, fm_spec 2.7.0): 97 zoom formula, 215 `option` (26), 36/144/245
  auto-open/e-mail, 36 XSLT stylesheet of the XML export (22 export only) —
  they can only be read from a clipboard copy, never from the catalog; the
  decompiler appends a "SaXML export gap" note to such a step for the
  target coverage. (219 `detect_vertical` is a FileMaker 26 option, not a
  gap — the 26 export carries it as a Boolean.)

4. Redelivery warning: pasting twice duplicates the script. Snippet paste can
   only ADD scripts, not edit in place.
5. Verification recommendation: paste, save, copy back to clipboard, diff
   against the generated XML (see `references/paste-semantics.md` §Verify).

Paste path: FileMaker Pro > Scripts panel > paste (Cmd/Ctrl+V). With MBS
installed, `MBS("Clipboard.SetMonitorEnabled"; 1)` enables XML<->clipboard
conversion; without plugins see `references/paste-semantics.md` §Delivery.

### Optional target: fmIDE ActionScript (`fmgen.py actionscript`)

Experimental second emission target (reference schema >= 1.8.0 required —
tables `action_catalog`/`step_action_map`). Two modes:

```bash
fmgen.py actionscript DRAFT.ir.json                 # translate parsed steps
fmgen.py actionscript --wrap-snippet S.xml --script-name "Target"  # delivery wrapper
```

Output JSON payload: `actions` (the interpreter's native JSON array),
`fmjaml` (authoring notation, array forms only), `findings`,
`capability_notes`. Gate: unknown action / registry-only / support=No are
hard errors (G-A01..A03); steps without action mapping or without curated
`param_map` abort deterministically (G-A04/G-A05) — exactly like unknown
step IDs in the snippet path. Values are FM calc expressions (fmIDE
evaluates them); literals must be quoted, the `fmxmlsnippet` parameter is
consumed raw and rendered as an fmJAML heredoc.

Delivery of an ActionScript is OUT of scope of this skill's validation: it
requires a running fmIDE (>= 0.60) in the target file under [Full Access],
macOS + MBS for most IDE actions, `fmurlscript` for the fmp-URL channel —
report `capability_notes` to the user with the artifact. Roundtrip
verification against a live fmIDE is pending; treat the target as
experimental.

## Editing existing scripts

Before touching any existing artifact file, create a backup next to it:
`<name>_backup_<YYYY-MM-DD>_<HH-MM-SS>.xml`. Remember: a re-pasted snippet is
a NEW copy of the script — in-place edits are a future delivery path (fmIDE
ActionScript / FMUpgradeTool), not part of this skill yet.

## References

- `references/paste-semantics.md` — silent-failure and save-invalid catalog,
  delivery/verification recipes (sources incl. andykear spec, CC BY 4.0).
- `references/mbs-guidelines.md` — when (not) to use MBS, object lifecycle,
  path conversion.
- `references/worked-example.md` — full pipeline walkthrough with artifacts.
- Function/step documentation: use the `filemaker-function-reference` and
  `mbs-function-reference` skills; grammar ad hoc via
  `duckdb reference/fm_spec.duckdb -c "..."`.
