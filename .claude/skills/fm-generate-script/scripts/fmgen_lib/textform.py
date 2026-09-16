"""Canonical script text form: normalization (P2) and parsing to IR.

Implements fm-spec script-text-notation v0.1 (rules T1-T8):
  - step name at line start is the only structural anchor (T1), resolved via
    script_step_name_lookup in any of the 11 locales
  - one bracket group, `;`-separated params (T2/T3), quote-/paren-aware
  - named options `Label: value`, positional values map to unlabeled inline
    options in sort_order (T4, data-driven from step_options)
  - `#` comment steps, `// ` disabled prefix (T6)
  - multi-line calculations continue the previous step (T7)
  - unicode hygiene and ASCII operators (T8)
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .db import Reference

# ---------------------------------------------------------------- P2 normalize

_UNICODE_OPS = {"≠": "<>", "≤": "<=", "≥": ">="}
_STRIP_CHARS = "﻿‎‏"  # BOM, LRM, RLM


def normalize_text(text: str) -> tuple[str, list[str]]:
    """Transport hygiene per T8. Returns (normalized, change notes)."""
    notes = []
    for pattern, repl, note in (
        ("\r\n", "\n", "CRLF -> LF"),
        ("\r", "\n", "CR -> LF"),
        (" ", "\n", "U+2028 -> LF"),
        (" ", "\n", "U+2029 -> LF"),
        (" ", " ", "NBSP -> space"),
    ):
        if pattern in text:
            text = text.replace(pattern, repl)
            notes.append(note)
    for ch in _STRIP_CHARS:
        if ch in text:
            text = text.replace(ch, "")
            notes.append(f"stripped U+{ord(ch):04X}")
    # Unicode operators -> ASCII, but never inside string literals.
    if any(ch in text for ch in _UNICODE_OPS):
        text = _replace_outside_strings(text, _UNICODE_OPS)
        notes.append("unicode operators -> ASCII")
    return text, notes


def _replace_outside_strings(text: str, mapping: dict[str, str]) -> str:
    out, in_str, i = [], False, 0
    while i < len(text):
        ch = text[i]
        if in_str and ch == "\\" and i + 1 < len(text):
            out.append(text[i:i + 2]); i += 2; continue
        if ch == '"':
            in_str = not in_str
        out.append(mapping.get(ch, ch) if not in_str else ch)
        i += 1
    return "".join(out)


def strip_strings(text: str) -> str:
    """Replace string-literal contents with spaces (for regex lint rules)."""
    out, in_str, i = [], False, 0
    while i < len(text):
        ch = text[i]
        if in_str and ch == "\\" and i + 1 < len(text):
            out.append("  "); i += 2; continue
        if ch == '"':
            in_str = not in_str
            out.append('"')
        else:
            out.append(" " if in_str else ch)
        i += 1
    return "".join(out)


def strip_comments(text: str) -> str:
    """Replace FileMaker calc comments ('//' to end of line, '/* … */') with
    spaces, length- and line-preserving so match offsets stay valid.

    Comment prose is not code: without this, the multi-word tolerance of CALL_RE
    glues the words in front of a call onto its name ('// liefert die Anzahl'
    followed by 'Get (' reads as the name 'liefert die Anzahl Get'). String
    literals win — a '//' inside a string is text, not a comment — so this pass
    tracks strings itself and must run before strip_strings()."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        ch = text[i]
        if in_str:
            if ch == "\\" and i + 1 < n:
                out.append(text[i:i + 2]); i += 2; continue
            if ch == '"':
                in_str = False
            out.append(ch); i += 1; continue
        if ch == '"':
            in_str = True; out.append(ch); i += 1; continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" "); i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("".join(" " if c != "\n" else "\n" for c in text[i:end]))
            i = end
            continue
        out.append(ch); i += 1
    return "".join(out)


# Function-call anchor for calc scanning: an identifier (optionally a multi-word
# name) immediately before an opening paren. Shared by the lint (arity/locale
# checks) and the resolver (custom-function / unknown-function detection) so both
# agree on what counts as "a function call". Always match on a string- and
# comment-stripped copy so parens inside literals or prose never register as
# calls: strip_strings(strip_comments(calc)).
# The name class must cover every character FileMaker allows in a custom-function
# name, not just ASCII letters: a leading underscore ("_EncodeCR") or a non-ASCII
# letter ("Größe") would otherwise not start a name, and the match would begin
# mid-word ("e (") — a name that resolves against nothing. [^\W\d] is the
# unicode-aware "letter or underscore".
_NAME = r"[^\W\d][\w.]*"
CALL_RE = re.compile(rf"({_NAME}(?:\s{_NAME})*?)\s*\(")

# FileMaker's word operators are spelled with ordinary name characters, so the
# multi-word tolerance of CALL_RE (required for custom functions with spaces,
# e.g. "Check eMail") glues them — and the bare operand in front of them — onto
# the function name: "1 or Get (" reads as the name "or Get", "Kunde::Name and
# Get (" as "Name and Get", and "not ( … )" as the name "not" although the paren
# only groups. call_name_candidates() undoes that gluing.
# The German UI localizes them (Claris help, "Logische Operatoren"); every other
# mirrored language keeps the EN spelling.
WORD_OPERATORS = frozenset({"and", "or", "not", "xor",
                            "und", "oder", "nicht", "xoder"})


def call_name_candidates(token: str) -> list[str]:
    """Function-name candidates for a CALL_RE match, longest first.

    The full token comes first so a custom function whose own name starts with
    an operator word still wins over the split form; each further candidate
    drops everything up to and including one word operator. An empty list means
    the paren groups an expression instead of calling something: nothing can be
    called through an operator, so a token ending in one is not a name.

        "Check eMail"    -> ["Check eMail"]
        "or Get"         -> ["or Get", "Get"]
        "Name and Get"   -> ["Name and Get", "Get"]
        "not"            -> []
        "Summe or"       -> []

    Consumers try the candidates in order against their positive lists and fall
    back to the last (shortest) one for reporting."""
    words = token.split()
    if not words or words[-1].casefold() in WORD_OPERATORS:
        return []
    out = [" ".join(words)]
    for i, w in enumerate(words):
        if w.casefold() in WORD_OPERATORS and i + 1 < len(words):
            cand = " ".join(words[i + 1:])
            if cand not in out:
                out.append(cand)
    return out


def matching_paren(text: str, open_idx: int) -> int:
    """Index of the ')' closing the '(' at open_idx, or -1 when unbalanced.

    Quote-aware: a paren inside a string literal does not count. Together with
    split_args() this turns a CALL_RE match into an argument count — used by the
    lint for built-in arity (L006) and by the resolver for custom-function arity.
    """
    depth, in_str, i = 0, False, open_idx
    while i < len(text):
        ch = text[i]
        if in_str and ch == "\\" and i + 1 < len(text):
            i += 2; continue
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def split_args(argstr: str) -> list[str]:
    """Split an argument list on top-level ';' (quote-, paren- and bracket-aware).

    Empty parts are dropped, so `f ( )` counts as zero arguments — which is what
    both arity checks compare against.
    """
    parts, buf, depth, in_str, i = [], [], 0, False, 0
    while i < len(argstr):
        ch = argstr[i]
        if in_str and ch == "\\" and i + 1 < len(argstr):
            buf.append(argstr[i:i + 2]); i += 2; continue
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            elif ch == ";" and depth == 0:
                parts.append("".join(buf)); buf = []; i += 1; continue
        buf.append(ch)
        i += 1
    if buf:
        parts.append("".join(buf))
    return [p for p in parts if p.strip()]


# ------------------------------------------------------------------- segmenter

@dataclass
class RawStep:
    line: int                       # 1-based line number of the step start
    head: str                       # step-name token as written
    step_id: int | None             # resolved via lookup (None = unknown)
    match_source: str | None
    enabled: bool = True
    is_comment: bool = False
    params_raw: str | None = None   # inside of the bracket group, unsplit
    raw: str = ""                   # full (possibly multi-line) source text
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _scan_state(text: str, depth: int, in_str: bool,
                in_block: bool = False) -> tuple[int, bool, bool]:
    """Advance (bracket depth, inside-string, inside block comment) over text.

    The state decides what counts as a continuation line (T7), so anything that
    is prose rather than code must not move it: a lone '(' or an odd number of
    '"' inside a calc comment would otherwise glue the following line onto this
    step — silently, because a phantom continuation produces no finding.

    Callers pass the line WITHOUT a leading '// ' disable prefix (T6): that
    prefix marks a disabled step, not a comment, and its continuation lines
    carry it too.
    """
    i = 0
    while i < len(text):
        ch = text[i]
        if in_block:
            if text.startswith("*/", i):
                in_block = False; i += 2; continue
            i += 1; continue
        if in_str:
            if ch == "\\" and i + 1 < len(text):
                i += 2; continue
            if ch == '"':
                in_str = False
            i += 1; continue
        if ch == '"':
            in_str = True; i += 1; continue
        if text.startswith("//", i):
            break  # rest of the line is a calc comment
        if text.startswith("/*", i):
            in_block = True; i += 2; continue
        if ch in "[({":
            depth += 1
        elif ch in "])}":
            depth -= 1
        i += 1
    return max(depth, 0), in_str, in_block


def segment(text: str, ref: Reference) -> list[RawStep]:
    lookup = ref.step_name_lookup()
    steps: list[RawStep] = []
    depth, in_str, in_block = 0, False, False

    for lineno, line in enumerate(text.split("\n"), start=1):
        stripped = line.strip()
        # a continuation belongs to the step it continues — capture that step's
        # disabled state before this line possibly appends a new one
        continuing = depth > 0 or in_str or in_block
        prev_disabled = bool(steps) and continuing and not steps[-1].enabled
        match = None
        if stripped and not continuing:
            match = _match_head(stripped, lookup)
        if match is not None:
            head, step_id, source, is_comment = match
            steps.append(RawStep(
                line=lineno, head=head, step_id=step_id, match_source=source,
                enabled=not stripped.startswith("// "), is_comment=is_comment,
                raw=line,
            ))
        elif steps and continuing:
            # genuine continuations (multi-line calcs) always sit inside an
            # open bracket group, string or block comment (T7); at depth 0 an
            # unmatched line is an unknown step, not a continuation
            steps[-1].raw += "\n" + line
            # Structural guard: a continuation that reads like a step name is
            # almost always a swallowed step — the line above left a bracket or
            # a comment open. Silent merges produce no other finding (the gate
            # only ever sees the steps that survived), so say it here. Inside a
            # string literal the same text is just text, so that case is quiet.
            if not in_str and stripped and _match_head(stripped, lookup) is not None:
                steps[-1].warnings.append(
                    f"line {lineno}: '{_ellipsis(stripped, 40)}' reads like a step "
                    f"but continues line {steps[-1].line} — check that line for an "
                    "unclosed bracket, quote or comment")
        elif stripped:
            steps.append(RawStep(
                line=lineno, head=stripped.split("[")[0].strip(), step_id=None,
                match_source=None, raw=line,
                errors=[f"line {lineno}: no known step name at line start"],
            ))

        # A comment step ends hard at the end of its line. Its payload is
        # arbitrary prose: an unbalanced '(' would pull the next line into the
        # comment, an unbalanced '[' the whole rest of the draft — in both
        # cases silently, since a phantom continuation produces no finding.
        if match is not None and match[3]:
            continue
        # The '//' of a disabled step (T6) is a prefix, not a comment — strip it
        # so _scan_state does not read the rest of the line as commented out.
        scan = line
        if (match is not None and stripped.startswith("// ")) or \
                (match is None and prev_disabled and stripped.startswith("//")):
            cut = line.index("//")
            scan = line[:cut] + line[cut + 2:]
        depth, in_str, in_block = _scan_state(scan, depth, in_str, in_block)

    _extract_params(steps)
    return steps


def _match_head(stripped: str, lookup: dict) -> tuple[str, int | None, str | None, bool] | None:
    """Match a step name at line start. Returns (head, step_id, source, is_comment)."""
    body = stripped
    if body.startswith("// "):
        body = body[3:].lstrip()
    if body.startswith("#"):
        return ("#", 89, "comment_shorthand", True)
    head = body.split("[", 1)[0].strip()
    if not head:
        return None
    hit = lookup.get(head.casefold())
    if hit:
        return (head, hit["step_id"], hit["match_source"], hit["step_id"] == 89)
    return None


def _extract_params(steps: list[RawStep]) -> None:
    for st in steps:
        if st.is_comment and st.head == "#":
            # A comment body keeps trailing / whitespace-only content: FileMaker
            # treats "# " (<Text> </Text>) as a state distinct from the empty
            # trenner line (<Step .../>). Only leading indentation and the
            # disabled prefix are structural — lstrip those, then drop exactly
            # one delimiter space after the '#' and keep the rest verbatim.
            body = st.raw.lstrip()
            if not st.enabled and body.startswith("// "):
                body = body[3:].lstrip()
            text = body[1:]
            st.params_raw = text[1:] if text.startswith(" ") else text
            continue
        body = st.raw.strip()
        if not st.enabled and body.startswith("// "):
            body = body[3:].lstrip()
        idx = body.find("[")
        if idx < 0:
            st.params_raw = None
            continue
        if not body.rstrip().endswith("]"):
            st.errors.append(f"line {st.line}: bracket group not closed")
            st.params_raw = body[idx + 1:]
            continue
        st.params_raw = body[idx + 1: body.rstrip().rfind("]")].strip()


def split_params(content: str) -> list[str]:
    """Split a bracket group on top-level `;` (quote-, paren- and bracket-aware, T3)."""
    parts, buf, depth, in_str, i = [], [], 0, False, 0
    while i < len(content):
        ch = content[i]
        if in_str and ch == "\\" and i + 1 < len(content):
            buf.append(content[i:i + 2]); i += 2; continue
        if ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch in "[({":
                depth += 1
            elif ch in "])}":
                depth -= 1
            elif ch == ";" and depth == 0:
                parts.append("".join(buf).strip()); buf = []; i += 1; continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail or parts:
        parts.append(tail)
    return [p for p in parts if p != ""]


# ------------------------------------------------------------- option mapping

_LABEL_RE = re.compile(r"^([^\";:\[\]]{1,40}?):\s+(.*)$", re.S)
_FIELD_REF_RE = re.compile(
    r'^([\wÀ-ɏЀ-ӿ .\-]+)::([\wÀ-ɏЀ-ӿ .\-]+)'
    r'(?:\s*\[\s*(.+?)\s*\])?$', re.S)
_QUOTED_TO_RE = re.compile(r'^"(.*)"\s*\(\s*([^)]+?)\s*\)$', re.S)
_QUOTED_RE = re.compile(r'^"(.*)"$', re.S)
_NEW_RE = re.compile(r"^\{\{NEW:(\w+):(.+)\}\}$", re.S)
# The same declaration INSIDE a calculation, where it marks one token of a
# larger expression instead of the whole parameter value — used for a custom
# function that does not exist in the catalog yet ("create before paste").
# Unanchored on purpose; the resolver strips every match before emission, so a
# marker never reaches FileMaker.
NEW_IN_CALC_RE = re.compile(r"\{\{NEW:(\w+):([^{}]+)\}\}")
# A script-local variable ($x / $$x). Only ever accepted where a step writes
# its result into a target (see _coerce) — never as an object reference.
_VAR_RE = re.compile(r"^\$\$?[A-Za-z_][\w.]*$")


def parse_ref(value: str) -> dict | None:
    """Parse a T5 object reference. Returns dict or None if not reference-shaped.

    `_form` records the surface syntax: 'field' (TO::Field), 'layout'
    ("Name" (TO)), 'named' ("Name").
    """
    value = value.strip()
    m = _NEW_RE.match(value)
    if m:
        inner = parse_ref(m.group(2)) or {"name": m.group(2), "_form": "named"}
        inner["new"] = True
        inner["new_type"] = m.group(1)
        return inner
    m = _FIELD_REF_RE.match(value)
    if m:
        ref = {"table": m.group(1).strip(), "name": m.group(2).strip(), "_form": "field"}
        if m.group(3):
            ref["repetition"] = m.group(3).strip()
        return ref
    m = _QUOTED_TO_RE.match(value)
    if m:
        return {"name": m.group(1), "table": m.group(2).strip(), "_form": "layout"}
    m = _QUOTED_RE.match(value)
    if m:
        return {"name": m.group(1), "_form": "named"}
    return None


def parse_target(value: str) -> dict | None:
    """Parse a TARGET slot: a field reference OR a script-local variable.

    Targets are the one slot kind FileMaker lets you point at a variable
    instead of a field (Set Variable, Show Custom Dialog input fields, ...).
    Shared by _coerce and the step hints so both agree on the rule.
    """
    value = value.strip()
    m = re.match(r"^(\$\$?[A-Za-z_][\w.]*)\s*(?:\[\s*(.+?)\s*\])?$", value)
    if m and _VAR_RE.match(m.group(1)):
        ref = {"name": m.group(1), "_form": "variable"}
        if m.group(2):
            ref["repetition"] = m.group(2)
        return ref
    return parse_ref(value)


def _option_section(xml_path: str) -> str:
    """The container element an option lives in, derived from its xml_path.

    Some steps nest a whole second option group and reuse the outer display
    labels inside it — Perform Script On Server with Callback carries
    'from file:' and 'Parameter' once at the top level and once inside
    <CallbackScript>. The path prefix is the only thing that tells them apart.
    A trailing @attribute does not open a section (CallbackScriptState/@value
    is a top-level element, not a group).
    """
    parts = [p for p in (xml_path or "").split("/") if p and not p.startswith("@")]
    return parts[0] if len(parts) > 1 else ""


def _norm_label(s: str) -> str:
    return re.sub(r"[^0-9a-zA-Z]+", "", s).casefold()


# ------------------------------------------------------------- repeat groups
# script-text-notation v0.2 T9: repeatable group labels collect list values.
# One knowledge source (fm_spec.step_repeat_groups), read by parse, render,
# emit and decompile alike.

_ITEM_PH_RE = re.compile(r"\{([a-z0-9_]+)(?::[a-z_]+)?(?:\|([^{}]*))?\??\}")
_GROUP_SLOT_RE = re.compile(r"\{([a-z0-9_]+)\[\]\}")


def group_item_keys(group: dict) -> list[str]:
    """Flat option keys of a group's item template, in template order."""
    seen: list[str] = []
    for m in _ITEM_PH_RE.finditer(group["item_template"]):
        if m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def group_item_defaults(group: dict) -> dict[str, str]:
    """{flat key: default} for defaulted item placeholders."""
    out = {}
    for m in _ITEM_PH_RE.finditer(group["item_template"]):
        if m.group(2) is not None:
            out.setdefault(m.group(1), m.group(2))
    return out


def group_child_keys(group: dict) -> list[str]:
    """Nested group slots ({key[]}) of the item template."""
    return [m.group(1) for m in _GROUP_SLOT_RE.finditer(group["item_template"])]


# ---------------------------------------------------------- fixed-slot groups
# T9 fixed-slot rule (fm_spec 1.16.0, Show Custom Dialog): a constant number
# of positional slots whose index is semantic (Get(LastMessageChoice)). These
# groups are slot-addressed via numbered extension labels derived from the
# [n] convention in step_options.xml_path — never the bracket/list form, and
# never touched by the list machinery (_instantiate/_extract/top_bracket).

def is_fixed_slot(group: dict) -> bool:
    return bool(group.get("max_items"))


def slot_families(ref: "Reference", step_id: int, group: dict) -> list[dict]:
    """The declared [n]-options of a fixed-slot group, in declared order
    (sort_order): [{opt, head, tail, primary}]. The container is matched by
    the first xml_path segment against the group's container element."""
    container_tag = group["container_path"].split("/")[-1]
    fams = []
    for o in ref.options(step_id):
        path = o.get("xml_path") or ""
        if "[n]" not in path or path.split("/")[0] != container_tag:
            continue
        head, _, tail = o["option_key"].partition("_")
        if not tail:
            continue
        fams.append({"opt": o, "head": head, "tail": tail,
                     "primary": not fams})
    return fams


def slot_key(fam: dict, n: int) -> str:
    """button_label + slot 2 -> button2_label (resolve._instance_keys pattern)."""
    return f"{fam['head']}{n}_{fam['tail']}"


def slot_label(fam: dict, n: int) -> str:
    """Canonical slot label: Head+N for the group's first-declared option
    (Button1, Input2), Head+N+LastSegment for the others (Button1Commit,
    Input1Label, Input1Password)."""
    base = fam["head"].capitalize() + str(n)
    if fam["primary"]:
        return base
    return base + fam["tail"].rpartition("_")[2].capitalize()


def fixed_slot_extras(options: dict, ref: "Reference", step_id: int) -> list[str]:
    """Render (and pop) the slot options of every fixed-slot group as
    extension-label parts, group / slot / declared-option order. Values pass
    verbatim (booleans keep their XML state text) — the parse direction is
    symmetric. Replaces the former 87 reverse hint."""
    extras: list[str] = []
    for g in ref.repeat_groups(step_id):
        if not is_fixed_slot(g) or g.get("parent_group"):
            continue
        fams = slot_families(ref, step_id, g)
        for n in range(1, int(g["max_items"]) + 1):
            for fam in fams:
                val = options.pop(slot_key(fam, n), None)
                if val is None:
                    continue
                rendered = render_ref(val) if isinstance(val, dict) else str(val)
                extras.append(f"{slot_label(fam, n)}: {rendered}")
    return extras


def item_label(group_key: str, flat_key: str) -> str:
    """Canonical item-local label: the flat key minus the group prefix."""
    prefix = group_key + "_"
    return flat_key[len(prefix):] if flat_key.startswith(prefix) else flat_key


@dataclass
class ParsedStep:
    line: int
    step_id: int
    canonical_name: str
    enabled: bool
    options: dict = field(default_factory=dict)
    raw: str = ""
    canonical_text: str = ""
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


_BOOL_STATES = {"on", "off", "true", "false", "yes", "no"}


def parse_step(st: RawStep, ref: Reference) -> ParsedStep:
    canonical = ref.steps().get(st.step_id, {}).get("canonical_name", st.head)
    ps = ParsedStep(line=st.line, step_id=st.step_id, canonical_name=canonical,
                    enabled=st.enabled, raw=st.raw.strip(), errors=list(st.errors),
                    warnings=list(st.warnings))

    if st.step_id == 89:  # comment: single positional text
        # Keep the payload verbatim — a whitespace-only body is an intentional
        # FileMaker state, so it must not be stripped away here. An empty
        # params_raw stays falsy and yields the empty trenner comment.
        if st.params_raw:
            ps.options["text"] = st.params_raw
        ps.canonical_text = render_canonical(ps, ref)
        return ps

    opts = ref.options(st.step_id)
    tpl = (ref.xml_map(st.step_id) or {}).get("snippet_template", "") or ""

    def unsatisfied_required(keys_present) -> list[str]:
        """Required options are only missing when the template holds a
        defaultless placeholder for them (literals / {key|default} self-satisfy)."""
        out = []
        for o in opts:
            if o["required"] and o["option_key"] not in keys_present and re.search(
                    r"\{%s(?::[a-z_]+)?\}" % re.escape(o["option_key"]), tpl):
                out.append(o["option_key"])
        return out

    if st.params_raw is None:
        for key in unsatisfied_required(set()):
            ps.errors.append(
                f"line {st.line}: step '{canonical}' requires option '{key}' "
                "(bracket group missing)")
        ps.canonical_text = render_canonical(ps, ref)
        return ps
    if not opts:
        ps.errors.append(
            f"line {st.line}: step '{canonical}' takes no options but has a bracket group (T2)")
        ps.canonical_text = render_canonical(ps, ref)
        return ps

    params = split_params(st.params_raw)
    params = _apply_pre_implications(ps, params, ref)

    groups = ref.repeat_groups(st.step_id)
    groups_by_key = {g["group_key"]: g for g in groups}
    top_bracket = {_norm_label(g["group_label"]): g for g in groups
                   if g["item_form"] == "bracket" and not g["parent_group"]
                   and not is_fixed_slot(g)}
    scalar_keys = {g["group_key"] for g in groups if g["item_form"] == "scalar"}

    # Fixed-slot groups: numbered slot labels (Button2:, Input1Label:) derived
    # from the [n] convention; the declared [n]-options themselves never bind
    # by label or position — slots are the only address (T9 fixed-slot rule).
    slot_by_label: dict[str, tuple[str, dict]] = {}
    for g in groups:
        if not is_fixed_slot(g):
            continue
        for fam in slot_families(ref, st.step_id, g):
            suffix = fam["tail"].rpartition("_")[2].capitalize()
            for n in range(1, int(g["max_items"]) + 1):
                sk = slot_key(fam, n)
                slot_by_label[_norm_label(slot_label(fam, n))] = (sk, fam["opt"])
                if fam["primary"]:
                    # the long form (Input1Field) stays accepted as input
                    slot_by_label.setdefault(
                        _norm_label(fam["head"].capitalize() + str(n) + suffix),
                        (sk, fam["opt"]))

    def _slotted(o: dict) -> bool:
        return "[n]" in (o.get("xml_path") or "")

    by_label = {}
    label_candidates: dict[str, list[dict]] = {}
    for o in opts:
        if _slotted(o):
            continue
        if o["display_label_en"]:
            by_label[_norm_label(o["display_label_en"])] = o
            label_candidates.setdefault(_norm_label(o["display_label_en"]), []).append(o)
        by_label.setdefault(_norm_label(o["option_key"]), o)
    positional = [o for o in opts
                  if o["display_location"] == "inline" and not o["display_label_en"]
                  and not _slotted(o)]
    inline_all = [o for o in opts if o["display_location"] == "inline"
                  and not _slotted(o)]

    def take_bare_boolean(param: str):
        """Flag-style booleans render as a bare keyword (Sort Records
        'Restore', Insert Text 'Select') — match against true_/false_text."""
        p = param.strip().casefold()
        for o in opts:
            if o["option_type"] != "boolean" or o["option_key"] in ps.options \
                    or _slotted(o):
                continue
            if p and p in ((o["true_text"] or "").casefold(), (o["false_text"] or "").casefold()):
                return o
        return None

    def take_positional(param: str):
        """sort_order is XML order, not display order (e.g. Set Field renders
        target before result but serializes Calculation before Field) — so
        reference-shaped params bind to ref-typed options first."""
        free = [o for o in positional if o["option_key"] not in ps.options]
        # only unambiguous reference syntax (TO::Field, "Name" (TO)) prefers
        # ref-typed options; a bare quoted string is usually a calculation
        r = parse_ref(param) if _LABEL_RE.match(param) is None else None
        is_ref = bool(r) and r.get("_form") in ("field", "layout")
        if not is_ref and _LABEL_RE.match(param) is None:
            # A bare value that belongs to the domain of exactly this kind of
            # free inline enum binds by value, not by position — FileMaker
            # renders inline enums label-free ('Records being browsed',
            # 'Blank record, as formatted'), so position alone is ambiguous
            # against free text options (Tier-1 fixture 22.0.6, step 144).
            v = param.strip().casefold()
            for o in inline_all:
                if o["option_type"] != "enum" or o["option_key"] in ps.options:
                    continue
                for row in ref.option_values(ps.step_id):
                    if row["option_key"] != o["option_key"]:
                        continue
                    if v == (row["display_text_en"] or "").casefold() or v == row["xml_value"].casefold():
                        return o
        if is_ref:
            # ref params may also fill labeled ref options (label often
            # omitted in drafts, e.g. Insert Text 'Target:')
            pool = [o for o in inline_all
                    if o["option_type"] in ("object_ref", "target")
                    and o["option_key"] not in ps.options]
            if pool:
                return pool[0]
        if _LABEL_RE.match(param) is None:
            # Placeholder display (step_option_values.display_text_en =
            # '{key}'): the enum state renders as the VALUE of another option
            # — 97 Set Zoom Level 'ByCalculation' shows the calculation in the
            # zoom slot. A bare value that is not in the enum's own domain
            # binds to that option; the enum state follows by implication.
            for o in free:
                if o["option_type"] != "enum":
                    continue
                for row in ref.option_values(ps.step_id):
                    disp = row["display_text_en"] or ""
                    if row["option_key"] != o["option_key"] or not disp.startswith("{"):
                        continue
                    other = disp.strip("{}")
                    tgt = next((x for x in inline_all if x["option_key"] == other
                                and x["option_key"] not in ps.options), None)
                    if tgt is not None:
                        ps.options[o["option_key"]] = row["xml_value"]
                        return tgt
        if not free:
            # single-free-option fallback: a bare (non-label-shaped) value maps
            # unambiguously when exactly one inline option is still unfilled,
            # even if that option carries a display label — e.g.
            # `Exit Script [ $n ]` == `Exit Script [ Text Result: $n ]`.
            # Label-shaped params stay strict so mistyped/localized labels
            # fail loudly instead of being swallowed as calculation text.
            if _LABEL_RE.match(param) is None:
                free_inline = [o for o in inline_all if o["option_key"] not in ps.options]
                if len(free_inline) == 1:
                    return free_inline[0]
            return None
        pool = [o for o in free if (o["option_type"] in ("object_ref", "target")) == is_ref]
        return (pool or free)[0]

    # Options are read left to right; an option belonging to a nested group
    # opens that section, and a label that exists both inside and outside it
    # binds to the section currently open. A top-level option closes it again,
    # which mirrors how FileMaker renders the step.
    section = ""
    for param in params:
        opt = None
        value = param
        m = _LABEL_RE.match(param)
        if m and _norm_label(m.group(1)) in top_bracket:
            g = top_bracket[_norm_label(m.group(1))]
            item = _parse_group_item(ps, g, m.group(2).strip(), ref, groups_by_key)
            if item is not None:
                ps.options.setdefault(g["group_key"], []).append(item)
            continue
        if m and _norm_label(m.group(1)) in slot_by_label:
            skey, srow = slot_by_label[_norm_label(m.group(1))]
            if skey in ps.options:
                ps.errors.append(f"line {st.line}: option '{skey}' given twice")
                continue
            val = m.group(2).strip()
            if srow["option_type"] in ("object_ref", "target"):
                parsed = (parse_target(val) if srow["option_type"] == "target"
                          else parse_ref(val))
                if parsed is None:
                    ps.errors.append(
                        f"line {st.line}: '{_ellipsis(val)}' is not a valid "
                        f"field or variable for '{skey}'")
                    continue
                ps.options[skey] = parsed
            elif srow["option_type"] == "boolean":
                # coerce like every other boolean: XML state is always
                # True/False; the render direction (fixed_slot_extras) is
                # verbatim only because decompiled XML never carries On/Off
                coerced = _coerce(ps, {**srow, "option_key": skey}, val, ref)
                if coerced is None:
                    continue
                ps.options[skey] = coerced
            else:
                # verbatim — symmetric with fixed_slot_extras' render
                # direction (booleans handled above)
                ps.options[skey] = val
            continue
        if m and _norm_label(m.group(1)) in by_label:
            label = _norm_label(m.group(1))
            cands = label_candidates.get(label, [])
            value = m.group(2).strip()
            if len(cands) > 1:
                scoped = [o for o in cands if _option_section(o["xml_path"]) == section]
                # only an unambiguous hit inside the open section wins; anything
                # else keeps the previous flat behaviour untouched
                opt = scoped[0] if len(scoped) == 1 else by_label[label]
                # An enum and a reference share one label (74/122/228 'Using
                # layout' = layout_destination + layout, mirroring FileMaker's
                # display): a labeled VALUE that is a display text or xml
                # value of the enum candidate belongs to the enum
                # ('<Current Layout>'), anything else to the reference
                # ('"LO - Text" (Coverage)').
                enum_hit = _enum_candidate_for_value(cands, value, ps, ref)
                if enum_hit is not None:
                    opt = enum_hit
                # A flag and its target share one label (242 'Password' =
                # password_enabled + password, 'Save print options to' =
                # flag + target): a labeled VALUE that is no boolean state
                # belongs to the non-boolean candidate.
                if opt["option_type"] == "boolean" and value \
                        and value.casefold() not in _BOOL_STATES \
                        and value.casefold() not in {
                            (opt.get("true_text") or "").casefold(),
                            (opt.get("false_text") or "").casefold()}:
                    non_bool = [o for o in cands if o["option_type"] != "boolean"]
                    if len(non_bool) == 1:
                        opt = non_bool[0]
            else:
                opt = by_label[label]
        else:
            opt = take_bare_boolean(param) or take_positional(param)
        if opt is None:
            ps.errors.append(
                f"line {st.line}: cannot map parameter '{_ellipsis(param)}' "
                f"to an option of '{canonical}'" + _other_coverage_hint(ps, param, m, ref))
            continue
        if opt["option_key"] in ps.options:
            if opt["option_key"] in scalar_keys:
                # T9 scalar repetition: the label of a scalar repeat group may
                # occur any number of times; each occurrence appends one item
                coerced = _coerce(ps, opt, value, ref)
                if coerced is not None:
                    prev = ps.options[opt["option_key"]]
                    if not isinstance(prev, list):
                        ps.options[opt["option_key"]] = [prev]
                    ps.options[opt["option_key"]].append(coerced)
                continue
            ps.errors.append(f"line {st.line}: option '{opt['option_key']}' given twice")
            continue
        section = _option_section(opt["xml_path"])
        coerced = _coerce(ps, opt, value, ref)
        if coerced is not None:
            ps.options[opt["option_key"]] = coerced

    _canonicalize_flat_groups(ps, groups, groups_by_key)
    _apply_post_implications(ps, ref)
    # canonical form: a mirror's read option and a paste-dropped option leave
    # the IR here (fm_spec 2.6.0) — both are reported, never silently lost
    ps.warnings += apply_mirror_rules(ps, ref, canonical=True)
    ps.warnings += apply_paste_dropped(ps, ref, "the canonical form")

    for key in unsatisfied_required(set(ps.options)):
        ps.errors.append(
            f"line {st.line}: required option '{key}' missing for '{canonical}'")

    ps.canonical_text = render_canonical(ps, ref)
    return ps


def _parse_group_item(ps: ParsedStep, group: dict, value: str, ref: Reference,
                      groups_by_key: dict) -> dict | None:
    """Parse one T9 item bracket `[ ... ]` against the group's item options."""
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        ps.errors.append(
            f"line {ps.line}: value of repeat group '{group['group_label']}' "
            f"must be an item bracket [ ... ], got '{_ellipsis(value)}'")
        return None
    inner = value[1:-1].strip()
    parts = split_params(inner)
    if not parts:
        ps.errors.append(
            f"line {ps.line}: empty item for repeat group '{group['group_label']}'")
        return None
    metas = {o["option_key"]: o for o in ref.options(ps.step_id)}
    item_keys = [k for k in group_item_keys(group) if k in metas]
    children = {c: groups_by_key[c] for c in group_child_keys(group)
                if c in groups_by_key}
    child_labels = {_norm_label(groups_by_key[c]["group_label"]): c for c in children}
    item: dict = {}
    for part in parts:
        m = _LABEL_RE.match(part)
        if m:
            label = _norm_label(m.group(1))
            if label in child_labels:
                ck = child_labels[label]
                sub = _parse_group_item(ps, children[ck], m.group(2).strip(),
                                        ref, groups_by_key)
                if sub is not None:
                    item.setdefault(ck, []).append(sub)
                continue
            hit = next((k for k in item_keys
                        if label in (_norm_label(item_label(group["group_key"], k)),
                                     _norm_label(k))), None)
            if hit is None:
                ps.errors.append(
                    f"line {ps.line}: '{m.group(1)}' is not an item option of "
                    f"repeat group '{group['group_label']}'")
                continue
            if hit in item:
                ps.errors.append(
                    f"line {ps.line}: item option '{hit}' given twice in one "
                    f"'{group['group_label']}' item")
                continue
            coerced = _coerce(ps, metas[hit], m.group(2).strip(), ref)
            if coerced is not None:
                item[hit] = coerced
            continue
        # positional inside the item: same T4 rules against the item options
        free = [metas[k] for k in item_keys if k not in item]
        opt = _take_item_positional(ps, part, free, ref)
        if opt is None:
            ps.errors.append(
                f"line {ps.line}: cannot map item parameter '{_ellipsis(part)}' "
                f"in repeat group '{group['group_label']}'")
            continue
        coerced = _coerce(ps, opt, part.strip(), ref)
        if coerced is not None:
            item[opt["option_key"]] = coerced
    if not item:
        return None
    return item


def _take_item_positional(ps: ParsedStep, param: str, free: list[dict],
                          ref: Reference):
    r = parse_ref(param)
    is_ref = bool(r) and r.get("_form") in ("field", "layout")
    if is_ref:
        pool = [o for o in free if o["option_type"] in ("object_ref", "target")]
        if pool:
            return pool[0]
    v = param.strip().casefold()
    for o in free:
        if o["option_type"] != "enum":
            continue
        for row in ref.option_values(ps.step_id):
            if row["option_key"] != o["option_key"]:
                continue
            if v == (row["display_text_en"] or "").casefold() \
                    or v == row["xml_value"].casefold():
                return o
    nonref = [o for o in free if o["option_type"] not in ("object_ref", "target")]
    if len(nonref) == 1:
        return nonref[0]
    if len(free) == 1:
        return free[0]
    return None


def _canonicalize_flat_groups(ps: ParsedStep, groups: list[dict],
                              groups_by_key: dict) -> None:
    """Flat-alias rule (T9): pre-v0.2 flat keys fill item 1 of their group.

    Runs bottom-up (children first) so nested flat keys (criteria_*) land
    inside the parent's item. Mixing flat and group form of the same group in
    one step is an error — the flat keys can only describe ONE item, so their
    meaning next to explicit items would be ambiguous.
    """
    for g in [g for g in groups if g["parent_group"]] + \
             [g for g in groups if not g["parent_group"]]:
        if g["item_form"] != "bracket" or is_fixed_slot(g):
            continue
        flat = [k for k in group_item_keys(g) if k in ps.options]
        child_items = {c: ps.options.pop("__pending_" + c)
                       for c in group_child_keys(g)
                       if "__pending_" + c in ps.options}
        if not flat and not child_items:
            continue
        if g["group_key"] in ps.options and not str(g["group_key"]).startswith("__pending_"):
            ps.errors.append(
                f"line {ps.line}: repeat group '{g['group_label']}' given in "
                "group form and flat form at once — use one form per step")
            for k in flat:
                ps.options.pop(k, None)
            continue
        item = {k: ps.options.pop(k) for k in flat}
        item.update(child_items)
        key = g["group_key"] if not g["parent_group"] else "__pending_" + g["group_key"]
        ps.options[key] = [item]


def _enum_candidate_for_value(cands: list[dict], value: str, ps: ParsedStep,
                              ref: Reference) -> dict | None:
    """Among options sharing one label, the enum whose domain (display text
    or xml value, case-insensitive) contains `value` — None when no enum
    candidate owns the value."""
    v = value.strip().casefold()
    if not v:
        return None
    for o in cands:
        if o["option_type"] != "enum" or o["option_key"] in ps.options:
            continue
        for row in ref.option_values(ps.step_id):
            if row["option_key"] != o["option_key"]:
                continue
            if v == (row["display_text_en"] or "").casefold() \
                    or v == row["xml_value"].casefold():
                return o
    return None


def _coerce(ps: ParsedStep, opt: dict, value: str, ref: Reference):
    kind = opt["option_type"]
    key = opt["option_key"]
    if kind == "boolean":
        true_t = (opt["true_text"] or "On").casefold()
        false_t = (opt["false_text"] or "Off").casefold()
        v = value.strip().casefold()
        state = None
        if v == true_t:
            state = True
        elif v == false_t:
            state = False
        elif v in ("on", "true"):
            state = True
        elif v in ("off", "false"):
            state = False
        if state is None:
            ps.errors.append(f"line {ps.line}: '{value}' is not a valid state for '{key}'")
            return None
        # normative in current reference builds: true_/false_text ARE the display
        # texts that produce XML state True/False — never invert on top
        # (inverted_label is documentary only)
        return "True" if state else "False"
    if kind == "enum":
        rows = [r for r in ref.option_values(ps.step_id) if r["option_key"] == key]
        # display texts first, across ALL states, then xml values: a display
        # text may equal the xml value of another state (35 import_method:
        # 'Update' is the display of UpdateOnMatch and the xml value of the
        # state displayed as 'Replace') — row order must not decide
        for row in rows:
            if row["display_text_en"] and row["display_text_en"].casefold() == value.casefold():
                return row["xml_value"]
        for row in rows:
            if row["xml_value"].casefold() == value.casefold():
                return row["xml_value"]
        ps.errors.append(
            f"line {ps.line}: '{value}' is not a known value for enum '{key}' "
            f"(valid: {', '.join(sorted({r['xml_value'] for r in ref.option_values(ps.step_id) if r['option_key'] == key}))})")
        return None
    if kind in ("object_ref", "target"):
        # A target may be a field OR a script-local variable ($x/$$x); an
        # object_ref always names a catalog object and never takes a variable.
        r = parse_target(value) if kind == "target" else parse_ref(value)
        if r is None:
            ps.errors.append(
                f"line {ps.line}: '{_ellipsis(value)}' is not a valid object reference for '{key}'")
            return None
        return r
    if kind == "text" and len(value) >= 2 \
            and value.startswith('"') and value.endswith('"') \
            and text_needs_quotes(value[1:-1]):
        # decompile wraps text values that would break the notation
        # (separator, brackets, calc-comment openers) in quotes
        # (render_canonical) — unwrap them here, symmetric pair
        return value[1:-1]
    return value  # calculation / text / repetition: verbatim


def text_needs_quotes(value: str) -> bool:
    """A text value is quoted in the text form when it carries the parameter
    separator, a bracket, or a calc-comment opener: `;` would split the
    parameter, `[`/`]` would shift the bracket depth, and `//` or `/*` would
    read as a calculation comment — the line scanner (_scan_state) stops at
    a `//` outside a string and swallows the following steps as
    continuation (find criteria text `// *:*:*`, Perform Find corpus)."""
    return any(t in value for t in (";", "[", "]", "//", "/*"))


def _other_coverage_hint(ps: ParsedStep, param: str, m, ref: Reference) -> str:
    """Suffix for an unmappable parameter whose label or key exists in
    another coverage's rows (S-6 'option needs FileMaker 26'): the shape of
    the target coverage has no slot for it, the other coverage has."""
    try:
        rows = ref.options_any_coverage(ps.step_id)
    except Exception:  # pragma: no cover - diagnostics only
        return ""
    target = ref.target_coverage()
    label = _norm_label(m.group(1)) if m else _norm_label(param.split(":")[0])
    hits = sorted({str(r["coverage"]) for r in rows
                   if str(r["coverage"]) not in ("*", target)
                   and (_norm_label(r.get("display_label_en") or "") == label
                        or _norm_label(r["option_key"]) == label)})
    if not hits:
        return ""
    return (f" — the option exists only in the FileMaker {', '.join(hits)} form "
            f"(target coverage {target}); target a FileMaker {hits[0]} file or drop it")


def _ellipsis(s: str, n: int = 60) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


# ------------------------------------------------------ option implications
# Parse-side implications (fm_spec.step_option_implications, 1.17.0): the
# canonical text form of a few very common steps leaves an option implicit —
# a keyword, a reference form, a mode switch or the mere presence of another
# option implies its value. The facts are data rows; the machinery here is
# generic. 87 Show Custom Dialog needs none of this since fm_spec 1.16.0:
# slot labels derive from the [n] convention, the default OK button and the
# slot padding live in step_repeat_groups (fixed-slot columns).

def _apply_pre_implications(ps: ParsedStep, params: list[str],
                            ref: Reference) -> list[str]:
    """Pre-loop implication kinds — they consume parameters.

    keyword:     a bare parameter equal to the trigger (label-normalized)
                 implies the option value and is consumed.
    mode_switch: the switch label ('Specified: <mode>') is consumed; the
                 matching mode row names the option that unlabeled positional
                 parameters bind to. An object_ref target consumes every
                 reference-shaped bare parameter; a calculation target
                 consumes every bare parameter verbatim. Without the switch
                 label the is_default row's mode applies (dialog default).
    """
    rows = ref.option_implications(ps.step_id)
    if not rows:
        return params
    keywords = [r for r in rows if r["trigger_kind"] == "keyword"]
    switches = [r for r in rows if r["trigger_kind"] == "mode_switch"]
    if keywords:
        rest = []
        for p in params:
            kw = next((r for r in keywords if _LABEL_RE.match(p) is None
                       and _norm_label(p.strip()) == _norm_label(r["trigger"])),
                      None)
            if kw is not None:
                ps.options[kw["implied_option"]] = kw["implied_value"]
            else:
                rest.append(p)
        params = rest
    if not switches:
        return params
    switch_label = switches[0]["trigger"].split(":", 1)[0]
    mode, rest = None, []
    for p in params:
        m = _LABEL_RE.match(p)
        if m and mode is None and _norm_label(m.group(1)) == _norm_label(switch_label):
            mode = m.group(2).strip()
        else:
            rest.append(p)
    if mode is None:
        default = next((r for r in switches if r["is_default"]), None)
        if default is None:
            return rest
        mode = default["trigger"].split(":", 1)[1].strip()
    row = next((r for r in switches
                if _norm_label(r["trigger"].split(":", 1)[1]) == _norm_label(mode)),
               None)
    if row is None:
        return rest
    target = row["implied_option"]
    meta = next((o for o in ref.options(ps.step_id)
                 if o["option_key"] == target), {})
    out = []
    for p in rest:
        if _LABEL_RE.match(p):
            out.append(p)
        elif meta.get("option_type") in ("object_ref", "target"):
            r_ = parse_ref(p)
            if r_ is not None:
                ps.options[target] = r_
            else:
                out.append(p)
        else:
            ps.options[target] = p
    return out


def _apply_post_implications(ps: ParsedStep, ref: Reference) -> None:
    """Post-loop implication kinds — they read the parsed options and never
    override an explicit value.

    option_present: the trigger option being set implies the value
                    (62: duration => pause_time='ForDuration'). Group items
                    carry full option keys, so the same rule applies per
                    item when trigger and implied option live inside a
                    repeat group (39: sort_value_list => sort_type='Custom'
                    within each sort item) — flat-form drafts are collapsed
                    into items before this runs, so the item walk covers
                    both draft forms.
    value_form:     a parsed option holding a reference of the trigger's T5
                    form implies the value (6: layout form =>
                    destination='SelectedLayout').
    """
    for r in ref.option_implications(ps.step_id):
        if r["trigger_kind"] == "option_present":
            if r["trigger"] in ps.options:
                ps.options.setdefault(r["implied_option"], r["implied_value"])
            else:
                for v in ps.options.values():
                    if isinstance(v, list):
                        for item in v:
                            if isinstance(item, dict) and r["trigger"] in item:
                                item.setdefault(r["implied_option"],
                                                r["implied_value"])
        elif r["trigger_kind"] == "value_form":
            if any(isinstance(v, dict) and v.get("_form") == r["trigger"]
                   for v in ps.options.values()):
                ps.options.setdefault(r["implied_option"], r["implied_value"])


def _option_label(ref: Reference, step_id: int, key: str) -> str:
    for o in ref.options(step_id):
        if o["option_key"] == key:
            return o.get("display_label_en") or key
    return key


def apply_mirror_rules(ps: ParsedStep, ref: Reference, canonical: bool) -> list[str]:
    """Mirror rules (step_mirror_elements, fm_spec 2.6.0): FileMaker writes
    the value of a source option a second time at another place of the step
    and keeps both in sync on paste — the source is the truth (144 Save
    Records as PDF: the document title is mirrored as a bare Step-level
    Calculation; paste probe 22.0.6/26.0.2: a title heals its mirror in, a
    pure mirror heals the title in, a divergent mirror is overwritten by the
    title). The read option of the target is the step_options row whose
    xml_path is the target path (title_mirror) — a legacy notation that stays
    readable but never canonical.

    canonical=True (parse side): the read option leaves the IR — a pure mirror
    is read as the source, an equal mirror is redundancy, a divergent mirror
    loses (as it does on paste). Every case is a warning: the draft is not
    canonical, the canonical text carries the source alone.
    canonical=False (emit side, IR that may not have passed parse): the copy
    is materialized — the target takes the source value when unset, a pure
    mirror heals the source in; an explicitly set, divergent target is never
    overwritten (implication doctrine) but reported, because FileMaker will
    overwrite it on paste and the snippet is not canonical.
    Returns the warnings."""
    out: list[str] = []
    for r in ref.mirror_elements(ps.step_id):
        src, tgt = r["source_option"], ref.mirror_target_option(ps.step_id, r["target_path"])
        if tgt is None:
            continue
        sval, tval = ps.options.get(src), ps.options.get(tgt)
        src_label = _option_label(ref, ps.step_id, src)
        if canonical:
            if tval is None:
                continue
            if sval is None:
                ps.options[src] = tval
                out.append(
                    f"line {ps.line}: '{tgt}' is FileMaker's copy of '{src}' ({src_label}) — "
                    f"read as {src_label}: {tval} (FileMaker heals the {src_label.lower()} in "
                    "on paste); write only the source in the canonical form")
            elif str(sval) != str(tval):
                out.append(
                    f"line {ps.line}: '{tgt}' ({tval}) differs from '{src}' ({sval}) — the "
                    f"{src_label.lower()} wins, FileMaker overwrites the mirror on paste; "
                    "the mirror value is discarded, the canonical form carries the source alone")
            else:
                out.append(
                    f"line {ps.line}: '{tgt}' is a derived copy of '{src}' ({src_label}) — "
                    "dropped from the canonical form (the emitter writes it from the source)")
            del ps.options[tgt]
        else:
            if sval is not None and tval is None:
                ps.options[tgt] = sval
            elif sval is None and tval is not None:
                ps.options[src] = tval
                out.append(
                    f"line {ps.line}: '{tgt}' set without '{src}' — the {src_label.lower()} is "
                    "emitted from the mirror (FileMaker heals it in on paste)")
            elif sval is not None and tval is not None and str(sval) != str(tval):
                out.append(
                    f"line {ps.line}: '{tgt}' ({tval}) differs from '{src}' ({sval}) — left as "
                    f"written, but FileMaker overwrites the mirror with the {src_label.lower()} "
                    "on paste; the emitted snippet is not canonical")
    return out


def apply_paste_dropped(ps: ParsedStep, ref: Reference, where: str) -> list[str]:
    """Options FileMaker discards on paste whatever their value
    (step_options.paste_dropped, fm_spec 2.6.0 — 144 appearance): the value
    has no persistence, so it leaves the IR with a warning and never reaches
    `where` (the canonical form on the parse side, the emission on the emit
    side). Returns the warnings."""
    out: list[str] = []
    for key in sorted(ref.paste_dropped_options(ps.step_id)):
        if key not in ps.options:
            continue
        val = ps.options.pop(key)
        out.append(
            f"line {ps.line}: option '{key}' ({val}) of '{ps.canonical_name}' is discarded "
            f"by FileMaker on paste whatever its value — left out of {where} "
            "(fm_spec step_options.paste_dropped)")
    return out


# ------------------------------------------------------------ canonical render

def render_ref(val: dict) -> str:
    form = val.get("_form", "named")
    if form == "variable":
        rep = f' [{val["repetition"]}]' if val.get("repetition") else ""
        return val.get("name", "") + rep
    if form == "field":
        rep = f' [{val["repetition"]}]' if val.get("repetition") else ""
        return f'{val["table"]}::{val["name"]}{rep}'
    if form == "layout":
        return f'"{val["name"]}" ({val["table"]})'
    return f'"{val.get("name", "")}"'


def render_canonical(ps: ParsedStep, ref: Reference | None = None,
                     force_labels: bool = False) -> str:
    """Render the parsed step back to canonical text (T1-T4 spacing; T9 groups).

    force_labels: every top-level option without a display label renders in
    the `option_key: value` extension form instead of positionally — the
    decompiler's fallback when the positional rendering would not re-parse
    into the same options (57 Send Event: three unlabeled inline text options
    behind two positional slots; 181 Get Folder Path: three calc slots)."""
    prefix = "" if ps.enabled else "// "
    if ps.step_id == 89:
        text = ps.options.get("text", "")
        # empty body -> bare '#'; any (whitespace-only) body -> '# ' + body, so
        # the single delimiter space round-trips back to the same payload.
        return f"{prefix}# {text}" if text else f"{prefix}#"
    if not ps.options:
        return prefix + ps.canonical_name
    meta = {}
    if ref is not None:
        meta = {o["option_key"]: o for o in ref.options(ps.step_id)}
    groups_by_key = {g["group_key"]: g for g in
                     (ref.repeat_groups(ps.step_id) if ref is not None else [])}
    parts = []
    for key, val in ps.options.items():
        if isinstance(val, list):
            g = groups_by_key.get(key)
            if g is None:
                # a list without a group declaration cannot be rendered — keep
                # the values visible rather than dropping them silently
                parts += [f"{key}: {render_ref(v) if isinstance(v, dict) else v}"
                          for v in val]
                continue
            if g["item_form"] == "scalar":
                for v in val:
                    part = _render_option_part(ps, key, v, meta.get(key, {}), ref,
                                               force_label=force_labels)
                    if part is not None:
                        parts.append(part)
            else:
                for item in val:
                    parts.append(_render_item(ps, g, item, meta, ref, groups_by_key))
            continue
        part = _render_option_part(ps, key, val, meta.get(key, {}), ref,
                                   force_label=force_labels)
        if part is not None:
            parts.append(part)
    if not parts:
        return prefix + ps.canonical_name
    return f"{prefix}{ps.canonical_name} [ {' ; '.join(parts)} ]"


def _render_item(ps: ParsedStep, group: dict, item: dict, meta: dict,
                 ref: Reference | None, groups_by_key: dict) -> str:
    """One T9 item bracket: short labels, defaults omitted, refs first."""
    defaults = group_item_defaults(group)
    keys = [k for k in group_item_keys(group) if k in item]
    keys.sort(key=lambda k: 0 if isinstance(item[k], dict) else 1)
    out = []
    for k in keys:
        v = item[k]
        if not isinstance(v, dict) and str(v) == defaults.get(k, "\x00"):
            continue
        part = _render_option_part(ps, k, v, dict(meta.get(k, {})), ref)
        if part is None:
            continue
        value_str = render_ref(v) if isinstance(v, dict) else \
            (part.split(": ", 1)[1] if ": " in part else part)
        out.append(f"{item_label(group['group_key'], k)}: {value_str}")
    for ck in group_child_keys(group):
        cg = groups_by_key.get(ck)
        if cg is None:
            continue
        for sub in item.get(ck, []):
            out.append(_render_item(ps, cg, sub, meta, ref, groups_by_key))
    return f"{group['group_label']}: [ {' ; '.join(out)} ]"


def _enum_value_implied(ps: ParsedStep, key: str, val: str, display: str,
                        ref: Reference) -> bool:
    """Is the enum state (key=val) re-derived by the parser from the OTHER
    options of the step, so that rendering it would be redundant?

    Two parse-side sources exist: (1) a placeholder display `{other}` names
    an option — a bare value binding to `other` sets the enum state
    (take_positional, 97 Set Zoom Level 'ByCalculation' via the calculation
    slot); (2) a step_option_implications row implies (key, val) from a
    present option (option_present) or from a reference form (value_form,
    6 layout form => destination='SelectedLayout'). Nothing else implies it
    — an enum state written by FileMaker WITHOUT its companion (corpus 07:
    'LayoutNameByCalc' with no calc, 'ByCalculation' with no calc,
    'SelectedLayout' with no layout, 'ByName' with no window name) would be
    lost in the positional form and must render explicitly."""
    for token in re.findall(r"\{([^{}]+)\}", display):
        if token in ps.options:
            return True
    for r in ref.option_implications(ps.step_id):
        if r["implied_option"] != key or r["implied_value"] != val:
            continue
        if r["trigger_kind"] == "option_present" and r["trigger"] in ps.options:
            return True
        if r["trigger_kind"] == "value_form" and any(
                isinstance(v, dict) and v.get("_form") == r["trigger"]
                for v in ps.options.values()):
            return True
    return False


def _render_option_part(ps: ParsedStep, key: str, val, o: dict,
                        ref: Reference | None, force_label: bool = False) -> str | None:
    """One `Label: value` / bare part — the per-option rendering of T4.

    Explicit `option_key: value` form (parse_step's by_label accepts the
    option key) whenever the display form cannot carry the state back:
    a flag-style boolean in its non-default OFF state, an enum state whose
    display is a placeholder of an absent companion, a display label the
    label grammar cannot read, or (force_label) an unlabeled option whose
    positional slot is ambiguous."""
    if isinstance(val, str) and val == "":
        # an empty value carries no information the text form could hold —
        # the template's empty default reproduces it on emit (131
        # UniversalPathList without a source path)
        return None
    label = o.get("display_label_en")
    if isinstance(val, dict):
        rendered = render_ref(val)
    elif o.get("option_type") == "boolean":
        # true_/false_text map XML state -> display text directly (1.7.0 norm)
        state = val == "True"
        if o.get("true_text") and not o.get("false_text"):
            # Flag-style boolean (no off text): displayed as the bare flag
            # keyword when set — matches FileMaker's rendering and
            # take_bare_boolean's parse direction. The OFF state is present
            # here only when it is NOT the template default (decompile drops
            # defaults): it renders explicitly, otherwise the emit side
            # would restore the default (corpus 07: SelectAll/NoStyle/
            # AppendLineFeed/LimitToWindowsOfCurrentFile state="False").
            if not state:
                return f"{key}: Off"
            return o["true_text"]
        rendered = (o.get("true_text") or "On") if state else (o.get("false_text") or "Off")
    elif o.get("option_type") == "enum":
        # enum states whose display text is another option's value (e.g.
        # Go to Layout destination=SelectedLayout) do not render separately
        # — unless nothing in the step implies them (see _enum_value_implied)
        rows = [r for r in (ref.option_values(ps.step_id) if ref else [])
                if r["option_key"] == key]
        display = next((r["display_text_en"] for r in rows if r["xml_value"] == val), None)
        if display and "{" in display:
            if ref is not None and not _enum_value_implied(ps, key, str(val), display, ref):
                return f"{key}: {val}"
            return None
        if display and sum(1 for r in rows if r["display_text_en"] == display) > 1:
            # one display text for several states (134 'Microsoft Entra ID'
            # = Azure and AzureGroup, 'Custom OAuth' = CustomOauth and
            # CustomOauthGroup): the parser would take the first — the
            # xml value is the only unambiguous spelling (_coerce accepts it)
            display = None
        rendered = display or str(val)
    else:
        rendered = str(val)
        if o.get("option_type") == "text" and text_needs_quotes(rendered):
            # separator, bracket or comment opener would break the re-parse —
            # wrap in quotes; _coerce unwraps (symmetric pair)
            rendered = f'"{rendered}"'
    if label and _LABEL_RE.match(f"{label}: x") is None:
        # a display label the label grammar cannot read back (longer than
        # its limit: 63 'Multiple emails (one for each record in found
        # set)', 66 'Wait for speech completion before continuing') — the
        # option key is the label both directions agree on
        label = key
    if label and force_label and ref is not None and sum(
            1 for o2 in ref.options(ps.step_id)
            if _norm_label(o2.get("display_label_en") or "") == _norm_label(label)) > 1:
        # a display label several options of the step share (63 'Collect
        # addresses across found set' on To/Cc/Bcc): the parser binds it
        # by the section that is open, which the rendering order does not
        # guarantee — under the guard the option key is the label
        label = key
    if not label and (force_label or o.get("display_location") not in (None, "inline")):
        # Hidden/dialog-only options have no positional slot in the text
        # form (T4) — an unlabeled value could never be parsed back. Use
        # the option_key as extension label; parse_step accepts option_key
        # labels via by_label, so both directions stay symmetric.
        label = key
    return f"{label}: {rendered}" if label else rendered
