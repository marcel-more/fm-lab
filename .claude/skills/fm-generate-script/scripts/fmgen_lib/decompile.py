"""Reverse direction: fmxmlsnippet XML -> IR -> canonical text.

Table-driven inversion of emit.py: the same snippet templates from
fm_spec.step_xml_map are matched AGAINST actual step XML, extracting the
placeholder values back into ParsedStep options; render_canonical() then
produces the text form. One knowledge source, both directions.

Lossiness contract: anything the template cannot account for (unknown step
ids, missing templates, literal mismatches, extra elements/attributes) marks
the step as lossy and emits a `# fmgen:unsupported …` comment line above the
best-effort text (or instead of it when nothing renders). Nothing is dropped
silently.
"""

from __future__ import annotations

import copy
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from .db import Database, Reference
from .resolve import _xmlpath_element  # one element mapping for both directions
from .read_tolerance import (NOTE_PREFIX as _FM26_NOTE, apply_fm26_read_tolerance,
                             boolean_literal_domain, read_boolean_state, strip_chrome)
from .textform import (ParsedStep, fixed_slot_extras, group_child_keys,
                       group_item_defaults, group_item_keys, is_fixed_slot,
                       parse_step, render_canonical, render_ref, segment,
                       slot_families, slot_key, strip_comments, strip_strings)

# One placeholder as the complete attribute value / element text:
# {key}, {key|default}, {key:sub}, {key:sub?}
_PH_RE = re.compile(r"^\{([a-z0-9_]+)(?::([a-z_]+))?(?:\|([^{}]*))?(\?)?\}$")

# Presentational block indentation (T7) — incomplete on purpose, cosmetic only.
_BLOCK_OPEN = {"If", "Loop"}
_VAR_TEXT_RE = re.compile(r"^\$\$?[A-Za-z_][\w.]*$")
_BLOCK_CLOSE = {"End If", "End Loop"}
_BLOCK_MID = {"Else", "Else If"}


@dataclass
class DecompiledStep:
    index: int
    step_id: int | None
    canonical_name: str | None
    enabled: bool = True
    text: str | None = None
    issues: list[str] = field(default_factory=list)
    """Lossy findings — anything here means information was NOT carried over."""
    notes: list[str] = field(default_factory=list)
    """Non-lossy transformations (e.g. calc canonicalization DE → EN)."""

    @property
    def lossy(self) -> bool:
        return bool(self.issues)


@dataclass
class DecompileResult:
    text: str = ""
    steps: list[DecompiledStep] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def lossy_count(self) -> int:
        return len([s for s in self.steps if s.lossy])

    @property
    def fm26_normalized_count(self) -> int:
        """Steps whose FileMaker 26 clipboard form was read through the
        read-tolerance rules (see read_tolerance.py) — informational."""
        return len([s for s in self.steps
                    if any(n.startswith(_FM26_NOTE) for n in s.notes)])


class _Extractor:
    """Collects option values / reference parts while matching one step.

    `bool_domain` (Reference.bool_domain) names the boolean options whose
    attribute takes a curated value domain (xml_true/xml_false, fm_spec
    2.2.0): their attribute values — and their template defaults, so the
    default omission compares like with like — are read into the internal
    state True/False. A localized-build spelling (`Ja`/`Nein`, registered as
    step_constraints localized_build_defect) is a tolerance note; a value
    that is no boolean state at all stays a lossy finding."""

    def __init__(self, bool_domain: dict[str, tuple[str, str]] | None = None) -> None:
        self.options: dict = {}
        self.refparts: dict[str, dict] = {}
        self.defaults: dict[str, str] = {}
        self.issues: list[str] = []
        self.notes: list[str] = []
        self.bool_domain = bool_domain or {}

    def set_scalar(self, key: str, value: str, default: str | None) -> None:
        domain = self.bool_domain.get(key)
        if domain:
            value = self._domain_state(key, value, domain, is_default=False)
            if default is not None:
                default = self._domain_state(key, default, domain, is_default=True)
        self.options[key] = value
        if default is not None:
            self.defaults[key] = default

    def _domain_state(self, key: str, value: str, domain: tuple[str, str],
                      is_default: bool) -> str:
        state = read_boolean_state(value, domain)
        if state is None:
            if not is_default:
                self.issues.append(
                    f"'{key}': '{value}' is no boolean state of this attribute "
                    f"(domain {domain[0]}/{domain[1]})")
            return value
        if not is_default and value not in domain:
            self.notes.append(
                f"'{key}': localized-build spelling '{value}' read as "
                f"{domain[0] if state else domain[1]} (step_constraints localized_build_defect)")
        return "True" if state else "False"

    def set_refpart(self, key: str, sub: str, value: str) -> None:
        self.refparts.setdefault(key, {})[sub] = value


def _ref_placeholder_keys(elem: ET.Element) -> set[str]:
    keys = set()
    for v in elem.attrib.values():
        m = _PH_RE.match(v.strip())
        if m and m.group(2):
            keys.add(m.group(1))
    return keys


_REF_ATTRS = ("table", "id", "name", "repetition")


def _text_form_field_ref(tpl: ET.Element, act: ET.Element) -> str | None:
    """Key of a field-or-variable target whose template encodes only the
    variable form (``<Field>{target}</Field>``) while the instance carries
    the FIELD form (``<Field table id name/>``) — the read counterpart of
    emit._expand_field_targets. Returns the option key or None."""
    if act.tag != "Field" or tpl.attrib or not act.attrib or len(act):
        return None
    m = _PH_RE.match((tpl.text or "").strip())
    if not m or m.group(2) or (act.text or "").strip():
        return None
    if not set(act.attrib) <= set(_REF_ATTRS):
        return None
    return m.group(1)


def _same_boolean_literal(template_value: str, actual_value: str) -> bool:
    """A literal boolean attribute of the template and the actual value
    denote the same state in another spelling (localized build)."""
    domain = boolean_literal_domain(template_value)
    if domain is None:
        return False
    return read_boolean_state(actual_value, domain) == read_boolean_state(template_value, domain)


def _match(tpl: ET.Element, act: ET.Element, ex: _Extractor) -> None:
    field_key = _text_form_field_ref(tpl, act)
    if field_key is not None:
        for k in _REF_ATTRS:
            if k in act.attrib:
                ex.set_refpart(field_key, k, act.attrib[k])
        return
    # --- attributes ---
    for k, tv in tpl.attrib.items():
        m = _PH_RE.match(tv.strip())
        av = act.attrib.get(k)
        if m:
            key, sub, default, _opt = m.groups()
            if av is None:
                continue  # pruned / optional attribute
            if sub:
                ex.set_refpart(key, sub, av)
            else:
                ex.set_scalar(key, av, default)
        else:
            # `name` on the Step root is display data (localized in non-EN
            # exports) — the id attribute is authoritative.
            if av is None:
                ex.issues.append(f"<{act.tag}> misses attribute '{k}'")
            elif av != tv and not (act.tag == "Step" and k in ("enable", "name")):
                if _same_boolean_literal(tv, av):
                    # a literal boolean attribute of the template (228
                    # NewWndStyles Close="Yes") written by a localized build
                    # in its own spelling (Ja) — same state, tolerance note
                    ex.notes.append(
                        f"<{act.tag}> attribute '{k}': localized-build spelling "
                        f"'{av}' read as '{tv}'")
                else:
                    ex.issues.append(
                        f"<{act.tag}> attribute '{k}': expected '{tv}', found '{av}'")
    for k in act.attrib:
        if k not in tpl.attrib and not (act.tag == "Step" and k == "enable"):
            ex.issues.append(f"<{act.tag}> has unexpected attribute '{k}'")

    # --- element text ---
    ttext = (tpl.text or "").strip()
    raw = act.text or ""
    atext = raw.strip() if "\n" in raw else raw  # mirror of the serializer rule
    m = _PH_RE.match(ttext) if ttext else None
    ref_keys = _ref_placeholder_keys(tpl)
    if m:
        key, sub, default, _opt = m.groups()
        if sub:
            ex.set_refpart(key, sub, atext)
        else:
            ex.set_scalar(key, atext, default)
    elif ttext:
        if atext != ttext:
            ex.issues.append(
                f"<{act.tag}> text: expected '{ttext}', found '{atext.strip()}'")
    elif atext.strip():
        tpl_attr_names = set(tpl.attrib)
        if ref_keys and all(k in tpl_attr_names for k in act.attrib):
            # Variable collapse (see emit._collapse_variable_targets): the
            # template's reference attributes were replaced by plain text.
            # A repetition attribute may survive alongside the variable
            # (<Field repetition="3">$var</Field>, Tier-2 22.0.6).
            key = next(iter(ref_keys))
            ex.refparts.setdefault(key, {})["name"] = atext.strip()
            ex.refparts[key]["_form"] = "variable"
            if act.attrib.get("repetition"):
                ex.refparts[key]["repetition"] = act.attrib["repetition"]
        else:
            ex.issues.append(f"<{act.tag}> has unexpected text content")

    # --- children (pair by tag, in order) ---
    achildren = list(act)
    used = [False] * len(achildren)

    def _literals_match(tc: ET.Element, a: ET.Element) -> bool:
        """Same-tag siblings are disambiguated by their literal (non-
        placeholder) attributes — 220 has <Field type="Messages"> and
        <Field type="ToolCalls"> side by side (Tier-2 22.0.6)."""
        for k, tv in tc.attrib.items():
            if _PH_RE.match(tv.strip()):
                continue
            if a.attrib.get(k) not in (None, tv):
                return False
        return True

    for tc in list(tpl):
        ai = next(
            (i for i, a in enumerate(achildren)
             if not used[i] and a.tag == tc.tag and _literals_match(tc, a)),
            None,
        )
        if ai is None:
            continue  # pruned in the actual XML — option absent
        used[ai] = True
        _match(tc, achildren[ai], ex)
    for i, a in enumerate(achildren):
        if not used[i]:
            ex.issues.append(f"<{act.tag}> has unexpected element <{a.tag}>")


def _finish_refs(ex: _Extractor, catalog: Database | None, file: str | None) -> None:
    for key, parts in ex.refparts.items():
        form = parts.pop("_form", None)
        if form == "variable":
            ref = {"name": parts.get("name", ""), "_form": "variable"}
            if parts.get("repetition"):
                ref["repetition"] = parts["repetition"]
            ex.options[key] = ref
            continue
        ref: dict = {"name": parts.get("name", ""), "_form": "named"}
        if parts.get("table"):
            ref["table"] = parts["table"]
            ref["_form"] = "field"
        if parts.get("repetition"):
            ref["repetition"] = parts["repetition"]
        if parts.get("id"):
            ref["id"] = parts["id"]
        if "comment" in parts:
            # informational attribute of a base-table reference (182); never
            # part of the text form, restored by the resolver from the catalog
            ref["comment"] = parts["comment"]
        if ref["_form"] == "named" and key == "layout":
            table = _layout_to(catalog, file, ref.get("name", ""))
            if table:
                ref["table"] = table
                ref["_form"] = "layout"
            else:
                ex.issues.append(
                    f"layout '{ref.get('name', '')}': table occurrence unknown "
                    "(no catalog match) — reference rendered name-only")
        ex.options[key] = ref


def _layout_to(catalog: Database | None, file: str | None, name: str) -> str | None:
    if catalog is None or not name:
        return None
    esc = name.replace("'", "''")
    clause = f" AND File_Name = '{file.replace(chr(39), chr(39) * 2)}'" if file else ""
    try:
        rows = catalog.query(
            f"SELECT L_TO_Name FROM Layouts WHERE L_Name = '{esc}'{clause} LIMIT 2")
    except Exception:
        return None
    if len(rows) == 1 and rows[0].get("L_TO_Name"):
        return rows[0]["L_TO_Name"]
    return None


# -------------------------------------------------- calc canonicalization
# Localized exports carry localized calc function names in the XML
# (`SQLAusführen`, `Hole ( LetzteFehlerNr )`). fmgen requires canonical EN
# calcs, so decompilation rewrites function-call tokens and Get-parameters
# via the reference lookups — deterministic, string-literal-safe, and
# comment-safe (a function name quoted in `/* … */` prose is not a call).
#
# Three passes, each on a string- and comment-stripped scan copy with the
# offsets applied to the real text:
#   1. function-call tokens (`Falls (` → `Case (`) via function_name_lookup
#      roles function/getfunction — the Get family is NOT a token there,
#      the reference stores it as whole forms (`Hole ( AktivesFeldInhalt )`,
#      `Get(ActiveFieldContents)`) whose function row carries the canonical
#      keyword as canonical_name (`ActiveFieldContents`);
#   2. Get whole forms: `<head> ( <keyword> )` matched against those rows —
#      hit: both head and keyword rewritten from the function row; no hit
#      but a localized head (`Hole`, `Obtenir` — the heads of the display_*
#      getfunction rows): head → `Get`, keyword left for pass 3;
#   3. `Get ( <localized keyword> )` via the getparameter rows (mixed
#      spellings, `Hole ( LayoutName )`).
# Spacing is the writer's — only the tokens are replaced.

_GET_PARAM_RE = re.compile(r"\bGet\s*\(\s*([^\W\d][\w]*)\s*\)")
_GET_FORM_RE = re.compile(r"\b([^\W\d][\w]*)\s*\(\s*([^\W\d][\w]*)\s*\)")

# Unicode-aware variant of textform.CALL_RE — localized function names carry
# umlauts/accents (`SQLAusführen`), which the ASCII identifier class misses.
_CALL_TOKEN_RE = re.compile(r"([^\W\d][\w.]*(?:[ ][^\W\d][\w.]*)*?)\s*\(")

_GET_HEAD = "Get"


def _localized_get_heads(lookup: dict[str, dict]) -> set[str]:
    """Casefolded Get heads other than `Get` (`hole`, `obtenir`), taken from
    the display_* whole forms — engine aliases (`Letzte ( … )`) are not heads
    of the Get family and stay out."""
    heads = set()
    for key, hit in lookup.items():
        if hit["chunk_role"] != "getfunction" or not hit["match_source"].startswith("display_"):
            continue
        head = key.split("(", 1)[0].strip()
        if head and head != _GET_HEAD.casefold():
            heads.add(head)
    return heads


def _apply(text: str, repls: list[tuple[int, int, str]]) -> str:
    for start, end, repl in sorted(repls, reverse=True):
        text = text[:start] + repl + text[end:]
    return text


def canonicalize_calc(text: str, ref: Reference) -> tuple[str, list[str]]:
    notes: list[str] = []
    lookup = ref.function_lookup()
    arity = ref.function_arity()

    # pass 1 — function-call tokens
    stripped = strip_strings(strip_comments(text))
    repls: list[tuple[int, int, str]] = []
    for m in _CALL_TOKEN_RE.finditer(stripped):
        token = m.group(1)
        hit = lookup.get(token.casefold())
        if not hit:
            continue
        canonical = (arity.get(hit["function_id"]) or {}).get("canonical_name")
        if canonical and canonical != token:
            repls.append((m.start(1), m.end(1), canonical))
            notes.append(f"{token} → {canonical}")
    text = _apply(text, repls)

    # pass 2 — Get whole forms and localized heads
    heads = _localized_get_heads(lookup)
    stripped = strip_strings(strip_comments(text))
    repls = []
    for m in _GET_FORM_RE.finditer(stripped):
        head, keyword = m.group(1), m.group(2)
        hit = lookup.get(f"{head} ( {keyword} )".casefold()) \
            or lookup.get(f"{head}({keyword})".casefold())
        if hit and hit["chunk_role"] == "getfunction":
            canonical = (arity.get(hit["function_id"]) or {}).get("canonical_name")
            if canonical and (head != _GET_HEAD or keyword != canonical):
                repls.append((m.start(1), m.end(1), _GET_HEAD))
                repls.append((m.start(2), m.end(2), canonical))
                notes.append(f"{head} ( {keyword} ) → Get ( {canonical} )")
            continue
        if head.casefold() in heads:
            repls.append((m.start(1), m.end(1), _GET_HEAD))
            notes.append(f"{head} ( {keyword} ) → Get ( {keyword} )")
    text = _apply(text, repls)

    # pass 3 — Get keywords in a localized spelling
    getparams = ref.get_parameter_lookup()
    stripped = strip_strings(strip_comments(text))
    repls = []
    for m in _GET_PARAM_RE.finditer(stripped):
        token = m.group(1)
        canonical = getparams.get(token.casefold())
        if canonical and canonical != token:
            repls.append((m.start(1), m.end(1), canonical))
            notes.append(f"Get ( {token} ) → Get ( {canonical} )")
    text = _apply(text, repls)

    return text, notes


# ------------------------------------------------------------ reparse guard
# The positional text form is the canonical one, but position is ambiguous
# when a step carries more unlabeled inline options than positional slots
# (57 Send Event: TargetName/class/id behind file_path/text; 181 Get Folder
# Path: three calculation slots; 87 Show Custom Dialog: Message alone reads
# as Title). The decompiler is the only writer that knows the true option
# set, so it re-parses its own rendering and, if the parser would bind any
# value elsewhere, falls back to the labeled extension form (option_key:
# value) — the form parse_step accepts for every option.

def _option_shape(options: dict) -> dict:
    """Comparable projection of an option dict: references reduce to name /
    table / repetition (the parser never sees ids), lists item-wise; empty
    values are not rendered and therefore not compared."""
    def norm(v):
        if isinstance(v, dict):
            parts = {k: str(x) for k, x in v.items()
                     if k in ("name", "table", "repetition") and x not in (None, "")}
            if set(parts) <= {"name"}:
                # a bare name (variable target `$v`, named ref) — the
                # decompiler keeps text-form targets as plain strings, the
                # parser wraps them; both mean the same name
                return parts.get("name", "")
            return tuple(sorted(parts.items()))
        if isinstance(v, list):
            return tuple(norm(x) for x in v)
        return str(v)
    return {k: norm(v) for k, v in options.items() if v not in ("", None)}


def _reparse_guard(ps: ParsedStep, text: str, ref: Reference) -> tuple[str, str | None]:
    """(text to emit, note) — the positional rendering when it re-parses to
    the same options, otherwise the labeled rendering. Every decompiled
    option must come back under its own key with its value; options the
    parser ADDS (implications) are not a mis-parse."""
    try:
        raws = segment(text, ref)
        if len(raws) != 1:
            return text, None
        back = parse_step(raws[0], ref)
    except Exception:  # noqa: BLE001 — a parser failure is the lossy path below
        return text, None
    want, got = _option_shape(ps.options), _option_shape(back.options)
    if not back.errors and all(got.get(k) == v for k, v in want.items()):
        return text, None
    labeled = render_canonical(ps, ref, force_labels=True)
    if labeled == text:
        return text, None
    return labeled, ("text form: the positional rendering would not re-parse "
                     "to the same options — labeled form used")


# --------------------------------------------------- direction-bound defaults
# Dialog-only options (T4 excludes them from the plain text form) render as
# extension labels the parse side reads back (`Button2: …`, `Input1: …`);
# injected defaults are dropped so they do not surface as phantom parameters.

def _drop_default_slot_items(options: dict, ref: Reference, step_id: int,
                             tpl: ET.Element) -> None:
    """Direction-dependent default at item level (T9 fixed-slot rule): when a
    fixed-slot group carries exactly its default item in slot 1 and nothing in
    any other slot, that item is FileMaker's injected default (87: the OK
    commit button) — the canonical text omits it and the emit side re-injects
    it. Dropping it in any other constellation would lose FileMaker's commit
    button and shift every Get(LastMessageChoice) by one, so the condition is
    strict: sole slot, values equal to the default item's extraction."""
    for g in ref.repeat_groups(step_id):
        if not is_fixed_slot(g) or not g.get("default_item_template"):
            continue
        fams = slot_families(ref, step_id, g)
        if not fams:
            continue
        n_max = int(g["max_items"])
        per_slot = {
            n: {slot_key(f, n): options[slot_key(f, n)]
                for f in fams if slot_key(f, n) in options}
            for n in range(1, n_max + 1)
        }
        if not per_slot[1] or any(per_slot[n] for n in range(2, n_max + 1)):
            continue
        container_tpl = tpl.find(g["container_path"])
        if container_tpl is None:
            continue
        try:
            default_item = ET.fromstring(g["default_item_template"])
        except ET.ParseError:
            continue
        slots_tpl = [c for c in container_tpl if c.tag == default_item.tag]
        if not slots_tpl:
            continue
        ex = _Extractor(ref.bool_domain(step_id))
        _match(slots_tpl[0], default_item, ex)
        default_vals = {k: v for k, v in ex.options.items()
                        if str(v) != ex.defaults.get(k, "\x00")}
        if per_slot[1] == default_vals:
            for k in per_slot[1]:
                options.pop(k, None)


def _qualify_item_fields(options: dict, ref: Reference, step_id: int,
                         notes: list[str]) -> None:
    """A repeat-group Field item carries no table of its own (35 import_field:
    `<Field id name/>` under the step's `<Table>`), so the extracted reference
    is a bare name — the text form needs the TO-qualified form (`Coverage::ID`)
    to resolve on the way back. The table occurrence is the step's single
    top-level Table reference; mirror of resolve.Resolver._step_table_ref."""
    meta = {o["option_key"]: o for o in ref.options(step_id)}
    tables = [o for o in meta.values()
              if o["option_type"] == "object_ref"
              and _xmlpath_element(o["xml_path"]) == "Table"
              and "/" not in (o["xml_path"] or "")]
    if len(tables) != 1:
        return
    tref = options.get(tables[0]["option_key"])
    tname = (tref.get("table") or tref.get("name")) if isinstance(tref, dict) else None
    if not tname:
        return
    by_key = {g["group_key"]: g for g in ref.repeat_groups(step_id)}

    def walk(items: list) -> int:
        n = 0
        for item in items:
            if not isinstance(item, dict):
                continue
            for k, v in item.items():
                if k in by_key and isinstance(v, list):
                    n += walk(v)
                    continue
                o = meta.get(k)
                if (o and o["option_type"] in ("object_ref", "target")
                        and _xmlpath_element(o["xml_path"]) == "Field"
                        and isinstance(v, dict) and v.get("_form") == "named"
                        and not v.get("table") and v.get("name")):
                    v["table"] = tname
                    v["_form"] = "field"
                    n += 1
        return n

    for g in by_key.values():
        if g["parent_group"]:
            continue
        items = options.get(g["group_key"])
        if isinstance(items, list):
            n = walk(items)
            if n:
                notes.append(f"{n} '{g['group_label']}' field item(s) qualified with "
                             f"the step's table occurrence '{tname}'")


def _consume_text_marker(act: ET.Element) -> None:
    """Consume the empty <Text/> marker of a variable-target-marker step
    (step_xml_map.variable_target_marker, fm_spec 1.17.0 — one knowledge
    source with emit._inject_text_marker) before template matching — the
    templates carry no Text element; the emit side re-injects it for
    variable-form targets. Consumed ONLY when a variable target is present:
    a marker next to a plain field target (not derivable from any catalog
    state) stays and surfaces as a lossy finding instead of being silently
    dropped."""
    has_var = any(
        e.tag not in ("Text", "Calculation") and (e.text or "").lstrip().startswith("$")
        for e in act.iter()
    )
    if not has_var:
        return
    for child in list(act):
        if (child.tag == "Text" and not child.attrib and len(child) == 0
                and not (child.text or "").strip()):
            act.remove(child)
            return


# ------------------------------------------------------------- repeat groups
# T9 inversion: the items of a declared group are matched one by one against
# the group's item template ({#index} compared literally per position) and
# collected into a list; the matched children are consumed so the main
# template match sees the container in its pruned single-exemplar shape.
# Anything beyond the item template stays a lossy finding — never a silent cut.

def _item_root_tag(g: dict) -> str:
    m = re.match(r"<([A-Za-z][A-Za-z0-9]*)", g["item_template"])
    return m.group(1) if m else ""


def _extract_repeat_groups(act: ET.Element, ref: Reference, step_id: int,
                           catalog: Database | None, file: str | None,
                           issues: list[str], notes: list[str]) -> dict:
    groups = ref.repeat_groups(step_id)
    if not groups:
        return {}
    by_key = {g["group_key"]: g for g in groups}
    out: dict = {}
    for g in groups:
        if g["parent_group"]:
            continue
        if is_fixed_slot(g):
            continue  # fixed-slot groups: the numbered main template extracts
                      # the slots; empty hulls dissolve via default omission
        container = act.find(g["container_path"])
        if container is None:
            continue
        items = _extract_items(g, container, by_key, ref, step_id,
                               catalog, file, issues, notes)
        if items is None or not items:
            continue
        if g["count_attr"]:
            declared = container.attrib.pop(g["count_attr"], None)
            if declared is not None and declared != str(len(items)):
                issues.append(
                    f"<{container.tag}> {g['count_attr']}='{declared}' does not "
                    f"match {len(items)} item(s)")
        if g["item_form"] == "scalar":
            vals = [item[g["group_key"]] for item in items if g["group_key"] in item]
            if not vals:
                continue
            out[g["group_key"]] = vals[0] if len(vals) == 1 else vals
        else:
            out[g["group_key"]] = items
    return out


def _extract_items(g: dict, container: ET.Element, by_key: dict, ref: Reference,
                   step_id: int, catalog: Database | None, file: str | None,
                   issues: list[str], notes: list[str]) -> list[dict] | None:
    item_tag = _item_root_tag(g)
    children = [c for c in container if c.tag == item_tag]
    if not children:
        return None
    meta = {o["option_key"]: o for o in ref.options(step_id)}
    defaults = group_item_defaults(g)
    items: list[dict] = []
    for i, child in enumerate(children):
        tpl_str = g["item_template"].replace("{#index}", str(i))
        try:
            tpl = ET.fromstring(tpl_str)
        except ET.ParseError as e:
            issues.append(f"item template of group '{g['group_key']}' not well-formed: {e}")
            return None
        item: dict = {}
        # nested slots first: extract + consume the child group's items
        for ck in group_child_keys(g):
            cg = by_key.get(ck)
            slot = next((e for e in tpl.iter()
                         if (e.text or "").strip() == "{%s[]}" % ck), None)
            if slot is None or cg is None:
                continue
            slot.text = None
            subs = _extract_items(cg, child, by_key, ref, step_id,
                                  catalog, file, issues, notes)
            if subs:
                item[ck] = subs
        ex = _Extractor(ref.bool_domain(step_id))
        _match(tpl, child, ex)
        _finish_refs(ex, catalog, file)
        for msg in ex.issues:
            issues.append(f"{g['group_label']} item {i + 1}: {msg}")
        notes.extend(ex.notes)
        # per-item default omission (canonical form drops item defaults, T9)
        for k, v in list(ex.options.items()):
            if not isinstance(v, dict) and str(v) == defaults.get(k, "\x00"):
                del ex.options[k]
        # empty object references: identity-less refs carry no information
        for k, v in list(ex.options.items()):
            if isinstance(v, dict) and not (v.get("name") or "").strip() \
                    and v.get("_form") != "variable":
                del ex.options[k]
        # calc canonicalization per item (localized exports)
        for k, v in list(ex.options.items()):
            o = meta.get(k)
            if isinstance(v, str) and o and o.get("option_type") in ("calculation", "repetition"):
                fixed, cnotes = canonicalize_calc(v, ref)
                if cnotes:
                    ex.options[k] = fixed
                    notes.extend(cnotes)
        item.update(ex.options)
        if item:
            items.append(item)
        container_or_child_consumed = True
    for child in children:
        container.remove(child)
    return items


# ------------------------------------------------------------- known FM bugs
# The bug registry in fm_spec.step_constraints (since 1.14.4) records
# documented FileMaker serialization defects. On the decompile side they are
# epistemic warnings about the INPUT — a clipboard snippet may already have
# lost a slot before fmgen ever saw it — so they surface as notes (never
# issues: the step is valid, the risk lies with FileMaker's serializer).
# The emit side deliberately does NOT warn: fmgen's own emission writes the
# full form and pastes intact (221: the snippet carries TemplateName), so a
# warning there would point the wrong way.

def _append_known_bug_notes(ds: DecompiledStep, ref: Reference, step_id: int) -> None:
    # The kind -> lead-text mapping lives in fm_spec.constraint_kinds
    # (consumer_note, since 1.17.0); only the bug-registry kinds carry one.
    kinds = ref.constraint_kinds()
    target = ref.target_coverage()
    for c in ref.constraints():
        if c["step_id"] != step_id:
            continue
        suffix = kinds.get(c["constraint_kind"])
        if suffix is None:
            continue
        # coverage-scoped rows (fm_spec 2.7.0: saxml_omission) speak about
        # ONE coverage's serialization — only the target's rows apply
        row_cov = str(c.get("coverage") or "*")
        if row_cov not in ("*", target):
            continue
        detail = (c.get("detail") or "").split(". ")[0].strip()
        if len(detail) > 160:
            detail = detail[:157] + "…"
        version = c.get("verified_version") or "?"
        if c["constraint_kind"] == "saxml_omission":
            # an export gap, not a defect of the snippet: the clipboard form
            # is complete, a catalog built from the SaXML export is not
            scope = "every SaXML version" if row_cov == "*" else f"the FM {row_cov} export"
            ds.notes.append(
                f"SaXML export gap (saxml_omission, {scope}, verified {version}): "
                f"{detail} — {suffix}")
            continue
        ds.notes.append(
            f"known FM bug ({c['constraint_kind']}, verified {version}): "
            f"{detail} — {suffix}")


def _display_order(options: dict, ref: Reference, step_id: int) -> dict:
    """Canonical display order differs from XML order (emit docstring):
    references/targets first, then unlabeled, then labeled options —
    each group in sort_order."""
    meta = {o["option_key"]: o for o in ref.options(step_id)}
    group_keys = {g["group_key"] for g in ref.repeat_groups(step_id)}
    position = {k: i for i, k in enumerate(options)}

    def rank(key: str) -> tuple:
        if key in group_keys and isinstance(options.get(key), list):
            return (3, position[key])
        o = meta.get(key, {})
        if o.get("option_type") in ("object_ref", "target"):
            group = 0
        elif not o.get("display_label_en"):
            group = 1
        else:
            group = 2
        sort_order = o.get("sort_order")
        return (group, 99 if sort_order is None else sort_order)

    return {k: options[k] for k in sorted(options, key=rank)}


_ALT_REFS: dict[tuple[int, str], Reference] = {}


def _alt_reference(ref: Reference, coverage: str) -> Reference:
    """A Reference on the same database resolved for another coverage
    (cached per process) — used to try the other shape of a step."""
    key = (id(ref.db), str(coverage))
    if key not in _ALT_REFS:
        _ALT_REFS[key] = Reference(ref.db, str(coverage))
    return _ALT_REFS[key]


def _extract_shape(ref: Reference, act: ET.Element, step_id: int,
                   catalog: Database | None, file: str | None):
    """Match one step instance (a private copy) against the shape of `ref`'s
    target coverage. Returns None when the step has no template, an error
    string when the template is malformed, else a dict with the extractor,
    group options, template, xml_map row, issues and notes."""
    xmap = ref.xml_map(step_id)
    template = (xmap or {}).get("snippet_template")
    if not template:
        return None
    try:
        tpl = ET.fromstring(template)
    except ET.ParseError as e:
        return f"reference template not well-formed: {e}"
    inst = copy.deepcopy(act)
    issues: list[str] = []
    notes: list[str] = []
    if (xmap or {}).get("variable_target_marker"):
        _consume_text_marker(inst)
    group_opts = _extract_repeat_groups(inst, ref, step_id, catalog, file, issues, notes)
    ex = _Extractor(ref.bool_domain(step_id))
    _match(tpl, inst, ex)
    _finish_refs(ex, catalog, file)
    return {"xmap": xmap, "tpl": tpl, "ex": ex, "group_opts": group_opts,
            "issues": issues + ex.issues, "notes": notes + ex.notes}


def decompile_step(
    act: ET.Element,
    index: int,
    ref: Reference,
    catalog: Database | None,
    file: str | None,
) -> DecompiledStep:
    raw_id = act.attrib.get("id")
    name_attr = act.attrib.get("name", "?")
    enabled = act.attrib.get("enable", "True") != "False"
    try:
        step_id = int(raw_id) if raw_id is not None else None
    except ValueError:
        step_id = None

    ds = DecompiledStep(index=index, step_id=step_id, canonical_name=None, enabled=enabled)
    if step_id is None or step_id not in ref.steps():
        ds.issues.append(f"unknown step id '{raw_id}' (name '{name_attr}')")
        return ds
    ds.canonical_name = ref.steps()[step_id]["canonical_name"]

    # Shape detection (coverage-aware, S-4): the instance is read against the
    # TARGET coverage's shape first. Chrome and editor state are stripped for
    # any target; for target 22 the FileMaker 26 forms are additionally
    # translated to the 22 form (read_tolerance) so the 22 information is
    # read and non-default 26 options surface as lossy. When the target
    # shape does not match cleanly, the OTHER coverage's shape is tried on
    # the untranslated instance; the better match wins and is reported as a
    # note ('read as FM 22 shape'). Values that exist only in the other
    # coverage are lossy for the target (FileMaker 22 drops them on paste).
    cov = ref.target_coverage()
    raw = copy.deepcopy(act)
    strip_chrome(raw, step_id, ref.coverage_rules())
    ds.notes += apply_fm26_read_tolerance(act, step_id, cov, ref.coverage_rules(),
                                          ref.coverage_renames())

    prim = _extract_shape(ref, act, step_id, catalog, file)
    if prim is None:
        ds.issues.append("no snippet template in the reference (not table-driven)")
        return ds
    if isinstance(prim, str):
        ds.issues.append(prim)
        return ds
    chosen, alt_cov = prim, None
    if prim["issues"]:
        for other in ref.known_coverages():
            if other == cov:
                continue
            alt = _extract_shape(_alt_reference(ref, other), raw, step_id, catalog, file)
            if isinstance(alt, dict) and len(alt["issues"]) < len(chosen["issues"]):
                chosen, alt_cov = alt, other
    if alt_cov is not None:
        ds.notes.append(f"{_FM26_NOTE}: read as FM {alt_cov} shape (target coverage {cov})")
        known_keys = {o["option_key"] for o in ref.options(step_id)}
        known_keys |= {g["group_key"] for g in ref.repeat_groups(step_id)}

        def _known(key: str) -> bool:
            # fixed-slot keys (button1_label) carry the slot index; the
            # reference declares the family once (button_label)
            return key in known_keys or re.sub(r"^([a-z]+)\d+_", r"\1_", key) in known_keys

        for key in list(chosen["ex"].options):
            if not _known(key):
                ds.issues.append(
                    f"option '{key}' exists only in the FileMaker {alt_cov} form — "
                    f"not carried to target coverage {cov} (FileMaker {cov} drops it on paste)")
                del chosen["ex"].options[key]
        for key in list(chosen["group_opts"]):
            if not _known(key):
                ds.issues.append(
                    f"option '{key}' exists only in the FileMaker {alt_cov} form — "
                    f"not carried to target coverage {cov}")
                del chosen["group_opts"][key]
    ex, group_opts, tpl, xmap = chosen["ex"], chosen["group_opts"], chosen["tpl"], chosen["xmap"]
    ds.issues += chosen["issues"]
    ds.notes += chosen["notes"]

    # Value form of a target slot read as element text: a variable ($x/$$x)
    # is the only legitimate text there — anything else is a name FileMaker
    # already stores as a variable (paste-verified 26.0.2) or a field written
    # without its identity. Lossy, never "0 lossy" (fm_spec 2.2.0 slot_kind).
    for o in ref.options(step_id):
        if o["option_type"] != "target":
            continue
        val = ex.options.get(o["option_key"])
        if isinstance(val, str) and val.strip() and not _VAR_TEXT_RE.match(val.strip()):
            kind = ref.slot_kind(step_id, o["option_key"])
            ds.issues.append(
                f"'{o['option_key']}': text '{val.strip()}' is neither a variable "
                "($x/$$x) nor a field reference"
                + (" — the slot takes a variable only" if kind == "variable_only" else "")
                + "; FileMaker stores such a name as a variable")

    # Default omission — only for options the display does not show inline
    # (repetitions, dialog-only states): their default value carries no
    # information. Inline options keep their value even at the default —
    # FileMaker always displays them (`Set Error Capture [ On ]`). A
    # flag-style boolean (true_text without false_text) is the exception
    # among inline options: FileMaker shows nothing for its OFF state, so an
    # OFF at the template default carries no information either — while an
    # OFF that differs from the default (14 SelectAll, 48 NoStyle, 192
    # AppendLineFeed, 121 LimitToWindowsOfCurrentFile: template True,
    # instance False) is real state and renders explicitly (`select_all:
    # Off`, textform._render_option_part). The ON state stays even at the
    # default — FileMaker displays the flag keyword (`Select`).
    meta = {o["option_key"]: o for o in ref.options(step_id)}
    field_or_var = (xmap or {}).get("target_slot_kind") == "field_or_var"

    def _flag(o: dict | None) -> bool:
        return bool(o and o.get("option_type") == "boolean"
                    and o.get("true_text") and not o.get("false_text"))

    for key, default in ex.defaults.items():
        o = meta.get(key)
        if (
            key in ex.options
            and ex.options[key] == default
            and (o is None or o.get("display_location") != "inline"
                 or (_flag(o) and ex.options[key] == "False"))
            # a target's repetition on a field-or-variable step is emitted only
            # when set (emit._settle_literal_text_marker) — keep it explicit so
            # an instance that carries it round-trips byte-true
            and not (field_or_var and o is not None
                     and o.get("option_type") == "repetition")
        ):
            del ex.options[key]

    # Empty object references: FileMaker emits reference elements with empty
    # identity (213 <Table id="0" name=""/> in DataTable mode with no table
    # selected) — an extracted ref without a name is no reference; the emit
    # side reconstructs the empty form from template defaults.
    for key, val in list(ex.options.items()):
        if isinstance(val, dict) and not (val.get("name") or "").strip() \
                and val.get("_form") != "variable":
            del ex.options[key]

    # Presence booleans (see emit._fix_presence_booleans): the template's
    # element-text placeholder extracts '' from the empty present element —
    # normalize to the boolean state True.
    for key, val in list(ex.options.items()):
        o = meta.get(key)
        if (o and o.get("option_type") == "boolean"
                and "/@" not in (o.get("xml_path") or "") and val == ""):
            ex.options[key] = "True"

    # Calc canonicalization (localized exports): calculation-typed options
    # rewrite localized function / Get-parameter names to canonical EN.
    for key, val in list(ex.options.items()):
        o = meta.get(key)
        if isinstance(val, str) and o and o.get("option_type") in ("calculation", "repetition"):
            fixed, notes = canonicalize_calc(val, ref)
            if notes:
                ex.options[key] = fixed
                ds.notes += notes

    # Mirror elements (step_mirror_elements, fm_spec 2.6.0): the second copy
    # FileMaker writes of a source value is redundancy, never information —
    # equal to the source it is dropped, a pure mirror is read as the source
    # (FileMaker heals the source in on paste), a divergence is reported: the
    # source wins, FileMaker overwrites the mirror on paste (144 title,
    # paste probe 22.0.6/26.0.2). The text form carries the source alone.
    for r in ref.mirror_elements(step_id):
        tgt = ref.mirror_target_option(step_id, r["target_path"])
        if tgt is None or tgt not in ex.options:
            continue
        src = r["source_option"]
        tval = ex.options.pop(tgt)
        sval = ex.options.get(src)
        if sval is None:
            ex.options[src] = tval
            ds.notes.append(f"'{tgt}' read as '{src}' — a pure mirror; FileMaker heals "
                            f"the {src} in on paste")
        elif str(sval) != str(tval):
            ds.notes.append(f"'{tgt}' ({tval}) differs from '{src}' ({sval}) — the "
                            f"{src} wins, FileMaker overwrites the mirror on paste")
    # Options FileMaker discards on paste (step_options.paste_dropped, 2.6.0):
    # a snippet from another source may carry the attribute; it has no
    # persistence, so it is reported and not carried to the text form.
    for key in sorted(ref.paste_dropped_options(step_id)):
        if key in ex.options:
            val = ex.options.pop(key)
            ds.notes.append(f"'{key}' = {val} is discarded by FileMaker on paste whatever "
                            "its value — not carried to the text form")

    ex.options.update(group_opts)
    _qualify_item_fields(ex.options, ref, step_id, ds.notes)

    _drop_default_slot_items(ex.options, ref, step_id, tpl)
    extras = fixed_slot_extras(ex.options, ref, step_id)
    _append_known_bug_notes(ds, ref, step_id)

    ps = ParsedStep(
        line=index, step_id=step_id, canonical_name=ds.canonical_name,
        enabled=enabled, options=_display_order(ex.options, ref, step_id),
    )
    text = render_canonical(ps, ref)
    text, guard_note = _reparse_guard(ps, text, ref)
    if guard_note:
        ds.notes.append(guard_note)
    # FileMaker keeps a multi-line comment in ONE step, but the text form has no
    # continuation for comment payloads — a comment line ends at the end of its
    # line (T1/T6), otherwise a stray bracket in the prose would swallow the
    # following steps. One comment step per line is the only rendering parse()
    # can read back; it changes the step count, so it is recorded as lossy
    # rather than shipped as text that silently fails to round-trip.
    if step_id == 89 and "\n" in str(ps.options.get("text", "")):
        payload = str(ps.options["text"]).split("\n")
        prefix = "" if enabled else "// "
        text = "\n".join(f"{prefix}# {ln}" if ln else f"{prefix}#" for ln in payload)
        ds.issues.append(
            f"multi-line comment split into {len(payload)} comment steps "
            "(the text form has no multi-line comment)")
    if extras:
        joined = " ; ".join(extras)
        if text.endswith(" ]"):
            text = f"{text[:-2]} ; {joined} ]"
        else:
            text = f"{text} [ {joined} ]"
    ds.text = text
    return ds


def decompile(
    xml_text: str,
    ref: Reference,
    catalog: Database | None = None,
    file: str | None = None,
) -> DecompileResult:
    res = DecompileResult()
    try:
        root = ET.fromstring(xml_text.strip())
    except ET.ParseError as e:
        res.errors.append(f"input is not well-formed XML: {e}")
        return res

    if root.tag == "Step":
        step_elems = [root]
    else:
        step_elems = [e for e in root.iter("Step") if e is not root]
    if not step_elems:
        res.errors.append("no <Step> elements found in input")
        return res

    for i, elem in enumerate(step_elems, start=1):
        res.steps.append(decompile_step(elem, i, ref, catalog, file))

    lines: list[str] = []
    depth = 0
    for ds in res.steps:
        name = ds.canonical_name or ""
        if name in _BLOCK_CLOSE or name in _BLOCK_MID:
            depth = max(0, depth - 1)
        indent = "  " * depth
        for issue in ds.issues:
            marker = f"# fmgen:unsupported step {ds.step_id or '?'}"
            if ds.canonical_name:
                marker += f" ({ds.canonical_name})"
            lines.append(f"{indent}{marker}: {issue}")
        if ds.text is not None:
            if ds.step_id == 89 and "\n" in ds.text:
                # split multi-line comment: every line is its own step and gets
                # its own block indentation
                lines.extend(indent + t for t in ds.text.split("\n"))
            else:
                lines.append(indent + ds.text)
        if name in _BLOCK_OPEN or name in _BLOCK_MID:
            depth += 1
    res.text = "\n".join(lines) + "\n"
    return res
