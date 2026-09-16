"""P5 table-driven emission: parsed IR -> fmxmlsnippet.

The XML per step comes exclusively from fm_spec.step_xml_map
(snippet_template with {placeholder} markers), never from prompt knowledge.

Placeholder grammar in templates:
  {key}          option value (calculation/text/enum/boolean state)
  {key|default}  default applied when the option is absent
  {key:sub}      subfield of an object_ref (id / name / table / repetition)
  {key:sub?}     optional attribute: when the value is absent the whole
                 attribute is dropped from the element (used for the field
                 repetition attribute — native FileMaker omits it entirely at
                 the default, emits it only for an explicit/calculated rep)

Pruning rule (derived from paste semantics): after substitution an element is
dropped when its subtree contains only unfilled defaultless placeholders and
no actual values; mixing filled and unfilled placeholders in one element is an
error (incomplete option group). Optional ('?') attributes never keep an
element alive on their own and never force a prune — they are simply omitted
when absent. Calculation element text is emitted as CDATA.
Serialization follows the roundtrip-verified canonical form: 2-space indent,
element order exactly as in the template.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from .db import Reference
from .textform import (_apply_post_implications, ParsedStep, apply_mirror_rules,
                       apply_paste_dropped, group_child_keys, group_item_keys,
                       is_fixed_slot, slot_families, slot_key)

_PLACEHOLDER_RE = re.compile(r"\{([a-z0-9_]+)(?::([a-z_]+))?(?:\|([^{}]*))?(\?)?\}")

# An attribute value that is exactly one optional ('?') placeholder — the whole
# attribute is dropped when the value resolves to absent (see module docstring).
_OPTIONAL_ATTR_RE = re.compile(r"^\{([a-z0-9_]+)(?::([a-z_]+))?\?\}$")

# An attribute value that is exactly one placeholder for an option (any subfield):
# used to detect a reference element whose identity is carried by attributes.
_ATTR_PLACEHOLDER_RE = re.compile(r"^\{([a-z0-9_]+)(?::[a-z_]+)?\??\}$")

_MISSING = object()


class _TextSlotReference(Exception):
    """A field reference would be rendered into a slot that carries plain text.

    The text form of a target slot holds a NAME only — a field's table and id
    have nowhere to go and are silently dropped, which FileMaker reads back as
    a variable of that name (verified by pasting such a snippet: the leaf name
    is taken over verbatim, no diagnostic). Raised by `_lookup_value` and
    turned into an emit error by the substitution pass.
    """

    def __init__(self, key: str, val: dict):
        super().__init__(key)
        self.key = key
        self.val = val

    def label(self) -> str:
        table = self.val.get("table")
        name = self.val.get("name") or "?"
        return f"{table}::{name}" if table else str(name)


@dataclass
class EmitResult:
    xml: str | None = None
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    unsupported: list[dict] = field(default_factory=list)


def template_placeholders(template: str) -> set[str]:
    return {m.group(1) for m in _PLACEHOLDER_RE.finditer(template)}


def _lookup_value(ps: ParsedStep, key: str, sub: str | None, default: str | None):
    val = ps.options.get(key, _MISSING)
    if val is _MISSING or val is None:
        return default if default is not None else _MISSING
    if isinstance(val, dict):
        if sub is None:
            if val.get("_form") == "field":
                # a field reference has an identity (table + id) that the text
                # form cannot carry — never render it as a bare name
                raise _TextSlotReference(key, val)
            return val.get("name", _MISSING)
        v = val.get(sub, _MISSING)
        if v is _MISSING and default is not None:
            # a reference part the resolver did not supply falls back to the
            # template default of its placeholder ({table:comment|} — the
            # BaseTable comment on a catalog that predates BT_Comment)
            return default
        return v
    if sub is not None:
        return _MISSING
    return str(val)


class _Sub:
    """Substitution pass over one template; tracks fill state per element."""

    def __init__(self, ps: ParsedStep, ref: Reference | None = None):
        self.ps = ps
        self.ref = ref
        self.filled = 0
        self.errors: list[str] = []
        # boolean options whose attribute takes a value domain other than
        # True/False (fm_spec 2.2.0 xml_true/xml_false, 74/122 NewWndStyles)
        self.bool_domain: dict[str, tuple[str, str]] = (
            ref.bool_domain(ps.step_id) if ref is not None and ps.step_id else {})

    def domain_value(self, key: str, sub: str | None, v):
        """Write a boolean option's internal state (True/False) in the XML
        value domain of its attribute (xml_true/xml_false) — the internal
        state is what the parser coerces every boolean to, the template
        defaults ({close|Yes}) are already spelled in the domain, so only an
        ACTUAL value is mapped. Without a curated domain the state is the
        value."""
        if sub is None and key in self.bool_domain and v in ("True", "False") \
                and self.ps.options.get(key) is not None:
            return self.bool_domain[key][0 if v == "True" else 1]
        return v

    def text_slot_error(self, exc: _TextSlotReference) -> str:
        """Message for a field reference in a text slot (see _TextSlotReference).
        Names the expected form when the reference classifies the slot."""
        kind = None
        if self.ref is not None:
            kind = self.ref.slot_kind(self.ps.step_id, exc.key)
        hint = (" — this slot takes a variable ($x/$$x); FileMaker offers no field "
                "there and stores a field name as a variable name"
                if kind == "variable_only" else
                " — the slot is written as element text, so table and id would be "
                "lost on paste")
        return (f"line {self.ps.line}: field reference '{exc.label()}' in text slot "
                f"'{exc.key}' of '{self.ps.canonical_name}'{hint}")

    def sub_text(self, text: str) -> tuple[str, int, int, int]:
        """Returns (result, n_filled_actual, n_missing, n_defaulted)."""
        filled = missing = defaulted = 0

        def repl(m: re.Match) -> str:
            nonlocal filled, missing, defaulted
            try:
                v = _lookup_value(self.ps, m.group(1), m.group(2), m.group(3))
            except _TextSlotReference as exc:
                self.errors.append(self.text_slot_error(exc))
                missing += 1
                return ""
            if v is _MISSING:
                missing += 1
                return ""
            if self.ps.options.get(m.group(1)) is not None:
                filled += 1
            else:
                defaulted += 1
            return str(self.domain_value(m.group(1), m.group(2), v))

        return _PLACEHOLDER_RE.sub(repl, text), filled, missing, defaulted


def _process(elem: ET.Element, sub: _Sub) -> tuple[int, int, int, int]:
    """Substitute placeholders depth-first. Returns (actuals, missing, lost,
    own_defaults) for the subtree — own_defaults counts default fills on THIS
    element's own attributes/text only.

    A child is pruned when its subtree carries no actual value but has missing
    defaultless placeholders OR lost its own children to pruning — default-only
    skeletons (empty Button/InputField/Repetition groups) must not survive.
    Steps whose real FileMaker emission keeps default-bearing skeleton
    elements alive (144 Security, 131 FilterList) restore them via
    step_skeleton_elements rows from the same template — the generic rule
    stays strict so fixed-slot hulls (87) keep dying here and are re-padded
    from step_repeat_groups data in _pad_fixed_slots.
    The root Step element is never pruned (handled by the caller).
    """
    actuals = missing = lost = own_defaults = 0
    for child in list(elem):
        ca, cm, cl, cdf = _process(child, sub)
        if (cm > 0 or cl > 0) and ca == 0:
            elem.remove(child)
            lost += 1
        else:
            if cm > 0 and ca > 0:
                sub.errors.append(
                    f"line {sub.ps.line}: incomplete option group in <{child.tag}> "
                    f"for '{sub.ps.canonical_name}' — some values set, others missing")
            actuals += ca
            missing += 0 if ca else cm
    if elem.text and elem.text.strip():
        t, f, m, d = sub.sub_text(elem.text)
        elem.text = t
        actuals += f
        missing += m
        own_defaults += d
    for k, v in list(elem.attrib.items()):
        opt = _OPTIONAL_ATTR_RE.match(v)
        if opt is not None:
            # Optional attribute: emit only when a value is present, otherwise
            # drop it. Absence never counts as 'missing' (so it neither prunes
            # the element nor keeps an otherwise-empty one alive).
            try:
                val = _lookup_value(sub.ps, opt.group(1), opt.group(2), None)
            except _TextSlotReference as exc:
                sub.errors.append(sub.text_slot_error(exc))
                val = _MISSING
            if val is _MISSING:
                del elem.attrib[k]
            else:
                elem.attrib[k] = str(sub.domain_value(opt.group(1), opt.group(2), val))
                if sub.ps.options.get(opt.group(1)) is not None:
                    actuals += 1
            continue
        t, f, m, d = sub.sub_text(v)
        elem.attrib[k] = t
        actuals += f
        missing += m
        own_defaults += d
    return actuals, missing, lost, own_defaults


def _collapse_variable_targets(elem: ET.Element, ps: ParsedStep) -> None:
    """Render a variable target as element text, not as id/name/table attributes.

    A reference element in a template carries the field form
    (``<Field table id name/>``); a field's identity lives in those attributes.
    A script-local variable has no such identity — FileMaker writes it as the
    plain text content of the same element (``<Field>$var</Field>``). Templates
    only encode the field form, so when a target resolves to a variable we
    rewrite the element to the text form here. This lets one template serve both
    cases and keeps a variable target from being pruned away with its (unfilled)
    attribute placeholders.
    """
    for child in list(elem):
        _collapse_variable_targets(child, ps)
    var_keys = set()
    for v in elem.attrib.values():
        m = _ATTR_PLACEHOLDER_RE.match(v.strip())
        if m:
            val = ps.options.get(m.group(1))
            if isinstance(val, dict) and val.get("_form") == "variable":
                var_keys.add(m.group(1))
    if not var_keys:
        return
    for k in list(elem.attrib):
        m = _ATTR_PLACEHOLDER_RE.match(elem.attrib[k].strip())
        if m and m.group(1) in var_keys:
            del elem.attrib[k]
    key = next(iter(var_keys))
    elem.text = ps.options[key]["name"]
    rep = ps.options[key].get("repetition")
    if rep:
        # a variable target keeps its repetition as the same attribute the
        # field form uses (<Field repetition="3">$var</Field>, Tier-2 22.0.6)
        elem.set("repetition", str(rep))


_TEXT_PLACEHOLDER_RE = re.compile(r"^\{([a-z0-9_]+)\}$")
# a reference-subfield placeholder attribute ({key:sub}, {key:sub|default},
# {key:sub?}) — the mark of an element that already carries the field form
_REF_SUB_ATTR_RE = re.compile(r"^\{[a-z0-9_]+:[a-z_]+(?:\|[^{}]*)?\??\}$")


def _expand_field_targets(elem: ET.Element, ps: ParsedStep,
                         ref: Reference | None = None) -> None:
    """Counterpart of _collapse_variable_targets for templates that encode
    only the VARIABLE form of a field-or-variable target
    (``<Field>{target}</Field>`` — 13/14/77/188–194/211,
    step_xml_map.target_slot_kind = field_or_var): a field reference there
    must become the attribute form ``<Field table id name/>`` — written as
    text it would turn into a variable of that name on paste. Evidence:
    paired 22.0.6 copies (Companion corpus B5/Files, Korpus 07-FM22).

    A slot the reference classifies as `variable_only` has no field form at
    all — FileMaker discards the attribute form on paste without a word, so
    the rewrite must not happen there. The field value then reaches the text
    placeholder and `_lookup_value` rejects it by name."""
    for child in list(elem):
        _expand_field_targets(child, ps, ref)
    m = _TEXT_PLACEHOLDER_RE.match((elem.text or "").strip())
    if not m or len(elem):
        return
    # Only a reference-subfield placeholder attribute marks an element that
    # already carries the field form; a foreign attribute
    # (IncludeToolCalls="{include_tool_calls|0}") must not switch the form
    # choice off — it is kept next to the rewritten reference attributes.
    if any(_REF_SUB_ATTR_RE.match(v.strip()) for v in elem.attrib.values()):
        return
    val = ps.options.get(m.group(1))
    if not isinstance(val, dict) or val.get("_form") == "variable" \
            or not (val.get("table") or val.get("id")):
        return
    key = m.group(1)
    if ref is not None and ref.slot_kind(ps.step_id, key) == "variable_only":
        return
    elem.text = None
    elem.set("table", "{%s:table}" % key)
    elem.set("id", "{%s:id}" % key)
    elem.set("name", "{%s:name}" % key)
    if val.get("repetition"):
        elem.set("repetition", "{%s:repetition?}" % key)


def _settle_literal_text_marker(elem: ET.Element, ps: ParsedStep, ref: Reference,
                                xmap: dict) -> None:
    """Templates of field-or-variable steps WITHOUT the structural marker flag
    carry the ``<Text/>`` marker literally (13/14/77/160/188–194/203). Native
    FileMaker writes it only next to a VARIABLE target — a field target and an
    unset target carry no marker (paired 22.0.6: Korpus 07-FM22 160/191/203,
    Companion corpus 13/14/77/188). A defaulted ``<Repetition>`` (14) is the
    target's repetition and exists only when it was actually set."""
    if xmap.get("target_slot_kind") != "field_or_var" \
            or xmap.get("variable_target_marker"):
        return
    targets = [o for o in ref.options(ps.step_id) if o["option_type"] == "target"]
    if not targets:
        return
    has_var = any(
        isinstance(ps.options.get(o["option_key"]), dict)
        and ps.options[o["option_key"]].get("_form") == "variable"
        for o in targets)
    if not has_var:
        for child in list(elem):
            if child.tag == "Text" and not child.attrib and len(child) == 0 \
                    and not (child.text or "").strip():
                elem.remove(child)
    rep_keys = [o["option_key"] for o in ref.options(ps.step_id)
                if o["option_type"] == "repetition"
                and o["xml_path"] == "Repetition/Calculation"]
    if rep_keys and all(ps.options.get(k) is None for k in rep_keys):
        rep = elem.find("Repetition")
        if rep is not None:
            elem.remove(rep)


def _apply_step_rules(elem: ET.Element, ps: ParsedStep) -> None:
    """Consumer rules the reference documents in notes rather than bindings.
    242 Print PDF: <PrintSettings> exists only when the print options are
    restored (restore=True) or a print-options target/password is set —
    the default form has no PrintSettings hull (paired 26.0.2, Korpus 07)."""
    if ps.step_id == 242:
        keep = ps.options.get("restore") == "True" or any(
            ps.options.get(k) is not None for k in
            ("save_print_options_to", "use_print_options_from", "password",
             "print_settings", "print_from", "print_type"))
        if not keep:
            e = elem.find("PrintSettings")
            if e is not None:
                elem.remove(e)


def _apply_post_rules(elem: ET.Element, ps: ParsedStep) -> None:
    """Rules that run AFTER skeleton restoration. 3 Save a Copy as XML (FM 26
    form): the SaXML/JSONOptions hull is written by FileMaker even with
    'Specify options as JSON' off — then with a GENERATED default formula
    that no consumer can reproduce. Emit the hull only with an authored
    formula; the generated default stays a documented read residue."""
    if ps.step_id == 3 and ps.options.get("json_options") is None:
        e = elem.find("SaXML")
        if e is not None:
            elem.remove(e)


def _has_unfilled(elem: ET.Element) -> list[str]:
    left = []
    for e in elem.iter():
        for source in [e.text or ""] + list(e.attrib.values()):
            left += [m.group(0) for m in _PLACEHOLDER_RE.finditer(source)]
    return left


def _inject_text_marker(elem: ET.Element, ps: ParsedStep, ref: Reference) -> None:
    """Structural variable-target marker (step_xml_map.variable_target_marker,
    fm_spec 1.17.0): the marked steps carry an empty <Text/> step-level marker
    exactly when a target option holds a variable instead of a field
    reference. The marker is structural, not an option — injected here at its
    element_order position, consumed by the decompile side (which consumes it
    only when a variable target is present; a marker next to a plain field
    target is not derivable and stays a lossy finding there)."""
    if not (ref.xml_map(ps.step_id) or {}).get("variable_target_marker"):
        return
    has_var_target = any(
        isinstance(v, dict) and v.get("_form") == "variable"
        for o in ref.options(ps.step_id) if o["option_type"] == "target"
        for v in [ps.options.get(o["option_key"])]
    )
    if not has_var_target or elem.find("Text") is not None:
        return
    order = [e.strip() for e in ((ref.xml_map(ps.step_id) or {}).get("element_order") or "").split(",")]
    after = set(order[order.index("Text") + 1:]) if "Text" in order else set()
    idx = len(list(elem))
    for i, child in enumerate(list(elem)):
        if child.tag in after:
            idx = i
            break
    elem.insert(idx, ET.Element("Text"))


def _bound_target(elem: ET.Element, path: str):
    """(parent, key, node) for a binding path relative to the Step root.
    Three forms: an element path (`Exit`, `Source/Field`), an indexed element
    (`Field[2]` — the second same-named child, ElementTree position
    predicate) and an attribute (`SerialNumbers/@increment`, fm_spec 2.5.0).
    node is the element, the attribute value, or None when absent."""
    if "/" in path:
        parent_path, tag = path.rsplit("/", 1)
        parent = elem.find(parent_path)
    else:
        parent, tag = elem, path
    if parent is None:
        return None, None, None
    if tag.startswith("@"):
        return parent, tag[1:], parent.attrib.get(tag[1:])
    try:
        return parent, tag, parent.find(tag)
    except SyntaxError:
        return None, None, None


def _remove_at(elem: ET.Element, path: str) -> None:
    """Remove the node at a Step-root-relative binding path (first match):
    an element, an indexed element or an attribute."""
    parent, key, node = _bound_target(elem, path)
    if parent is None or node is None:
        return
    if key in parent.attrib and not isinstance(node, ET.Element):
        del parent.attrib[key]
    else:
        parent.remove(node)


def _apply_element_bindings(elem: ET.Element, ps: ParsedStep, ref: Reference) -> None:
    """Option-value/element couplings (step_option_element_bindings, fm_spec
    1.17.0): prune bound elements BEFORE substitution so mode-scoped defaults
    survive and nothing leaks across modes (161 device-mode matrix, 212
    provider form, 213 data source). Semantics per binding:

      requires        element exists only at the listed option value(s) —
                      several rows for one (option, element) form the allowed
                      set; an unset option never satisfies a requires binding
      excludes        element dropped at the listed option value
      requires_option element exists only while the option is set
      excludes_option element dropped while the option is set
      suppress_empty  the (empty) template element is never emitted
                      deterministically; decompilation tolerates a present
                      one via the template (185 Text residue)

    element_path names an element, an indexed element (`Field[2]`, 202: the
    trailing Field only outside the Uninstall form) or an attribute
    (`SerialNumbers/@increment`, 91: dropped with UseEntryOptions) —
    fm_spec 2.5.0.

    The decompile side needs no counterpart — the template match tolerates
    absence of any pruned element."""
    rows = ref.element_bindings(ps.step_id)
    if not rows:
        return
    allowed: dict[str, dict[str, set]] = {}
    for r in rows:
        if r["binding"] == "requires":
            allowed.setdefault(r["element_path"], {}) \
                   .setdefault(r["option_key"], set()).add(r["option_value"])
    for path, conds in allowed.items():
        if any(ps.options.get(k) not in vals for k, vals in conds.items()):
            _remove_at(elem, path)
    for r in rows:
        b, path = r["binding"], r["element_path"]
        _parent, _key, e = _bound_target(elem, path)
        if e is None:
            continue
        val = ps.options.get(r["option_key"]) if r["option_key"] else None
        if (b == "excludes" and val == r["option_value"]) \
                or (b == "excludes_option" and val is not None) \
                or (b == "requires_option" and val is None) \
                or (b == "suppress_empty" and isinstance(e, ET.Element)
                    and not e.attrib and len(e) == 0
                    and not (e.text or "").strip()):
            _remove_at(elem, path)


def _strip_hull_children(elem: ET.Element, ps: ParsedStep, ref: Reference) -> None:
    """Skeleton hulls with keep_mode='hull_strip_children'
    (step_skeleton_elements, fm_spec 1.17.0): the hull element persists with
    its attributes while unfilled placeholder children are stripped BEFORE
    substitution — so the strict prune never sees the dead children and the
    hull survives (161: Signature Title/Message/Prompt hulls, MaxDuration
    state without calc, ScanFrom without scan field). A child whose subtree
    references at least one SET option stays for normal substitution."""
    for row in ref.skeleton_elements(ps.step_id):
        if row["keep_mode"] != "hull_strip_children":
            continue
        if row["condition_option"] \
                and ps.options.get(row["condition_option"]) != row["condition_value"]:
            continue
        parent = elem if row["parent_tag"] == "Step" \
            else elem.find(f".//{row['parent_tag']}")
        hull = parent.find(row["child_tag"]) if parent is not None else None
        if hull is None:
            continue
        for child in list(hull):
            keys = set()
            for e in child.iter():
                for source in [e.text or ""] + list(e.attrib.values()):
                    keys |= {m.group(1) for m in _PLACEHOLDER_RE.finditer(source)}
            if keys and all(ps.options.get(k) is None for k in keys):
                hull.remove(child)


def _fix_presence_booleans(elem: ET.Element, ps: ParsedStep, ref: Reference) -> None:
    """Presence booleans: a boolean option whose xml_path names an ELEMENT
    (no /@attr) is encoded by presence — empty element = True, absent = False
    (216 Overwrite/ContinueOnError/ShowSummary, 222 LLMTrainSkipRecords;
    Tier-2 fixture 22.0.6). The template carries the state as element text;
    rewrite True -> empty element, False -> element removed."""
    for o in ref.options(ps.step_id or -1):
        path = o.get("xml_path") or ""
        if o.get("option_type") != "boolean" or "/@" in path or not path:
            continue
        e = elem.find(path)
        if e is None:
            continue
        txt = (e.text or "").strip()
        if txt == "True":
            e.text = None
        elif txt == "False":
            parent = elem.find("/".join(path.split("/")[:-1])) if "/" in path else elem
            if parent is not None:
                parent.remove(e)


def _restore_skeletons(elem: ET.Element, ps: ParsedStep, ref: Reference,
                       template: str, element_order: str | None = None) -> None:
    """Re-instantiate FM-persistent skeleton children pruned by the strict
    rule (step_skeleton_elements keep_mode='hull', fm_spec 1.17.0):
    substitute the template subtree with defaults, prune ITS dead children,
    insert at the template-order position. A condition_option row runs only
    at its option value (214 TableAliases with data_tables='By List')."""
    spec = [r for r in ref.skeleton_elements(ps.step_id)
            if r["keep_mode"] == "hull"]
    if not spec:
        return
    tpl = ET.fromstring(template)
    for entry in spec:
        parent_tag, child_tag = entry["parent_tag"], entry["child_tag"]
        if entry["condition_option"] \
                and ps.options.get(entry["condition_option"]) != entry["condition_value"]:
            continue
        parent = elem.find(f".//{parent_tag}") if elem.tag != parent_tag else elem
        if parent is None or parent.find(child_tag) is not None:
            continue
        tpl_parent = tpl if tpl.tag == parent_tag else tpl.find(f".//{parent_tag}")
        tpl_child = tpl_parent.find(child_tag) if tpl_parent is not None else None
        if tpl_child is None:
            continue
        fresh = ET.fromstring(ET.tostring(tpl_child))
        _collapse_variable_targets(fresh, ps)
        _process(fresh, _Sub(ps, ref))
        # insertion index: after the last sibling that precedes child_tag.
        # At Step level the authoritative order is element_order — it also
        # carries the structural <Text/> marker, which the template does not
        # (a restored group must not jump ahead of an injected marker).
        if parent is elem and element_order:
            order = [e.strip() for e in element_order.split(",")]
            before = order[:order.index(child_tag)] if child_tag in order else []
        else:
            before = []
            for c in tpl_parent:
                if c.tag == child_tag:
                    break
                before.append(c.tag)
        idx = 0
        for i, c in enumerate(parent):
            if c.tag in before:
                idx = i + 1
        parent.insert(idx, fresh)


def _pad_fixed_slots(elem: ET.Element, ps: ParsedStep, ref: Reference,
                     element_order: str | None = None) -> None:
    """Fixed-slot groups (fm_spec 1.16.0, T9 fixed-slot rule — Show Custom
    Dialog is the lead case): once any slot of a group is configured FileMaker
    persists ALL max_items slots (pad_mode=all_when_any, paired 22.0.6) —
    unconfigured slots as the empty_item_template hull, slot positions
    preserved, so the elements surviving the strict prune are re-distributed
    onto their configured indices. An entirely unconfigured group with a
    default_item_template gets that item as slot 1 (the OK commit button) and
    is padded like any configured group; without a default the container
    simply stays pruned (InputFields)."""
    for g in ref.repeat_groups(ps.step_id):
        if not is_fixed_slot(g) or g.get("pad_mode") != "all_when_any":
            continue
        fams = slot_families(ref, ps.step_id, g)
        if not fams or not g.get("empty_item_template"):
            continue
        n_max = int(g["max_items"])
        item_tag = _item_root_tag(g)
        configured = [
            any(ps.options.get(slot_key(f, n)) is not None for f in fams)
            for n in range(1, n_max + 1)
        ]
        container = elem.find(g["container_path"])
        if not any(configured):
            # The default item exists only on a CONFIGURED step: a fully
            # unconfigured Show Custom Dialog exports as a bare <Step/>
            # without Buttons or the OK default (Tier-3 fixture 22.0.6).
            if not ps.options or not g.get("default_item_template") \
                    or "/" in g["container_path"]:
                continue
            if container is None:
                container = ET.Element(g["container_path"])
                _insert_in_order(elem, container, element_order)
            for c in [c for c in container if c.tag == item_tag]:
                container.remove(c)
            container.append(ET.fromstring(g["default_item_template"]))
            for _ in range(n_max - 1):
                container.append(ET.fromstring(g["empty_item_template"]))
            continue
        if container is None:
            continue
        survivors = [c for c in container if c.tag == item_tag]
        for c in survivors:
            container.remove(c)
        it = iter(survivors)
        for used in configured:
            child = next(it, None) if used else None
            container.append(child if child is not None
                             else ET.fromstring(g["empty_item_template"]))


def _insert_in_order(elem: ET.Element, child: ET.Element,
                     element_order: str | None) -> None:
    """Insert a rebuilt Step-level container at its element_order position
    (same rule as _restore_skeletons)."""
    order = [e.strip() for e in (element_order or "").split(",") if e.strip()]
    before = order[:order.index(child.tag)] if child.tag in order else []
    idx = 0
    for i, c in enumerate(elem):
        if c.tag in before:
            idx = i + 1
    elem.insert(idx, child)


# ------------------------------------------------------------- repeat groups
# T9 (fm_spec 1.15.0): a group's items replace the template exemplar children
# of the container element; the item template is instantiated once per item
# with the same substitution/prune machinery ({#index} = 0-based item index;
# count_attr derives the container count attribute from the item count).
# Prune acts PER ITEM; the container itself is never pruned at n >= 1.

def _instantiate_groups(elem: ET.Element, ps: ParsedStep, ref: Reference) -> list[str]:
    errors: list[str] = []
    groups = ref.repeat_groups(ps.step_id)
    if not groups:
        return errors
    by_key = {g["group_key"]: g for g in groups}
    for g in groups:
        if g["parent_group"]:
            continue  # nested groups are instantiated inside their parent item
        if is_fixed_slot(g):
            continue  # fixed-slot groups: slots live in the main template,
                      # padding is _pad_fixed_slots' job
        val = ps.options.get(g["group_key"])
        if val is None:
            continue
        items = val if isinstance(val, list) else [val]
        if not items:
            continue
        container = elem.find(g["container_path"])
        if container is None:
            errors.append(
                f"line {ps.line}: repeat group '{g['group_key']}' — container "
                f"<{g['container_path']}> not present in the reference template")
            continue
        item_tag = _item_root_tag(g)
        for c in list(container):
            if c.tag == item_tag:
                container.remove(c)
        for i, item in enumerate(items):
            node = _instantiate_item(g, item, i, ps, by_key, errors, ref)
            if node is not None:
                container.append(node)
        if g["count_attr"]:
            container.set(g["count_attr"], str(len(items)))
            # the derived count makes a manually supplied count option
            # meaningless — drop the parse alias so nothing dangles
            ps.options.pop(g["group_key"] + "_count", None)
            ps.options.pop("web_script_parameter_count", None)
    return errors


def _item_root_tag(g: dict) -> str:
    m = re.match(r"<([A-Za-z][A-Za-z0-9]*)", g["item_template"])
    return m.group(1) if m else ""


def _instantiate_item(g: dict, item, idx: int, ps: ParsedStep,
                      by_key: dict, errors: list[str],
                      ref: Reference | None = None) -> ET.Element | None:
    tpl_str = g["item_template"].replace("{#index}", str(idx))
    try:
        node = ET.fromstring(tpl_str)
    except ET.ParseError as e:
        errors.append(f"step {ps.step_id}: item template of group "
                      f"'{g['group_key']}' is not well-formed: {e}")
        return None
    opts = item if (g["item_form"] == "bracket" and isinstance(item, dict)) \
        else {g["group_key"]: item}
    pseudo = ParsedStep(line=ps.line, step_id=ps.step_id,
                        canonical_name=ps.canonical_name, enabled=True,
                        options=dict(opts))
    # nested group slots ({child[]} as element text) fill BEFORE substitution
    for ck in group_child_keys(g):
        cg = by_key.get(ck)
        slot = next((e for e in node.iter()
                     if (e.text or "").strip() == "{%s[]}" % ck), None)
        if slot is None:
            continue
        slot.text = None
        subs = (item.get(ck) if isinstance(item, dict) else None) or []
        if cg is None:
            continue
        if not subs:
            errors.append(
                f"line {ps.line}: '{g['group_label']}' item {idx + 1} has no "
                f"'{cg['group_label']}' item — FileMaker requires at least one")
            continue
        for j, sub in enumerate(subs):
            child = _instantiate_item(cg, sub, j, ps, by_key, errors, ref)
            if child is not None:
                slot.append(child)
        pseudo.options.pop(ck, None)
    sub_ = _Sub(pseudo, ref)
    actuals, missing, _lost, _dft = _process(node, sub_)
    errors += sub_.errors
    if missing > 0:
        errors.append(
            f"line {ps.line}: incomplete '{g['group_label']}' item {idx + 1} — "
            "some values set, others missing")
        return None
    if actuals == 0 and len(list(node)) == 0 and g["item_form"] == "bracket":
        errors.append(
            f"line {ps.line}: '{g['group_label']}' item {idx + 1} resolves to "
            "nothing after substitution")
        return None
    return node


def emit_step(ps: ParsedStep, ref: Reference) -> tuple[ET.Element | None, list[str], list[str]]:
    """Returns (element, errors, warnings) for one step."""
    xmap = ref.xml_map(ps.step_id)
    if xmap is None or not xmap.get("snippet_template"):
        return None, [f"line {ps.line}: no snippet template for step "
                      f"{ps.step_id} ('{ps.canonical_name}') in the reference"], []
    template = xmap["snippet_template"]
    known = template_placeholders(template)
    known |= {g["group_key"] for g in ref.repeat_groups(ps.step_id)}
    warnings, errors = [], []
    for key, val in ps.options.items():
        base_hit = key in known or any(k.startswith(key) for k in known)
        if not base_hit:
            errors.append(
                f"line {ps.line}: option '{key}' of '{ps.canonical_name}' has no "
                "placeholder in the reference template — not supported by the "
                "table-driven emitter; author this step manually against "
                "step_xml_map and validate with the gate")
    if errors:
        return None, errors, warnings

    try:
        elem = ET.fromstring(template)
    except ET.ParseError as e:
        return None, [f"step {ps.step_id}: reference template is not well-formed: {e}"], []

    # parse-side implications once more on the IR (idempotent setdefault):
    # an IR that reaches the emitter without going through parse_step (REST
    # compile, test fixtures) must not lose an element whose binding waits
    # for the implied option (220 message-history variable => link_avail)
    _apply_post_implications(ps, ref)
    # fm_spec 2.6.0: an option FileMaker discards on paste never reaches the
    # snippet (144 appearance); a mirror rule copies the source value to its
    # second place (144 title -> Step-level Calculation) — both on the IR, so
    # the substitution below writes FileMaker's own canonical form
    warnings += apply_paste_dropped(ps, ref, "the emission")
    warnings += apply_mirror_rules(ps, ref, canonical=False)
    _collapse_variable_targets(elem, ps)
    _expand_field_targets(elem, ps, ref)
    _settle_literal_text_marker(elem, ps, ref, xmap)
    _inject_text_marker(elem, ps, ref)
    _apply_element_bindings(elem, ps, ref)
    _apply_step_rules(elem, ps)
    _strip_hull_children(elem, ps, ref)
    errors += _instantiate_groups(elem, ps, ref)
    sub = _Sub(ps, ref)
    _process(elem, sub)
    errors += sub.errors
    leftover = _has_unfilled(elem)
    if leftover:
        errors.append(
            f"line {ps.line}: unfilled placeholders {sorted(set(leftover))} in "
            f"'{ps.canonical_name}' after substitution")
    _fix_presence_booleans(elem, ps, ref)
    _restore_skeletons(elem, ps, ref, template, xmap.get("element_order"))
    # a restored hull is instantiated from the raw template and may carry an
    # element that a binding excludes for this option state (220
    # LLMRequestWithTools restored with its SlidingWindowVariable hull while
    # link_avail is unset) — the bindings run once more over the whole step
    _apply_element_bindings(elem, ps, ref)
    _apply_post_rules(elem, ps)
    _pad_fixed_slots(elem, ps, ref, xmap.get("element_order"))
    if not ps.enabled:
        elem.set("enable", "False")
    if errors:
        return None, errors, warnings
    return elem, [], warnings


# ------------------------------------------------------------- serialization

_XML_ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}
# Attribute values: an XML parser normalizes a LITERAL tab/newline/CR in an
# attribute to a space (attribute-value normalization), a character reference
# survives — FileMaker writes `FieldDelimiter="&#9;"` (35 Import Records,
# corpus 07) and would read a raw tab back as a space delimiter.
_ATTR_ESC = {**_XML_ESC, '"': "&quot;", "\t": "&#9;", "\n": "&#10;", "\r": "&#13;"}


def _esc(s: str, table: dict) -> str:
    return "".join(table.get(c, c) for c in s)


def _serialize(elem: ET.Element, indent: int, out: list[str]) -> None:
    pad = "  " * indent
    attrs = "".join(f' {k}="{_esc(v, _ATTR_ESC)}"' for k, v in elem.attrib.items())
    children = list(elem)
    raw = elem.text or ""
    if elem.tag == "Calculation":
        # CDATA, verbatim content (already plain text in the IR)
        body = raw.strip()
        body = body.replace("]]>", "]]]]><![CDATA[>")
        out.append(f"{pad}<{elem.tag}{attrs}><![CDATA[{body}]]></{elem.tag}>")
        return
    # A leaf's text is content; template pretty-printing only ever puts
    # newline+indent into a *parent's* text or a sibling's tail, never a leaf's
    # own text. So text carrying a newline is formatting (strip it, as before),
    # but no-newline text is genuine content and is preserved verbatim — a
    # whitespace-only comment body must serialize as <Text> </Text>, not a
    # self-closing element.
    text = raw.strip() if "\n" in raw else raw
    if not children and not text:
        out.append(f"{pad}<{elem.tag}{attrs}/>")
        return
    if not children:
        out.append(f"{pad}<{elem.tag}{attrs}>{_esc(text, _XML_ESC)}</{elem.tag}>")
        return
    if text:
        # mixed content: leading text before child elements
        # (202 <ConfigureCoreML>Vision<Name>…, paired 22.0.6)
        out.append(f"{pad}<{elem.tag}{attrs}>{_esc(text, _XML_ESC)}")
    else:
        out.append(f"{pad}<{elem.tag}{attrs}>")
    for child in children:
        _serialize(child, indent + 1, out)
    out.append(f"{pad}</{elem.tag}>")


def emit(parsed: list[ParsedStep], ref: Reference, xml_decl: bool = False) -> EmitResult:
    res = EmitResult()
    elems: list[ET.Element] = []
    for ps in parsed:
        elem, errors, warnings = emit_step(ps, ref)
        res.errors += errors
        res.warnings += warnings
        if elem is not None:
            elems.append(elem)
    if res.errors:
        return res
    lines = []
    if xml_decl:
        lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<fmxmlsnippet type="FMObjectList">')
    for elem in elems:
        _serialize(elem, 1, lines)
    lines.append("</fmxmlsnippet>")
    res.xml = "\n".join(lines) + "\n"
    return res
