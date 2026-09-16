"""P6 validation gate v2 — three layers, every check reported individually.

Layer 1 (paste validity): real XML parse; Step ids exist in the reference
  (legacy/reserved ids rejected); children/order per step_xml_map; name
  attribute matches canonical name or a known xml_emission alias; Set Variable
  Name element present; Calculation content in CDATA.
Layer 2 (save validity): step_constraints catalog — save_invalid_bare,
  save_invalid_nesting (flat transactions), requires_pair balance on the XML;
  plus G202, the known-FM-bug registry (clipboard_loss & co) as a pure
  warning class — the snippet is valid, FileMaker itself is the risk.
Layer 3 (runtime validity): resolution report free of errors; version gate
  (origin_version of every step <= target file version, from step_compat data);
  calc findings (a reference that exists but is used wrongly, e.g. a custom
  function called with the wrong argument count); the opt-in variable-init
  convention.

Status values: 'pass' | 'fail' | 'skipped' | 'warning'. Only 'fail' makes the
gate fail — a 'warning' is a finding the deliverer must report but that does not
block the paste. Checks that cannot run (missing grammar tables, no resolution
report, no IR, convention not enabled, file not in catalog) are reported as
'skipped' with a reason — never as passed.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from .db import Reference
from .read_tolerance import read_boolean_state

IF_OPEN, IF_CLOSE, LOOP_OPEN, LOOP_CLOSE = 68, 70, 71, 73
SET_VARIABLE = 141

# Bug-registry kinds in step_constraints (since fm_spec 1.14.4) — a warning
# class, never a validity rule (G202).
_KNOWN_BUG_KINDS = {"clipboard_loss", "version_skew", "save_corruption",
                    "serialization_unstable", "localized_build_defect",
                    "paste_validator_warning"}


@dataclass
class Check:
    check_id: str
    layer: int
    status: str  # 'pass' | 'fail' | 'skipped'
    message: str

    def as_dict(self) -> dict:
        return self.__dict__


@dataclass
class GateResult:
    checks: list[Check] = field(default_factory=list)

    def add(self, check_id: str, layer: int, status: str, message: str) -> None:
        self.checks.append(Check(check_id, layer, status, message))

    @property
    def passed(self) -> bool:
        return not any(c.status == "fail" for c in self.checks)

    def as_dict(self) -> dict:
        return {"passed": self.passed, "checks": [c.as_dict() for c in self.checks]}


def _version_num(v: str | None) -> float | None:
    if not v:
        return None
    if "earlier" in v or "früher" in v:
        return 0.0
    m = re.match(r"(\d+(?:\.\d+)?)", v.strip())
    return float(m.group(1)) if m else None


def run_gate(xml_text: str, ref: Reference, resolution: dict | None = None,
             target_version: str | None = None, ir_steps: list[dict] | None = None,
             check_var_init: bool = False) -> GateResult:
    res = GateResult()

    # ---- Layer 1: paste validity -------------------------------------------
    try:
        root = ET.fromstring(xml_text)
        res.add("G101-wellformed", 1, "pass", "XML parses with a real parser")
    except ET.ParseError as e:
        res.add("G101-wellformed", 1, "fail", f"XML not well-formed: {e}")
        return res

    if root.tag != "fmxmlsnippet" or root.get("type") != "FMObjectList":
        res.add("G102-wrapper", 1, "fail",
                'wrapper must be <fmxmlsnippet type="FMObjectList">')
    else:
        res.add("G102-wrapper", 1, "pass", "fmxmlsnippet wrapper correct")

    steps = root.findall("Step")
    if not steps:
        res.add("G103-steps", 1, "fail", "no Step elements in snippet")
        return res
    res.add("G103-steps", 1, "pass", f"{len(steps)} Step element(s)")

    known = ref.steps()
    legacy = ref.legacy_step_ids()
    lookup = ref.step_name_lookup()
    bad_ids, bad_names = [], []
    for st in steps:
        sid = int(st.get("id", "-1"))
        name = st.get("name", "")
        if sid in legacy:
            bad_ids.append(f"id={sid} is a legacy/reserved id "
                           f"({legacy[sid].get('doc_status', 'legacy')})")
        elif sid not in known:
            bad_ids.append(f"id={sid} not in fm_spec.script_steps")
        else:
            # FileMaker itself ships step 227 with a trailing space in the
            # name attribute ('Configure RAG Account ') — compare stripped.
            hit = lookup.get(name.strip().casefold())
            if not hit or hit["step_id"] != sid:
                bad_names.append(
                    f"id={sid}: name attribute '{name}' does not match any known "
                    f"name/alias of '{known[sid]['canonical_name']}'")
    res.add("G104-step-ids", 1, "fail" if bad_ids else "pass",
            "; ".join(bad_ids) or "all Step ids exist in the reference")
    res.add("G105-step-names", 1, "fail" if bad_names else "pass",
            "; ".join(bad_names) or "all Step name attributes match the reference")

    if not ref.grammar_available():
        res.add("G106-structure", 1, "skipped",
                "grammar tables not installed — structure not checked")
    else:
        problems = []
        tolerated = _tolerated_elements(ref)
        for st in steps:
            sid = int(st.get("id", "-1"))
            xmap = ref.xml_map(sid)
            if not xmap:
                problems.append(f"id={sid}: no template in step_xml_map")
                continue
            order = [e.strip() for e in (xmap.get("element_order") or "").split(",") if e.strip()]
            # chrome/editor-state elements of the target coverage are tolerated
            # in INPUT (a snippet copied from FileMaker) but never emitted
            children = [c.tag for c in st if c.tag not in tolerated]
            unknown = [c for c in children if order and c not in order]
            if unknown:
                problems.append(f"id={sid}: unexpected child element(s) {unknown}")
            problems += _deep_shape_problems(st, sid, xmap.get("snippet_template") or "",
                                             tolerated, ref)
            if order:
                # greedy subsequence match: element_order may repeat an element
                # name (mixed-content quirk — e.g. step 202 emits Field before AND
                # after ConfigureCoreML), so consume the NEXT free slot per child
                # rather than mapping every child to the first occurrence.
                j = 0
                for c in children:
                    if c not in order:
                        continue
                    while j < len(order) and order[j] != c:
                        j += 1
                    if j >= len(order):
                        problems.append(
                            f"id={sid}: child order {children} violates reference "
                            f"order {order} (element order is paste-relevant)")
                        break
                    j += 1
        res.add("G106-structure", 1, "fail" if problems else "pass",
                "; ".join(problems) or "children and order match step_xml_map")

    name_missing = [st.get("id") for st in steps
                    if st.get("id") == "141" and st.find("Name") is None]
    res.add("G107-setvar-name", 1, "fail" if name_missing else "pass",
            "Set Variable without Name element (silently dropped on paste)"
            if name_missing else "Set Variable Name elements present")

    n_calcs = len(root.findall(".//Calculation"))
    n_cdata = xml_text.count("<![CDATA[")
    res.add("G108-cdata", 1, "pass" if n_cdata >= n_calcs else "fail",
            f"{n_calcs} Calculation element(s), {n_cdata} CDATA section(s)"
            + ("" if n_cdata >= n_calcs else " — calculations must be CDATA-wrapped"))

    # G109: enum values whose reference evidence is 'claris-doc' are doc-only
    # (never roundtrip-verified) — report as a fail-free warning, never fail.
    if not ref.grammar_available():
        res.add("G109-doc-only", 1, "skipped",
                "grammar tables not installed — doc-only evidence not checked")
    else:
        doc_only = []
        for st in steps:
            sid = int(st.get("id", "-1"))
            flagged = [v for v in ref.option_values(sid)
                       if v.get("evidence") == "claris-doc"]
            if not flagged:
                continue
            paths = {o["option_key"]: o.get("xml_path") for o in ref.options(sid)}
            for v in flagged:
                actual = _value_at_path(st, paths.get(v["option_key"]))
                if actual is not None and actual == v["xml_value"]:
                    doc_only.append(
                        f"id={sid}: {v['option_key']}='{v['xml_value']}'")
        res.add("G109-doc-only", 1, "warning" if doc_only else "pass",
                ("doc-only enum value(s) used — documented by Claris but not "
                 "roundtrip-verified, verify behaviour after paste: "
                 + "; ".join(doc_only)) if doc_only
                else "no doc-only enum values used")

    # G110: value domains of boolean state attributes. Class check: every
    # attribute a boolean option maps to must carry its value domain in the
    # XML — True|False, or the option's curated xml_true|xml_false (fm_spec
    # 2.2.0: 74/122 NewWndStyles take Yes|No). The domain is derived from the
    # reference (option_type='boolean' + attribute-shaped xml_path, fixed
    # slots via [n]), no attribute names are hardcoded. Catches any parse/emit
    # path that lets a display spelling (On/Off) through into the emission.
    # A localized-build spelling of the same state (a German build writes
    # Ja/Nein there — step_constraints localized_build_defect) is FileMaker's
    # own output, not a defect of the snippet: warning, not fail.
    if not ref.grammar_available():
        res.add("G110-state-domains", 1, "skipped",
                "grammar tables not installed — state domains not checked")
    else:
        problems110, localized110 = [], []
        for st in steps:
            sid = int(st.get("id", "-1"))
            domains = ref.bool_domain(sid)
            for o in ref.options(sid):
                if o["option_type"] != "boolean":
                    continue
                path = o.get("xml_path") or ""
                if "/@" not in path:
                    continue
                epath, _, attr = path.rpartition("/@")
                domain = domains.get(o["option_key"], ("True", "False"))
                for node in _nodes_at(st, epath):
                    val = node.get(attr)
                    if val is None or val in domain:
                        continue
                    state = read_boolean_state(val, domain)
                    if state is not None:
                        localized110.append(
                            f"id={sid}: {epath}/@{attr}='{val}' is a localized-build "
                            f"spelling of {domain[0] if state else domain[1]} — option "
                            f"'{o['option_key']}' (step_constraints "
                            "localized_build_defect; pastes into a build of that language)")
                    else:
                        problems110.append(
                            f"id={sid}: {epath}/@{attr}='{val}' is not a "
                            f"valid boolean state ({domain[0]}|{domain[1]}) — option "
                            f"'{o['option_key']}'")
        status110 = "fail" if problems110 else ("warning" if localized110 else "pass")
        res.add("G110-state-domains", 1, status110,
                "; ".join(problems110 + localized110)
                or "all boolean state attributes carry their reference domain "
                   "(True/False, or the option's xml_true/xml_false)")

    # ---- Layer 2: save validity --------------------------------------------
    constraints = ref.constraints() if ref.grammar_available() else []
    if_depth, problems2 = 0, []
    for st in steps:
        sid = int(st.get("id", "-1"))
        if sid == IF_OPEN:
            if_depth += 1
        elif sid == IF_CLOSE:
            if_depth = max(0, if_depth - 1)
        for c in constraints:
            if c["step_id"] != sid:
                continue
            if c["constraint_kind"] == "save_invalid_nesting" and if_depth > 0:
                problems2.append(f"id={sid} inside If block: {c['detail']}")
            if c["constraint_kind"] == "save_invalid_bare" and sid == 141:
                calc = st.find("Value/Calculation")
                if calc is not None and (calc.text or "").strip() == "Self":
                    problems2.append(f"id=141: {c['detail']}")
    balance = _pair_balance(steps)
    if balance:
        problems2 += balance
    if constraints:
        res.add("G201-save-constraints", 2, "fail" if problems2 else "pass",
                "; ".join(problems2) or "no save-invalid pattern matched")
    else:
        res.add("G201-save-constraints", 2, "skipped", "step_constraints not installed")

    # G202: known FileMaker bugs (registry kinds in step_constraints since
    # fm_spec 1.14.4). Always a warning, never a fail — the steps are valid;
    # the risk lies with FileMaker's own serialization (clipboard drops,
    # version skew, save-time corruption). The emit side deliberately does not
    # warn (fmgen's emission writes the full form and pastes intact); the gate
    # reports so the deliverer can pass the caveat on with the artifact.
    if constraints:
        hits: dict[tuple[int, str], int] = {}
        details: dict[tuple[int, str], dict] = {}
        for st in steps:
            sid = int(st.get("id", "-1"))
            for c in constraints:
                if c["step_id"] == sid and c["constraint_kind"] in _KNOWN_BUG_KINDS:
                    key = (sid, c["constraint_kind"])
                    hits[key] = hits.get(key, 0) + 1
                    details[key] = c
        if hits:
            msgs = []
            for (sid, kind), n in sorted(hits.items()):
                c = details[(sid, kind)]
                short = (c.get("detail") or "").split(". ")[0].strip()
                if len(short) > 120:
                    short = short[:117] + "…"
                msgs.append(
                    f"id={sid} ('{known.get(sid, {}).get('canonical_name', '?')}')"
                    + (f" x{n}" if n > 1 else "")
                    + f": {kind} (verified {c.get('verified_version') or '?'}) — {short}")
            # paste_validator_warning is the one benign registry kind (a
            # validator dialog, nothing lost) — the loss/skew lead would
            # contradict its own detail text
            benign_only = all(kind == "paste_validator_warning"
                              for (_, kind) in hits)
            lead = ("known FileMaker paste-validator quirk(s) affect step(s) "
                    "in this snippet — a dialog may appear in some "
                    "environments; the steps import completely: "
                    if benign_only else
                    "known FileMaker serialization bug(s) affect step(s) in "
                    "this snippet — valid to paste, but FileMaker itself may "
                    "lose or skew the marked data: ")
            res.add("G202-known-fm-bugs", 2, "warning", lead + "; ".join(msgs))
        else:
            res.add("G202-known-fm-bugs", 2, "pass",
                    "no step carries a known-FM-bug registry entry")
    else:
        res.add("G202-known-fm-bugs", 2, "skipped", "step_constraints not installed")

    # ---- Layer 3: runtime validity -----------------------------------------
    if resolution is None:
        res.add("G301-resolution", 3, "skipped", "no resolution report supplied")
    else:
        errs = [u for u in resolution.get("unresolved", [])
                if u.get("severity") == "error"]
        res.add("G301-resolution", 3, "fail" if errs else "pass",
                f"{len(errs)} unresolved reference(s) with severity=error"
                if errs else f"{len(resolution.get('resolved', []))} reference(s) resolved, "
                             f"{len(resolution.get('new_objects', []))} declared new")
        if resolution.get("new_objects"):
            res.add("G302-new-objects", 3, "pass",
                    "create before paste: " + "; ".join(
                        n["ref"] for n in resolution["new_objects"]))

    # G304: references that exist but are used wrongly (custom-function arity).
    # Separate from G301 on purpose — 'resolved but misused' is a different
    # failure than 'not in the catalog', and the two must stay distinguishable
    # in the protocol.
    if resolution is None:
        res.add("G304-calc-arity", 3, "skipped", "no resolution report supplied")
    else:
        findings = resolution.get("findings", [])
        errs = [f for f in findings if f.get("severity") == "error"]
        warns = [f for f in findings if f.get("severity") == "warning"]
        if errs:
            res.add("G304-calc-arity", 3, "fail",
                    "; ".join(f"line {f['line']}: {f['message']}" for f in errs))
        elif warns:
            res.add("G304-calc-arity", 3, "warning",
                    "; ".join(f"line {f['line']}: {f['message']}" for f in warns))
        else:
            res.add("G304-calc-arity", 3, "pass",
                    "calculation references used with a valid argument count")

    tv = _version_num(target_version)
    if tv is None:
        res.add("G303-version-gate", 3, "skipped",
                "target file version unknown — origin_version not checked")
    else:
        too_new = []
        for st in steps:
            sid = int(st.get("id", "-1"))
            ov = _version_num(known.get(sid, {}).get("origin_version"))
            if ov is not None and ov > tv:
                too_new.append(f"id={sid} ('{known[sid]['canonical_name']}') needs "
                               f"FM {known[sid]['origin_version']}, target is {target_version}")
        res.add("G303-version-gate", 3, "fail" if too_new else "pass",
                "; ".join(too_new) or f"all steps available in FM {target_version}")

    _function_version_gate(res, root, ref, target_version)
    _options_preserved(res, steps, ir_steps, ref)
    _value_forms(res, steps, ir_steps, ref)
    _var_init_check(res, ir_steps, check_var_init)
    return res


def _function_version_gate(res: GateResult, root: ET.Element, ref: Reference,
                           target_version: str | None) -> None:
    """G303b: built-in functions called in any calculation must exist in the
    target FileMaker version — in both directions. Too young: a formula with
    `Get ( WindowUUID )` pasted into a 22 file evaluates to an error
    (functions.origin_version, F-8). Retired: `SetPersistentData ( … )` pasted
    into a 26 file arrives as `<function missing>` — FileMaker 26 no longer
    resolves it (functions.removed_in_version, fm_spec 2.2.0; on an older
    reference that direction stands down and the message says so)."""
    tv = _version_num(target_version)
    if tv is None:
        res.add("G303b-function-versions", 3, "skipped",
                "target file version unknown — function origin not checked")
        return
    from .textform import CALL_RE, call_name_candidates, strip_comments, strip_strings
    lookup = ref.function_lookup()
    names = {fid: v["canonical_name"] for fid, v in ref.function_arity().items()}
    versions = ref.function_versions()
    too_new: dict[str, str] = {}
    retired: dict[str, str] = {}

    def judge(fid: int, fallback_name: str) -> None:
        v = versions.get(fid)
        if not v:
            return
        name = names.get(fid, fallback_name)
        ov = _version_num(v.get("origin_version"))
        if ov is not None and ov > tv:
            too_new[name] = v["origin_version"]
        rv = _version_num(v.get("removed_in_version"))
        if rv is not None and rv <= tv:
            retired[name] = v["removed_in_version"]

    get_re = re.compile(r"\b(\w+)\s*\(\s*(\w+)\s*\)")
    for calc in root.iter("Calculation"):
        scanned = strip_strings(strip_comments(calc.text or ""))
        # Get ( Keyword ) functions are stored decomposed ('get ( windowuuid )')
        for m in get_re.finditer(scanned):
            # lookup names carry both spellings ('Get(WindowUUID)', 'Hole ( FensterUUID )')
            hit = lookup.get(f"{m.group(1)}({m.group(2)})".casefold()) \
                or lookup.get(f"{m.group(1)} ( {m.group(2)} )".casefold())
            if hit:
                judge(hit["function_id"], m.group(0))
        for m in CALL_RE.finditer(scanned):
            for cand in call_name_candidates(m.group(1)):
                hit = lookup.get(cand.casefold())
                if not hit:
                    continue
                judge(hit["function_id"], cand)
                break
    problems = [f"'{n}' needs FM {v}, target is {target_version}"
                for n, v in sorted(too_new.items())]
    problems += [f"'{n}' was removed in FM {v} — FileMaker {target_version} no longer "
                 "resolves it (functions.removed_in_version)"
                 for n, v in sorted(retired.items())]
    if problems:
        res.add("G303b-function-versions", 3, "fail", "; ".join(problems))
    else:
        res.add("G303b-function-versions", 3, "pass",
                f"all built-in functions available in FM {target_version}"
                + (" and none retired by it" if ref.function_retirement_available()
                   else " (retired-function direction: no retirement data in the reference)"))


def _tolerated_elements(ref: Reference) -> set[str]:
    """Step-level chrome/state element names of the target coverage
    (coverage_step_rules) plus the read-tolerance constants."""
    names = {r["element"] for r in ref.coverage_rules()}
    try:
        from .read_tolerance import FM26_CHROME, FM26_STATE
        names |= {tag for _ids, tag, _a in FM26_CHROME} | {tag for _ids, tag, _a in FM26_STATE}
    except ImportError:  # pragma: no cover
        pass
    return names


def _template_shape(template: str) -> dict[str, set[str]]:
    """element path (below Step) -> attribute names, over the whole template
    tree — the shape of the target coverage including nested elements and
    attributes (F-7: 26 attributes BlanksLast/IncludeToolCalls/KeepOriginalData,
    nested PDFSaveType/LightMode/Parameters)."""
    shape: dict[str, set[str]] = {}
    try:
        tpl = ET.fromstring(template)
    except ET.ParseError:
        return shape

    def walk(el: ET.Element, path: str) -> None:
        for child in el:
            p = f"{path}/{child.tag}" if path else child.tag
            attrs = set(child.attrib.keys())
            if not attrs and not len(child) and re.fullmatch(r"\{[a-z0-9_]+\}", (child.text or "").strip()):
                # a text-form target slot (<Field>{target}</Field>): the
                # emitter writes the FIELD form with reference attributes
                # when the value is a field (emit._expand_field_targets)
                attrs |= {"table", "id", "name", "repetition"}
            shape.setdefault(p, set()).update(attrs)
            walk(child, p)

    walk(tpl, "")
    return shape


def _deep_shape_problems(st: ET.Element, sid: int, template: str,
                         tolerated: set[str], ref: Reference) -> list[str]:
    """Every element path and attribute of the instance must exist in the
    resolved template of the target coverage. Repeat-group items and the
    structural <Text/> marker are template elements too, so they pass;
    calculation text is content, not shape."""
    shape = _template_shape(template)
    if not shape:
        return []
    known_paths = set(shape)
    # element_order may name elements the template does not carry (the
    # structural Text marker) — accept them at Step level
    order = {e.strip() for e in ((ref.xml_map(sid) or {}).get("element_order") or "").split(",")}
    problems: list[str] = []

    def walk(el: ET.Element, path: str) -> None:
        for child in el:
            if not path and child.tag in tolerated:
                continue
            p = f"{path}/{child.tag}" if path else child.tag
            if p not in known_paths:
                if not path and child.tag in order:
                    continue
                if path and (path in known_paths or any(k.startswith(path + "/") for k in known_paths)):
                    problems.append(f"id={sid}: element <{p}> not in the FM {ref.target_coverage()} shape")
                continue
            extra = set(child.attrib) - shape[p]
            if extra:
                problems.append(f"id={sid}: <{p}> attribute(s) {sorted(extra)} not in the "
                                f"FM {ref.target_coverage()} shape")
            walk(child, p)

    walk(st, "")
    return problems


def _nodes_at(st: ET.Element, epath: str) -> list[ET.Element]:
    """All elements at a template element path below <Step>; a '[n]' segment
    fans out over every instantiated sibling. '' resolves to the step itself."""
    nodes = [st]
    for seg in [s for s in epath.split("/") if s]:
        tag = seg[:-3] if seg.endswith("[n]") else seg
        nodes = [c for n in nodes for c in n.findall(tag)]
        if not nodes:
            return []
    return nodes


def _options_preserved(res: GateResult, steps: list[ET.Element],
                       ir_steps: list[dict] | None, ref: Reference) -> None:
    """G306: every parsed option must materialize in the emission — element or
    attribute at its reference xml_path, repeat groups via their container —
    or its absence must be explained by a reference rule (element bindings for
    mode-scoped prunes, omit_when_false presence booleans, paste_dropped
    options FileMaker discards anyway — fm_spec 2.6.0). Class check behind
    the silent WebScript prune: user data that vanishes without a finding is a
    fail. Presence only — value fidelity is G109/G110 territory.

    Mirror rules sharpen the check the other way round (step_mirror_elements,
    fm_spec 2.6.0): a set source option (144 title) must have its copy at the
    target path (the Step-level Calculation) — FileMaker writes it there on
    paste, an emission without it is not canonical.
    """
    if ir_steps is None:
        res.add("G306-option-preservation", 3, "skipped",
                "no IR supplied — option preservation not checked")
        return
    if not ref.grammar_available():
        res.add("G306-option-preservation", 3, "skipped",
                "grammar tables not installed — option preservation not checked")
        return
    if len(ir_steps) != len(steps):
        res.add("G306-option-preservation", 3, "skipped",
                f"IR/XML step count mismatch ({len(ir_steps)}/{len(steps)}) — "
                "pairing not possible")
        return
    problems = []
    for ir, st in zip(ir_steps, steps):
        sid = ir.get("step_id")
        if sid is None or int(st.get("id", "-1")) != int(sid):
            continue
        meta = {o["option_key"]: o for o in ref.options(sid)}
        groups = {g["group_key"]: g for g in ref.repeat_groups(sid)}
        # only element bindings explain a SET option's absence (mode-scoped
        # prunes); skeleton rules never do — they strip UNFILLED children,
        # a set option's node always survives them
        explained = [r["element_path"] for r in ref.element_bindings(sid)]
        dropped = ref.paste_dropped_options(sid)
        for key, val in (ir.get("options") or {}).items():
            if key in dropped:
                continue  # FileMaker discards the option on paste — the emitter leaves it out by rule
            epath, attr, text_mode = None, None, False
            if key in groups:
                epath = groups[key]["container_path"]
            else:
                row = meta.get(key)
                if row is None:
                    # numbered fixed-slot key (button_commit_2) -> family row
                    base, _, n = key.rpartition("_")
                    row = meta.get(base) if n.isdigit() else None
                if row is None:
                    continue
                if row.get("omit_when_false") and val == "False":
                    continue  # presence boolean: False = element absent
                path = row.get("xml_path") or ""
                if not path:
                    continue
                if "/@" in path:
                    epath, _, attr = path.rpartition("/@")
                elif path.endswith("/text()"):
                    # mixed-content text slot (202 operation)
                    epath, text_mode = path[:-len("/text()")], True
                else:
                    epath = path
            nodes = _nodes_at(st, epath)
            if attr:
                ok = any(nd.get(attr) is not None for nd in nodes)
            elif text_mode:
                ok = any((nd.text or "").strip() for nd in nodes)
            else:
                ok = bool(nodes)
            if ok:
                continue
            if any(e and (e.startswith(epath) or epath.startswith(e))
                   for e in explained):
                continue  # a binding rule governs this subtree
            problems.append(
                f"line {ir.get('line', '?')} id={sid}: option '{key}' was "
                f"parsed but nothing materialized at '{epath or '@' + str(attr)}'"
                " and no reference rule explains the absence")
        for r in ref.mirror_elements(sid):
            src, tpath = r["source_option"], r["target_path"]
            sval = (ir.get("options") or {}).get(src)
            if sval is None or isinstance(sval, (dict, list)):
                continue
            texts = [(nd.text or "").strip() for nd in _nodes_at(st, tpath)]
            if str(sval).strip() not in texts:
                problems.append(
                    f"line {ir.get('line', '?')} id={sid}: '{src}' is set but its mirror at "
                    f"'{tpath}' is {'missing' if not texts else 'different (' + ', '.join(texts) + ')'}"
                    " — FileMaker writes the source value there on paste (step_mirror_elements)")
    res.add("G306-option-preservation", 3, "fail" if problems else "pass",
            "; ".join(problems)
            or "every parsed option materialized (or is rule-explained)")


_VAR_TEXT_RE = re.compile(r"^\$\$?[A-Za-z_][\w.]*$")


def _value_forms(res: GateResult, steps: list[ET.Element],
                 ir_steps: list[dict] | None, ref: Reference) -> None:
    """G307: the VALUE FORM of every target slot, judged on the emitted
    snippet alone — no IR (the parsed step structure) needed (successor of
    the presence-only G306; fm_spec 2.2.0 `step_options.slot_kind`).

    A target element carries either the field form (table/id/name attributes)
    or a variable as element text. Three things are data loss on paste and
    fail here whatever produced the snippet:
      * bare text that is no variable — FileMaker stores it as a variable of
        that name (paste-verified 26.0.2), so a field name written as text
        silently changes meaning;
      * the attribute form in a `variable_only` slot — FileMaker discards it
        without a diagnostic;
      * a variable in a `field_only` slot.
    With the IR (`--resolved`) one cross-check is added: a resolved field
    reference whose element exists must carry the attribute form
    (table/id/name) — a pruned element is G306's presence question.
    """
    if not ref.grammar_available():
        res.add("G307-value-form", 3, "skipped",
                "grammar tables not installed — value forms not checked")
        return
    paired = ir_steps if ir_steps is not None and len(ir_steps) == len(steps) else None
    problems: list[str] = []
    for i, st in enumerate(steps):
        sid = int(st.get("id", "-1"))
        for o in ref.options(sid):
            if o["option_type"] != "target":
                continue
            path = o.get("xml_path") or ""
            if not path or "/@" in path:
                continue
            kind = ref.slot_kind(sid, o["option_key"])
            slot = f"id={sid}: '{o['option_key']}'"
            nodes = _nodes_at(st, path)
            for nd in nodes:
                has_ref = any(a in nd.attrib for a in ("table", "id", "name"))
                text = (nd.text or "").strip()
                if not has_ref and not text:
                    continue  # unset slot
                if has_ref:
                    if kind == "variable_only":
                        problems.append(
                            f"{slot} carries the attribute form (table/id/name) in a "
                            "variable-only slot — FileMaker discards it on paste "
                            "without a diagnostic")
                elif _VAR_TEXT_RE.match(text):
                    if kind == "field_only":
                        problems.append(
                            f"{slot} holds the variable '{text}' but takes a field "
                            "reference only")
                else:
                    problems.append(
                        f"{slot} holds the text '{text}', which is neither a variable "
                        "($x/$$x) nor a field reference — FileMaker would store it "
                        "as a variable name")
            if paired is not None:
                ir = paired[i]
                val = (ir.get("options") or {}).get(o["option_key"]) if isinstance(ir, dict) else None
                # only the FORM of nodes that exist is judged here — an
                # element a binding rule pruned (245 target container in
                # File mode) is G306's presence question, not a form error
                if isinstance(val, dict) and val.get("_form") == "field" \
                        and kind != "variable_only" and nodes \
                        and not any(nd.get("name") is not None for nd in nodes):
                    problems.append(
                        f"{slot}: the IR holds the field reference "
                        f"'{val.get('table', '?')}::{val.get('name', '?')}' but no "
                        "attribute form reached the XML")
    res.add("G307-value-form", 3, "fail" if problems else "pass",
            "; ".join(problems) or "every target slot carries a form its slot accepts")


def _var_init_check(res: GateResult, ir_steps: list[dict] | None,
                    enabled: bool) -> None:
    """G305: is a variable written as a step target initialised beforehand?

    This is a house CONVENTION, not FileMaker semantics — a target step creates
    the variable by itself, so the check is off unless a setup opts in (see the
    conventions block in docs/agents/codegen-registry.md). It is a typo net: a
    target that never appears in a preceding Set Variable is often a misspelt
    name. Never a fail, always a warning.

    It runs on the IR, not the XML: only there is a target variable
    ({'_form': 'variable'}) reliably distinguishable from a variable merely READ
    inside a calculation. 'Beforehand' is lexical order in the snippet — no flow
    analysis, so a variable set in one If branch counts as initialised.
    """
    if not enabled:
        res.add("G305-var-init", 3, "skipped",
                "variable-initialisation convention not enabled "
                "(--check-var-init / FMGEN_CHECK_VAR_INIT)")
        return
    if ir_steps is None:
        res.add("G305-var-init", 3, "skipped",
                "no IR supplied (gate run without --resolved) — variable "
                "initialisation not checked")
        return
    initialised: set[str] = set()
    missing: list[str] = []
    for step in ir_steps:
        if not step.get("enabled", True):
            continue  # a disabled step neither initialises nor is checked
        options = step.get("options") or {}
        for val in options.values():
            if not (isinstance(val, dict) and val.get("_form") == "variable"):
                continue
            name = (val.get("name") or "").strip()
            if not name:
                continue
            if name.casefold() not in initialised:
                missing.append(
                    f"line {step.get('line')}: '{name}' is written as a target "
                    "without a preceding Set Variable")
            initialised.add(name.casefold())  # exists from here on
        if step.get("step_id") == SET_VARIABLE and isinstance(options.get("name"), str):
            initialised.add(options["name"].strip().casefold())
    res.add("G305-var-init", 3, "warning" if missing else "pass",
            "; ".join(missing) or
            "every variable target is initialised by a preceding Set Variable")


def _value_at_path(st: ET.Element, xml_path: str | None) -> str | None:
    """Value at a step_options.xml_path ('Elem/Sub/@attr' or 'Elem/Sub') below <Step>."""
    if not xml_path:
        return None
    if "@" in xml_path:
        elem_path, _, attr = xml_path.rpartition("/@")
        node = st.find(elem_path) if elem_path else st
        return node.get(attr) if node is not None else None
    node = st.find(xml_path)
    if node is None:
        return None
    return (node.text or "").strip()


def _pair_balance(steps: list[ET.Element]) -> list[str]:
    stack, problems = [], []
    for st in steps:
        sid = int(st.get("id", "-1"))
        if sid in (IF_OPEN, LOOP_OPEN):
            stack.append(sid)
        elif sid == IF_CLOSE:
            if not stack or stack.pop() != IF_OPEN:
                problems.append("End If without matching If")
        elif sid == LOOP_CLOSE:
            if not stack or stack.pop() != LOOP_OPEN:
                problems.append("End Loop without matching Loop")
    for sid in stack:
        problems.append(("If" if sid == IF_OPEN else "Loop") + " never closed")
    return problems
