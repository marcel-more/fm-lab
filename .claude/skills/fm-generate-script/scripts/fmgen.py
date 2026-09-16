#!/usr/bin/env python3
"""fmgen — deterministic pipeline tooling for the fm-generate-script skill.

Subcommands (pipeline phases P2-P6 of the codegen method):

  parse    DRAFT.fmscript            normalize + segment + parse + lint -> IR JSON
  resolve  IR.json --file NAME       resolve object refs against fm_catalog -> report
  emit     RESOLVED.json             table-driven emission -> fmxmlsnippet
  gate     SNIPPET.xml               3-layer validation gate -> protocol JSON
  run      DRAFT.fmscript --file NAME   all phases; artifacts into --out-dir

Exit codes: 0 ok · 2 findings with severity error (pipeline must not continue)
· 3 environment/database problem.

JSON goes to stdout (or --out-dir files); human-readable summary to stderr.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
from pathlib import Path

from fmgen_lib import actionscript, db, decompile, emit, gate, lint, resolve, textform


def _fail_env(msg: str) -> int:
    print(f"fmgen: {msg}", file=sys.stderr)
    return 3


def _ir_to_json(parsed, raw_notes, lint_result) -> dict:
    return {
        "normalization": raw_notes,
        "steps": [
            {
                "line": ps.line, "step_id": ps.step_id,
                "canonical_name": ps.canonical_name, "enabled": ps.enabled,
                "options": ps.options, "canonical_text": ps.canonical_text,
            }
            for ps in parsed
        ],
        "lint": [f.as_dict() for f in lint_result.findings],
    }


def _ir_from_json(data: dict) -> list[textform.ParsedStep]:
    return [
        textform.ParsedStep(
            line=s["line"], step_id=s["step_id"],
            canonical_name=s["canonical_name"], enabled=s["enabled"],
            options=s["options"], canonical_text=s.get("canonical_text", ""),
        )
        for s in data["steps"]
    ]


def _coverage_from_version(version: str | None, ref) -> str | None:
    """FilesCatalog.FileMaker_Version -> shape coverage: the major version
    must be a coverage the reference knows (22.x -> '22', 26.x -> '26')."""
    if not version:
        return None
    major = str(version).strip().split(".")[0]
    return major if major in ref.known_coverages() else None


def determine_coverage(args, ref) -> tuple[str, str]:
    """Target shape coverage for this invocation and where it came from.

    Order (E7-C1): explicit --coverage; the FileMaker_Version of --file in
    the catalog; the coverage recorded in an IR/RESOLVED input file; the
    reference's base coverage for phases that carry no file context. A
    target file whose version is unknown (not in the catalog, or a major
    version the reference has no coverage for) is a hard error — pass
    --coverage to override.
    """
    known = ref.known_coverages()
    if getattr(args, "coverage", None):
        cov = str(args.coverage)
        if cov not in known:
            raise db.DbError(f"--coverage {cov} is not a coverage of this reference "
                             f"(known: {', '.join(known)})")
        return cov, "option"
    file = getattr(args, "file", None)
    if file and args.cmd in ("run", "resolve", "decompile"):
        try:
            catalog = db.catalog_db(args.catalog_db)
        except db.DbError:
            catalog = None
        if catalog is not None:
            rows = catalog.query(
                "SELECT FileMaker_Version FROM FilesCatalog "
                f"WHERE File_Name = {db.sql_quote(file)}")
            if rows:
                cov = _coverage_from_version(rows[0]["FileMaker_Version"], ref)
                if cov is None:
                    raise db.DbError(
                        f"target file '{file}' is FileMaker {rows[0]['FileMaker_Version']} — "
                        f"the reference has no shape coverage for it (known: {', '.join(known)}); "
                        "pass --coverage to choose one")
                return cov, "catalog"
        if args.cmd in ("run", "resolve"):
            raise db.DbError(
                f"target file '{file}' is not in FilesCatalog — its FileMaker version and "
                "shape coverage are unknown; pass --coverage 22|26 (references then fall "
                "back to name-only placeholders)")
    tv = getattr(args, "target_version", None)
    if tv and args.cmd in ("gate", "decompile"):
        # a bare snippet gated for an explicit FileMaker version: the version's
        # major is the coverage when the reference knows it
        cov = _coverage_from_version(str(tv), ref)
        if cov:
            return cov, "target-version"
    inp = getattr(args, "input", None) or getattr(args, "resolved", None)
    if inp and args.cmd in ("emit", "gate", "actionscript") and str(inp).endswith(".json"):
        try:
            recorded = json.loads(Path(inp).read_text(encoding="utf-8")).get("coverage")
        except (OSError, ValueError):
            recorded = None
        if recorded and str(recorded) in known:
            return str(recorded), "input"
    return ref.base_coverage(), "default"


def do_parse(args, ref) -> tuple[int, dict]:
    text = Path(args.input).read_text(encoding="utf-8")
    normalized, notes = textform.normalize_text(text)
    raw_steps = textform.segment(normalized, ref)
    parsed = [textform.parse_step(st, ref) for st in raw_steps if st.step_id is not None]
    result = lint.lint(raw_steps, parsed, ref)
    payload = _ir_to_json(parsed, notes, result)
    payload["coverage"] = ref.target_coverage()
    n_err = len(result.errors)
    print(f"fmgen parse: {len(parsed)} step(s), {n_err} error(s), "
          f"{len(result.findings) - n_err} warning(s)/info", file=sys.stderr)
    return (2 if n_err else 0), payload


def do_resolve(args, ref) -> tuple[int, dict]:
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    parsed = _ir_from_json(data)
    catalog = db.catalog_db(args.catalog_db)
    report = resolve.resolve(parsed, catalog, ref, args.file)
    data["steps"] = _ir_to_json(parsed, data.get("normalization", []), lint.LintResult())["steps"]
    data["resolution"] = report.as_dict()
    n_err = len([u for u in report.unresolved if u["severity"] == "error"])
    f_err = len([f for f in report.findings if f["severity"] == "error"])
    print(f"fmgen resolve: {len(report.resolved)} resolved, "
          f"{len(report.unresolved)} unresolved ({n_err} error), "
          f"{len(report.new_objects)} new, "
          f"{len(report.findings)} finding(s) ({f_err} error)", file=sys.stderr)
    return (2 if report.has_errors else 0), data


def do_emit(args, ref) -> tuple[int, dict | str]:
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    parsed = _ir_from_json(data)
    result = emit.emit(parsed, ref, xml_decl=args.xml_decl)
    if result.errors:
        for e in result.errors:
            print(f"fmgen emit: ERROR {e}", file=sys.stderr)
        return 2, {"errors": result.errors, "warnings": result.warnings}
    # emit-side warnings (IR that did not pass parse: a mirror read option
    # without its source, a paste-dropped option — fm_spec 2.6.0) are not
    # errors, but never silent either
    for w in result.warnings:
        print(f"fmgen emit: WARNING {w}", file=sys.stderr)
    print(f"fmgen emit: {len(parsed)} step(s) emitted", file=sys.stderr)
    return 0, result.xml  # type: ignore[return-value]


def _flag(args, name: str, env: str) -> bool:
    """CLI flag with an environment fallback — the env channel is what survives
    into child processes (the agent reads the convention from the registry and
    exports it once, see SKILL.md P0)."""
    if getattr(args, name, False):
        return True
    return os.environ.get(env, "").strip().lower() in ("1", "true", "on", "yes")


def do_gate(args, ref) -> tuple[int, dict]:
    xml_text = Path(args.input).read_text(encoding="utf-8")
    resolution, ir_steps = None, None
    # Target FileMaker version for the version gate (G303): an explicit
    # --target-version wins, otherwise the FilesCatalog version of the target
    # file as recorded by the resolver; the protocol names value and source.
    target_version, tv_source = args.target_version, "option" if args.target_version else None
    if args.resolved:
        data = json.loads(Path(args.resolved).read_text(encoding="utf-8"))
        resolution = data.get("resolution")
        ir_steps = data.get("steps")
        if not target_version and resolution:
            for a in resolution.get("assumptions", []):
                if ", FM " in a:
                    target_version, tv_source = a.rsplit(", FM ", 1)[1], "catalog"
    result = gate.run_gate(xml_text, ref, resolution, target_version, ir_steps,
                           _flag(args, "check_var_init", "FMGEN_CHECK_VAR_INIT"))
    n_fail = len([c for c in result.checks if c.status == "fail"])
    n_warn = len([c for c in result.checks if c.status == "warning"])
    n_skip = len([c for c in result.checks if c.status == "skipped"])
    print(f"fmgen gate: {'PASS' if result.passed else 'FAIL'} "
          f"({len(result.checks)} checks, {n_fail} failed, {n_warn} warning, "
          f"{n_skip} skipped)", file=sys.stderr)
    # separate line: the summary line above is parsed by generator scripts
    print(f"fmgen gate: target FM {target_version or 'unknown'}"
          f"{' (' + tv_source + ')' if tv_source else ' — G303 skipped'}", file=sys.stderr)
    protocol = result.as_dict()
    protocol["target_version"] = target_version
    protocol["target_version_source"] = tv_source
    protocol["coverage"] = ref.target_coverage()
    protocol["coverage_source"] = getattr(args, "_coverage_source", None)
    return (0 if result.passed else 2), protocol


def do_actionscript(args, ref) -> tuple[int, dict]:
    try:
        layer = actionscript.ActionLayer(ref)
    except LookupError as e:
        raise db.DbError(str(e))
    if args.wrap_snippet:
        xml_text = Path(args.wrap_snippet).read_text(encoding="utf-8")
        result = actionscript.wrap_snippet(xml_text, layer, args.script_name)
    else:
        if not args.input:
            raise db.DbError("actionscript needs an IR/RESOLVED json input or --wrap-snippet")
        data = json.loads(Path(args.input).read_text(encoding="utf-8"))
        result = actionscript.from_ir(_ir_from_json(data), layer)
    payload = {
        "actions": result.actions,
        "fmjaml": actionscript.to_fmjaml(result),
        "findings": result.findings,
        "capability_notes": sorted(set(result.capability_notes)),
    }
    n_err = len([f for f in result.findings if f["severity"] == "error"])
    print(f"fmgen actionscript: {len(result.actions)} action(s), {n_err} error(s), "
          f"{len(result.findings) - n_err} warning(s)/info", file=sys.stderr)
    return (2 if result.has_errors else 0), payload


def do_decompile(args, ref) -> tuple[int, dict | str]:
    xml_text = Path(args.input).read_text(encoding="utf-8")
    catalog = None
    try:
        catalog = db.catalog_db(args.catalog_db)
    except db.DbError:
        catalog = None  # optional: only enriches layout TO names
    result = decompile.decompile(xml_text, ref, catalog, args.file)
    if result.errors:
        for e in result.errors:
            print(f"fmgen decompile: ERROR {e}", file=sys.stderr)
        return 2, {"errors": result.errors}
    fm26 = result.fm26_normalized_count
    print(f"fmgen decompile: {len(result.steps)} step(s), "
          f"{result.lossy_count} lossy"
          + (f", {fm26} read through FM 26 tolerance" if fm26 else ""),
          file=sys.stderr)
    if args.json:
        payload = {
            "text": result.text,
            "steps": [
                {
                    "index": s.index, "step_id": s.step_id,
                    "canonical_name": s.canonical_name, "enabled": s.enabled,
                    "text": s.text, "issues": s.issues, "notes": s.notes,
                }
                for s in result.steps
            ],
            "lossy": result.lossy_count,
            "fm26_normalized": result.fm26_normalized_count,
        }
        return (2 if result.lossy_count else 0), payload
    return (2 if result.lossy_count else 0), result.text


def do_run(args, ref) -> int:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(args.input).stem

    code, ir = do_parse(args, ref)
    (out_dir / f"{stem}.ir.json").write_text(_dumps(ir), encoding="utf-8")
    if code:
        print(f"fmgen run: stopped after parse/lint — see {out_dir / (stem + '.ir.json')}",
              file=sys.stderr)
        return code

    args.input = str(out_dir / f"{stem}.ir.json")
    code, resolved = do_resolve(args, ref)
    (out_dir / f"{stem}.resolved.json").write_text(_dumps(resolved), encoding="utf-8")
    if code:
        print("fmgen run: stopped after resolve — resolution errors", file=sys.stderr)
        return code

    args.input = str(out_dir / f"{stem}.resolved.json")
    code, xml_or_err = do_emit(args, ref)
    if code:
        (out_dir / f"{stem}.emit-errors.json").write_text(_dumps(xml_or_err), encoding="utf-8")
        return code
    xml_path = out_dir / f"{stem}.xml"
    xml_path.write_text(xml_or_err, encoding="utf-8")  # type: ignore[arg-type]

    args.input = str(xml_path)
    args.resolved = str(out_dir / f"{stem}.resolved.json")
    code, protocol = do_gate(args, ref)
    (out_dir / f"{stem}.gate.json").write_text(_dumps(protocol), encoding="utf-8")
    print(f"fmgen run: artifacts in {out_dir}/ ({stem}.xml, .ir.json, "
          f".resolved.json, .gate.json)", file=sys.stderr)
    return code


def _dumps(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2, default=str) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(prog="fmgen", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reference-db", help="path to fm_spec.duckdb")
    ap.add_argument("--catalog-db", help="path to fm_catalog.duckdb")
    ap.add_argument("--coverage", metavar="22|26",
                    help="target shape coverage (FileMaker clipboard form) for emit, "
                         "decompile and gate; default: derived from the FileMaker_Version "
                         "of --file in the catalog, else the reference's base coverage")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse");  p.add_argument("input")
    p = sub.add_parser("resolve"); p.add_argument("input"); p.add_argument("--file", required=True)
    p = sub.add_parser("emit");   p.add_argument("input"); p.add_argument("--xml-decl", action="store_true")
    tv_help = ("FileMaker version of the target file for the version gate (G303), "
               "e.g. 22 or 26.0.2; default: FileMaker_Version of --file in the "
               "catalog (FilesCatalog), read from the resolution report")
    p = sub.add_parser("gate")
    p.add_argument("input"); p.add_argument("--resolved")
    p.add_argument("--target-version", help=tv_help)
    p.add_argument("--check-var-init", action="store_true",
                   help="check the convention that a variable used as a step target "
                        "was initialised by a preceding Set Variable (G305); "
                        "env fallback FMGEN_CHECK_VAR_INIT")
    p = sub.add_parser("actionscript")
    p.add_argument("input", nargs="?")
    p.add_argument("--wrap-snippet", help="fmxmlsnippet file for a clipboard-delivery script")
    p.add_argument("--script-name", help="target script for the delivery navigation")
    p = sub.add_parser("decompile")
    p.add_argument("input")
    p.add_argument("--file", help="FM file context for layout TO enrichment")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("run")
    p.add_argument("input"); p.add_argument("--file", required=True)
    p.add_argument("--out-dir", default="output/codegen")
    p.add_argument("--xml-decl", action="store_true")
    p.add_argument("--check-var-init", action="store_true",
                   help="see 'gate --check-var-init'")
    p.add_argument("--resolved", help=argparse.SUPPRESS)
    p.add_argument("--target-version", help=tv_help)

    args = ap.parse_args()
    try:
        ref = db.Reference(db.reference_db(args.reference_db))
        cov, cov_source = determine_coverage(args, ref)
        ref.set_coverage(cov)
        args._coverage_source = cov_source
        print(f"fmgen: shape coverage {cov} ({cov_source})", file=sys.stderr)
    except db.DbError as e:
        return _fail_env(str(e))

    try:
        if args.cmd == "run":
            return do_run(args, ref)
        fn = {"parse": do_parse, "resolve": do_resolve, "emit": do_emit, "gate": do_gate,
              "actionscript": do_actionscript, "decompile": do_decompile}[args.cmd]
        code, payload = fn(args, ref)
        sys.stdout.write(payload if isinstance(payload, str) else _dumps(payload))
        return code
    except db.DbError as e:
        return _fail_env(str(e))
    except FileNotFoundError as e:
        return _fail_env(str(e))


if __name__ == "__main__":
    sys.exit(main())
