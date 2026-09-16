"""Read tolerance for FileMaker 26 clipboard snippets (consumer-side pre-stage).

fm_spec's shape layer (`step_xml_map`, options, groups) is FileMaker 22
coverage. A snippet copied from FileMaker 26 carries a few forms the 22
templates cannot account for, and without this module every one of them
surfaces as a lossy finding — the whole step is then flagged although the
information it carries is exactly the 22 information:

  chrome      — presentational elements FileMaker 26 writes on EVERY step
                (`<DisableStepCollapsed state="False"/>`, and `<Restore
                state="False"/>` on comment steps) that carry no option
  spelling    — element names FileMaker 26 corrected (212 `SetLLMAccout` →
                `SetLLMAccount`, 226 `RAGPPrompt` → `RAGPrompt`) and one
                value (`RAGPrompt` → `RAGPromptRequest`)
  wrapping    — 202 moved the operation from mixed-content text into a child
                element (`<ConfigureCoreML><Operation>…`)
  defaults    — NEW 26 options serialized at their default value (39
                `BlanksLast`, 144 `PDFSaveType`, 220 `IncludeToolCalls`, …)

Everything here is read DIRECTION only: the 26 form is normalized to the 22
form the templates know, canonical text is rendered from that, and the emit
side keeps writing 22 shapes (FileMaker 26 pastes them unchanged). A NEW
option that is NOT at its default stays a lossy finding — the text form has
no notation for it — so nothing is dropped silently. The rules are the
consumer-side pre-stage of the coverage model: as fm_spec takes them over as
data they move there and the constants here become a FALLBACK for a
reference without that table — chrome/state live in `coverage_step_rules`
(fm_spec 2.0.0), the spellings and the 202 text hoist in `coverage_renames`
(fm_spec 2.7.0; `Reference.coverage_renames()`); the default-valued new
options are still constants (a later reference release).

Evidence: the same scripts copied to the clipboard from FileMaker 22.0.6 and
from FileMaker 26.0.2 (33 scripts, about 1800 step instances paired one to
one), plus FileMaker 26.0.2 copies of the changed steps with their new options
set. Every rule cites the step it was observed on; a rule is never generalized
beyond that evidence.
"""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET

NOTE_PREFIX = "FM 26 form"

# --- chrome: (step ids or None = every step, child tag, required attrs or None)
# Fallback for a reference without coverage_step_rules (pre-2.0.0); with the
# table present the rules come from the reference (coverage_rules()).
FM26_CHROME: tuple[tuple[tuple[int, ...] | None, str, dict | None], ...] = (
    (None, "DisableStepCollapsed", {"state": "False"}),  # every step, default state
    ((89,), "Restore", {"state": "False"}),   # comment steps only, default state only
)

# --- state: elements that record editor state (a collapsed disabled block,
# the count of hidden steps). Stripped for the template match like chrome,
# but REPORTED as a note — the emitter never writes them, so a script copied
# with a collapsed block comes back expanded.
FM26_STATE: tuple[tuple[tuple[int, ...] | None, str, dict | None], ...] = (
    (None, "DisableStepCollapsed", {"state": "True"}),
    (None, "HiddenStepsCount", None),
)

# --- spelling: (step id, parent path from Step ('.' = Step), 26 tag, 22 tag).
# Order matters: a parent rename precedes the renames underneath it.
# FALLBACK for a reference without coverage_renames (pre-2.7.0); with the
# table present the rows come from the reference (Reference.coverage_renames(),
# rename_kind 'element' / 'text' / 'text_hoist') — the constants below mirror
# the 2.7.0 rows one to one (coverage_resolution_test keeps them in step).
FM26_ELEMENT_RENAMES: tuple[tuple[int, str, str, str], ...] = (
    (212, ".", "SetLLMAccount", "SetLLMAccout"),
    (212, "SetLLMAccout", "AccountName", "AccoutName"),
    (226, "ConfigurePromptTemplate", "RAGPrompt", "RAGPPrompt"),
)

# --- spelling of an element VALUE: (step id, element path, 26 text, 22 text)
FM26_TEXT_RENAMES: tuple[tuple[int, str, str, str], ...] = (
    (226, "ConfigurePromptTemplate/RequestType", "RAGPromptRequest", "RAGPrompt"),
)

# --- wrapping: (step id, element path, child tag whose text is the 22
# mixed-content text of the element)
FM26_TEXT_HOISTS: tuple[tuple[int, str, str], ...] = (
    (202, "ConfigureCoreML", "Operation"),
)

# --- new options at their default: (step id, parent path, tag, attrs at the
# default, text at the default or None = don't care). Dropped ONLY when every
# listed attribute matches, the element has no children and the text matches.
FM26_DEFAULT_ELEMENTS: tuple[tuple[int, str, str, dict, str | None], ...] = (
    (3, ".", "OutputEntireBinaryData", {"state": "False"}, None),
    (3, ".", "SpecifyJSONOptions", {"state": "False"}, None),
    (144, "PDFOptions", "PDFSaveType", {}, "File"),
    (161, "DeviceOptions", "LightMode", {"choice": "Auto"}, None),
    (215, ".", "Option", {"state": "False"}, None),
    (218, ".", "UniversalPathList", {"type": "Embedded"}, ""),
    (219, ".", "DetectVertical", {"state": "False"}, None),
    (219, ".", "RAGSpaceTokensPerTextChunk", {"state": "False"}, None),
)

# --- new attributes at their default on a 22 element: (step id, element
# path, attribute, default value)
FM26_DEFAULT_ATTRS: tuple[tuple[int, str, str, str], ...] = (
    (39, "SortList", "BlanksLast", "False"),
    (220, "LLMRequestWithTools/SlidingWindowVariable", "IncludeToolCalls", "0"),
)


# --- boolean attribute domains of localized builds --------------------------
# fm_spec 2.2.0 registers per boolean option the XML value domain of its
# attribute (step_options.xml_true/xml_false — 74/122 NewWndStyles write
# Yes/No, every other boolean attribute True/False) and, as step_constraints
# `localized_build_defect` (paired 22.0.6 and 26.0.2), that a localized
# FileMaker build serializes exactly those attributes in ITS language. The
# reading side accepts the reference domain, the internal state and the
# spellings a paired corpus has evidenced; anything else is no boolean state
# and stays a lossy finding. Evidence-bound like every table in this module:
# DE from corpus 07 (German 22.0.6 / 26.0.2 build, `Ja`/`Nein` on 74/122/228).
LOCALIZED_BOOLEAN_SPELLINGS: dict[str, bool] = {
    "ja": True, "nein": False,   # de — corpus 07, FileMaker 22.0.6 + 26.0.2
}


def read_boolean_state(value: str | None, domain: tuple[str, str] = ("True", "False")) -> bool | None:
    """The boolean state an attribute value denotes, or None when the value
    is no boolean state at all. Accepted, in this order: the attribute's XML
    domain (exact, then case-insensitive), the internal True/False, and the
    localized-build spellings above."""
    v = (value or "").strip()
    if v == domain[0]:
        return True
    if v == domain[1]:
        return False
    cf = v.casefold()
    if cf == domain[0].casefold():
        return True
    if cf == domain[1].casefold():
        return False
    if cf == "true":
        return True
    if cf == "false":
        return False
    return LOCALIZED_BOOLEAN_SPELLINGS.get(cf)


# The two value domains a boolean attribute is written in. A LITERAL boolean
# attribute of a template (228 `<NewWndStyles Close="Yes" …/>` — the
# reference models those window styles as fixed, not as options) declares
# its domain by its own spelling.
_BOOLEAN_LITERAL_DOMAINS: tuple[tuple[str, str], ...] = (("True", "False"), ("Yes", "No"))


def boolean_literal_domain(literal: str | None) -> tuple[str, str] | None:
    """The value domain a literal boolean attribute value belongs to, or None
    when the literal is no boolean word."""
    for domain in _BOOLEAN_LITERAL_DOMAINS:
        if literal in domain:
            return domain
    return None


def literal_boolean_attrs(template_xml: str) -> list[tuple[str, str, tuple[str, str]]]:
    """(element path below Step, attribute, domain) for every literal boolean
    attribute of a snippet template — attributes whose value is a boolean
    word and no placeholder. Empty when the template is not well-formed."""
    try:
        root = ET.fromstring(template_xml)
    except ET.ParseError:
        return []
    out: list[tuple[str, str, tuple[str, str]]] = []

    def walk(elem: ET.Element, path: str) -> None:
        for child in elem:
            cpath = f"{path}/{child.tag}" if path else child.tag
            for attr, val in child.attrib.items():
                domain = boolean_literal_domain(val)
                if domain is not None:
                    out.append((cpath, attr, domain))
            walk(child, cpath)

    walk(root, "")
    return out


def normalize_boolean_domains(step: ET.Element, options: list[dict],
                              template_xml: str | None = None) -> list[str]:
    """Rewrite localized-build spellings of boolean attributes of one <Step>
    IN PLACE to the attribute's reference domain (`Ja` -> `Yes`): the
    comparison-side twin of the decompiler's read normalization, used by
    valcmp on the fixture side. Two sources name the attributes and their
    domain: the step's option rows with xml_true/xml_false (`options`,
    Reference.options — fixed slots ([n] paths) are not touched, no curated
    domain sits there) and, when the snippet template is given, its LITERAL
    boolean attributes (228 window styles). Returns one note per rewrite."""
    targets: list[tuple[str, str, tuple[str, str]]] = []
    for o in options:
        if o.get("option_type") != "boolean" or not (o.get("xml_true") and o.get("xml_false")):
            continue
        path = o.get("xml_path") or ""
        if "/@" not in path or "[n]" in path:
            continue
        epath, _, attr = path.rpartition("/@")
        targets.append((epath, attr, (str(o["xml_true"]), str(o["xml_false"]))))
    if template_xml:
        targets += literal_boolean_attrs(template_xml)
    notes: list[str] = []
    for epath, attr, domain in targets:
        for node in step.findall(epath):
            val = node.get(attr)
            if val is None or val in domain:
                continue
            state = read_boolean_state(val, domain)
            if state is None:
                continue
            node.set(attr, domain[0] if state else domain[1])
            notes.append(f"{NOTE_PREFIX}: {epath}/@{attr} '{val}' read as "
                         f"'{domain[0] if state else domain[1]}' (localized build)")
    return notes


def _find_parent(step: ET.Element, path: str) -> ET.Element | None:
    return step if path == "." else step.find(path)


def _attrs_match(elem: ET.Element, attrs: dict | None) -> bool:
    return not attrs or all(elem.attrib.get(k) == v for k, v in attrs.items())


def _rules_from_reference(rules: list[dict] | None):
    """coverage_step_rules rows -> (chrome, state) tuples in the constant
    format; None when the reference carries no rules (fallback constants)."""
    if not rules:
        return None, None
    chrome, state = [], []
    for r in rules:
        ids = None
        if r.get("step_ids"):
            ids = tuple(int(x) for x in str(r["step_ids"]).split(",") if x.strip())
        attrs = None
        if r.get("attrs"):
            try:
                attrs = json.loads(r["attrs"]) if isinstance(r["attrs"], str) else dict(r["attrs"])
            except ValueError:
                attrs = None
        (chrome if r.get("rule_kind") == "chrome" else state).append((ids, r["element"], attrs))
    return tuple(chrome), tuple(state)


def _renames_from_reference(renames: list[dict] | None):
    """coverage_renames rows -> (element renames, text renames, text hoists)
    in the constant format; None when the reference carries no rows
    (fallback constants). Row order is the reference order (parent first)."""
    if not renames:
        return None
    elements, texts, hoists = [], [], []
    for r in renames:
        sid = int(r["step_id"])
        kind = r.get("rename_kind")
        if kind == "element":
            elements.append((sid, r["path"], r["coverage_name"], r["base_name"]))
        elif kind == "text":
            texts.append((sid, r["path"], r["coverage_name"], r["base_name"]))
        elif kind == "text_hoist":
            hoists.append((sid, r["path"], r["coverage_name"]))
    return tuple(elements), tuple(texts), tuple(hoists)


def strip_chrome(step: ET.Element, step_id: int | None,
                 rules: list[dict] | None = None) -> list[str]:
    """Remove the presentational FM 26 elements (chrome) and the editor-state
    elements from one <Step>. Chrome yields a tolerance note, state a
    distinct 'state' note (the information is not carried — the emitter
    never writes state). Rules come from the reference's coverage_step_rules
    when given, else from the constants. Safe on 22 snippets: nothing matches."""
    notes: list[str] = []
    chrome, state = _rules_from_reference(rules)
    if chrome is None:
        chrome, state = FM26_CHROME, FM26_STATE
    for kind, table in (("chrome", chrome), ("state", state)):
        for ids, tag, attrs in table:
            if ids is not None and step_id not in ids:
                continue
            for child in list(step):
                if child.tag == tag and len(child) == 0 and _attrs_match(child, attrs):
                    if kind == "chrome" and (child.text or "").strip():
                        continue
                    step.remove(child)
                    if kind == "chrome":
                        notes.append(f"{NOTE_PREFIX}: chrome <{tag}> dropped")
                    else:
                        detail = (child.text or "").strip() or \
                            " ".join(f'{k}="{v}"' for k, v in child.attrib.items())
                        notes.append(f"{NOTE_PREFIX}: editor state <{tag}> {detail} "
                                     "not carried (the emitter never writes it)")
    return notes


def apply_fm26_read_tolerance(step: ET.Element, step_id: int | None,
                              target_coverage: str = "22",
                              rules: list[dict] | None = None,
                              renames: list[dict] | None = None) -> list[str]:
    """Normalize one <Step> element IN PLACE for the template match of the
    TARGET coverage. Chrome and editor state are always stripped. With target
    22 the FileMaker 26 forms are additionally translated to the 22 form the
    standard templates describe (renames, hoists, new options at their
    default — non-default new options stay for the match to report them as
    lossy). With target 26 the templates ARE the 26 shapes, so nothing else
    is touched. Spellings and the text hoist come from the reference's
    coverage_renames when given (`renames`), else from the constants.
    Returns the notes (empty for a 22 snippet under target 22).
    """
    notes = strip_chrome(step, step_id, rules)
    if step_id is None or str(target_coverage) != "22":
        return notes

    tables = _renames_from_reference(renames)
    element_renames, text_renames, text_hoists = tables if tables else (
        FM26_ELEMENT_RENAMES, FM26_TEXT_RENAMES, FM26_TEXT_HOISTS)

    for sid, parent_path, tag26, tag22 in element_renames:
        if sid != step_id:
            continue
        parent = _find_parent(step, parent_path)
        if parent is None:
            continue
        for child in parent:
            if child.tag == tag26:
                child.tag = tag22
                notes.append(f"{NOTE_PREFIX}: <{tag26}> read as <{tag22}>")

    for sid, path, text26, text22 in text_renames:
        if sid != step_id:
            continue
        elem = step.find(path)
        if elem is not None and (elem.text or "").strip() == text26:
            elem.text = text22
            notes.append(f"{NOTE_PREFIX}: <{elem.tag}> value '{text26}' read as '{text22}'")

    for sid, path, child_tag in text_hoists:
        if sid != step_id:
            continue
        elem = step.find(path)
        if elem is None:
            continue
        child = elem.find(child_tag)
        if child is not None and len(child) == 0 and not (elem.text or "").strip():
            elem.text = (child.text or "").strip()
            elem.remove(child)
            notes.append(f"{NOTE_PREFIX}: <{elem.tag}>/<{child_tag}> read as element text")

    for sid, parent_path, tag, attrs, text in FM26_DEFAULT_ELEMENTS:
        if sid != step_id:
            continue
        parent = _find_parent(step, parent_path)
        if parent is None:
            continue
        for child in list(parent):
            if child.tag != tag or len(child) or not _attrs_match(child, attrs):
                continue
            if text is not None and (child.text or "").strip() != text:
                continue
            if set(child.attrib) - set(attrs):
                continue  # an attribute the rule does not know — leave it
            parent.remove(child)
            notes.append(f"{NOTE_PREFIX}: new option <{tag}> at its default dropped")

    for sid, path, attr, default in FM26_DEFAULT_ATTRS:
        if sid != step_id:
            continue
        for elem in step.findall(path):
            if elem.attrib.get(attr) == default:
                del elem.attrib[attr]
                notes.append(f"{NOTE_PREFIX}: new attribute {attr}='{default}' (default) dropped")

    return notes
