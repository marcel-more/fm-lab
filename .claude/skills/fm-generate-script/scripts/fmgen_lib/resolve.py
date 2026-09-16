"""P4 reference resolution against the fm-lab object catalog (fm_catalog.duckdb).

Every object reference in the IR is resolved to a real ID (+UUID where the
catalog has one) and recorded in a machine-readable resolution report:

  resolved     — real IDs found; emitted into the snippet
  unresolved   — name not in the catalog; severity 'error' stops the pipeline
  new_objects  — {{NEW:...}} placeholders; emitted name-only, to create before paste
  findings     — the reference EXISTS but is used wrongly (e.g. a custom function
                 called with the wrong number of arguments); severity 'error'
                 stops the pipeline just like an unresolved reference
  assumptions  — target file, FM version, fallback modes

Resolution modes come from fm_spec.ref_element_semantics:
  by-id / by-name-fallback — resolve to real IDs; name-only fallback ONLY when
  the target file is not in the catalog (concept P4, explicitly reported)
  by-id-strict — name fallback forbidden (e.g. PrivilegeSet)
  by-name / by-name-only — no catalog IDs (Window, CustomFunction, Plugin)

All catalog joins are File_Name-scoped: FileMaker numeric IDs are only unique
per file (see memory: layout-id-not-globally-unique).
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field

from .db import Database, Reference, sql_quote
from .textform import (CALL_RE, NEW_IN_CALC_RE, ParsedStep,
                       call_name_candidates, matching_paren, render_canonical,
                       render_ref, split_args, strip_comments, strip_strings)

# option xml_path leaf -> ref_element_semantics.element
_XMLPATH_ELEMENT = {
    "Field": "Field", "Layout": "Layout", "Script": "Script",
    "ValueList": "ValueList", "Table": "Table", "FileReference": "DataSource",
    "Window": "Window", "Object": "Object", "PrivilegeSet": "PrivilegeSet",
    "CustomMenuSet": "CustomMenuSet", "ScriptName": "Script",
    "BaseTable": "BaseTable",
}

def _xmlpath_element(xml_path: str | None) -> str | None:
    """Map an option's xml_path onto its ref_element_semantics element.

    Identity sits on the leaf, not on the container: a Field nested under
    Query/RequestRow/Criteria/ is still a Field, and the callback block of
    Perform Script On Server with Callback holds its FileReference and
    ScriptName one level down. Try the first segment (flat options), then the
    last element segment. Attribute steps (@state) never name an element.
    """
    segs = [s.split("[")[0] for s in (xml_path or "").split("/")
            if s and not s.startswith("@")]
    if not segs:
        return None
    return _XMLPATH_ELEMENT.get(segs[0]) or _XMLPATH_ELEMENT.get(segs[-1])


def _option_section(xml_path: str | None) -> str:
    """Container element an option lives in — "" for top level. Mirrors
    textform._option_section so parser and resolver agree on the grouping."""
    segs = [s.split("[")[0] for s in (xml_path or "").split("/")
            if s and not s.startswith("@")]
    return segs[0] if len(segs) > 1 else ""


@dataclass
class Report:
    target_file: str | None = None
    resolved: list[dict] = field(default_factory=list)
    unresolved: list[dict] = field(default_factory=list)
    new_objects: list[dict] = field(default_factory=list)
    findings: list[dict] = field(default_factory=list)
    assumptions: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def has_errors(self) -> bool:
        return (any(u.get("severity") == "error" for u in self.unresolved)
                or any(f.get("severity") == "error" for f in self.findings))

    def as_dict(self) -> dict:
        return {
            "target_file": self.target_file,
            "resolved": self.resolved,
            "unresolved": self.unresolved,
            "new_objects": self.new_objects,
            "findings": self.findings,
            "assumptions": self.assumptions,
            "warnings": self.warnings,
        }


class Resolver:
    def __init__(self, catalog: Database, ref: Reference, target_file: str):
        self.cat = catalog
        self.ref = ref
        self.file = target_file
        self.report = Report(target_file=target_file)
        self.file_row = self._load_file()
        self._calc_ctx: dict | None = None
        # custom functions declared as {{NEW:CustomFunction:...}} in a calc —
        # snippet-wide: declaring once exempts every use in the same draft
        self._declared_new_cf: set[str] = set()
        # elements without a ref_element_semantics row, reported once each
        self._semantics_gaps: set[str] = set()

    # ------------------------------------------------------------ file context

    def _load_file(self) -> dict | None:
        rows = self.cat.query(
            "SELECT File_Name, FileMaker_Version, Has_DDR_INFO FROM FilesCatalog "
            f"WHERE File_Name = {sql_quote(self.file)}")
        if rows:
            self.report.assumptions.append(
                f"target file '{rows[0]['File_Name']}' per FilesCatalog, "
                f"FM {rows[0]['FileMaker_Version']}")
            return rows[0]
        names = [r["File_Name"] for r in self.cat.query("SELECT File_Name FROM FilesCatalog")]
        close = difflib.get_close_matches(self.file, names, n=3, cutoff=0.5)
        self.report.warnings.append(
            f"target file '{self.file}' not in FilesCatalog"
            + (f" (close: {', '.join(close)})" if close else "")
            + " — all references fall back to name-only placeholders (id=1)")
        return None

    # ------------------------------------------------------------ entry point

    def resolve(self, parsed: list[ParsedStep]) -> None:
        self._collect_new_declarations(parsed)
        for ps in parsed:
            for opt in self.ref.options(ps.step_id):
                if opt["option_type"] not in ("object_ref", "target"):
                    continue
                element = _xmlpath_element(opt["xml_path"])
                if not element:
                    if opt["option_type"] == "target":
                        self._resolve_unmapped_target(ps, opt)
                    continue
                for key in self._instance_keys(ps, opt):
                    self._resolve_ref(ps, key, element, opt["xml_path"])
            self._resolve_groups(ps)
            self._mark_calc_repetition(ps)
            for calc in self._calcs(ps):
                self._scan_calc(ps, calc)

    def _resolve_unmapped_target(self, ps: ParsedStep, opt: dict) -> None:
        """A target slot whose template element names no catalog element
        (220 `save_message_history_to` -> SlidingWindowVariable) used to be
        skipped silently — neither checked nor reported, so a phantom field
        passed the resolver. Now the slot's value form decides:

          * `variable_only` slot: form check only — a variable needs no
            catalog; anything else is an error finding (the lint L010 and
            the emit guard say the same, this is the resolver's own line);
          * a field reference elsewhere resolves as a Field against
            FieldsForTables like any top-level target;
          * any other reference form is reported as a warning — the value
            was not verified against the catalog."""
        kind = self.ref.slot_kind(ps.step_id, opt["option_key"])
        for key in self._instance_keys(ps, opt):
            val = ps.options.get(key)
            if not isinstance(val, dict) or val.get("_form") == "variable":
                continue
            if kind == "variable_only":
                self._finding(
                    ps, "R010-slot-form", "error", render_ref(val),
                    f"'{render_ref(val)}' in '{key}' — this slot takes a variable "
                    "($x/$$x) only; FileMaker offers no field there and would "
                    "store the name as a variable name, so nothing was looked up")
                continue
            if val.get("_form") == "field":
                self._resolve_ref_value(ps, val, "Field", opt["xml_path"])
                continue
            self._finding(
                ps, "R011-unmapped-slot", "warning", render_ref(val),
                f"'{render_ref(val)}' in '{key}' — the slot names no catalog "
                "element in the reference, the value was not verified")

    def _mark_calc_repetition(self, ps: ParsedStep) -> None:
        """Byte-true calc-repetition form (native FileMaker convention): when a
        step carries a top-level Repetition/Calculation value, its top-level
        Field target must expose the marker attribute repetition="0" (the
        attribute and the <Repetition> element co-occur only for a *calculated*
        repetition). A literal repetition already carried by the field ref
        (TO::Field[2]) is left untouched — that is the attribute-only form."""
        xmap = self.ref.xml_map(ps.step_id)
        # only steps whose Field actually emits an optional repetition attribute
        # can carry the marker; skip the rest so nothing leaks into their refs
        if not xmap or 'repetition="{' not in (xmap.get("snippet_template") or ""):
            return
        opts = self.ref.options(ps.step_id)
        if not any(o["option_type"] == "repetition"
                   and o["xml_path"] == "Repetition/Calculation"
                   and o["option_key"] in ps.options for o in opts):
            return
        for o in opts:
            if o["option_type"] in ("object_ref", "target") and o["xml_path"] == "Field":
                ref_val = ps.options.get(o["option_key"])
                if (isinstance(ref_val, dict) and ref_val.get("_form") != "variable"
                        and not ref_val.get("repetition")):
                    ref_val["repetition"] = "0"
                return

    def _resolve_groups(self, ps: ParsedStep) -> None:
        """T9 repeat groups: run every reference-typed item value through the
        same resolution as its flat counterpart, and scan item calculations.
        Items are mutated in place (list holds the same dicts)."""
        groups = self.ref.repeat_groups(ps.step_id)
        if not groups:
            return
        metas = {o["option_key"]: o for o in self.ref.options(ps.step_id)}
        by_key = {g["group_key"]: g for g in groups}
        step_table = self._step_table_ref(ps, metas)

        def qualify(o: dict, v) -> None:
            """A Field item written as a bare name ("ID") takes the table
            occurrence of the step's single Table reference (35 Import Records
            `target_table`): the item template carries id and name only, so
            the item has no table of its own — mirror of
            decompile._qualify_item_fields."""
            if (step_table and isinstance(v, dict) and v.get("_form") == "named"
                    and not v.get("table") and v.get("name")
                    and _xmlpath_element(o["xml_path"]) == "Field"):
                v["table"] = step_table
                v["_form"] = "field"
                self.report.assumptions.append(
                    f"line {ps.line}: '{o['option_key']}' item '{v['name']}' qualified "
                    f"with the step's table occurrence '{step_table}'")

        def handle_items(g: dict, items: list) -> None:
            for item in items:
                if g["item_form"] == "scalar" or not isinstance(item, dict):
                    o = metas.get(g["group_key"])
                    if isinstance(item, dict) and o and \
                            o["option_type"] in ("object_ref", "target"):
                        qualify(o, item)
                        self._resolve_ref_value(
                            ps, item, _xmlpath_element(o["xml_path"]), o["xml_path"])
                    elif isinstance(item, str) and o and \
                            o["option_type"] in ("calculation", "repetition"):
                        self._scan_calc(ps, item)
                    continue
                for k, v in item.items():
                    if k in by_key and isinstance(v, list):
                        handle_items(by_key[k], v)
                        continue
                    o = metas.get(k)
                    if o is None:
                        continue
                    if o["option_type"] in ("object_ref", "target") and isinstance(v, dict):
                        qualify(o, v)
                        self._resolve_ref_value(
                            ps, v, _xmlpath_element(o["xml_path"]), o["xml_path"])
                    elif o["option_type"] in ("calculation", "repetition") and isinstance(v, str):
                        self._scan_calc(ps, v)

        for g in groups:
            if g["parent_group"]:
                continue
            val = ps.options.get(g["group_key"])
            if val is None:
                continue
            handle_items(g, val if isinstance(val, list) else [val])

    def _step_table_ref(self, ps: ParsedStep, metas: dict) -> str | None:
        """Name of the step's single top-level Table reference (an object_ref
        option whose xml_path is the Table element itself, 35 `target_table`)
        when the draft names it — None otherwise."""
        cands = [o for o in metas.values()
                 if o["option_type"] == "object_ref"
                 and _xmlpath_element(o["xml_path"]) == "Table"
                 and "/" not in (o["xml_path"] or "")]
        if len(cands) != 1:
            return None
        val = ps.options.get(cands[0]["option_key"])
        if isinstance(val, dict):
            return val.get("table") or val.get("name") or None
        return None

    def _calc_items(self, ps: ParsedStep) -> list[tuple[str, str]]:
        out = []
        for o in self.ref.options(ps.step_id):
            if o["option_type"] in ("calculation", "repetition"):
                v = ps.options.get(o["option_key"])
                if isinstance(v, str):
                    out.append((o["option_key"], v))
        return out

    def _calcs(self, ps: ParsedStep) -> list[str]:
        return [v for _, v in self._calc_items(ps)]

    # ------------------------------------------------- {{NEW:...}} in a calc

    def _collect_new_declarations(self, parsed: list[ParsedStep]) -> None:
        """Pre-pass over every calculation: register {{NEW:CustomFunction:X}}
        as an object to create before paste and strip the marker from the IR.

        Stripping is not cosmetic — without it the marker would travel verbatim
        through the emitter into the snippet and land in FileMaker as part of the
        formula. It runs BEFORE the per-step scan so the bare name left behind is
        already covered by the exemption list and is not reported as unknown.
        """
        for ps in parsed:
            changed = False
            for key, calc in self._calc_items(ps):
                if "{{NEW:" not in calc:
                    continue
                stripped = NEW_IN_CALC_RE.sub(
                    lambda m: self._new_declaration(ps, m), calc)
                if stripped != calc:
                    ps.options[key] = stripped
                    changed = True
            if changed:
                # the draft-level marker is gone from the values, so the
                # canonical text in the report must show what is delivered
                ps.canonical_text = render_canonical(ps, self.ref)

    def _new_declaration(self, ps: ParsedStep, m: re.Match) -> str:
        """Replacement for one {{NEW:...}} inside a calculation."""
        new_type, name = m.group(1), m.group(2).strip()
        if new_type != "CustomFunction":
            # Only custom functions have a meaning as a bare token inside a
            # formula. Keep the marker so the value cannot ship silently, and
            # say so — an unfilled marker in the XML is worse than a stop.
            self._finding(
                ps, "R002-new-marker", "error", m.group(0),
                f"'{{{{NEW:{new_type}:...}}}}' is not supported inside a "
                "calculation — only {{NEW:CustomFunction:Name}} is; use a real "
                "object reference at the option level instead")
            return m.group(0)
        existing = self._calc_context()["cf_lower"].get(name.casefold()) \
            if self.file_row is not None else None
        if existing is not None:
            self.report.warnings.append(
                f"line {ps.line}: custom function '{name}' is declared as new but "
                f"already exists in '{self.file}' — the declaration is redundant")
        elif name.casefold() not in self._declared_new_cf:
            self._declared_new_cf.add(name.casefold())
            self.report.new_objects.append({
                "type": "CustomFunction", "ref": name,
                "action": "create before paste", "line": ps.line,
            })
        return name

    @staticmethod
    def _instance_keys(ps: ParsedStep, opt: dict) -> list[str]:
        """Option keys actually present for this option.

        A repeating group is declared ONCE in the reference, with the slot in
        the xml_path (Show Custom Dialog: input_field ->
        InputFields/InputField[n]/Field). Template and text form address the
        slots individually (input1_field .. input3_field), so the declared key
        never appears verbatim in a parsed step — expand it to the slot keys
        that are present. Flat options return their own key unchanged.
        """
        key = opt["option_key"]
        if "[n]" not in (opt["xml_path"] or ""):
            return [key] if key in ps.options else []
        head, _, tail = key.partition("_")
        if not tail:
            return []
        pat = re.compile(rf"^{re.escape(head)}(\d+)_{re.escape(tail)}$")
        return sorted((k for k in ps.options if pat.match(k)),
                      key=lambda k: int(pat.match(k).group(1)))

    # ------------------------------------------------------ object references

    def _resolve_ref(self, ps: ParsedStep, key: str, element: str,
                     xml_path: str | None = None) -> None:
        self._resolve_ref_value(ps, ps.options[key], element, xml_path)

    def _resolve_ref_value(self, ps: ParsedStep, ref_val, element: str,
                           xml_path: str | None = None) -> None:
        if not isinstance(ref_val, dict):
            return
        if ref_val.get("_form") == "variable":
            # Script-local variable: it has no catalog identity, so it is
            # neither resolved nor unresolved — leave it for the emitter to
            # write out verbatim.
            return
        semantics = self.ref.ref_element_semantics().get(element)
        if semantics is None:
            # Reference gap: every element a handler exists for is a row of
            # ref_element_semantics (BaseTable since fm_spec 2.2.0 — the last
            # consumer-side stand-in went with it). Resolved by name only,
            # reported once per element so the reference can be completed.
            if element not in self._semantics_gaps:
                self._semantics_gaps.add(element)
                self.report.warnings.append(
                    f"reference gap: ref_element_semantics has no row for element "
                    f"'{element}' — resolved by name only")
            semantics = {}
        mode = semantics.get("resolution", "by-name")

        if ref_val.get("new"):
            self.report.new_objects.append({
                "type": ref_val.get("new_type", element), "ref": render_ref(ref_val),
                "action": "create before paste", "line": ps.line,
            })
            ref_val["id"] = 1
            return
        if element == "DataSource" and (xml_path or "").endswith("FileReference"):
            # A FileReference needs a numeric id, so it does not take the
            # generic by-name shortcut below. Next to a script reference it is
            # resolved together with the script in _script()/_external_file();
            # a step that only names a file (33 Open File, 34 Close File) has
            # no script option in its section and resolves the data source
            # here. In degraded mode (target file absent) fall back to the
            # name form so the FileReference group stays complete for the emitter.
            if self.file_row is None:
                ref_val["id"] = 1
                ref_val["fallback"] = "by-name"
                return
            section = _option_section(xml_path)
            if not self._section_has_script(ps, section):
                self._external_file(ps, section)
            return
        if mode in ("by-name", "by-name-only"):
            return  # literal name, no catalog IDs (Window, Object, ...)
        if self.file_row is None:
            if mode == "by-id-strict":
                self._unresolved(ps, element, ref_val, "error",
                                 f"{element} resolves by id in FileMaker — "
                                 "name fallback is not allowed and the target file "
                                 "is not in the catalog")
            else:
                ref_val["id"] = 1
                ref_val["fallback"] = "by-name"
            return

        if element == "Script":
            # the file the script lives in is the FileReference of the SAME
            # section, so a callback script resolves against callback_file
            self._script(ps, ref_val, _option_section(xml_path))
            return
        handler = {
            "Field": self._field, "Layout": self._layout,
            "ValueList": self._valuelist, "Table": self._table,
            "DataSource": self._datasource, "PrivilegeSet": self._privilegeset,
            "BaseTable": self._basetable, "CustomMenuSet": self._custommenuset,
        }.get(element)
        if handler is None:
            return
        handler(ps, ref_val)

    def _hit(self, ps: ParsedStep, element: str, ref_val: dict, row: dict) -> None:
        entry = {"type": element, "ref": render_ref(ref_val), "line": ps.line}
        entry.update({k: v for k, v in row.items() if v is not None})
        self.report.resolved.append(entry)
        ref_val["id"] = row["id"]
        if "table" in row:
            ref_val["table"] = row["table"]
        if "name" in row:
            ref_val["name"] = row["name"]
        if "comment" in row:
            ref_val["comment"] = row["comment"]

    def _unresolved(self, ps: ParsedStep, element: str, ref_val: dict,
                    severity: str, msg: str, suggestion: str | None = None) -> None:
        self.report.unresolved.append({
            "type": element, "ref": render_ref(ref_val), "line": ps.line,
            "severity": severity, "message": msg,
            **({"suggestion": suggestion} if suggestion else {}),
        })

    def _suggest(self, name: str, candidates: list[str]) -> str | None:
        close = difflib.get_close_matches(name, candidates, n=1, cutoff=0.6)
        return close[0] if close else None

    def _field(self, ps: ParsedStep, ref_val: dict) -> None:
        to_name, f_name = ref_val.get("table"), ref_val.get("name")
        if not to_name:
            self._unresolved(ps, "Field", ref_val, "error",
                             "field reference without table occurrence")
            return
        tos = self.cat.query(
            "SELECT TO_Name, BT_Name, DS_Name FROM TableOccurrenceCatalog "
            f"WHERE TO_Name = {sql_quote(to_name)} AND File_Name = {sql_quote(self.file)}")
        if not tos:
            cands = [r["TO_Name"] for r in self.cat.query(
                f"SELECT TO_Name FROM TableOccurrenceCatalog WHERE File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "Field", ref_val, "error",
                             f"table occurrence '{to_name}' not in '{self.file}'",
                             self._suggest(to_name, cands))
            return
        to = tos[0]
        field_file = self.file
        if to["DS_Name"]:  # external TO: base table lives in the data-source file
            field_file = to["DS_Name"]
        rows = self.cat.query(
            "SELECT Field_ID, Field_Name, Field_UUID FROM FieldsForTables "
            f"WHERE Table_Name = {sql_quote(to['BT_Name'])} "
            f"AND Field_Name = {sql_quote(f_name)} AND File_Name = {sql_quote(field_file)}")
        if not rows:
            cands = [r["Field_Name"] for r in self.cat.query(
                "SELECT Field_Name FROM FieldsForTables "
                f"WHERE Table_Name = {sql_quote(to['BT_Name'])} AND File_Name = {sql_quote(field_file)}")]
            sug = self._suggest(f_name, cands)
            self._unresolved(ps, "Field", ref_val, "error",
                             f"field '{f_name}' not in base table '{to['BT_Name']}'"
                             + (f" (file '{field_file}')" if field_file != self.file else ""),
                             f"{to_name}::{sug}" if sug else None)
            return
        self._hit(ps, "Field", ref_val, {
            "id": rows[0]["Field_ID"], "name": rows[0]["Field_Name"],
            "table": to_name, "uuid": rows[0]["Field_UUID"], "file": field_file,
        })

    def _layout(self, ps: ParsedStep, ref_val: dict) -> None:
        rows = self.cat.query(
            "SELECT L_ID, L_Name, L_UUID, L_TO_Name FROM Layouts "
            f"WHERE L_Name = {sql_quote(ref_val.get('name'))} AND File_Name = {sql_quote(self.file)}")
        if not rows:
            cands = [r["L_Name"] for r in self.cat.query(
                f"SELECT L_Name FROM Layouts WHERE File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "Layout", ref_val, "error",
                             f"layout '{ref_val.get('name')}' not in '{self.file}'",
                             self._suggest(ref_val.get("name") or "", cands))
            return
        row = rows[0]
        if ref_val.get("table") and row["L_TO_Name"] and ref_val["table"] != row["L_TO_Name"]:
            self.report.warnings.append(
                f"line {ps.line}: layout '{row['L_Name']}' is based on TO "
                f"'{row['L_TO_Name']}', draft says '{ref_val['table']}' — using catalog value")
            ref_val["table"] = row["L_TO_Name"]
        self._hit(ps, "Layout", ref_val, {
            "id": row["L_ID"], "name": row["L_Name"], "uuid": row["L_UUID"],
            "file": self.file,
        })

    def _file_in_catalog(self, name: str) -> bool:
        return bool(self.cat.query(
            f"SELECT 1 FROM FilesCatalog WHERE File_Name = {sql_quote(name)}"))

    def _file_option_key(self, ps: ParsedStep, section: str) -> str | None:
        """Key of the FileReference option belonging to `section` — `file` at the
        top level, `callback_file` inside <CallbackScript>, and so on."""
        for o in self.ref.options(ps.step_id):
            if o["option_type"] != "object_ref":
                continue
            segs = [x.split("[")[0] for x in (o["xml_path"] or "").split("/")
                    if x and not x.startswith("@")]
            if segs and segs[-1] == "FileReference" and _option_section(o["xml_path"]) == section:
                return o["option_key"]
        return None

    def _external_file(self, ps: ParsedStep, section: str = "") -> dict | None:
        """Resolve the `from file:` option of an external script call.

        FileMaker stores such a call as a FileReference — the data source *as
        declared in the calling file* — plus a Script reference whose id is the
        script's id **in the referenced file**. The two ids come from different
        catalogs, and neither is the calling file's own ScriptCatalog, so the
        data source has to be resolved before the script can be looked up.

        The DataSource element itself carries `resolution = by-name` in
        ref_element_semantics, so the generic `_resolve_ref` traversal returns
        before reaching a handler. That is correct for steps that merely name a
        file, but an external script call needs the numeric DS_ID — hence the
        explicit resolution here.

        Returns the data-source row, or None when the step carries no file
        option **or** the option could not be resolved (the error is reported).
        """
        key = self._file_option_key(ps, section)
        ref_val = ps.options.get(key) if key else None
        if not isinstance(ref_val, dict) or not ref_val.get("name"):
            return None
        name = ref_val["name"]
        rows = self.cat.query(
            "SELECT ds.DS_ID, ds.DS_Name, ds.DS_UUID, ds.Path, m.Resolved_File "
            "FROM ExternalDataSourceCatalog ds "
            "LEFT JOIN DataSourceFileMap m "
            "  ON m.DS_UUID = ds.DS_UUID AND m.File_Name = ds.File_Name "
            f"WHERE ds.File_Name = {sql_quote(self.file)} "
            f"AND ds.DS_Name = {sql_quote(name)}")
        if not rows:
            cands = [r["DS_Name"] for r in self.cat.query(
                "SELECT DS_Name FROM ExternalDataSourceCatalog "
                f"WHERE File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "DataSource", ref_val, "error",
                             f"data source '{name}' is not declared in "
                             f"'{self.file}' — FileMaker resolves the "
                             "FileReference by id, name fallback is invalid",
                             self._suggest(name, cands))
            return None
        row = rows[0]
        # Resolved_File is the authoritative data-source -> file mapping;
        # fall back to the declared name for catalogs written before it existed.
        row["target_file"] = row["Resolved_File"] or row["DS_Name"]
        self._hit(ps, "DataSource", ref_val, {
            "id": row["DS_ID"], "name": row["DS_Name"],
            "uuid": row["DS_UUID"], "file": row["target_file"],
        })
        # The FileReference element carries the declared path verbatim
        # (<UniversalPathList>); _hit only propagates id/name/table.
        if row["Path"]:
            ref_val["path"] = row["Path"]
        return row

    def _script(self, ps: ParsedStep, ref_val: dict, section: str = "") -> None:
        file_key = self._file_option_key(ps, section)
        has_file = (file_key is not None
                    and isinstance(ps.options.get(file_key), dict)
                    and bool(ps.options[file_key].get("name")))
        ext = self._external_file(ps, section)
        if has_file and ext is None:
            return  # data-source error already reported; the scope is unknown
        scope = ext["target_file"] if ext else self.file

        if ext and not self._file_in_catalog(scope):
            # The data source is declared but its file was not exported. Script
            # refs resolve by-name-fallback in FileMaker, so emit by name and
            # say that the id could not be verified.
            self.report.warnings.append(
                f"line {ps.line}: external file '{scope}' is not in the catalog "
                f"— script '{ref_val.get('name')}' cannot be verified; "
                "emitted by name with id fallback")
            ref_val["id"] = 1
            ref_val["fallback"] = "by-name"
            return

        rows = self.cat.query(
            "SELECT Script_ID, Script_Name, Script_UUID FROM ScriptCatalog "
            f"WHERE Script_Name = {sql_quote(ref_val.get('name'))} "
            f"AND File_Name = {sql_quote(scope)} AND NOT Is_Separator")
        if not rows:
            cands = [r["Script_Name"] for r in self.cat.query(
                f"SELECT Script_Name FROM ScriptCatalog WHERE File_Name = {sql_quote(scope)}")]
            self._unresolved(ps, "Script", ref_val, "error",
                             f"script '{ref_val.get('name')}' not in '{scope}'",
                             self._suggest(ref_val.get("name") or "", cands))
            return
        self._hit(ps, "Script", ref_val, {
            "id": rows[0]["Script_ID"], "name": rows[0]["Script_Name"],
            "uuid": rows[0]["Script_UUID"], "file": scope,
        })

    def _valuelist(self, ps: ParsedStep, ref_val: dict) -> None:
        rows = self.cat.query(
            "SELECT VL_ID, VL_Name, VL_UUID FROM ValueListCatalog "
            f"WHERE VL_Name = {sql_quote(ref_val.get('name'))} AND File_Name = {sql_quote(self.file)}")
        if not rows:
            cands = [r["VL_Name"] for r in self.cat.query(
                f"SELECT VL_Name FROM ValueListCatalog WHERE File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "ValueList", ref_val, "error",
                             f"value list '{ref_val.get('name')}' not in '{self.file}'",
                             self._suggest(ref_val.get("name") or "", cands))
            return
        self._hit(ps, "ValueList", ref_val, {
            "id": rows[0]["VL_ID"], "name": rows[0]["VL_Name"],
            "uuid": rows[0]["VL_UUID"], "file": self.file,
        })

    def _table(self, ps: ParsedStep, ref_val: dict) -> None:
        name = ref_val.get("table") or ref_val.get("name")
        rows = self.cat.query(
            "SELECT TO_ID, TO_Name, TO_UUID FROM TableOccurrenceCatalog "
            f"WHERE TO_Name = {sql_quote(name)} AND File_Name = {sql_quote(self.file)}")
        if not rows:
            self._unresolved(ps, "Table", ref_val, "error",
                             f"table occurrence '{name}' not in '{self.file}'")
            return
        self._hit(ps, "Table", ref_val, {
            "id": rows[0]["TO_ID"], "name": rows[0]["TO_Name"],
            "uuid": rows[0]["TO_UUID"], "file": self.file,
        })

    def _section_has_script(self, ps: ParsedStep, section: str) -> bool:
        """True when the step declares a Script reference in `section` — then
        the FileReference of that section belongs to the script call."""
        return any(
            o["option_type"] == "object_ref"
            and _xmlpath_element(o["xml_path"]) == "Script"
            and _option_section(o["xml_path"]) == section
            for o in self.ref.options(ps.step_id))

    def _basetable(self, ps: ParsedStep, ref_val: dict) -> None:
        """Base table (182 Truncate Table): the id is the BASE table's id, not
        a table occurrence's — BaseTableCatalog, never TableOccurrenceCatalog."""
        name = ref_val.get("table") or ref_val.get("name")
        # BT_Comment exists from catalog schema 1.30.0 on; FileMaker writes the
        # base table's comment into the step (`<BaseTable id comment name/>`,
        # empty string without one — corpus 07 0.6.6) — probe the column, an
        # older catalog leaves the template default ({table:comment|})
        has_comment = bool(self.cat.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'BaseTableCatalog' AND column_name = 'BT_Comment' LIMIT 1"))
        comment_col = ", COALESCE(BT_Comment, '') AS BT_Comment" if has_comment else ""
        rows = self.cat.query(
            f"SELECT BT_ID, BT_Name, BT_UUID{comment_col} FROM BaseTableCatalog "
            f"WHERE BT_Name = {sql_quote(name)} AND File_Name = {sql_quote(self.file)}")
        if not rows:
            cands = [r["BT_Name"] for r in self.cat.query(
                f"SELECT BT_Name FROM BaseTableCatalog WHERE File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "BaseTable", ref_val, "error",
                             f"base table '{name}' not in '{self.file}'",
                             self._suggest(name or "", cands))
            return
        hit = {"id": rows[0]["BT_ID"], "name": rows[0]["BT_Name"],
               "uuid": rows[0]["BT_UUID"], "file": self.file}
        if has_comment:
            hit["comment"] = rows[0]["BT_Comment"] or ""
        self._hit(ps, "BaseTable", ref_val, hit)

    def _custommenuset(self, ps: ParsedStep, ref_val: dict) -> None:
        """Custom menu set (142 Install Menu Set): lives only in ObjectCatalog
        (Object_Type 'CustomMenuSet'), resolved by name within the file."""
        name = ref_val.get("name")
        rows = self.cat.query(
            "SELECT Object_ID, Object_Name, Object_UUID FROM ObjectCatalog "
            "WHERE Object_Type = 'CustomMenuSet' "
            f"AND Object_Name = {sql_quote(name)} AND File_Name = {sql_quote(self.file)}")
        if not rows:
            cands = [r["Object_Name"] for r in self.cat.query(
                "SELECT Object_Name FROM ObjectCatalog WHERE Object_Type = 'CustomMenuSet' "
                f"AND File_Name = {sql_quote(self.file)}")]
            self._unresolved(ps, "CustomMenuSet", ref_val, "error",
                             f"custom menu set '{name}' not in '{self.file}'",
                             self._suggest(name or "", cands))
            return
        self._hit(ps, "CustomMenuSet", ref_val, {
            "id": rows[0]["Object_ID"], "name": rows[0]["Object_Name"],
            "uuid": rows[0]["Object_UUID"], "file": self.file,
        })

    def _datasource(self, ps: ParsedStep, ref_val: dict) -> None:
        name = ref_val.get("name")
        rows = self.cat.query(
            f"SELECT File_Name FROM FilesCatalog WHERE File_Name = {sql_quote(name)}")
        if not rows:
            self.report.warnings.append(
                f"line {ps.line}: data source '{name}' not in FilesCatalog — "
                "cannot verify (external file may be intentional)")
            return
        self.report.resolved.append({"type": "DataSource", "ref": name, "line": ps.line})

    def _privilegeset(self, ps: ParsedStep, ref_val: dict) -> None:
        rows = self.cat.query(
            "SELECT PrivilegeSet_ID AS PS_ID, PrivilegeSet_Name AS PS_Name "
            "FROM PrivilegeSetsCatalog "
            f"WHERE PrivilegeSet_Name = {sql_quote(ref_val.get('name'))} "
            f"AND File_Name = {sql_quote(self.file)}")
        if not rows:
            self._unresolved(ps, "PrivilegeSet", ref_val, "error",
                             f"privilege set '{ref_val.get('name')}' not in '{self.file}' — "
                             "FileMaker resolves privilege sets by id, name fallback is invalid")
            return
        self._hit(ps, "PrivilegeSet", ref_val, {
            "id": rows[0]["PS_ID"], "name": rows[0]["PS_Name"], "file": self.file,
        })

    # ------------------------------------------------- calc content verification

    _MBS_RE = re.compile(r'MBS\s*\(\s*"([^"]+)"', re.I)

    def _calc_context(self) -> dict:
        """Positive lists + suggestion pool for the function-call scan, resolved
        once per target file (memoized). Every set is casefolded — FileMaker
        matches function and custom-function names case-insensitively."""
        if self._calc_ctx is not None:
            return self._calc_ctx
        flookup = self.ref.function_lookup()  # keys already casefolded
        # 'Get' is stored decomposed as 'Get ( Keyword )' in the reference, so the
        # bare token before '(' is not a lookup key. Recover the locale-specific
        # prefixes (get / hole / obtenir / ...) from the parenthesized lookup names.
        get_prefixes = {k.split("(", 1)[0].strip() for k in flookup if "(" in k}
        # Folder_Type/Is_Separator exist from catalog schema 1.15.0 on; older
        # catalogs carry folders and separators of the "Manage Custom Functions"
        # dialog as ordinary rows. Probe the column instead of assuming it —
        # the skill must keep working against a catalog that was built before.
        has_folder_flag = bool(self.cat.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'CustomFunctionsCatalog' "
            "AND column_name = 'Folder_Type' LIMIT 1"))
        folder_filter = (
            " AND (Folder_Type IS NULL OR Folder_Type = 'False') "
            "AND NOT COALESCE(Is_Separator, FALSE)" if has_folder_flag else "")
        cf_rows = self.cat.query(
            "SELECT CF_Name, Parameters FROM CustomFunctionsCatalog "
            f"WHERE File_Name = {sql_quote(self.file)}{folder_filter}")
        if not has_folder_flag:
            self.report.assumptions.append(
                "catalog predates schema 1.15.0 — custom-function folders are "
                "indistinguishable from parameterless functions")
        # A parameterless custom function is stored with Parameters = NULL, not
        # with an empty list — so NULL means 'takes no arguments'. Only when the
        # WHOLE file is NULL is that indistinguishable from an extraction gap;
        # in that case the arity check stands down instead of reporting every
        # call as 'expects 0'.
        cf_arity_usable = any(r["Parameters"] for r in cf_rows)
        cf_lower = {
            r["CF_Name"].casefold(): {
                "name": r["CF_Name"], "arity": len(r["Parameters"] or []),
            }
            for r in cf_rows
        }
        if cf_rows and not cf_arity_usable:
            self.report.assumptions.append(
                f"no custom-function parameter lists in the catalog for "
                f"'{self.file}' — custom-function arity not checked")
        plugin_direct, plugin_umbrella = set(), set()
        for r in self.cat.query(
                "SELECT DISTINCT Object_Name FROM ObjectCatalog "
                "WHERE Object_Type = 'PluginFunction'"):
            name = r["Object_Name"]
            if ":" in name:
                # qualified 'Umbrella:Selector::Selector' (e.g. MBS): only the
                # umbrella reaches a calc as a bare token; the selector is passed
                # as a string and is verified by the MBS scan below.
                plugin_umbrella.add(name.split(":", 1)[0].strip().casefold())
            else:
                plugin_direct.add(name.casefold())  # direct external function call
        builtins = {v["canonical_name"] for v in self.ref.function_arity().values()}
        self._calc_ctx = {
            "flookup": flookup, "get_prefixes": get_prefixes, "cf_lower": cf_lower,
            "cf_arity_usable": cf_arity_usable,
            "cf_folders_known": has_folder_flag,
            "plugin_direct": plugin_direct, "plugin_umbrella": plugin_umbrella,
            "suggest_pool": sorted({c["name"] for c in cf_lower.values()} | builtins),
        }
        return self._calc_ctx

    def _scan_calc(self, ps: ParsedStep, calc: str) -> None:
        if self.file_row is None:
            return
        # MBS/plugin functions: verify the registered plugin function exists
        for m in self._MBS_RE.finditer(calc):
            fn = m.group(1)
            # MBS treats function names case-insensitively; match the same way so
            # a spelling like Text.ReplaceNewline resolves against Text.ReplaceNewLine.
            rows = self.cat.query(
                "SELECT Object_Name FROM ObjectCatalog WHERE Object_Type = 'PluginFunction' "
                f"AND (lower(Object_Name) = lower({sql_quote(fn)}) "
                f"OR lower(Object_Name) LIKE lower({sql_quote('%::' + fn)})) "
                "LIMIT 1")
            if rows:
                self.report.resolved.append(
                    {"type": "PluginFunction", "ref": f"MBS(\"{fn}\")", "line": ps.line})
            else:
                self._unresolved(ps, "PluginFunction",
                                 {"name": fn, "_form": "named"}, "warning",
                                 f"MBS function '{fn}' not seen anywhere in the catalog — "
                                 "verify the name via mbs-function-reference")
        # Function calls in the calc: an identifier immediately before '(' that is
        # neither a built-in (incl. localized names and the Get-keyword), a custom
        # function of the target file, nor a registered plugin function is an
        # unknown reference — the counterpart to the positive CF scan, so a typo or
        # a missing utility CF surfaces here instead of only at paste time.
        ctx = self._calc_context()
        flookup, get_prefixes = ctx["flookup"], ctx["get_prefixes"]
        cf_lower, plugin_direct = ctx["cf_lower"], ctx["plugin_direct"]
        plugin_umbrella = ctx["plugin_umbrella"]
        scanned = strip_strings(strip_comments(calc))
        seen = set()
        for m in CALL_RE.finditer(scanned):
            # a word operator in front of the call is part of the match, not of
            # the name — try the candidates longest-first and report the bare
            # name (the last candidate) if none of them is known
            cands = call_name_candidates(m.group(1))
            if not cands:
                continue  # operators only: '(' groups here, it does not call
            tok = cands[-1]
            low = tok.casefold()
            lows = [c.casefold() for c in cands]
            if any(c in flookup or c in get_prefixes for c in lows):
                continue  # FileMaker built-in (arity is the lint's job, L006)
            hit = next((c for c in lows if c in cf_lower), None)
            if hit is not None:
                # arity is checked per CALL SITE, the existence report is
                # deduplicated per name — two wrong calls of the same custom
                # function are two findings, not one
                if ctx["cf_arity_usable"]:
                    self._cf_arity(ps, calc, scanned, m, cf_lower[hit])
                if low not in seen:
                    seen.add(low)
                    self.report.resolved.append(
                        {"type": "CustomFunction", "ref": cf_lower[hit]["name"],
                         "line": ps.line, "file": self.file})
                continue
            if any(c in self._declared_new_cf for c in lows):
                # declared as {{NEW:CustomFunction:...}} somewhere in this draft:
                # exempt from the existence check by design, and from the arity
                # check because the signature does not exist yet
                continue
            if low in seen:
                continue
            seen.add(low)
            hit = next((i for i, c in enumerate(lows) if c in plugin_direct), None)
            if hit is not None:
                self.report.resolved.append(
                    {"type": "PluginFunction", "ref": cands[hit], "line": ps.line})
                continue
            if any(c in plugin_umbrella for c in lows):
                continue  # e.g. MBS("…") — the selector is checked by the MBS scan
            self._unresolved(
                ps, "CustomFunction", {"name": tok, "_form": "named"}, "error",
                f"'{tok}' is called as a function but is neither a FileMaker built-in "
                f"nor a custom function of '{self.file}'",
                self._suggest(tok, ctx["suggest_pool"]))

    def _cf_arity(self, ps: ParsedStep, calc: str, scanned: str,
                  m: re.Match, cf: dict) -> None:
        """Argument count of one custom-function call site against the catalog.

        FileMaker custom functions have a fixed signature — no optional and no
        variadic parameters — so this is an exact comparison, unlike the built-in
        min/max check in the lint (L006). Arguments are counted on the original
        calc so a ';' inside a string literal cannot split an argument.
        """
        close = matching_paren(scanned, m.end() - 1)
        if close < 0:
            return  # unbalanced parens — the lint reports that on its own
        got = len(split_args(calc[m.end():close]))
        expected = cf["arity"]
        if got == expected:
            return
        if expected == 0 and not self._calc_context()["cf_folders_known"]:
            # Pre-1.15.0 catalog: a custom-function FOLDER carries Parameters
            # NULL just like a parameterless function, so 'declares 0' may not
            # be a signature at all. That ambiguity — not the arity itself — is
            # why this stays a warning instead of stopping the pipeline.
            self._finding(
                ps, "R001-cf-arity", "warning", cf["name"],
                f"custom function '{cf['name']}' declares no parameters but is "
                f"called with {got} argument(s) — this catalog carries no folder "
                "flag, so a custom-function folder looks the same as a "
                "parameterless function; verify the signature in FileMaker")
            return
        self._finding(
            ps, "R001-cf-arity", "error", cf["name"],
            f"custom function '{cf['name']}' expects {expected} argument(s), "
            f"got {got}")

    def _finding(self, ps: ParsedStep, rule: str, severity: str, ref: str,
                 message: str) -> None:
        self.report.findings.append({
            "rule": rule, "severity": severity, "line": ps.line,
            "ref": ref, "message": message,
        })


def resolve(parsed: list[ParsedStep], catalog: Database, ref: Reference,
            target_file: str) -> Report:
    r = Resolver(catalog, ref, target_file)
    r.resolve(parsed)
    return r.report
