"""P3 lint rules on the segmented/parsed draft.

Rule catalog:
  L001 unknown step name (with close-match suggestion)
  L002 block balance (If/End If, Loop/End Loop, branch/exit placement)
  L003 $$$ variables
  L004 bare ::Field reference without table occurrence
  L005 bracket group on a step that takes no options
  L006 function arity in calculations (against function_parameters; bracket
       repetition groups are checked per group, see REPEAT_GROUPS)
  L007 localized function names in calculations (canonical EN policy)
  L008 transaction constraints from step_constraints: Commit/Revert inside
       If (save_invalid_nesting), Open/Commit pairing in the same script
       without nesting (requires_pair), Revert only between them
       (requires_parent)
  L009 reference-declared option couplings (step_option_implications)
  L010 value form of a target slot (variable-only / field-only, see
       Reference.slot_kind)
  L011 error-code literal compared with Get ( LastError ) that the FileMaker
       error-code table does not list (warning; web-only codes as info) —
       reference-driven (error_codes, fm_spec >= 2.8.0), skipped with a note
       on older references

Block-step IDs (68/69/70/125, 71/72/73) are universal, locale-independent
FileMaker constants; the reference DB's step_constraints carries the same
semantics as prose and is used for messages.
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field

from .db import Reference
from .textform import (CALL_RE, ParsedStep, RawStep, call_name_candidates,
                       matching_paren, split_args, strip_comments, strip_strings)

IF_OPEN, IF_BRANCH, IF_CLOSE = {68}, {69, 125}, {70}
LOOP_OPEN, LOOP_EXIT, LOOP_CLOSE = {71}, {72}, {73}
# Legacy fallback for a reference without step_constraints rows of kind
# save_invalid_nesting: Commit/Revert Transaction, save-invalid inside If.
# With the rows present every transaction rule is data-driven
# (_transaction_rules) — step ids come from the rows, not from here.
TRANSACTION_FLAT = {206, 207}

_MERGED_HEADS = {"endif": "End If", "elseif": "Else If", "endloop": "End Loop",
                 "exitloopif": "Exit Loop If"}

# Functions whose trailing parameters repeat as bracket groups:
#   JSONSetElement ( json ; [ key ; value ; type ] ; [ … ] … )
#   Substitute     ( text ; [ search ; replace ]  ; [ … ] … )
# The value is the number of elements per group. This is deliberately a closed
# list and deliberately NOT handled inside split_args(): `While`, `Let` and
# `Evaluate` also take bracket groups, but there a group is ONE argument
# (`While ( [ i = 0 ; n = 0 ] ; … )`) — expanding groups generically would turn
# those into false alarms, and split_args() is shared with the resolver's
# custom-function arity check. Verified complete against the Claris help for
# the reference's FileMaker coverage (2025): no other built-in repeats.
REPEAT_GROUPS = {"jsonsetelement": 3, "substitute": 2}


@dataclass
class Finding:
    rule: str
    severity: str  # 'error' | 'warning' | 'info'
    line: int
    message: str

    def as_dict(self) -> dict:
        return self.__dict__


@dataclass
class LintResult:
    findings: list[Finding] = field(default_factory=list)

    def add(self, rule: str, severity: str, line: int, message: str) -> None:
        self.findings.append(Finding(rule, severity, line, message))

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]


def lint(raw_steps: list[RawStep], parsed: list[ParsedStep], ref: Reference) -> LintResult:
    res = LintResult()
    _unknown_steps(raw_steps, ref, res)
    _block_balance(parsed, ref, res)
    _text_rules(parsed, res)
    _calc_rules(parsed, ref, res)
    _option_coupling(parsed, ref, res)
    _slot_form(parsed, ref, res)
    _error_code_literals(parsed, ref, res)
    for ps in parsed:
        for e in ps.errors:
            res.add("PARSE", "error", ps.line, e)
        for w in ps.warnings:
            res.add("PARSE", "warning", ps.line, w)
    return res


def _unknown_steps(raw_steps: list[RawStep], ref: Reference, res: LintResult) -> None:
    names = list(ref.step_name_lookup().keys())
    for st in raw_steps:
        if st.step_id is not None:
            continue
        head = st.head
        merged = _MERGED_HEADS.get(re.sub(r"\s+", "", head).casefold())
        if merged:
            res.add("L001", "error", st.line,
                    f"'{head}' is not a step name — write '{merged}' (two words)")
            continue
        close = difflib.get_close_matches(head.casefold(), names, n=1, cutoff=0.75)
        hint = f" — did you mean '{close[0]}'?" if close else ""
        res.add("L001", "error", st.line, f"unknown step name '{head}'{hint}")


# `Name (id)` — the curation convention step_constraints details use to name
# another step ("Requires closing Commit Transaction (206) in the same script")
_DETAIL_STEP_REF_RE = re.compile(r"\((\d{1,3})\)")


def _transaction_rules(ref: Reference) -> tuple[set[int], list[tuple[int, int, set[int]]]]:
    """Transaction constraints from step_constraints (fm_spec 2.2.0 D-2) —
    step ids from the rows, never from literals:

      save_invalid_nesting -> flat: the step may not sit inside an If block
      requires_pair        -> a row per pair member; the partner is the step
                              the detail names by the `Name (id)` convention
                              and that is itself a requires_pair row
      requires_parent      -> valid only between the pair its detail names

    The reference declares the control-flow blocks the same way (If/End If,
    Loop/End Loop); those pairs stay with L002, which knows their branch
    semantics — only pairs outside the block constants are returned here
    (205 Open <-> 206 Commit Transaction, parent 207 Revert). A pair's OPENER
    is its lower id: FileMaker numbers a step family in dialog order and the
    reference carries no role column. Rows absent (older reference): the flat
    check falls back to the legacy constant, pair checks stand down.
    Returns (flat, [(opener, closer, steps that need the pair as parent)])."""
    rows = ref.constraints() if ref.grammar_available() else []
    flat = {int(c["step_id"]) for c in rows if c.get("constraint_kind") == "save_invalid_nesting"}
    if not flat:
        flat = set(TRANSACTION_FLAT)
    pair_rows = {int(c["step_id"]): c.get("detail") or ""
                 for c in rows if c.get("constraint_kind") == "requires_pair"}
    pairs: dict[frozenset, tuple[int, int]] = {}
    for sid, detail in pair_rows.items():
        partner = next((int(x) for x in _DETAIL_STEP_REF_RE.findall(detail)
                        if int(x) in pair_rows and int(x) != sid), None)
        if partner is not None:
            pairs[frozenset((sid, partner))] = (min(sid, partner), max(sid, partner))
    block_steps = IF_OPEN | IF_CLOSE | LOOP_OPEN | LOOP_CLOSE
    out: list[tuple[int, int, set[int]]] = []
    for members, (opener, closer) in pairs.items():
        if members & block_steps:
            continue
        parents = {
            int(c["step_id"]) for c in rows
            if c.get("constraint_kind") == "requires_parent"
            and {int(x) for x in _DETAIL_STEP_REF_RE.findall(c.get("detail") or "")} & members
        }
        out.append((opener, closer, parents))
    return flat, sorted(out)


def _block_balance(parsed: list[ParsedStep], ref: Reference, res: LintResult) -> None:
    stack: list[tuple[str, int]] = []  # (kind, line)
    flat, pairs = _transaction_rules(ref)
    names = {sid: r["canonical_name"] for sid, r in ref.steps().items()}
    open_lines: dict[int, int] = {}  # opener id -> line of the open pair
    for ps in parsed:
        if not ps.enabled:
            continue
        sid = ps.step_id
        if sid in IF_OPEN:
            stack.append(("if", ps.line))
        elif sid in LOOP_OPEN:
            stack.append(("loop", ps.line))
        elif sid in IF_BRANCH:
            if not any(k == "if" for k, _ in stack) or stack[-1][0] != "if":
                res.add("L002", "error", ps.line,
                        f"'{ps.canonical_name}' outside an open If block")
        elif sid in LOOP_EXIT:
            if not any(k == "loop" for k, _ in stack):
                res.add("L002", "error", ps.line, "'Exit Loop If' outside a Loop block")
        elif sid in IF_CLOSE:
            if stack and stack[-1][0] == "if":
                stack.pop()
            else:
                res.add("L002", "error", ps.line, "'End If' without matching 'If'")
        elif sid in LOOP_CLOSE:
            if stack and stack[-1][0] == "loop":
                stack.pop()
            else:
                res.add("L002", "error", ps.line, "'End Loop' without matching 'Loop'")
        if sid in flat and any(k == "if" for k, _ in stack):
            res.add("L008", "error", ps.line,
                    f"'{ps.canonical_name}' inside an If block — pastes cleanly but the "
                    "file fails to save (step_constraints: save_invalid_nesting); "
                    "branch to a flat commit instead")
        for opener, closer, parents in pairs:
            if sid == opener:
                if opener in open_lines:
                    res.add("L008", "error", ps.line,
                            f"'{ps.canonical_name}' inside an open '{names.get(opener)}' — "
                            "the pair does not nest; the file fails to save "
                            "(step_constraints: requires_pair)")
                else:
                    open_lines[opener] = ps.line
            elif sid == closer:
                if opener not in open_lines:
                    res.add("L008", "error", ps.line,
                            f"'{ps.canonical_name}' without a preceding '{names.get(opener)}' — "
                            "pastes, then the file fails to save (step_constraints: requires_pair)")
                else:
                    del open_lines[opener]
            elif sid in parents and opener not in open_lines:
                res.add("L008", "error", ps.line,
                        f"'{ps.canonical_name}' outside an open transaction — valid only between "
                        f"'{names.get(opener)}' and '{names.get(closer)}'; the file fails to save "
                        "(step_constraints: requires_parent)")
    for kind, line in stack:
        block = "If" if kind == "if" else "Loop"
        res.add("L002", "error", line, f"'{block}' opened here is never closed")
    for opener, closer, _parents in pairs:
        if opener in open_lines:
            res.add("L008", "error", open_lines[opener],
                    f"'{names.get(opener)}' opened here is never closed — a "
                    f"'{names.get(closer)}' in the same script is required; the file fails "
                    "to save (step_constraints: requires_pair)")


def _text_rules(parsed: list[ParsedStep], res: LintResult) -> None:
    for ps in parsed:
        code = strip_strings(ps.raw)
        if "$$$" in code:
            res.add("L003", "error", ps.line,
                    "'$$$' is not a valid variable prefix ($ local, $$ global)")
        for m in re.finditer(r"(?<![\w.\"])::\s*[\w]", code):
            res.add("L004", "error", ps.line,
                    "bare '::Field' reference — always qualify with a table occurrence (T5)")


def _option_coupling(parsed: list[ParsedStep], ref: Reference, res: LintResult) -> None:
    """L009 — option-on-option couplings, entirely data-driven since fm_spec
    2.2.0 (step_option_implications, trigger_kind 'requires_option'): the last
    code constant (web-script parameters ⇒ web viewer + function name, an
    emission-prune case) became reference rows for 214/220 in that release."""
    for ps in parsed:
        if not ps.step_id:
            continue
        _implied_requirements(ps, ref, res)


def _ref_label(val: dict) -> str:
    name = val.get("name") or "?"
    table = val.get("table")
    return f"{table}::{name}" if table else str(name)


def _slot_form(parsed: list[ParsedStep], ref: Reference, res: LintResult) -> None:
    """L010 — the VALUE FORM a target slot accepts (Reference.slot_kind).

    A slot serialized as element text carries a name and nothing else: a field
    reference written there loses table and id, and FileMaker takes the bare
    leaf name over as a variable name without a diagnostic (paste-verified,
    FileMaker 26.0.2). The emitter refuses that (emit._lookup_value), but the
    draft line is where the author can see it, so the same knowledge is
    applied one phase earlier.

    Severities follow the evidence:
      * `variable_only` — hard error. Claris help, both SaXML corpora, the
        FileMaker options dialog (no field picker) and the paste probe agree.
      * `field_only` — error where the OPTION ROW classifies the slot
        (`step_options.slot_kind`, fm_spec 2.2.0); where the value is only
        derived from the step aggregate (`step_xml_map.target_slot_kind`,
        curated for the emitter's form switch, not as a validity statement)
        it degrades to a warning."""
    for ps in parsed:
        if not ps.step_id:
            continue
        labels = None
        for key, val in ps.options.items():
            if not isinstance(val, dict) or not val.get("_form"):
                continue
            kind = ref.slot_kind(ps.step_id, key)
            if kind not in ("variable_only", "field_only"):
                continue
            form = val.get("_form")
            if labels is None:
                labels = {o["option_key"]: (o["display_label_en"] or o["option_key"])
                          for o in ref.options(ps.step_id)}
            slot = f"'{key}' ({labels.get(key, key)})"
            if kind == "variable_only" and form != "variable":
                res.add("L010", "error", ps.line,
                        f"'{_ref_label(val)}' must be a variable ($x/$$x) for {slot}"
                        " — FileMaker offers no field there and would store the"
                        " name as a variable name")
            elif kind == "field_only" and form == "variable":
                curated = ref.slot_kind_curated(ps.step_id, key)
                res.add("L010", "error" if curated else "warning", ps.line,
                        f"'{_ref_label(val)}' is a variable, but {slot} takes a field"
                        " reference (TableOccurrence::Field)"
                        + ("" if curated else " — derived from the step's target slot"
                           " kind, not curated per option"))


def _is_set(value) -> bool:
    """An option counts as set when it carries a value; a boolean flag that
    was written switched off ('False') requires nothing."""
    if value is None or value == "":
        return False
    if isinstance(value, str) and value == "False":
        return False
    return True


def _implied_requirements(ps: ParsedStep, ref: Reference, res: LintResult) -> None:
    """Reference-declared option-on-option couplings (step_option_implications,
    trigger_kind 'requires_option', direction 'lint'): a set flag or a mode
    value that is worthless without its counterpart — FileMaker drops it
    silently on paste (242 print-options flags => their targets, 244/246
    From=Target => source container, 245 Save to=Target => target container).
    The trigger is 'option_key' (set, and not a switched-off flag) or
    'option_key: xml_value' (the enum holds exactly that value). Reported as
    L009 error so the pipeline stops before emission; never restored."""
    rows = [r for r in ref.option_implications(ps.step_id)
            if r["trigger_kind"] == "requires_option"]
    if not rows:
        return
    labels = {o["option_key"]: (o["display_label_en"] or o["option_key"])
              for o in ref.options(ps.step_id)}
    for r in rows:
        key, _, value = r["trigger"].partition(": ")
        if key not in ps.options:
            continue
        have = ps.options[key]
        if value:
            if not (isinstance(have, str) and have.casefold() == value.casefold()):
                continue
            what = f"'{labels.get(key, key)}: {value}'"
        else:
            if not _is_set(have):
                continue
            what = f"the '{labels.get(key, key)}' flag ({key})"
        need = r["implied_option"]
        if _is_set(ps.options.get(need)):
            continue
        res.add("L009", "error", ps.line,
                f"{what} requires '{need}' — add '{labels.get(need, need)}: …';"
                " FileMaker drops the flag or mode without its counterpart"
                " silently on paste (reference implication)")


def _calc_options(ps: ParsedStep, ref: Reference) -> list[str]:
    calcs = []
    for o in ref.options(ps.step_id) if ps.step_id else []:
        if o["option_type"] in ("calculation", "repetition") and o["option_key"] in ps.options:
            v = ps.options[o["option_key"]]
            if isinstance(v, str):
                calcs.append(v)
    return calcs


def _calc_rules(parsed: list[ParsedStep], ref: Reference, res: LintResult) -> None:
    flookup = ref.function_lookup()
    arity = ref.function_arity()
    for ps in parsed:
        for calc in _calc_options(ps, ref):
            # Both passes are length-preserving, so offsets stay valid — and
            # arguments are counted on the stripped copy too: a ';' inside a
            # calc comment would otherwise be read as an argument separator,
            # and a comment in front of a repetition group would hide the '['
            # that identifies it (real code puts both there, confirmed by a
            # corpus sweep).
            stripped = strip_strings(strip_comments(calc))
            for m in CALL_RE.finditer(stripped):
                # a leading word operator is part of the match, not of the name
                # ("1 or Left (") — without the split the arity/locale checks
                # below would silently skip every such call
                token, hit = None, None
                for cand in call_name_candidates(m.group(1)):
                    hit = flookup.get(cand.casefold())
                    if hit is not None:
                        token = cand
                        break
                if hit is None:
                    continue  # custom/plugin functions are the resolver's job
                fn = arity.get(hit["function_id"])
                if fn is None:
                    continue
                if hit["match_source"].startswith("display_") and hit["match_source"] != "display_en" \
                        and token.casefold() != fn["canonical_name"].casefold():
                    res.add("L007", "warning", ps.line,
                            f"localized function name '{token}' — use canonical EN "
                            f"'{fn['canonical_name']}' in generated calcs "
                            "(registry convention: FM calc function-name locale)")
                close = matching_paren(stripped, m.end() - 1)
                if close < 0:
                    continue
                args = split_args(stripped[m.end():close])
                lo, hi = fn["min_args"], fn["max_args"]
                if lo == 0 and hi == 0:
                    # The reference declares no parameters at all for this
                    # function — either it genuinely takes none (those are
                    # written without parentheses and never reach here) or the
                    # parameter data is missing. Nothing to compare against, so
                    # the check stands down instead of reporting every call as
                    # 'expects 0' (mirror of the resolver's cf_arity_usable).
                    continue
                if _repetition_arity(fn, args, ps, res):
                    continue
                if len(args) < lo or (hi is not None and len(args) > hi):
                    span = f"{lo}" if hi == lo else (f"{lo}+" if hi is None else f"{lo}-{hi}")
                    res.add("L006", "error", ps.line,
                            f"'{fn['canonical_name']}' expects {span} argument(s), "
                            f"got {len(args)}")


# Get ( LastError ) compared with a numeric literal. Calc text reaches the lint
# canonicalized (EN function names, `Get` keyword) — the EN form is enough; the
# resolver's localized-name pass (L007) handles the rest. Reversed comparisons
# and Case/Choose forms stay out of scope on purpose (rare, and a false positive
# there costs more than the miss).
_LASTERROR_LITERAL_RE = re.compile(
    r"(?i)\bGet\s*\(\s*LastError\s*\)\s*(?:=|≠|<>|<=|>=|≤|≥|<|>)\s*(-?\d+)")


def _error_code_literals(parsed: list[ParsedStep], ref: Reference, res: LintResult) -> None:
    """L011 — numeric literals compared with Get ( LastError ) are checked
    against the FileMaker error-code table (Reference.error_codes, spans
    code_from..code_to). Unknown code → warning (the branch can never match a
    FileMaker error: a typo, a plug-in code or a custom code outside
    5000-5499); a code only the web publishing engine / REST API returns →
    info (right in a web context, unreachable in a client script). No gate,
    no emission change. Older references have no table: rule skipped, one
    note per run."""
    codes = None
    noted = False
    for ps in parsed:
        for calc in _calc_options(ps, ref):
            stripped = strip_strings(strip_comments(calc))
            for m in _LASTERROR_LITERAL_RE.finditer(stripped):
                if codes is None:
                    codes = ref.error_codes()
                    if codes is None:
                        if not noted:
                            res.add("L011", "info", ps.line,
                                    "error-code literal not checked — the reference carries no "
                                    "error_codes table (fm_spec < 2.8.0)")
                            noted = True
                        return
                n = int(m.group(1))
                row = next((c for c in codes if c["code_from"] <= n <= c["code_to"]), None)
                if row is None:
                    res.add("L011", "warning", ps.line,
                            f"Get ( LastError ) is compared with {n}, a code the FileMaker "
                            "error-code table does not list — a typo, a plug-in code, or a "
                            "custom code outside 5000-5499")
                elif row["scope"] == "web":
                    res.add("L011", "info", ps.line,
                            f"Get ( LastError ) is compared with {n} ({row['message_en']}) — "
                            "a code returned only by the web publishing engine or a FileMaker "
                            "REST API; unreachable in a client-side script")


def _repetition_arity(fn: dict, args: list[str], ps: ParsedStep, res: LintResult) -> bool:
    """Check a call written in FileMaker's bracket-repetition syntax.

    Returns True when the call uses that syntax (and was checked here), so the
    caller skips the flat min/max comparison — the reference only carries the
    base-form arity, which every repetition beyond the base form exceeds.

    Checked instead: the leading arguments before the first group, and that
    every group has exactly the group size. `n` groups stay unbounded, which is
    what FileMaker allows.
    """
    size = REPEAT_GROUPS.get(fn["canonical_name"].casefold())
    if not size:
        return False
    groups = [a.strip() for a in args if a.strip().startswith("[") and a.strip().endswith("]")]
    if not groups:
        return False  # base form — the ordinary min/max check applies
    base = fn["min_args"] - size
    plain = len(args) - len(groups)
    if plain != base:
        res.add("L006", "error", ps.line,
                f"'{fn['canonical_name']}' expects {base} argument(s) before the "
                f"first repetition group, got {plain}")
    for i, g in enumerate(groups, start=1):
        n = len(split_args(g[1:-1]))
        if n != size:
            res.add("L006", "error", ps.line,
                    f"'{fn['canonical_name']}' repetition group {i} has {n} "
                    f"element(s), expected {size}")
    return True
