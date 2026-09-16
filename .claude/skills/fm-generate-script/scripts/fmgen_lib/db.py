"""DuckDB access layer for fmgen.

Queries go through the DuckDB CLI binary (no Python duckdb module required
in the fm-lab container). All access is read-only.

Database resolution order:
  1. explicit CLI flag (--reference-db / --catalog-db)
  2. environment (FMGEN_REFERENCE_DB / FMGEN_CATALOG_DB)
  3. repo-root defaults: reference/fm_spec.duckdb and
     db/fm_catalog.duckdb (repo root = nearest ancestor with CLAUDE.md)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path


class DbError(RuntimeError):
    pass


def find_repo_root(start: Path | None = None) -> Path:
    p = (start or Path(__file__)).resolve()
    for parent in [p] + list(p.parents):
        if (parent / "CLAUDE.md").exists() or (parent / ".git").exists():
            return parent
    raise DbError("repo root not found (no CLAUDE.md/.git in ancestors)")


def duckdb_binary() -> str:
    exe = os.environ.get("FMGEN_DUCKDB", shutil.which("duckdb"))
    if not exe:
        raise DbError("duckdb binary not found on PATH (see docs/agents/tooling.md)")
    return exe


def sql_quote(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


# Template path of a variable-exclusive target slot: the last path segment is
# an element whose name ends in `Variable` (LLMRequestWithTools/
# SlidingWindowVariable). LEGACY fallback of Reference.slot_kind() for a
# reference without the curated column (fm_spec < 2.2.0); with the column the
# option row is the only source.
_VARIABLE_SLOT_ELEMENT = re.compile(r"(?:^|/)[A-Za-z0-9_]*Variable$")


class Database:
    def __init__(self, path: Path):
        self.path = Path(path)
        if not self.path.exists():
            raise DbError(f"database not found: {self.path}")

    def query(self, sql: str) -> list[dict]:
        proc = subprocess.run(
            [duckdb_binary(), "-readonly", "-json", "-c", sql, str(self.path)],
            capture_output=True, text=True, timeout=120,
        )
        if proc.returncode != 0:
            raise DbError(f"duckdb query failed on {self.path.name}: {proc.stderr.strip()}\nSQL: {sql}")
        out = proc.stdout.strip()
        if not out:
            return []
        return json.loads(out)

    def has_table(self, name: str) -> bool:
        rows = self.query(
            "SELECT 1 AS x FROM information_schema.tables "
            f"WHERE table_name = {sql_quote(name)} LIMIT 1"
        )
        return bool(rows)


def _default(env: str, rel: str, override: str | None) -> Path:
    if override:
        return Path(override)
    if os.environ.get(env):
        return Path(os.environ[env])
    return find_repo_root() / rel


def reference_db(override: str | None = None) -> Database:
    return Database(_default("FMGEN_REFERENCE_DB", "reference/fm_spec.duckdb", override))


def catalog_db(override: str | None = None) -> Database:
    return Database(_default("FMGEN_CATALOG_DB", "db/fm_catalog.duckdb", override))


class Reference:
    """Cached read access to fm_spec.duckdb (grammar + lookups).

    Shape coverages (fm_spec 2.0.0): the six shape tables carry a `coverage`
    column — '*' = standard row, '<NN>' = override/addition of ONE FileMaker
    coverage. Every shape read resolves against the TARGET coverage of this
    Reference (`set_coverage`, default = the base coverage of the reference):

      * a row of the target coverage overrides the '*' row of the same key
        (step_xml_map: the step; step_options: option_key; …)
      * rows of other coverages are ignored
      * no target row = the standard row (inheritance, never "not modelled")
      * additions (options, enum values, bindings, skeletons, groups) are the
        union; enum values of the target coverage come FIRST so a display
        text shared by two xml values (226 RAGPromptRequest / RAGPrompt)
        resolves to the coverage-specific value on the write side while both
        values stay readable

    A reference without the column (pre-2.0.0) has standard rows only and
    resolves to them for any target (C4 backwards compatibility).
    """

    def __init__(self, db: Database, coverage: str | None = None):
        self.db = db
        self.coverage: str | None = coverage

    # ----------------------------------------------------------- coverages

    @lru_cache(maxsize=1)
    def coverages(self) -> list[dict]:
        """Rows of the `coverages` vocabulary (since 2.0.0); empty before."""
        if not self.db.has_table("coverages"):
            return []
        return self.db.query(
            "SELECT coverage, paired_version, saxml_version, is_base "
            "FROM coverages ORDER BY is_base DESC, coverage")

    def base_coverage(self) -> str:
        rows = [r for r in self.coverages() if r.get("is_base")]
        if rows:
            return str(rows[0]["coverage"])
        return str(self.meta().get("filemaker_coverage") or "22")

    def known_coverages(self) -> list[str]:
        return [str(r["coverage"]) for r in self.coverages()] or [self.base_coverage()]

    def set_coverage(self, coverage: str | None) -> None:
        """Select the target coverage for all subsequent shape reads. Clears
        the per-step caches so a switch inside one process is safe."""
        self.coverage = coverage
        for name in ("options", "option_values", "xml_map", "repeat_groups",
                     "skeleton_elements", "element_bindings", "mirror_elements"):
            getattr(self, name).cache_clear()

    def target_coverage(self) -> str:
        return str(self.coverage or self.base_coverage())

    @lru_cache(maxsize=1)
    def coverage_rules(self) -> list[dict]:
        """Chrome/state rules of the target coverage (coverage_step_rules,
        since 2.0.0) — elements a FileMaker version writes outside the
        templates. Empty on older builds (consumers fall back to constants)."""
        if not self.db.has_table("coverage_step_rules"):
            return []
        return self.db.query(
            "SELECT coverage, rule_kind, step_ids, element, attrs "
            f"FROM coverage_step_rules WHERE coverage = {sql_quote(self.target_coverage())} "
            "ORDER BY rule_kind, element")

    @lru_cache(maxsize=1)
    def coverage_renames(self) -> list[dict]:
        """Spelling/wrapping deltas of the non-base coverages relative to the
        base shape (coverage_renames, since 2.7.0): element tags, element
        values and the text-hoist of 202 — read direction only, ordered so a
        parent rename precedes the renames underneath it. Empty on older
        builds (consumers fall back to their constants)."""
        if not self.db.has_table("coverage_renames"):
            return []
        return self.db.query(
            "SELECT coverage, step_id, rename_kind, path, coverage_name, base_name, sort_order "
            "FROM coverage_renames ORDER BY coverage, step_id, sort_order, coverage_name")

    @lru_cache(maxsize=None)
    def options_any_coverage(self, step_id: int) -> list[dict]:
        """Option rows of a step across ALL coverages (unresolved) — for
        diagnostics such as 'this option exists only in FileMaker 26'."""
        return self.db.query(
            f"SELECT option_key, option_type, display_label_en, xml_path, {self._covcol()} "
            f"FROM step_options WHERE step_id = {int(step_id)} ORDER BY option_key, coverage")

    @staticmethod
    def _resolve(rows: list[dict], key, target: str) -> list[dict]:
        """Apply the resolution rule to a union of '*' and target rows:
        target rows win over '*' rows with the same key; target rows keep
        their relative order and come first, then the surviving '*' rows.
        `coverage` stays on the row for consumers that want to know."""
        target_keys = {key(r) for r in rows if str(r.get("coverage")) == target}
        own = [r for r in rows if str(r.get("coverage")) == target]
        std = [r for r in rows if str(r.get("coverage")) != target and key(r) not in target_keys]
        return own + std

    @lru_cache(maxsize=1)
    def meta(self) -> dict:
        return {r["key"]: r["value"] for r in self.db.query("SELECT key, value FROM reference_meta")}

    @lru_cache(maxsize=1)
    def grammar_available(self) -> bool:
        return all(self.db.has_table(t) for t in ("step_options", "step_xml_map", "step_constraints"))

    @lru_cache(maxsize=1)
    def step_name_lookup(self) -> dict[str, dict]:
        """lookup_name (casefolded) -> {step_id, match_source} (primary matches win)."""
        rows = self.db.query(
            "SELECT lookup_name, step_id, match_source, is_primary "
            "FROM script_step_name_lookup ORDER BY is_primary"
        )
        table: dict[str, dict] = {}
        for r in rows:  # is_primary=1 rows come last and overwrite
            table[r["lookup_name"].casefold()] = {
                "step_id": r["step_id"], "match_source": r["match_source"],
            }
        return table

    @lru_cache(maxsize=1)
    def steps(self) -> dict[int, dict]:
        return {
            r["step_id"]: r
            for r in self.db.query(
                "SELECT step_id, canonical_name, url_slug, origin_version FROM script_steps"
            )
        }

    @lru_cache(maxsize=1)
    def legacy_step_ids(self) -> dict[int, dict]:
        if not self.db.has_table("script_step_legacy_ids"):
            return {}
        return {r["step_id"]: r for r in self.db.query("SELECT * FROM script_step_legacy_ids")}

    @lru_cache(maxsize=1)
    def _shape_has_coverage(self) -> bool:
        # shape coverages exist since fm_spec 2.0.0: the six shape tables carry
        # a `coverage` column ('*' = standard row, '<NN>' = override/addition
        # of one FileMaker coverage). Older builds have no column and hence
        # only standard rows.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_xml_map' AND column_name = 'coverage' LIMIT 1"
        )
        return bool(rows)

    def _cov(self) -> str:
        # Shape reads fetch the standard rows plus the rows of the target
        # coverage; _resolve applies the override rule in Python. On a
        # reference without the column every row is a standard row.
        if not self._shape_has_coverage():
            return ""
        return f" AND coverage IN ('*', {sql_quote(self.target_coverage())})"

    def _covcol(self) -> str:
        return "coverage" if self._shape_has_coverage() else "'*' AS coverage"

    @lru_cache(maxsize=1)
    def _options_have_slot_kind(self) -> bool:
        # option-precise value form of a target slot (step_options.slot_kind):
        # the step aggregate step_xml_map.target_slot_kind classifies the whole
        # step and is too coarse for a step whose slots differ. References
        # without the column read as NULL — slot_kind() falls back.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_options' AND column_name = 'slot_kind' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=1)
    def _options_have_xml_domain(self) -> bool:
        # XML value domain of a boolean ATTRIBUTE (step_options.xml_true /
        # xml_false, fm_spec 2.2.0): a few attributes serialize Yes/No instead
        # of True/False (74/122 NewWndStyles). References without the columns
        # read as NULL — every boolean attribute is then True/False.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_options' AND column_name = 'xml_true' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=1)
    def _options_have_paste_dropped(self) -> bool:
        # options FileMaker discards on paste whatever their value
        # (step_options.paste_dropped, fm_spec 2.6.0 — 144 appearance).
        # References without the column read as FALSE for every option.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_options' AND column_name = 'paste_dropped' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=None)
    def options(self, step_id: int) -> list[dict]:
        slot_kind = "slot_kind" if self._options_have_slot_kind() else "NULL AS slot_kind"
        xml_domain = ("xml_true, xml_false" if self._options_have_xml_domain()
                      else "NULL AS xml_true, NULL AS xml_false")
        dropped = ("paste_dropped" if self._options_have_paste_dropped()
                   else "FALSE AS paste_dropped")
        rows = self.db.query(
            "SELECT option_key, option_type, required, display_location, display_label_en, "
            f"true_text, false_text, omit_when_false, inverted_label, xml_path, sort_order, "
            f"{slot_kind}, {xml_domain}, {dropped}, {self._covcol()} "
            f"FROM step_options WHERE step_id = {int(step_id)}{self._cov()} "
            "ORDER BY COALESCE(sort_order, 999), option_key"
        )
        rows = self._resolve(rows, lambda r: r["option_key"], self.target_coverage())
        rows.sort(key=lambda r: (r["sort_order"] if r["sort_order"] is not None else 999,
                                 r["option_key"]))
        return rows

    def paste_dropped_options(self, step_id: int) -> set[str]:
        """Option keys FileMaker discards on paste whatever their value
        (step_options.paste_dropped, fm_spec 2.6.0 — 144 appearance: no SaXML
        parameter, never in the paired corpus, paste probe strips AsFormatted
        and WithBoxes alike). Parse and emit leave them out with a warning, the
        gate counts the absence as explained. Empty on older builds."""
        return {o["option_key"] for o in self.options(step_id)
                if o.get("paste_dropped") in (True, "true", 1)}

    @lru_cache(maxsize=None)
    def mirror_elements(self, step_id: int) -> list[dict]:
        """Value-copy rules of a step (step_mirror_elements, fm_spec 2.6.0):
        FileMaker writes the value of `source_option` a second time at
        `target_path` and keeps both in sync on paste — the source is the
        truth (144: the document title mirrored as a bare Step-level
        Calculation). Empty on older builds."""
        if not self.db.has_table("step_mirror_elements"):
            return []
        rows = self.db.query(
            f"SELECT * FROM step_mirror_elements WHERE step_id = {int(step_id)}{self._cov()} "
            "ORDER BY source_option, target_path"
        )
        rows = self._resolve(rows, lambda r: (r["source_option"], r["target_path"]),
                             self.target_coverage())
        rows.sort(key=lambda r: (r["source_option"], r["target_path"]))
        return rows

    def mirror_target_option(self, step_id: int, target_path: str) -> str | None:
        """The READ option of a mirror target — the step_options row whose
        xml_path is the target path (144 title_mirror). None when the target
        is a bare element without an option row."""
        for o in self.options(step_id):
            if o.get("xml_path") == target_path:
                return o["option_key"]
        return None

    def bool_domain(self, step_id: int) -> dict[str, tuple[str, str]]:
        """option_key -> (xml_true, xml_false) for every boolean option whose
        XML attribute carries a curated value domain (fm_spec 2.2.0
        step_options.xml_true/xml_false — 74/122 NewWndStyles write Yes/No;
        every other boolean attribute is True/False and is NOT listed here).
        Empty on references without the columns. One knowledge source for the
        emitter (state -> attribute value), the gate (G110 domain), the
        decompiler and valcmp (attribute value -> state)."""
        return {
            o["option_key"]: (str(o["xml_true"]), str(o["xml_false"]))
            for o in self.options(step_id)
            if o.get("option_type") == "boolean" and o.get("xml_true") and o.get("xml_false")
        }

    @lru_cache(maxsize=1)
    def _option_values_have_evidence(self) -> bool:
        # per-value evidence exists only in newer reference builds
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_option_values' AND column_name = 'evidence' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=None)
    def option_values(self, step_id: int) -> list[dict]:
        evidence = "evidence" if self._option_values_have_evidence() else "NULL AS evidence"
        rows = self.db.query(
            f"SELECT option_key, xml_value, display_text_en, {evidence}, {self._covcol()} "
            f"FROM step_option_values WHERE step_id = {int(step_id)}{self._cov()}"
        )
        # union keyed by (option, xml_value); target rows first (enum precedence)
        return self._resolve(rows, lambda r: (r["option_key"], r["xml_value"]),
                             self.target_coverage())

    @lru_cache(maxsize=1)
    def _xml_map_has_marker(self) -> bool:
        # the structural variable-target marker column exists since fm_spec
        # 1.17.0 — older builds simply have no marker steps
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_xml_map' AND column_name = 'variable_target_marker' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=1)
    def _xml_map_has_slot_kind(self) -> bool:
        # target_slot_kind (field_or_var / field / variable) classifies the
        # target slot of a step; it drives the field-or-variable form switch in
        # emit/decompile. Older builds carry no column — read as NULL.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_xml_map' AND column_name = 'target_slot_kind' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=None)
    def xml_map(self, step_id: int) -> dict | None:
        marker = ("variable_target_marker" if self._xml_map_has_marker()
                  else "NULL AS variable_target_marker")
        slot_kind = ("target_slot_kind" if self._xml_map_has_slot_kind()
                     else "NULL AS target_slot_kind")
        rows = self.db.query(
            f"SELECT step_id, snippet_template, element_order, {marker}, {slot_kind}, "
            f"evidence, verified_version, {self._covcol()} "
            f"FROM step_xml_map WHERE step_id = {int(step_id)}{self._cov()}"
        )
        rows = self._resolve(rows, lambda r: r["step_id"], self.target_coverage())
        return rows[0] if rows else None

    def options_have_slot_kind(self) -> bool:
        """True when the reference classifies the value form PER OPTION
        (`step_options.slot_kind`). Consumers use it to decide how far they
        trust a classification that otherwise comes from the step aggregate."""
        return self._options_have_slot_kind()

    def slot_kind(self, step_id: int, option_key: str) -> str | None:
        """Value form of ONE target slot: 'field_only' | 'field_or_var' |
        'variable_only' — None when nothing classifies it.

        Resolution order:
          1. the curated option row (`step_options.slot_kind`, fm_spec 2.2.0)
          2. ONLY on a reference without that column (< 2.2.0): the legacy
             rule that a target slot whose template element is named
             `…Variable` holds a variable name, never a field reference
          3. the step aggregate (`step_xml_map.target_slot_kind`), which knows
             `field_only`/`field_or_var` but not the variable-exclusive case
             (a NULL option row on a 2.2.0 reference means "not curated per
             option" and lands here)

        Deliberately uncached: it reads the cached `options()` rows, so a
        coverage switch invalidates it along with them.
        """
        opt = next((o for o in self.options(step_id)
                    if o["option_key"] == option_key), None)
        if opt is None or opt.get("option_type") != "target":
            return None
        if opt.get("slot_kind"):
            return str(opt["slot_kind"])
        if not self._options_have_slot_kind():
            path = str(opt.get("xml_path") or "")
            if "@" not in path and _VARIABLE_SLOT_ELEMENT.search(path):
                return "variable_only"
        return (self.xml_map(step_id) or {}).get("target_slot_kind") or None

    def slot_kind_curated(self, step_id: int, option_key: str) -> bool:
        """True when the OPTION ROW itself classifies the slot (curated
        `step_options.slot_kind`), as opposed to a value derived from the
        step aggregate or the legacy rule. Consumers grade the severity of
        a form violation by this: curated = error, derived = warning."""
        opt = next((o for o in self.options(step_id)
                    if o["option_key"] == option_key), None)
        return bool(opt and opt.get("slot_kind"))

    @lru_cache(maxsize=1)
    def repeat_groups_available(self) -> bool:
        return self.db.has_table("step_repeat_groups")

    @lru_cache(maxsize=None)
    def repeat_groups(self, step_id: int) -> list[dict]:
        """Repeat groups of a step (since fm_spec 1.15.0), parents before
        children so instantiation can nest top-down. Empty on older builds.
        SELECT * so the fixed-slot columns (since 1.16.0: max_items,
        slot_positional, pad_mode, empty/default_item_template) flow through
        when present — consumers read them via .get() and stay graceful on
        older builds."""
        if not self.repeat_groups_available():
            return []
        rows = self.db.query(
            f"SELECT * FROM step_repeat_groups WHERE step_id = {int(step_id)}{self._cov()} "
            "ORDER BY (parent_group IS NOT NULL), group_key"
        )
        rows = self._resolve(rows, lambda r: r["group_key"], self.target_coverage())
        rows.sort(key=lambda r: (r.get("parent_group") is not None, r["group_key"]))
        return rows

    @lru_cache(maxsize=1)
    def _constraints_have_coverage(self) -> bool:
        # step_constraints.coverage exists since fm_spec 2.7.0 ('*' = every
        # coverage, '<NN>' = the constraint holds for that coverage only —
        # the saxml_omission rows). Older builds: every row is a '*' row.
        rows = self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'step_constraints' AND column_name = 'coverage' LIMIT 1"
        )
        return bool(rows)

    @lru_cache(maxsize=1)
    def constraints(self) -> list[dict]:
        cov = "coverage" if self._constraints_have_coverage() else "'*' AS coverage"
        return self.db.query(
            "SELECT step_id, constraint_kind, detail, evidence, verified_version, "
            f"{cov} FROM step_constraints"
        )

    @lru_cache(maxsize=1)
    def constraint_kinds(self) -> dict[str, str]:
        """constraint_kind -> consumer_note for kinds that carry one (the
        bug-registry kinds; since fm_spec 1.17.0). Empty on older builds —
        decompile bug notes then degrade gracefully to none."""
        if not self.db.has_table("constraint_kinds"):
            return {}
        return {
            r["constraint_kind"]: r["consumer_note"]
            for r in self.db.query(
                "SELECT constraint_kind, consumer_note FROM constraint_kinds "
                "WHERE consumer_note IS NOT NULL")
        }

    @lru_cache(maxsize=1)
    def _hint_tables_available(self) -> bool:
        # the hint-inventory tables (fm_spec 1.17.0) travel together
        return all(self.db.has_table(t) for t in (
            "step_skeleton_elements", "step_option_element_bindings",
            "step_option_implications"))

    @lru_cache(maxsize=None)
    def skeleton_elements(self, step_id: int) -> list[dict]:
        """Skeleton hulls of a step (since fm_spec 1.17.0), Step-level rows
        first so restored parents exist before their child rows run. Empty on
        older builds."""
        if not self._hint_tables_available():
            return []
        rows = self.db.query(
            f"SELECT * FROM step_skeleton_elements WHERE step_id = {int(step_id)}{self._cov()} "
            "ORDER BY (parent_tag <> 'Step'), child_tag"
        )
        rows = self._resolve(
            rows, lambda r: (r["parent_tag"], r["child_tag"], r.get("condition_option"),
                             r.get("condition_value")), self.target_coverage())
        rows.sort(key=lambda r: (r["parent_tag"] != "Step", r["child_tag"]))
        return rows

    @lru_cache(maxsize=None)
    def element_bindings(self, step_id: int) -> list[dict]:
        """Option-value/element couplings of a step (since fm_spec 1.17.0).
        Empty on older builds."""
        if not self._hint_tables_available():
            return []
        rows = self.db.query(
            f"SELECT * FROM step_option_element_bindings WHERE step_id = {int(step_id)}{self._cov()} "
            "ORDER BY element_path, binding, option_key, option_value"
        )
        rows = self._resolve(
            rows, lambda r: (r["option_key"], r.get("option_value"), r["element_path"],
                             r["binding"]), self.target_coverage())
        rows.sort(key=lambda r: (r["element_path"], r["binding"], r["option_key"] or "",
                                 r.get("option_value") or ""))
        return rows

    @lru_cache(maxsize=None)
    def option_implications(self, step_id: int) -> list[dict]:
        """Parse-side option implications of a step (since fm_spec 1.17.0).
        Empty on older builds."""
        if not self._hint_tables_available():
            return []
        return self.db.query(
            f"SELECT * FROM step_option_implications WHERE step_id = {int(step_id)} "
            "ORDER BY trigger_kind, trigger"
        )

    @lru_cache(maxsize=1)
    def step_compat(self) -> dict[int, dict]:
        return {r["step_id"]: r for r in self.db.query("SELECT * FROM step_compat")}

    @lru_cache(maxsize=1)
    def ref_element_semantics(self) -> dict[str, dict]:
        return {
            r["element"]: r
            for r in self.db.query("SELECT element, resolution, catalog_table FROM ref_element_semantics")
        }

    @lru_cache(maxsize=1)
    def function_lookup(self) -> dict[str, dict]:
        """function token (casefolded) -> {function_id, match_source, chunk_role}."""
        rows = self.db.query(
            "SELECT lookup_name, function_id, match_source, chunk_role, is_primary "
            "FROM function_name_lookup WHERE chunk_role IN ('function','getfunction') "
            "ORDER BY is_primary"
        )
        return {
            r["lookup_name"].casefold(): {
                "function_id": r["function_id"], "match_source": r["match_source"],
                "chunk_role": r["chunk_role"],
            }
            for r in rows
        }

    @lru_cache(maxsize=1)
    def error_codes(self) -> list[dict] | None:
        """FileMaker error codes as spans (error_codes, since 2.8.0): rows
        {code_from, code_to, code_text, scope, message_en}; a code is looked up
        with code_from <= n <= code_to (Claris lists ranges such as 5000-5499).
        None on older builds — the caller skips its rule with a note."""
        if not self.db.has_table("error_codes"):
            return None
        return self.db.query(
            "SELECT code_from, code_to, code_text, scope, message_en "
            "FROM error_codes ORDER BY code_from")

    @lru_cache(maxsize=1)
    def get_parameter_lookup(self) -> dict[str, str]:
        """localized Get-parameter token (casefolded) -> canonical EN name."""
        rows = self.db.query(
            "SELECT l.lookup_name, f.canonical_name FROM function_name_lookup l "
            "JOIN functions f USING (function_id) WHERE l.chunk_role = 'getparameter'"
        )
        return {r["lookup_name"].casefold(): r["canonical_name"] for r in rows}

    @lru_cache(maxsize=1)
    def function_retirement_available(self) -> bool:
        """functions.removed_in_version exists since fm_spec 2.2.0 (361/367
        SetPersistentData/FindPersistentData = 26.0). Without the column the
        retirement direction of G303b stands down, reported as such."""
        return bool(self.db.query(
            "SELECT 1 AS x FROM information_schema.columns "
            "WHERE table_name = 'functions' AND column_name = 'removed_in_version' LIMIT 1"))

    @lru_cache(maxsize=1)
    def function_versions(self) -> dict[int, dict]:
        """function_id -> {origin_version, removed_in_version} for every
        function carrying either (removed_in_version None on references
        without the column)."""
        if self.function_retirement_available():
            removed, where = "removed_in_version", \
                "origin_version IS NOT NULL OR removed_in_version IS NOT NULL"
        else:
            removed, where = "NULL AS removed_in_version", "origin_version IS NOT NULL"
        rows = self.db.query(
            f"SELECT function_id, origin_version, {removed} FROM functions WHERE {where}")
        return {r["function_id"]: {"origin_version": r["origin_version"],
                                   "removed_in_version": r["removed_in_version"]}
                for r in rows}

    @lru_cache(maxsize=1)
    def function_arity(self) -> dict[int, dict]:
        """function_id -> {canonical_name, min_args, max_args (None = variadic)}."""
        rows = self.db.query(
            "SELECT f.function_id, f.canonical_name, "
            "COALESCE(SUM(CASE WHEN p.is_optional=0 AND p.is_variadic=0 THEN 1 ELSE 0 END),0) AS min_args, "
            "COUNT(p.position) AS n_params, "
            "COALESCE(MAX(p.is_variadic),0) AS variadic "
            "FROM functions f LEFT JOIN function_parameters p USING (function_id) "
            "GROUP BY f.function_id, f.canonical_name"
        )
        out = {}
        for r in rows:
            out[r["function_id"]] = {
                "canonical_name": r["canonical_name"],
                "min_args": int(r["min_args"]),
                "max_args": None if int(r["variadic"]) else int(r["n_params"]),
            }
        return out
