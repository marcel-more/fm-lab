#!/bin/bash
# FileMaker XML to DuckDB Conversion Script
# version 5.1.0 - 2026-07-08
#
#
#   *** KATANA XML Engine ***
# - Part of the FM-Lab project
# - Architected by Marcel Moré
# - Built with Claude Code
# - Forged through countless refinements
# - Proven by hundreds of test cuts
#
#
# This script automates the conversion of FileMaker XML exports to DuckDB database.
# It handles UTF-16 to UTF-8 encoding conversion automatically.
# Supports both single-file and batch processing modes.
#
# Supported XML formats:
#   - SaXML v2.1.0.0+ (FileMaker 19+) with root element <FMSaveAsXML>
#   - SaXML v2.0.0.0 (FileMaker 18.x) is NOT supported — uses legacy root
#     element <FMDynamicTemplate> which is incompatible with the SQL XPath queries.
#     Files with this root element are skipped with a warning.
#
# Schema versioning & auto-heal:
#   Before every import the script compares the schema version in the SQL template
#   (ingestion/sql/convert_xml_01_extract.sql: @SCHEMA_VERSION) with the version persisted in
#   the DB table SchemaInfo. On drift a rebuild runs automatically in batch mode
#   (delete the DB, re-import all XMLs). In single-file mode the script aborts
#   instead and points to --batch --force-rebuild.
#
# Usage:
#   convert_fm_xml.sh                                         # No arg: interactive batch default (only at a TTY)
#   convert_fm_xml.sh <xml-filename>                          # Single file mode
#   convert_fm_xml.sh <xml-filename> --force-rebuild          # Single + forced rebuild
#   convert_fm_xml.sh --batch                                 # Batch mode (all XML files)
#   convert_fm_xml.sh --batch --fail-fast                     # Batch mode (stop on first error)
#   convert_fm_xml.sh --batch --force-rebuild                 # Batch + delete DB beforehand
#   convert_fm_xml.sh --batch --no-auto-heal                  # Abort on schema drift instead of rebuilding
#   convert_fm_xml.sh --batch --memory_limit 4GB              # Limit DuckDB RAM (e.g. 4GB, 60%)
#   convert_fm_xml.sh --all                                   # Alias for --batch
#   convert_fm_xml.sh --batch --solution erp-live             # Import a specific solution bundle (default: active solution)
#   convert_fm_xml.sh --test                                  # Test mode (tools/tests/fixtures/xml/ → fm_test.duckdb)
#   convert_fm_xml.sh --test --fail-fast                      # Test mode (stop on first error)
#
# Adaptive default (no mode flag): turbo + --auto (OOM backoff) + SAX streaming when
#   the patched webbed is present — robust, never hard-aborts on tight RAM (~2.5 GB
#   floor). Any explicit mode flag below overrides it; FM_FORCE_DOM=1 keeps turbo+auto
#   on DOM. Test mode (--test) stays on the classic deterministic DOM path.
#
# Flags (all optional, freely combinable):
#   --fail-fast            Stop on first error (Batch/Test mode only)
#   --force-rebuild        Delete the DB before import and rebuild it from scratch
#   --no-auto-heal         On schema drift do NOT auto-rebuild — abort instead
#   --memory_limit <value> Limit DuckDB memory (format: 4GB, 512MB, 60%); injected into all
#                          DuckDB runs (Convert, Catalogs, Resolutions, Post-Checks)
#   --split                Chunk Phase 1 per file at top-level branch boundaries
#                          (StepsForScripts + DDR_INFO split out) — lowers the peak DOM
#                          memory for large files. The result is bit-identical to the
#                          unsplit run.
#   --jobs <N>             Run Phase 1 for N files in PARALLEL ('auto' = nproc).
#                          Each file runs into its own part DB, then merges into the
#                          master DB (File_Names disjoint → conflict-free). Default
#                          8 = empirical sweet spot; 1 = sequential. Combinable with
#                          --split (orthogonal: parallel ACROSS files + chunking WITHIN;
#                          lowers per-file RAM peak).
#                          The result is bit-identical to the sequential run.
#   --turbo                Coexisting chunkmap engine. Implies --split; drives
#                          split/sub-chunk over a persistent chunkmap
#                          (db/streaming/chunkmap_<db>.duckdb). Sub-chunk granularity
#                          from --subchunk/FM_SUBCHUNK OR a per-catalog M in the recmap
#                          (FM_SUBCHUNK_RECMAP entries "Branch:RecElem:M"). Phases: S (split+plan)
#                          → D (worker pool over chunks → chunk_<id>.duckdb, W=--jobs) → C
#                          (consolidation into the master). The classic path stays untouched;
#                          the result is bit-identical to --split[ --subchunk] (FilesCatalog.XML_Path aside).
#   --changed-only          File-level manifest skip (implies --turbo). Unchanged XML
#   (Alias: --incremental)  (mtime+size→sha256, plus converter/schema version gate) are skipped
#                          entirely; their master rows remain. The manifest (db/streaming/
#                          manifest_<db>.duckdb) is ALWAYS updated (even in a full build).
#                          --force-rebuild ignores it. The result == full rebuild of the changed
#                          state. NOT to be confused with the schema detection
#                          SCHEMA_ACTION="incremental" (normal import instead of rebuild, a different thing).
#   --auto                 Memory-induced backoff (implies --turbo). If a chunk worker
#                          dies with rc=137 (OOM), ONLY that split-group is cut finer
#                          (mp=⌈record_count/2⌉) and re-dispatched, until it fits the band
#                          or the convergence limit (FM_AUTO_MAX_ATTEMPT, default 4)
#                          is reached; indivisible units (main/DDR_INFO, ≤1 record)
#                          escalate with a clear diagnosis. Test hook: FM_AUTO_TEST_OOM="Cat[:N]"
#                          (P1 chunk OOM); FM_P2_TEST_OOM="all"|<slice-idx> simulates a P2
#                          slice OOM → post-P2 gate → clean memory abort (exit 8);
#                          FM_P2_TEST_FAIL=1 simulates a P2 SQL failure (single-pass path)
#                          → post-P2 gate (batch and single-file) → abort, exit 1. Test-only.
#   --no-auto              Disable the memory backoff even where a mode implies it (e.g.
#                          --turbo, which otherwise turns --auto on).
#   --attempt <N>          Attempt counter (1-based, default 1) for retry tracking;
#                          appears in the log header + JSON sidecar.
#   --retry-reason <slug>  Reason for the retry run. Enum: oom, split-fallback,
#                          memory-limit, timeout, manual; unknown values are marked
#                          'custom' (retry_reason_known=false).
#   --retry-of <log-id>    Base name of the previous (failed) log, for chaining.
#
# Pipeline stages:
#   Script-level stages:
#     [1] Pre-Processor   preprocess_file(): encoding→UTF-8 (BOM sniffing), special-char cleanup
#     [2] Batch           discovery, --memory_limit; per-file Extract(P1), then batch-wide P2–P6
#     [3] Post-Processor  postprocess_db(): plausibility/consistency checks (Calc_UUID guard)
#     [4] Error-Handling  finalize_run(): validity decision, error classification, retry hints
#   Six-phase SQL pipeline (P1 runs once per file; P2–P6 run once after all files are imported):
#     P1 Extract  (ingestion/sql/convert_xml_01_extract.sql)  — the ONLY phase that reads XML; raw catalogs + raw-XML columns
#     P1b/P1c     (ingestion/sql/convert_xml_01b_heal_cascade.sql / convert_xml_01c_design_function_retype.sql) — once on the merged master before P2: UUID heal cascade; design-function chunks PluginFunctionRef → FunctionRef (seed: ingestion/sql/generated/design_functions_seed.sql)
#     P2 Resolve  (ingestion/sql/convert_xml_02_resolve.sql)  — tables only; reference/resolution tables
#     P3 Details  (ingestion/sql/convert_xml_03_details.sql)  — tables only; variable analysis (VariableUsages, VariablesCatalog)
#     P3.5 Recovery (ingestion/sql/convert_xml_03b_plugin_subname_recovery.sql) — MBS subnames from calc plain text (DDR chunk loss)
#     P4 Catalog  (ingestion/sql/convert_xml_04_catalog.sql)  — tables only; ObjectCatalog + ObjectLinks
#     P5 Homes    (ingestion/sql/convert_xml_05_homes.sql)    — tables only; cross-file resolution (ObjectHomes, TableOccurrenceResolution)
#     P6 Validate (ingestion/sql/convert_xml_06_validate.sql) — tables only; plausibility/consistency check views, queried by the post-processor
#
# Exit codes:
#   0 - Success
#   1 - File not found / No files found / Validation error / Some files failed
#   2 - UTF-8 conversion failed
#   3 - DuckDB conversion failed
#   4 - Unsupported XML format (e.g. legacy FMDynamicTemplate)
#   5 - XML preprocessing failed
#   6 - Schema drift detected (single mode or --no-auto-heal): manual rebuild required
#   7 - Concurrency lock collided (another convert is already running)
#   8 - webbed/xml extension too old (no read_xml 'streaming' parameter — stage b version gate)

# Constants
# Converter version (SemVer): version of THIS ingestion script, independent of the
# SQL template's schema version (@SCHEMA_VERSION). Written into the log header so
# logs are comparable by converter version (e.g. to evaluate runtime/memory
# behavior across script revisions). Bump on material changes to script behavior.
#   2.0.0 — six-phase pipeline, --split, DuckDB settings hardening (spill/threads),
#           awk-based timing (bc-free), OOM classification (exit 137).
#   2.1.0 — conversion log v2: phase timeline (P1–P6 individually, P3/P4 separate),
#           object counts per phase, environment context (RAM/CPU/DuckDB settings/spill),
#           retry context (--attempt/--retry-reason/--retry-of) and a machine-readable
#           JSON sidecar (log schema fmlab.convert-log/2.0).
#   2.2.0 — file parallelism (--jobs N): Phase 1 concurrently into part DBs +
#           merge into the master DB (bit-identical). Log options extended with
#           jobs/parallel.
#   2.3.0 — Merge dedup hardening (stage a):
#           the chunk/part-union merges (catmerge, _turbo_build_part, parquet variant) now carry
#           `ON CONFLICT DO NOTHING` on PK/UNIQUE tables → cross-chunk record overlap or clone
#           UUIDs no longer crash the catalog build with a duplicate-key error (a1). Absorbed
#           duplicates are logged (a2). Sync no longer blocked by a single failed file and refuses
#           to publish a master without ObjectCatalog (a4). Bit-identical on clean data.
#   2.4.0 — webbed capability gate (stage b): startup probe of the actually
#           loaded webbed → clear upfront abort (exit 8) when it lacks the read_xml 'streaming'
#           parameter (the real version floor, previously a cryptic mid-run Binder Error), plus
#           capability provenance logging (streaming-param / nested-attr-SAX-fix). Capability-driven
#           instead of dev-artifact-presence. FM_SKIP_WEBBED_PROBE=1 bypasses. Auto-SAX activation
#           on a capable stock webbed (b1) follows once a signed webbed with the fix is published.
# ── Bash version guard (macOS ships bash 3.2; we exploit newer features when there) ──
# The script body is written to be bash-3.2-safe (the macOS default — no associative
# arrays, no `declare -g`, no `wait -n`). A newer bash (4+) is nonetheless preferred:
# it is faster and sidesteps any 3.2 edge case. So if we are on <4 and a newer bash is
# reachable (commonly Homebrew under /opt/homebrew or /usr/local), re-exec under it.
# If none is found we simply continue on 3.2 — the code path is portable.
# FM_NO_BASH_REEXEC=1 forces the current bash (e.g. to exercise the 3.2 path on a Mac
# that also has Homebrew bash). FM_BASH_REEXECED guards against an exec loop.
if [ -z "${FM_BASH_REEXECED:-}" ] && [ "${BASH_VERSINFO:-0}" -lt 4 ] && [ "${FM_NO_BASH_REEXEC:-}" != "1" ]; then
    for _newbash in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
        [ -n "$_newbash" ] && [ -x "$_newbash" ] || continue
        _v="$("$_newbash" -c 'echo ${BASH_VERSINFO:-0}' 2>/dev/null)"
        if [ "${_v:-0}" -ge 4 ]; then
            export FM_BASH_REEXECED=1
            exec "$_newbash" "$0" "$@"
        fi
    done
    # No bash 4+ found → continue on the current (3.2) bash; the code below is 3.2-safe.
fi

# Force a dot decimal separator for ALL numeric formatting. The script computes
# durations with awk and renders them with the bash `printf` builtin (e.g.
# `printf '%11.3fs' "$dur"` in the batch summary). The bash builtin parses %f
# input via the active locale's decimal_point — under a comma locale (de_DE,
# fr_FR, …) it rejects the dot-decimal "0.248" with `printf: invalid number`
# and truncates the value. We pin LC_NUMERIC=C (not LC_ALL=C — that would also
# change LC_CTYPE/collation and affect non-ASCII filenames). Because a present
# LC_ALL outranks LC_NUMERIC, re-express it into the individual categories first
# (preserving the user's effective locale everywhere except numbers), then drop
# it — so the guard holds whether the comma locale comes via LANG or LC_ALL.
if [ -n "${LC_ALL:-}" ]; then
    export LC_CTYPE="$LC_ALL" LC_COLLATE="$LC_ALL" LC_TIME="$LC_ALL" \
           LC_MESSAGES="$LC_ALL" LC_MONETARY="$LC_ALL"
    unset LC_ALL
fi
export LC_NUMERIC=C

# CONVERTER_VERSION is NOT the display version (that lives in the header line 3 and
# feeds version.json → xml_import), but the OPERATIVE invalidation token
# of the turbo manifest: it is persisted per file in manifest_file; if it differs
# on the next --changed-only run, a full re-conversion is triggered. Bump it as soon
# as the CONVERSION RESULT can change (new columns, changed
# extraction/normalization) — independent of the header or @SCHEMA_VERSION.
#   2.23.0 — design functions re-typed from plug-in references (new phase 1c,
#           no DDL on existing tables, @SCHEMA_VERSION stays 1.27.0): FileMaker's
#           SaXML export tags the design functions (WindowNames, DatabaseNames,
#           LayoutIDs, ValueListItems, …) as PluginFunctionRef chunks in the
#           authoring client's language; they surfaced as synthetic
#           PluginFunction objects with calls_pluginfunction edges (plug-in
#           statistics, plug-in dashboards, cluster god nodes). Phase 1c
#           (sql/convert_xml_01c_design_function_retype.sql, once on the merged
#           master right after the heal cascade, before any P2 statement)
#           retypes them to FunctionRef against a positive name list generated
#           from the reference DB (sql/generated/design_functions_seed.sql via
#           gen_design_functions.sh — all reference languages, persisted as
#           catalog table DesignFunctionNames); downstream they resolve as
#           BuiltinFunction / calls_function. New P6 view
#           v_check_design_function_retype + import-report line. Corpora
#           without design functions stay bit-identical.
#   2.22.0 — LogicalLinks 1.5.0 — special types (view-only, no DDL,
#           @SCHEMA_VERSION stays 1.27.0): Chart and Web Viewer layout objects
#           are no longer hoisted onto their layout in the logical graph view.
#           Their field/variable references come from their OWN calc slots
#           (chart title/axes/series, web_viewer_url) and are invisible data
#           sources of OBJECT properties — unlike a field control's visible
#           placement, for which "layout shows field" holds. Criterion is the
#           curated type list, not the edge role. Their own parent_layout edge
#           is re-admitted in the role filter and carries the node into the
#           layout (layout -> object d1 -> fields/variables d2). Bumped because
#           the view travels with the DB sync; ObjectLinks/import are untouched.
#   2.21.0 — chart curation (no DDL, @SCHEMA_VERSION stays 1.27.0): (a) kind=13
#           disambiguation — Chart layout objects share kind=13 with Web Viewer
#           and were cataloged as 'Web Viewer'; fm_canon_layout_type now probes
#           the locale-independent /LayoutObject/External/Chart wrapper (canonical
#           EN raw type 'Chart' passes through) → new LayoutObjects/ObjectCatalog
#           Object_Type 'Chart'. (b) chart head calc slots curated: LayoutObject
#           anchors Title/XAxisList_Title/YAxisList_Title → chart_title/
#           chart_xaxis_title/chart_yaxis_title (previously lower(raw) fallback,
#           v_check_calc_roles signal); YSeriesList_<n>_Title stays chart_series.
#   2.20.0 — display-calculation recovery refinements (no DDL, @SCHEMA_VERSION
#           stays 1.27.0; fixture-driven, layout "Fixtures"): (a) %X:-prefixed
#           VariableReference chunks whose remainder starts with '$' are REAL
#           variables behind the result type (<<ƒ:%N:$$var>>) — kept with the
#           prefix stripped (P3 A.3, P2 A.6.10) instead of discarded, and
#           excluded from the field rescue (P2 A.5.1b). (b) Empty-ChunkList
#           recovery extended: variables are matched from the recovered
#           formula text (P3 A.6c, double-quoted literals stripped; variables
#           are syntactically unambiguous) and CustomFunction names are
#           matched file-locally (P2 A.5.1c CF branch — CF names are NOT
#           localized, unlike builtins). (c) Name-collision semantics
#           (fixture-verified): when a field and a CF share a name, FileMaker
#           serializes the FIELD reference quoted as ${Name} — the field
#           rescue unwraps ${…} (A.5.1b) and the empty-ChunkList field match
#           requires the quoted form on collision, while unquoted occurrences
#           resolve to the CF; the boundary predecessor class additionally
#           rejects '$' and '{'. (d) The empty-ChunkList variable recovery is
#           mirrored slot-scoped into XMLCalcReferences (P2 A.6.10b, Subrole =
#           DisplayCalculations_<i>) — symmetry with the chunk-based variable
#           rows of intact slots; feeds the API's synthetic tokenization.
#   2.19.0 — display-calculation gaps of the merge family (@SCHEMA_VERSION
#           1.27.0): new P1 table DDR_ChunkListContexts (context TO +
#           chunk count per DDR ChunkList anchor, INCLUDING empty ChunkLists;
#           DOM + streamify extended identically) and new P3 table
#           LayoutObjectSymbols ({{…}} inventory from Text_Content, no
#           where-used edges by design). CalculationsCatalog gains Result_Type
#           (result type from the %X: prefix of typed layout calculations,
#           default Text); display_calculation instances get Formula_Text
#           (localized raw formula from Text_Content, wrapper + prefix
#           stripped) and their context TO. Compensation for two FileMaker DDR
#           defects in typed layout calculations: (a) misclassified
#           VariableReference chunks ('%N:Zahl') no longer create phantom
#           variables (P3 A.3 exclusion + P2 A.6.10) — the field reference is
#           recovered against the ChunkList's context TO (P2 A.5.1b);
#           (b) EMPTY ChunkLists (expression + prefix) get a fallback instance
#           (P4 b_disp) plus field edges matched from the layout text against
#           the context TO's field names (P2 A.5.1c). Two new P6 info views
#           v_check_display_prefix_chunks / v_check_display_empty_chunklist.
#   2.18.0 — field-anchored trigger mirrors in the graph projection (view-only,
#           @SCHEMA_VERSION stays 1.26.0): the P5 LogicalLinks view redirects
#           object-level trigger mirrors (triggers_script from LayoutObject
#           sources, subrole != button_action) onto the owner's displayed
#           field instead of the parent layout — the field is the data anchor
#           of the trigger, the layout was a mis-attributed proxy. Owners
#           without a displayed field (UI controls: popover/tab/buttons) and
#           button_action edges keep the layout anchor; Is_Cross_File is
#           recomputed for the field branch (related-field placements).
#           Edge contract: existence semantics ("at least one placement of
#           this field carries the trigger"). ClusterEdgesBaseMat follows the
#           view; ObjectLinks/where-used stay untouched.
#   2.17.0 — trigger model revision (no DDL, @SCHEMA_VERSION stays 1.26.0):
#           P4 block 21a emits the triggers_script·<event> owner mirror for ALL
#           THREE owner levels (LayoutObject/Layout/File; Source_Type from
#           Owner_Type — Layout/File need no multiset, they have no button
#           actions; 21b stays LayoutObject-bound). LinkRoleRegistry demotes
#           trigger_script to Counts_For_Where_Used=FALSE (the owner mirrors are
#           the only counting where-used truth; the granular edge remains for
#           navigation/detail). P5 LogicalLinks excludes trigger_script and the
#           OnWindowTransaction field candidates (reads_field·
#           transaction_parameter_field) (graph policy: trigger nodes were
#           pure script satellites — the owner mirrors now carry the affinity;
#           the graph tab of a trigger focus is fed by the focus bridge in
#           graph_subgraph.sql 1.5.0 / graph_depth_profile.sql 1.2.0). New P6 view
#           v_check_trigger_mirror_symmetry (per-level 1:1 invariant, WARN).
#   2.16.0 — (see @SCHEMA_VERSION 1.26.0) trigger parameter plain text +
#           candidates: P1 column ScriptTriggers.Trigger_Parameter_Text
#           (structural /ScriptTrigger/ScriptReference/Calculation/Text, all
#           three owner levels, DOM + streamify). P4: script_trigger_parameter
#           DDR-anchor instances gain Formula_Text via an equi join on the
#           trigger id (a_owner.Trigger_Pos); the collapsed no-DDR fallback
#           (one Calc_Kind_Raw NULL instance per object) is replaced by
#           per-trigger instances from ScriptTriggers (b_trig — covers Layout/
#           File owners without DDR-Info for the first time); new candidate
#           edges reads_field·transaction_parameter_field for the
#           OnWindowTransaction parameter field (one edge per same-named field
#           of the own file, via FieldsForTables). New P6 report view
#           v_report_trigger_parameter_fields (info, no gate).
#   2.15.1 — P4 CalculationsCatalog CTAS join physics (no DDL, bit-identical
#           result, EXCEPT-ALL-verified on a 59-file corpus): left-side-only
#           predicates removed from the LEFT-JOIN ON clauses (5× a.Owner_Type
#           type dispatch, 1× i.Owner_Name IS NULL fallback guard) and the step
#           position precomputed as an equi key (a_owner.Step_Pos). DuckDB
#           planned those joins as BLOCKWISE_NL_JOIN (cross product, ~18 s /
#           260 s CPU for 187k rows); as pure equi/hash joins the CTAS runs in
#           ~0.6 s. Bumped despite the identical result to keep the schema-hash
#           manifests consistent (P4 is in @SCHEMA_HASH_FILES).
#   2.15.0 — owner-exact layout script references (P2, no DDL): the
#           XMLLayoutReferences script block gains an ancestor guard
#           //ScriptReference[not(ancestor::LayoutObject/ancestor::LayoutObject)]
#           on all three parallel lists (@UUID/@name/@id), keeping only each
#           object's OWN references. Previously the bare descendant axis also
#           copied every nested child's refs onto each container ancestor
#           (portal, tab control, panel, group, button bar, popover/grouped
#           button — one phantom copy per nesting level), which block 21b then
#           mislabeled as 'button_action'. Row count drops intentionally
#           (corpus −25.7%); guard result equals the multiset subtraction
#           r(self) − Σ r(direct children) with 0 negatives; own container
#           triggers (e.g. OnPanelSwitch) and child refs are unchanged.
#   2.14.0 — triggers_script edges carry a Link_Subrole (P4 block 21, no DDL):
#           block 21 split into 21a (one edge per LayoutObject-owned
#           ScriptTriggers row, subrole = Trigger_Action event passthrough)
#           + 21b (remaining XMLLayoutReferences script rows as
#           'button_action'). Edge count per (object, file, script) group is
#           unchanged (multiset reconstruction over the t<=r invariant);
#           role, link kind and where-used semantics untouched.
#   2.13.0 — (see @SCHEMA_VERSION 1.25.0) conditional-formatting rules as
#           structured import table LayoutObjectConditions (P3 A.12): one row
#           per rule, depth-anchored at /LayoutObject/Conditions/Formatting/
#           Condition (own rules only — container nesting cannot double-count),
#           with condition type/kind, Options bitmask, formula text+hash,
#           value-operator operands (Range Start/End, FM pre-encoding decoded)
#           and the raw LocalCSS payload; Calculation_UUID FK filled in P4 via
#           Calc_Kind_Raw='Condition_N'; new P6 view v_check_cf_rules
#           (membercount guard + FK coverage).
#   2.12.0 — hard P2 gate in single-file mode (batch parity): a Phase-2 failure
#           (SQL error incl. heal cascade, OOM, or 0 references with objects
#           loaded) now aborts BEFORE P3 with exit 1, done ok:false and no REST
#           sync, instead of warning and publishing a stale catalog with rc=0.
#           No conversion-result change on healthy runs; bumped so existing
#           manifests re-convert once under the gated semantics.
#   2.11.0 — (see @SCHEMA_VERSION 1.22.0) Calculation object type: CalculationsCatalog
#           (one row per calculation instance), Object_Type='Calculation' in P4,
#           has_calculation containment edges and v_calculation_links.
#   2.10.0 — MBS subname recovery from calc plain text (new phase 3.5,
#           convert_xml_03b_plugin_subname_recovery.sql): FileMaker's DDR export
#           drops NoRef chunks carrying the first string argument of container
#           plugin calls (comment adjacency, nested calls) — those SubNames are
#           now recovered by lexing the CDATA plain text and pairing the k-th
#           MBS ref chunk with the k-th lexed MBS call. Fills MBS_SubnameMap
#           NULLs, requalifies PluginFunctionUsages ('MBS' → 'MBS:<Sub>') and
#           rebuilds the affected XMLCalcReferences MBS rows; P4 then registers
#           granular PluginFunction objects instead of dead 'MBS::' UUIDs.
#   2.9.0 — PSoS execution context as Link_Subrole on calls_script edges
#           ('on_server'/'on_server_callback', P4 block 15; schema 1.20.0).
#   2.8.0 — UUID-healing foundation (H0): the P2 reference tables gain Ref_ID
#           (FileMaker-internal @id of the referenced element; SaXML triple
#           id+name+UUID) and TO_Ref_ID (context-TO @id for field references);
#           DuplicateAbsorptionDetails gains Healed_UUID/Heal_Status/Discriminator;
#           new prelude macros fm_heal_uuid/fm_heal_pick/fm_heal_enabled compute
#           deterministic md5 replacement UUIDs from internal FM ids (survivor =
#           smallest internal id, kill switch FM_UUID_HEAL=0). Healing itself
#           lands in later stages; duplicate-free corpora stay run-to-run
#           bit-identical.
#   2.7.0 — clone scoping via declared data sources (P4): new DataSourceFileMap
#           table resolves (File_Name, DS_UUID) → imported target file (DS_Name
#           match or path-list resolution, closing the _dev-suffix gap); the
#           base_table link block scopes its target to the declared source file
#           and a new prefer-declared-source post-pass removes phantom edges in
#           clone corpora (edge fans over multiple files, exactly one of which
#           is a declared data source). Clone-free corpora stay bit-identical.
#   2.6.0 — duplicate-UUID census completed (metadata-integrity stage 0):
#           DuplicateAbsorptionDetails gains context/plaintext columns (Parent_Name,
#           Position, Display_Text, Payload_XML) and now also covers StepsForScripts,
#           Layouts and LayoutObjects; the LayoutObjects census counts copy-paste
#           duplicates (same UUID, distinct object ids) separately from FileMaker's
#           double serialization; the catmerge a2 dup report is persisted into the
#           new MergeAbsorptions table (best-effort, s. convert_turbo.sh).
CONVERTER_VERSION="2.23.0"
PROJECT_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd))"
# Engine root: the ingestion/ directory this script lives in. ALL engine-internal
# assets (sql/, engine/, lib/, fixtures/, version_check.json, gen_streamify_sql.sh)
# resolve against ENGINE_ROOT — the directory is self-contained and relocatable.
# PROJECT_ROOT stays reserved for the documented outside interface only:
# solutions/ bundles + db/ symlink, tools/lib/resolve_solution.sh,
# tools/install_modes.sh, tools/graph-export/cluster.sh, tools/tests/fixtures
# (--test mode), logs/, .fmlab/.
ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm-lab release provenance for the log headers: bug reports quote the RELEASE
# version (e.g. "v0.9.8"), while the logs so far only carried converter-internal
# versions — mapping a log to a release needed the release history. Source:
# version.json (release version + source commit of the version stamp), fallback
# package.json, else "unknown". Deliberately grep/sed (no jq dependency,
# bash-3.2-safe); the first "version" key in version.json is the global one.
FMLAB_VERSION=$(grep -m1 '"version"' "$PROJECT_ROOT/version.json" 2>/dev/null | sed -E 's/.*"version"[^"]*"([^"]*)".*/\1/')
[ -z "$FMLAB_VERSION" ] && FMLAB_VERSION=$(grep -m1 '"version"' "$PROJECT_ROOT/package.json" 2>/dev/null | sed -E 's/.*"version"[^"]*"([^"]*)".*/\1/')
[ -z "$FMLAB_VERSION" ] && FMLAB_VERSION="unknown"
FMLAB_SOURCE_COMMIT=$(grep -m1 '"source_commit"' "$PROJECT_ROOT/version.json" 2>/dev/null | sed -E 's/.*"source_commit"[^"]*"([^"]*)".*/\1/')
[ -z "$FMLAB_SOURCE_COMMIT" ] && FMLAB_SOURCE_COMMIT="unknown"
# Six-phase pipeline. Phase 1 (extraction, the only XML-reading phase) and Phase 2
# (reference resolution) live in separate files; the skill script runs them per
# file in sequence.
SQL_TEMPLATE="$ENGINE_ROOT/sql/convert_xml_01_extract.sql"
P2_TEMPLATE="$ENGINE_ROOT/sql/convert_xml_02_resolve.sql"
# Phase 6 (validation): check views for the post-checks.
VALIDATE_TEMPLATE="$ENGINE_ROOT/sql/convert_xml_06_validate.sql"
# Analysis views (static code analysis): batch-wide, table-only phase after P6.
ANALYSIS_VIEWS_TEMPLATE="$ENGINE_ROOT/sql/create_analysis_views.sql"
# awk splitter for --split: moves the heavy top-level branches
# (StepsForScripts, DDR_INFO) into their own chunks to lower the
# Phase-1 peak memory. P2–P5 run unchanged, batch-wide.
SPLITTER_AWK="$ENGINE_ROOT/engine/split_fm_xml.awk"
# Shared Katana core functions: loaded on EVERY splitter/fuse/renamer
# call via an additional -f BEFORE the specific file.
KATANA_COMMON_AWK="$ENGINE_ROOT/engine/katana_common.awk"
# Turbo Phase-S pass fusion: ONE awk pass replaces
# clean(tr)+counts(wc/tr)+streamify-rename+split. Used only on the turbo path.
TURBO_FUSE_AWK="$ENGINE_ROOT/engine/turbo_phaseS_fuse.awk"
# awk binary for the Phase-S passes: mawk (typically 2–5× faster on byte/line
# work) preferred, gawk/awk fallback. Override via FM_AWK_BIN. Byte transparency
# is enforced via LC_ALL=C at the call site (mawk is byte-transparent).
AWK_BIN="${FM_AWK_BIN:-$(command -v mawk || command -v gawk || command -v awk)}"

# A-B9: macOS/BSD date does not know %N (returns the literal 'N' → all durations
# lose the sub-seconds or carry '…N' remnants). One-off capability probe;
# fallback = whole seconds. All time measurements use now_epoch().
if case "$(date +%N 2>/dev/null)" in (*[!0-9]*|'') false ;; (*) true ;; esac; then
    now_epoch() { date +%s.%N; }
else
    now_epoch() { date +%s; }
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# start time for the last_xml_run stamp (UTC, ISO — same format as the API record)
RUN_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')

# NDJSON-Mode helpers (shared with installer skills). Sourcing the file gives
# us emit_log / emit_progress / phase_progress / emit_done plus the QUIET_MODE
# flag. In default mode these fall back to plain text — the CLI experience is
# unchanged. When the REST-API spawns the script with --quiet (POST
# /api/xml/convert), every emit_* writes NDJSON to stdout instead.
QUIET_MODE=false
# Existence check before every source (A-B10): a missing module aborts immediately
# with a clear message instead of dying later on undefined functions.
[ -f "$PROJECT_ROOT/tools/install_modes.sh" ] || { echo "ERROR: Module missing: tools/install_modes.sh" >&2; exit 1; }
# shellcheck source=tools/install_modes.sh
source "$PROJECT_ROOT/tools/install_modes.sh"

# ---------------------------------------------------------------------------
# Module libraries (shell split) — pure code movement out of this file:
#   lib/webbed_caps.sh         webbed capability/version probes
#   lib/convert_preprocess.sh  stage-1 pre-processor (encoding/byte-clean/DDR-recmap)
#   lib/convert_turbo.sh       turbo pipeline (phase S/D/C) + parallel-P1/catmerge
#   lib/convert_report.sh      conversion log v2 (text log + JSON sidecar)
# The libs only define functions (+ module state variables without
# dependencies) — early sourcing therefore does not change the execution order.
# ---------------------------------------------------------------------------
for _fm_lib in webbed_caps convert_preprocess convert_turbo convert_report; do
    if [ ! -f "$ENGINE_ROOT/lib/${_fm_lib}.sh" ]; then
        echo "ERROR: Module library missing: ingestion/lib/${_fm_lib}.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$ENGINE_ROOT/lib/${_fm_lib}.sh"
done
unset _fm_lib

# Locate DuckDB binary — check PATH first, then common install locations
DUCKDB_BIN=""
if command -v duckdb &>/dev/null; then
    DUCKDB_BIN=$(command -v duckdb)
else
    for _candidate in \
        "$HOME/.duckdb/cli/latest/duckdb" \
        "/opt/homebrew/bin/duckdb" \
        "/usr/local/bin/duckdb"; do
        if [ -x "$_candidate" ]; then
            DUCKDB_BIN="$_candidate"
            break
        fi
    done
fi
if [ -z "$DUCKDB_BIN" ]; then
    echo "ERROR: DuckDB CLI not found. Install it from https://duckdb.org/docs/installation/"
    exit 1
fi

# ============================================================================
# SAX streaming via a patched webbed extension
# ----------------------------------------------------------------------------
# Phase 1 can drastically lower the XML DOM RAM peak when a webbed build with the
# nested-attr SAX fix (teaguesterling/duckdb_webbed#98) is available. That build
# is built locally → UNSIGNED → needs `duckdb -unsigned` + LOAD by absolute path.
# SAFE-BY-DEFAULT: without a patched build everything runs unchanged on the signed
# stock webbed in the DOM path (no -unsigned, no streaming edits).
#
# Activation: ONLY the opt-in mode --streamify arms the patched mode
# (PATCHED_WEBBED_ACTIVE=true → run_p1_on swaps LOAD to $WEBBED_PATCHED_EXT +
# -unsigned + a capability self-test in the SQL). --streamify aborts hard if the
# artifact under $WEBBED_PATCHED_EXT is missing (no silent fallback in THIS mode).
# All default paths (incl. --split/--turbo/--changed-only) stay on stock webbed/DOM —
# the patched artifact is never a prerequisite there.
# $FM_WEBBED_EXT overrides the default path (the bake path baked into the image).
# FM_FORCE_DOM=1 forces DOM even under --streamify (A/B test); the self-test also
# degrades to DOM at runtime if the loaded webbed turns out not to have the
# nested-attr SAX fix. FM_DOM_THRESHOLD overrides the stream threshold (bytes).
WEBBED_PATCHED_EXT="${FM_WEBBED_EXT:-$HOME/.duckdb/webbed-patched/webbed.duckdb_extension}"
WEBBED_SAX_PROBE="$ENGINE_ROOT/fixtures/webbed_sax_probe.xml"
# Stream threshold (maximum_file_size per read in patched mode). Small enough that
# all real FileMaker XMLs (MB–GB) exceed it → SAX. FM_DOM_THRESHOLD overrides
# (e.g. for tests on small files).
WEBBED_STREAM_THRESHOLD="${FM_DOM_THRESHOLD:-1000000}"
# Streaming (patched webbed + renamer + streamify SQL) is OPT-IN via --streamify
# (hybrid model): the default path stays pure DOM/stock (no auto-streaming). The
# activation decision is made AFTER arg parsing (STREAMIFY_MODE is not yet known here).
PATCHED_WEBBED_ACTIVE=false
# stage b1: --streamify on the SIGNED stock webbed (no dev patch), as soon as it carries the
# nested-attr SAX fix (#98). Like PATCHED_WEBBED_ACTIVE, but WITHOUT the LOAD redirect/-unsigned
# (stock loads via `LOAD webbed;`). The final decision is made after the capability probe.
STOCK_STREAMING_ACTIVE=false

# ----------------------------------------------------------------------------
# → moved to ingestion/lib/webbed_caps.sh (shell split)
# nested_attr_sax (#98) → flag use_streaming. Resolved ONCE from the manifest and
# used as the single source of _probe_webbed_caps (startup log/floor) AND the
# @WEBBED_SELFTEST@ injection (run_p1_on). Hardcode fallback = the previous
# behavior if the manifest is missing.
_vc_nested_probe_sql="$(_vc_probe_sql nested_attr_sax)"
if [ -z "$_vc_nested_probe_sql" ]; then
    _vc_nested_probe_sql="SELECT COALESCE(MAX(CASE WHEN CustomFunctionReference.UUID IS NOT NULL THEN 1 ELSE 0 END),0) FROM read_xml('$WEBBED_SAX_PROBE', root_element='CalcsForCustomFunctions', record_element='CustomFunctionCalc', maximum_file_size=100, streaming=true, columns={'CustomFunctionReference':'STRUCT(UUID VARCHAR)'})"
fi
# sax_cr_parity (#109) → flag sax_text_faithful. Probe against its own CR fixture
# (probe_fixture in the manifest). 1 = SAX preserves CR DOM-faithfully (fixed), otherwise CR→Space.
# Feeds the auto-default-SAX decision (text-faithful only when #109 is present). Hardcode fallback.
WEBBED_CR_PROBE="$ENGINE_ROOT/fixtures/webbed_cr_probe.xml"
_vc_cr_probe_sql="$(_vc_probe_sql sax_cr_parity)"
if [ -z "$_vc_cr_probe_sql" ]; then
    _vc_cr_probe_sql="SELECT COALESCE(MAX(CASE WHEN contains(Parameter.Text.value, chr(13)) THEN 1 ELSE 0 END),0) FROM read_xml('$WEBBED_CR_PROBE', root_element='CRProbe', record_element='Step', maximum_file_size=100, streaming=true, columns={'Parameter':'STRUCT(\"Text\" STRUCT(value VARCHAR))'})"
fi
# whitespace_preservation (#73) → flag wa_ws_sentinel. The probe tests whether the loaded
# webbed preserves internal whitespace in the DEFAULT DOM path (typed read AND fragment
# xml_extract_text) instead of collapsing it. 1 = preserved → the chr(127) sentinel is
# redundant (wa_ws_sentinel=false, preproc CR→0x7F is dropped). 0/old → sentinel ON
# (conservative). DOM path (do NOT force streaming). Hardcode fallback as with #109.
WEBBED_WS_PROBE="$ENGINE_ROOT/fixtures/webbed_ws_probe.xml"
_vc_ws_probe_sql="$(_vc_probe_sql whitespace_preservation)"
if [ -z "$_vc_ws_probe_sql" ]; then
    _vc_ws_probe_sql="SELECT CASE WHEN (SELECT COALESCE(MAX(CASE WHEN contains(Calc,chr(10)) OR contains(Calc,chr(13)) THEN 1 ELSE 0 END),0) FROM read_xml('$WEBBED_WS_PROBE', root_element='WSProbe', record_element='Row', columns={'Calc':'VARCHAR'})) = 1 AND (SELECT COALESCE(MAX(CASE WHEN contains(xml_extract_text(xml,'//Calc')[1],chr(10)) OR contains(xml_extract_text(xml,'//Calc')[1],chr(13)) THEN 1 ELSE 0 END),0) FROM read_xml_objects('$WEBBED_WS_PROBE', maximum_file_size=100000000)) = 1 THEN 1 ELSE 0 END"
fi

# Argument parsing: mode + flags in any order.
# Exactly one positional argument (filename) OR one mode flag is expected.
ORIGINAL_ARGS="$*"   # verbatim invocation args, for the console-log header
MODE=""
FILENAME=""
FAIL_FAST=false
TEST_MODE=false
FORCE_REBUILD=false
NO_AUTO_HEAL=false
SPLIT_MODE=false
STREAMIFY_MODE=false
# Tracks whether the user explicitly chose a Phase-1 strategy (any of
# --split/--subchunk/--turbo/--changed-only/--auto/--streamify). When FALSE the
# adaptive default kicks in (turbo + --auto, plus SAX when the patched webbed is
# present) — see the "Adaptive default" block below. --jobs/--memory_limit are NOT
# strategy choices and do not set this. FM_FORCE_DOM=1 is handled separately (it
# only suppresses SAX, the default stays turbo+auto on DOM).
MODE_EXPLICIT=false
# Turbo mode: a coexisting opt-in engine that drives split/sub-chunk over a
# persistent chunkmap (db/streaming/chunkmap.duckdb) — Phase S (Split & Plan),
# D (Dispatch), C (Consolidate). Additive rollout; the classic path
# (--split/--jobs/--subchunk/--streamify) stays untouched. Implies --split, runs
# sequentially, and sources seq_offset from the chunkmap instead of inline.
TURBO_MODE=false
# Set true by run_turbo_pipeline when a --changed-only run finds NOTHING changed
# (0 pending chunks) AND the catalogs were last fully built (P6) for the current
# manifest state → the batch flow then skips the catalog rebuild (P2–P6) + sync,
# since the master DB is already byte-identical to the previous run. Default false
# so non-turbo batch paths always run P2–P6.
TURBO_NO_CHANGES=false
# --changed-only: file-level manifest skip. Implies --turbo. The manifest
# (db/streaming/manifest_<db>.duckdb, persistent) is ALWAYS updated (even in a full
# build), but only UNDER --changed-only are unchanged files
# (mtime+size→content-hash, plus a converter/schema version gate) skipped entirely.
# --force-rebuild ignores the manifest (everything is rebuilt).
CHANGED_ONLY=false
# --auto: memory-induced backoff. If a chunk worker dies with rc=137
# (OOM SIGKILL), ONLY that split-group is cut finer (halve M), re-inserted into the
# chunkmap with an increased attempt and re-dispatched — until it fits the band or K
# attempts are exhausted. Catalogs that cannot be split further (main/DDR_INFO, M=1)
# escalate (clear diagnosis). Implies --turbo. Test hook: FM_AUTO_TEST_OOM="Catalog[:N]".
AUTO_MODE=false
# --no-auto: opt out of the memory backoff even when a mode would otherwise imply it
# (turbo now implies --auto). Power-user override for reproducible single-round runs.
NO_AUTO=false
# Reference-resolution (Phase 2) outcome flags. P2_FAILED is set when the resolve
# step (partitioned or single-pass) did not complete; P2_OOM narrows the cause to a
# memory kill (worker exited 137/143). The post-P2 gate reads both to stop the
# pipeline cleanly instead of letting the universal catalogs (P4+) fail on the
# missing reference tables.
P2_FAILED=false
P2_OOM=false
# Sub-chunking: on --split, additionally cuts the heavy separated branches WITHIN
# into pieces of SUBCHUNK records each → lowers the per-chunk DOM peak. 0/empty = off
# (default; --split behaves unchanged). --subchunk N or FM_SUBCHUNK sets N. SUBCHUNK_RECMAP
# lists the safe branches; a recmap entry implies separation (splitter).
# Default: StepsForScripts:Script + LayoutCatalog:Layout — both fully
# chunk-invariant verified (split==unsplit 0/0 over Layouts/LayoutObjects/LayoutParts/
# ObjectLinks/ObjectCatalog/ScriptCatalog). Three chunk sensitivities had to be fixed for this:
#  ✓ Layouts.Sequence_ID  → seq_offset (ROW_NUMBER() + offset per sub-chunk)
#  ✓ LayoutObjects.Nesting_Level  → deterministic MIN-nesting dedup (Z_Order-DESC
#    tie-break) in the LayoutObjects INSERT (base + streamify override)
#  ✓ names with XML entities  → xml_unescape() on Script_Name/L_Name (webbed-SAX
#    does not decode attribute entities like DOM → was chunk-size-dependent)
# FM_SUBCHUNK_RECMAP override remains possible. LayoutCatalog is the peak setter on large
# files → sub-chunking lowers the P1 RAM peak (membench: −18%). DDR_INFO stays out of it
# (no name-fixed records).
SUBCHUNK="${FM_SUBCHUNK:-0}"
# In turbo mode the LayoutCatalog/StepsForScripts windowing becomes the default
# (SUBCHUNK>0) — it lowers the non-spillable P1 DOM peak (LayoutCatalog is the peak
# setter on large files); the mechanic is chunk-invariant verified (split==unsplit
# 0/0, even on the pure DOM path). The flip applies ONLY when the user has set M
# neither via --subchunk nor via FM_SUBCHUNK. SUBCHUNK_SOURCE tracks the origin;
# "env" also covers FM_SUBCHUNK=0 (opt-out to the coarse path). The classic path
# (--split without --turbo) stays at SUBCHUNK=0 (coarse), unchanged.
if [ -n "${FM_SUBCHUNK+x}" ]; then SUBCHUNK_SOURCE="env"; else SUBCHUNK_SOURCE="default"; fi
SUBCHUNK_RECMAP="${FM_SUBCHUNK_RECMAP:-StepsForScripts:Script LayoutCatalog:Layout}"
# Default M for the turbo windowing flip. Provisionally 25 (proven in the 2-GB full
# build); the final value comes from the peak-vs-wall sweep (M ∈ {50,25,10}).
TURBO_SUBCHUNK_DEFAULT="${FM_TURBO_SUBCHUNK_DEFAULT:-25}"
# NEST map: splits DDR_INFO into a Calculation + a Script chunk (instead of one
# DDR chunk per file) → roughly halves the DDR long pole in the Phase-D dispatch
# and lowers the remaining peak (DDR). Identity: additive UPSERT by UUID, separate
# XPaths. Default: on in turbo mode (see below), otherwise off.
# Opt-out: FM_DDR_NEST=0; explicit map: FM_NEST_MAP="Parent:Child1,Child2 …".
NEST_MAP="${FM_NEST_MAP:-}"
# DDR sub-chunk: cuts the DDR_INFO/Calculation NEST child at
# ObjectList-record boundaries (anchor sc_rec="*", 2-level wrapper) → lowers the irreducible
# DDR-Calculation DOM peak (the ~2.3-GB long pole that --auto cannot resplit). ONLY
# Calculation is sub-chunked (Script is NOT — see _ddr_recmap_for_file: its bare "<_ hash=>"
# records break the Step_UUID key under catmerge). Calc records carry a unique tag-name UUID
# → each lands in one sub-chunk, catmerge plain-INSERT stays collision-free, additive.
#
# CHUNK-EXPLOSION-GUARD (lesson learned): sub-chunking EVERY file's DDR at a small fixed M
# multiplies the chunk count (~380k DDR records corpus-wide; M=3 → ~119k chunks, which once
# crashed the container — 1 chunk = 1 XML file = 1 part-DB = 1 merge in Phase D). M is
# therefore NEVER applied raw: it is computed PER FILE so a single file never exceeds
# FM_DDR_MAX_CHUNKS chunks (M is RAISED if needed — "raise M when in doubt"). Files below the
# Calc-record gate are not sub-chunked at all, so only genuinely large files are touched.
# A global Phase-S guard (FM_MAX_TOTAL_CHUNKS) is the corpus-wide backstop on top of this.
#
# Engagement (resolved below, AFTER _avail_mb is known):
#   • explicit  FM_DDR_SUBCHUNK=N (N≥1)  → on for every file ≥ gate; N = M floor.
#               FM_DDR_SUBCHUNK=0        → hard off (also disables auto).
#   • auto      (default, FM_DDR_SUBCHUNK unset) → engages ONLY under RAM pressure
#               (_avail_mb < FM_DDR_AUTO_AVAIL_MB); M floor = FM_DDR_AUTO_M.
# Gate (both modes): only files with ≥ FM_DDR_MIN_RECORDS Calculation records.
# Per file: M = max(M_floor, ceil(R_calc / FM_DDR_MAX_CHUNKS)).  Requires turbo + NEST.
DDR_SUBCHUNK="${FM_DDR_SUBCHUNK:-}"            # explicit M (≥1 on / 0 hard-off / empty = auto)
DDR_MAX_CHUNKS="${FM_DDR_MAX_CHUNKS:-1000}"    # hard per-file chunk cap (raises M to honor it)
DDR_AUTO_M="${FM_DDR_AUTO_M:-150}"             # M floor when auto-engaged (peak-vs-count balance)
DDR_MIN_RECORDS="${FM_DDR_MIN_RECORDS:-10000}" # gate: only files with ≥ this many Calc records (peak driver)
DDR_AUTO_AVAIL_MB="${FM_DDR_AUTO_AVAIL_MB:-3000}" # auto trigger: engage when avail RAM below this
DDR_SUBCHUNK_ACTIVE=false                      # resolved: does it engage at all this run?
DDR_AUTO_MODE=false                            # resolved: auto path (RAM-pressure gated) vs explicit
DDR_REQ_M=0                                     # resolved: requested M floor (explicit value or auto)
MEMORY_LIMIT=""
# Number of parallel Phase-1 workers. EMPTY = dynamic default from effectively
# available RAM (cgroup-aware on Linux, vm_stat on macOS — see _detect_avail_mb)
# + nproc + mode (see below). The earlier fixed-8 assumption was tuned for a
# "14-GiB RAM cliff (anon ~9 GiB/63%)" — which turned out to be a fork explosion in
# the per-worker sampler (_tree_rss_kb, fixed), NOT a real RAM limit. RAM demand is
# mode-dependent: streaming ~5 GB base + ~1.3 GB/worker (spillable); DOM ~8-9 GB base
# + ~6 GB/worker (NOT spillable). --jobs N (flag) or FM_JOBS (env) override.
# 1 = sequential; >1 = part-DB parallel path.
JOBS=""
# Multi-solution context: production runs operate on ONE solution bundle
# solutions/<id>/ (XML inbox, master DB, per-solution state). Empty = resolve
# from the active-solution pointer file (see below); test mode ignores it.
SOLUTION=""
# Retry/attempt context (caller-coordinated): the script itself does not know
# whether this is a retry run — the calling process passes it through.
ATTEMPT=1
RETRY_REASON=""
RETRY_REASON_KNOWN=true
RETRY_OF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            MODE="batch"
            TEST_MODE=true
            shift
            ;;
        --solution)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            SOLUTION="$2"
            shift 2
            ;;
        --solution=*)
            SOLUTION="${1#*=}"
            shift
            ;;
        --memory_limit)
            # Guard before shift 2: if the flag is the last argument, bash 3.2 does
            # not shift → the while loop would hang forever (applies to all value-taking flags).
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --memory_limit=*)
            MEMORY_LIMIT="${1#*=}"
            shift
            ;;
        --batch|--all)
            MODE="batch"
            shift
            ;;
        --fail-fast)
            FAIL_FAST=true
            shift
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --no-auto-heal)
            NO_AUTO_HEAL=true
            shift
            ;;
        --split)
            # Chunk Phase 1 per file at top-level branch boundaries (lower memory).
            SPLIT_MODE=true; MODE_EXPLICIT=true
            shift
            ;;
        --subchunk)
            # Additionally cut the heavy separated branches (StepsForScripts) into
            # pieces of N records each. Implies --split.
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            SUBCHUNK="$2"; SUBCHUNK_SOURCE="flag"; SPLIT_MODE=true; MODE_EXPLICIT=true
            shift 2
            ;;
        --subchunk=*)
            SUBCHUNK="${1#*=}"; SUBCHUNK_SOURCE="flag"; SPLIT_MODE=true; MODE_EXPLICIT=true
            shift
            ;;
        --turbo)
            # Turbo engine (chunkmap-driven). Implies --split; the sub-chunk
            # granularity comes from --subchunk/FM_SUBCHUNK or the per-catalog M
            # in the recmap (Branch:RecElem:M). Runs sequentially (dispatcher comes later).
            # Implies --auto (memory backoff) so an explicit --turbo keeps the OOM
            # safety net the adaptive default already carries; opt out with --no-auto.
            TURBO_MODE=true; SPLIT_MODE=true; MODE_EXPLICIT=true
            AUTO_MODE=true
            shift
            ;;
        --no-auto)
            # Disable the memory backoff even where a mode implies it (see --turbo).
            NO_AUTO=true; AUTO_MODE=false
            shift
            ;;
        --changed-only|--incremental)
            # Manifest skip. Implies --turbo. Without this flag turbo always builds
            # fully; the skip is deliberately placed behind its own flag.
            # --incremental is the old alias name (backward-compatible); NOT to be
            # confused with SCHEMA_ACTION="incremental" (schema detection, different meaning).
            CHANGED_ONLY=true; TURBO_MODE=true; SPLIT_MODE=true; MODE_EXPLICIT=true
            shift
            ;;
        --auto)
            # Memory-induced backoff. Implies --turbo.
            AUTO_MODE=true; TURBO_MODE=true; SPLIT_MODE=true; MODE_EXPLICIT=true
            shift
            ;;
        --streamify|--low-mem)
            # Opt-in SAX streaming path (hybrid): renamer (ingestion/engine/streamify_fm_xml.awk)
            # + patched webbed + streamify SQL variant. Lowers the RAM peak of the
            # read_xml_objects heavyweights. Requires the patched webbed
            # (otherwise a hard abort).
            STREAMIFY_MODE=true; MODE_EXPLICIT=true
            shift
            ;;
        --jobs)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            JOBS="$2"
            shift 2
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            shift
            ;;
        --attempt)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            ATTEMPT="$2"
            shift 2
            ;;
        --attempt=*)
            ATTEMPT="${1#*=}"
            shift
            ;;
        --retry-reason)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            RETRY_REASON="$2"
            shift 2
            ;;
        --retry-reason=*)
            RETRY_REASON="${1#*=}"
            shift
            ;;
        --retry-of)
            [ $# -ge 2 ] || { echo "ERROR: $1 needs a value"; exit 1; }
            RETRY_OF="$2"
            shift 2
            ;;
        --retry-of=*)
            RETRY_OF="${1#*=}"
            shift
            ;;
        --quiet)
            # Switch all emit_* helpers into NDJSON mode. Used by the REST-API
            # SSE bridge — never set this manually on the command line unless
            # you want to read NDJSON yourself.
            QUIET_MODE=true
            shift
            ;;
        --*)
            echo "ERROR: Unknown flag: $1"
            echo "Usage: $0 <xml-filename> [--force-rebuild] | --batch [--fail-fast] [--force-rebuild] [--no-auto-heal] [--memory_limit <value>] [--split] [--turbo] [--changed-only] [--auto] [--jobs <N>] [--quiet] [--attempt <N>] [--retry-reason <slug>] [--retry-of <log-id>] | --test [--fail-fast] [--force-rebuild] [--split]"
            exit 1
            ;;
        *)
            if [ -n "$FILENAME" ]; then
                echo "ERROR: Multiple filenames provided ('$FILENAME', '$1'). Use --batch to process all files."
                exit 1
            fi
            FILENAME="$1"
            MODE="single"
            shift
            ;;
    esac
done

# Validate the --memory_limit format (e.g. 4GB, 512MB, 60%). Prevents a typo from
# being silently passed through to DuckDB as SET memory_limit='...'.
if [ -n "$MEMORY_LIMIT" ]; then
    if ! [[ "$MEMORY_LIMIT" =~ ^[0-9]+([.][0-9]+)?([KkMmGgTt][Ii]?[Bb]|%)$ ]]; then
        echo "ERROR: Invalid --memory_limit '$MEMORY_LIMIT'. Expected e.g. 4GB, 512MB, 60%."
        exit 1
    fi
fi

# --jobs source: flag (--jobs) > FM_JOBS env > dynamic default (host RAM).
JOBS_SOURCE="dynamic"
if [ -n "$JOBS" ]; then
    JOBS_SOURCE="flag"
elif [ -n "${FM_JOBS:-}" ]; then
    JOBS="$FM_JOBS"; JOBS_SOURCE="env"
fi
if [ "$JOBS" = "auto" ]; then
    JOBS=$( (command -v nproc >/dev/null && nproc) || echo 4 ); JOBS_SOURCE="auto"
fi

# Cross-platform effectively available RAM in MB (0 = not determinable →
# conservative JOBS=1 fallback). /proc/meminfo alone is not enough — it is HOST-wide
# and does not know the cgroup limit (Docker/k8s/systemd MemoryMax on a large host →
# MemAvailable overestimates what THIS group is entitled to → OOM despite "free"
# host RAM). Hence on Linux: min(MemAvailable, cgroup headroom). macOS has neither
# /proc nor cgroups → a dedicated vm_stat/sysctl branch, otherwise the knob would
# stay blind on Mac (JOBS=1) and the floor protection inactive. Both platforms thus
# provide the same _avail_mb contract; cgroups stay Linux-only, but that is correct
# (on Mac there are none → the min() automatically reduces to the vm_stat value).
_detect_avail_mb() {
    local os; os=$(uname -s 2>/dev/null)
    if [ "$os" = "Darwin" ]; then
        local pagesize free spec inact mb total_b total_mb vs
        pagesize=$(sysctl -n hw.pagesize 2>/dev/null); [[ "$pagesize" =~ ^[0-9]+$ ]] || pagesize=4096
        # vm_stat pages: free + speculative + inactive are short-term reclaimable
        # → approximated as "available" (the counterpart to Linux' MemAvailable).
        vs=$(vm_stat 2>/dev/null)
        free=$(printf '%s\n' "$vs"  | awk '/Pages free/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
        spec=$(printf '%s\n' "$vs"  | awk '/Pages speculative/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
        inact=$(printf '%s\n' "$vs" | awk '/Pages inactive/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
        free=${free:-0}; spec=${spec:-0}; inact=${inact:-0}
        mb=$(( (free + spec + inact) * pagesize / 1024 / 1024 ))
        total_b=$(sysctl -n hw.memsize 2>/dev/null)   # safety cap against parse errors
        if [[ "$total_b" =~ ^[0-9]+$ ]]; then total_mb=$(( total_b / 1024 / 1024 )); [ "$mb" -gt "$total_mb" ] && mb=$total_mb; fi
        echo "${mb:-0}"; return
    fi
    # ----- Linux -----
    local meminfo_mb=0 cg_head_mb=0 lim cur reclaim=0 workingset res
    [ -r /proc/meminfo ] && meminfo_mb=$(awk '/^MemAvailable:/{print int($2/1024); exit}' /proc/meminfo 2>/dev/null)
    meminfo_mb=${meminfo_mb:-0}
    # cgroup headroom = limit − NON-reclaimable working set. IMPORTANT: in cgroup v2
    # memory.current also counts the reclaimable page cache → after a large
    # file copy/read (max−current) collapses to ~0, even though the kernel evicts
    # that cache immediately under pressure (otherwise the knob would be permanently
    # throttled to JOBS=1 in production). Hence subtract reclaimable file cache +
    # reclaimable slab — the counterpart to MemAvailable at the cgroup level. v2
    # (memory.max/.current/.stat) → v1. Reclaimable = ENTIRE page cache (v2 'file')
    # + reclaimable slab. Deliberately the total 'file' counter rather than
    # inactive_file+active_file: the LRU subtotals lag briefly after a fresh write
    # copy (dirty pages not yet on the LRU), which made the headroom falsely collapse
    # to ~0 (membench: avail=190MB right after the 5.5GB master backup). 'file'
    # captures dirty+clean immediately → stable.
    lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
    # printf "%.0f" (NOT print): otherwise awk prints byte sums >~1e9 in exponential
    # notation (e.g. 7.78298e+09), which breaks the integer guard below → reclaim=0.
    [ -r /sys/fs/cgroup/memory.stat ] && reclaim=$(awk '/^file /{a=$2}/^slab_reclaimable /{b=$2}END{printf "%.0f", a+b}' /sys/fs/cgroup/memory.stat 2>/dev/null)
    if ! [[ "$lim" =~ ^[0-9]+$ ]]; then
        lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        cur=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
        [ -r /sys/fs/cgroup/memory/memory.stat ] && reclaim=$(awk '/^total_cache /{printf "%.0f", $2; exit}' /sys/fs/cgroup/memory/memory.stat 2>/dev/null)
    fi
    [[ "$reclaim" =~ ^[0-9]+$ ]] || reclaim=0
    if [[ "$lim" =~ ^[0-9]+$ ]] && [[ "$cur" =~ ^[0-9]+$ ]] && [ "$lim" -lt 1125899906842624 ]; then
        # "max" (v2, no limit) and the huge v1 sentinel are not real limits
        # → skipped above via regex/cutoff so they do not distort the min().
        workingset=$(( cur - reclaim )); [ "$workingset" -lt 0 ] && workingset=0
        cg_head_mb=$(( (lim - workingset) / 1024 / 1024 )); [ "$cg_head_mb" -lt 0 ] && cg_head_mb=0
    fi
    # min(meminfo, cgroup headroom), ignoring 0 values (= not determined).
    res=$meminfo_mb
    if [ "$cg_head_mb" -gt 0 ] && { [ "$res" -eq 0 ] || [ "$cg_head_mb" -lt "$res" ]; }; then res=$cg_head_mb; fi
    echo "$res"
}

# ── webbed capability probe (BEFORE the mode choice) ──────────────────────────
# Probes the actually loaded webbed against the registry fixtures, BEFORE the
# adaptive default decides SAX-vs-DOM (auto-default-SAX gate). Two capabilities:
#   • nested_attr_sax (#98)  → streaming param present + SAX delivers nested attr
#     (version floor: if the streaming param is missing → clear upfront abort exit 8).
#   • sax_cr_parity (#109)   → SAX preserves CR DOM-faithfully (otherwise CR→Space, multi-line loss).
# The probes come from the data-driven registry (ingestion/version_check.json).
# FM_SKIP_WEBBED_PROBE=1 skips it (⇒ conservative: no capability confirmed → DOM).
WEBBED_HAS_STREAMING_PARAM=unknown
WEBBED_HAS_NESTED_ATTR_FIX=false
WEBBED_HAS_CR_PARITY=false
WEBBED_HAS_WS_PRESERVE=false
WEBBED_PROBE_RAN=false
WEBBED_PROBE_ERRORS=""            # three-state probes: raw error text on probe 'error' outcomes
WEBBED_VERSION_DETECTED=unknown   # filled by _probe_webbed_caps (duckdb_extensions())
# Policy-lock (B2): where this run's SAX/DOM policy and sentinel state came from.
# Values: flag (explicit user intent: FM_FORCE_DOM/--streamify/mode flags/
# FM_FORCE_WS_SENTINEL) · probe (clean capability/gate verdict, true OR false) ·
# sticky (last successfully used policy, adopted because a probe/gate failed
# with an infra error) · default (conservative default, no state available).
# Surfaced in the Strategy line and the JSON sidecar (run.strategy.source).
POLICY_SOURCE=default
WS_SENTINEL_SOURCE=default
# Sticky state file: installation-wide (.fmlab/), because the policy depends on
# webbed + repo state, not on the solution — and this block runs BEFORE the
# solution/manifest path resolution. Test mode ignores the installation state
# entirely (neither read nor write); FM_POLICY_STATE_FILE overrides the location
# (sticky-path E2E tests, analog FM_WEBBED_MANIFEST).
POLICY_STATE_FILE=""
if [ -n "${FM_POLICY_STATE_FILE:-}" ]; then
    POLICY_STATE_FILE="$FM_POLICY_STATE_FILE"
elif ! $TEST_MODE; then
    POLICY_STATE_FILE="$PROJECT_ROOT/.fmlab/webbed_policy.state"
fi
_policy_state_read   # → STICKY_POLICY / STICKY_WS_SENTINEL (empty when absent)
# chr(127) sentinel gate (#73): ON = workaround active (default, conservative). Set to OFF
# below if the probe confirms that webbed preserves whitespace natively.
# Single source for (a) the preproc gating (preprocess_file tr pipeline + awk -v ws_sentinel)
# AND (b) the SQL injection of wa_ws_sentinel at the @WEBBED_SELFTEST@ marker.
WS_SENTINEL_ON=true
# → moved to ingestion/lib/webbed_caps.sh (shell split)
if [ -z "${FM_SKIP_WEBBED_PROBE:-}" ] && [ -f "$WEBBED_SAX_PROBE" ]; then
    _probe_webbed_caps
    WEBBED_PROBE_RAN=true
    if [ "$WEBBED_HAS_STREAMING_PARAM" = "false" ]; then
        echo "ERROR: The loaded webbed/xml extension does not know the read_xml parameter 'streaming' (too old)."
        echo "       fm-lab requires DuckDB ≥ 1.5 with a current webbed/xml. Please update both"
        echo "       (e.g. in DuckDB: FORCE INSTALL webbed FROM community;) and restart."
        echo "       Bypass at your own risk (e.g. on misdetection): FM_SKIP_WEBBED_PROBE=1."
        exit 8
    fi
    # streaming param=unknown ⇒ the probe returned neither 0/1 nor "Invalid named
    # parameter" — practically always because `LOAD webbed` itself failed (extension
    # not present for the active DuckDB version). Hard-abort instead of silently sliding
    # into a DOM run that fails on every read_xml (→ hundreds of
    # follow-up errors "Table … does not exist"). Plain text + the actual webbed message.
    if [ "$WEBBED_HAS_STREAMING_PARAM" = "unknown" ]; then
        echo "ERROR: The webbed/xml extension could not be loaded (LOAD webbed failed)."
        echo "       A common cause is that webbed is not installed for the active DuckDB version"
        echo "       (see the webbed message below for the actual reason)."
        echo "       DuckDB stores extensions PER version — after a DuckDB update (e.g. 1.5.3 → 1.5.4)"
        echo "       webbed must be reinstalled."
        echo "       Fix:  \"$DUCKDB_BIN\" -c \"FORCE INSTALL webbed FROM community;\""
        if [ -n "${WEBBED_PROBE_RAW:-}" ]; then
            echo "       webbed message: $WEBBED_PROBE_RAW"
        fi
        echo "       Bypass at your own risk (e.g. on misdetection): FM_SKIP_WEBBED_PROBE=1."
        exit 8
    fi
    # #73: webbed preserves whitespace natively → sentinel off (preproc CR→0x7F is dropped,
    # SQL ws_restore becomes a no-op). Otherwise conservatively ON. Shared source for preproc + SQL.
    # Three-state (policy-lock): a clean probe verdict (true/false) decides; on
    # 'error' (probe infra failure) the run keeps the last successfully used
    # sentinel state (sticky) — the sentinel stamps the Phase-S chunk bytes, so
    # a transient flip would devalue every stored content_hash (false-changed).
    # Without a state the conservative default (ON) applies, as before.
    if [ "$WEBBED_HAS_WS_PRESERVE" = "true" ]; then
        WS_SENTINEL_ON=false; WS_SENTINEL_SOURCE=probe
    elif [ "$WEBBED_HAS_WS_PRESERVE" = "false" ]; then
        WS_SENTINEL_ON=true; WS_SENTINEL_SOURCE=probe
    elif [ -n "${STICKY_WS_SENTINEL:-}" ]; then
        WS_SENTINEL_ON="$STICKY_WS_SENTINEL"; WS_SENTINEL_SOURCE=sticky
        emit_warn "ws-preserve probe (#73) failed (infra, not a capability verdict) — keeping the last successfully used chr(127)-sentinel state ($([ "$WS_SENTINEL_ON" = "true" ] && echo ON || echo OFF), sticky). A clean probe run will re-decide. Probe error: ${WEBBED_PROBE_ERRORS:-unknown}"
    else
        WS_SENTINEL_ON=true; WS_SENTINEL_SOURCE=default
        emit_warn "ws-preserve probe (#73) failed and no policy state exists yet — conservative default: chr(127)-sentinel ON (this may restamp the chunk bytes and force a one-time full reload). Probe error: ${WEBBED_PROBE_ERRORS:-unknown}"
    fi
fi
# Operator/test override for the chr(127) sentinel (analogous to FM_FORCE_DOM): 1/true = force ON,
# 0/false = force OFF. Overrides the probe decision and
# activates the SQL injection even without a run probe (identity tests; misdetection).
WS_SENTINEL_FORCED=""
case "${FM_FORCE_WS_SENTINEL:-}" in
    1|true|on|ON|TRUE)     WS_SENTINEL_ON=true;  WS_SENTINEL_FORCED=" (FM_FORCE_WS_SENTINEL)"; WS_SENTINEL_SOURCE=flag ;;
    0|false|off|OFF|FALSE) WS_SENTINEL_ON=false; WS_SENTINEL_FORCED=" (FM_FORCE_WS_SENTINEL)"; WS_SENTINEL_SOURCE=flag ;;
esac
if [ "$WEBBED_PROBE_RAN" = "true" ]; then
    $QUIET_MODE || echo "webbed capabilities [registry: ${WEBBED_VERSION_CHECK_MANIFEST#$PROJECT_ROOT/}]: streaming-param=$WEBBED_HAS_STREAMING_PARAM · nested-attr-SAX(#98)=$WEBBED_HAS_NESTED_ATTR_FIX · sax-cr-parity(#109)=$WEBBED_HAS_CR_PARITY · ws-preserve(#73)=$WEBBED_HAS_WS_PRESERVE → chr(127)-sentinel=$([ "$WS_SENTINEL_ON" = "true" ] && echo ON || echo OFF)${WS_SENTINEL_FORCED}"
fi

# Streamify (SAX) path assets — defined BEFORE the adaptive default so it can
# validate the streamify preconditions as part of the auto-SAX decision (a stale
# or missing generate must keep the adaptive default on DOM, with correct DOM
# memory budgets, instead of hard-aborting a conversion the user never asked to
# stream). Explicit --streamify still hard-aborts on these (power-user intent).
STREAMIFY_RENAMER="$ENGINE_ROOT/engine/streamify_fm_xml.awk"
STREAMIFY_RULES="${FM_STREAMIFY_RULES:-LayoutCatalog:Layout:LC_Layout,StepsForScripts:Script:SFS_Script}"
STREAMIFY_SQL="$ENGINE_ROOT/sql/convert_xml_01_extract.streamify.sql"
# Preconditions of the SAX/streamify path: renamer + awk present, generate present
# AND fresh. Returns 0 = ready, 1 = not ready (reason in $_STREAMIFY_PRECOND_MSG).
# Pure read-check — the freshness gate regenerates only into mktemp, writes nothing.
# _STREAMIFY_PRECOND_CLASS distinguishes the failure class (policy lock):
#   not_ready = genuine state (assets missing, generate stale rc 2, pattern
#               drift rc 3) → DOM fallback stays correct;
#   infra     = the gate itself failed (rc 4 = mktemp/cmp, or any unexpected
#               rc) → NOT a staleness verdict; sticky candidate — the adaptive
#               default may keep the last successfully used policy instead of
#               flipping SAX→DOM on a transient error.
# Test hook: FM_TEST_FRESHNESS_RC=<rc> substitutes the gate's exit code
# (convention analog FM_P2_TEST_FAIL / FM_AUTO_TEST_OOM).
_STREAMIFY_PRECOND_MSG=""
_STREAMIFY_PRECOND_CLASS=""
_streamify_preconditions_ok() {
    _STREAMIFY_PRECOND_MSG=""; _STREAMIFY_PRECOND_CLASS=""
    if [ ! -f "$STREAMIFY_RENAMER" ] || ! command -v awk >/dev/null 2>&1; then
        _STREAMIFY_PRECOND_MSG="needs awk + $STREAMIFY_RENAMER"; _STREAMIFY_PRECOND_CLASS=not_ready; return 1
    fi
    if [ ! -f "$STREAMIFY_SQL" ]; then
        _STREAMIFY_PRECOND_MSG="streamify SQL variant missing ($STREAMIFY_SQL; generate via ingestion/gen_streamify_sql.sh)"; _STREAMIFY_PRECOND_CLASS=not_ready; return 1
    fi
    local _rc=0
    if [ -n "${FM_TEST_FRESHNESS_RC:-}" ]; then
        _rc="$FM_TEST_FRESHNESS_RC"
    else
        bash "$ENGINE_ROOT/gen_streamify_sql.sh" --check >/dev/null 2>&1 || _rc=$?
    fi
    case "$_rc" in
        0) return 0 ;;
        2) _STREAMIFY_PRECOND_MSG="streamify SQL generate is stale/missing (run ingestion/gen_streamify_sql.sh and commit)"; _STREAMIFY_PRECOND_CLASS=not_ready; return 1 ;;
        3) _STREAMIFY_PRECOND_MSG="streamify base pattern drift (adjust EXPECT_* in ingestion/gen_streamify_sql.sh deliberately)"; _STREAMIFY_PRECOND_CLASS=not_ready; return 1 ;;
        *) _STREAMIFY_PRECOND_MSG="freshness gate failed with rc $_rc (infrastructure — mktemp/cmp/TMPDIR? —, not a staleness verdict)"; _STREAMIFY_PRECOND_CLASS=infra; return 1 ;;
    esac
}

# ── Adaptive default ──────────────────────────────────────────────────────────
# No explicit Phase-1 strategy → pick the robust, never-hard-abort engine instead
# of classic whole-doc DOM: Turbo (chunked, ~2.5 GB floor) + --auto (OOM backoff via
# resplit). SAX (--streamify) is auto-chosen ONLY when the loaded webbed is BOTH
# correct AND text-faithful per probe: #98 (nested_attr_sax → use_streaming) makes SAX
# functionally identical to DOM, and #109 (sax_cr_parity) guarantees CR fidelity (no
# &#13;→space loss). On v2.2.1 #109 is NOT fixed → DOM stays the faithful default;
# --streamify remains an explicit opt-in (catalog-identical, but CR-lossy in text cols).
# SAX halves the parse RAM in the 3-5 GB band. Opt-outs: any explicit mode flag, or
# FM_FORCE_DOM=1 (keeps turbo+auto, just on DOM). The per-file self-test still degrades
# SAX→DOM at runtime if #98 turns out missing.
if ! $MODE_EXPLICIT && ! $TEST_MODE; then
    TURBO_MODE=true; SPLIT_MODE=true; AUTO_MODE=true
    # Policy decision, three-valued (policy lock). Priority order:
    # explicit flag (FM_FORCE_DOM) > clean probe/gate verdict (true OR false)
    # > sticky state (only on error/infra) > conservative default. A SAX
    # default needs #98 (functional identity) AND #109 (CR text fidelity) AND
    # a ready streamify path — but a probe 'error' or an infra failure of the
    # freshness gate is NOT evidence of a missing capability: with a 'sax'
    # sticky state the run keeps the last successfully used policy (loud
    # warning) instead of silently flipping to DOM and thereby devaluing every
    # policy-stamped content_hash (false-changed full reload). A clean 'false'
    # (capability provably absent) always decides — sticky never overrides
    # genuine state.
    _sax_ok=false; _sax_sticky_reason=""
    if [ "${FM_FORCE_DOM:-}" != "1" ] && [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ]; then
        _cr_ok=false
        if [ "$WEBBED_HAS_CR_PARITY" = "true" ]; then
            _cr_ok=true
        elif [ "$WEBBED_HAS_CR_PARITY" = "error" ] && [ "${STICKY_POLICY:-}" = "sax" ]; then
            _cr_ok=true; _sax_sticky_reason="CR-parity probe (#109) failed: ${WEBBED_PROBE_ERRORS:-unknown}"
        fi
        if $_cr_ok; then
            if _streamify_preconditions_ok; then
                _sax_ok=true
            elif [ "$_STREAMIFY_PRECOND_CLASS" = "infra" ] && [ "${STICKY_POLICY:-}" = "sax" ]; then
                _sax_ok=true
                _sax_sticky_reason="${_sax_sticky_reason:+$_sax_sticky_reason; }$_STREAMIFY_PRECOND_MSG"
            fi
        fi
    fi
    if $_sax_ok; then
        STREAMIFY_MODE=true
        if [ -n "$_sax_sticky_reason" ]; then
            POLICY_SOURCE=sticky
            emit_warn "Adaptive default: keeping the last successfully used policy SAX despite a transient check failure (sticky) — $_sax_sticky_reason. A clean probe run will re-decide; if webbed is genuinely broken, this run will fail visibly on read_xml instead of silently switching to DOM."
        else
            POLICY_SOURCE=probe
            echo "Note: adaptive default — SAX streaming (webbed with #98 nested-attr AND #109 CR-parity → text-faithful) + turbo + auto-backoff. Opt-out: FM_FORCE_DOM=1 or an explicit mode flag (e.g. --split)."
        fi
    elif [ "${FM_FORCE_DOM:-}" = "1" ]; then
        POLICY_SOURCE=flag
        echo "Note: adaptive default — turbo (DOM, chunked) + auto-backoff (FM_FORCE_DOM=1)."
    elif [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ] && [ "$WEBBED_HAS_CR_PARITY" = "error" ]; then
        # Probe infra failure without a usable sticky-SAX path → conservative
        # default (DOM, today's behavior) — but loud, since this is exactly the
        # silent-flip class the policy lock exists for. (Either no 'sax' state
        # exists, or the streamify path is additionally genuinely not ready.)
        POLICY_SOURCE=$([ "${STICKY_POLICY:-}" = "dom" ] && echo sticky || echo default)
        emit_warn "CR-parity probe (#109) failed (infra, not a capability verdict) — conservative default: DOM${_STREAMIFY_PRECOND_MSG:+ (streamify path additionally: $_STREAMIFY_PRECOND_MSG)}. If the previous runs were SAX, expect a one-time full reload (content hashes are policy-stamped). Probe error: ${WEBBED_PROBE_ERRORS:-unknown}"
    elif [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ] && [ "$WEBBED_HAS_CR_PARITY" = "true" ] && [ "$_STREAMIFY_PRECOND_CLASS" = "infra" ]; then
        POLICY_SOURCE=$([ "${STICKY_POLICY:-}" = "dom" ] && echo sticky || echo default)
        emit_warn "Streamify freshness gate failed with an infrastructure error and no 'sax' policy state exists — conservative default: DOM. $_STREAMIFY_PRECOND_MSG"
    elif [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ] && [ "$WEBBED_HAS_CR_PARITY" = "true" ]; then
        # webbed COULD do SAX (text-faithful), but the streamify path is not ready →
        # safe DOM fallback instead of a hard abort (the adaptive default must never
        # block a conversion the user never asked to stream).
        POLICY_SOURCE=probe
        echo "Note: adaptive default — turbo (DOM, chunked) + auto-backoff. (webbed could do SAX, but the streamify path is not ready: $_STREAMIFY_PRECOND_MSG → DOM fallback.)"
    elif [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ]; then
        POLICY_SOURCE=probe
        echo "Note: adaptive default — turbo (DOM, chunked) + auto-backoff. (#98 present, but #109 CR-parity missing → DOM stays text-faithful; --streamify only as opt-in with a text caveat.)"
    else
        POLICY_SOURCE=probe
        echo "Note: adaptive default — turbo (DOM, chunked) + auto-backoff (never a hard RAM abort).$([ "$WEBBED_HAS_NESTED_ATTR_FIX" != "true" ] && echo ' (No #98-capable webbed → no SAX.)')"
    fi
fi

# --no-auto wins over every mode that would otherwise imply the backoff (explicit
# --turbo or the adaptive default), regardless of argument order.
$NO_AUTO && AUTO_MODE=false

# Policy source for explicit user choices (flags outrank probe and sticky).
# An explicit mode flag (incl. --streamify) or FM_FORCE_DOM pins the policy by
# intent — the adaptive block above never ran, or its verdict is overridden.
$MODE_EXPLICIT && POLICY_SOURCE=flag
[ "${FM_FORCE_DOM:-}" = "1" ] && POLICY_SOURCE=flag

# Effective mode + memory metrics. Streaming: low per-file floor, spillable, cheap
# workers. DOM: full whole-doc peak, NOT spillable (libxml2 lives outside
# memory_limit), expensive workers.
_streaming_mode=false
if $STREAMIFY_MODE && [ "${FM_FORCE_DOM:-}" != "1" ]; then _streaming_mode=true; fi

# Turbo windowing default. Applies only when the user has not chosen M themselves
# (neither --subchunk nor FM_SUBCHUNK). Opt-out remains FM_SUBCHUNK=0
# (→ SUBCHUNK_SOURCE="env" → skipped → coarse). Classic path (no --turbo)
# untouched. The default recmap covers LayoutCatalog+StepsForScripts (both chunk-invariant).
if $TURBO_MODE && [ "$SUBCHUNK_SOURCE" = "default" ] && [ "${SUBCHUNK:-0}" -eq 0 ]; then
    SUBCHUNK="$TURBO_SUBCHUNK_DEFAULT"
    echo "Note: turbo windowing default — --subchunk $SUBCHUNK (LayoutCatalog+StepsForScripts; lowers the P1 peak). Opt-out: FM_SUBCHUNK=0."
fi
# DDR_INFO split as the default in turbo mode (additive-identical).
# Applies only when no explicit FM_NEST_MAP is set and FM_DDR_NEST≠0.
if $TURBO_MODE && [ -z "$NEST_MAP" ] && [ "${FM_DDR_NEST:-1}" != "0" ]; then
    NEST_MAP="DDR_INFO:Calculation,Script"
    echo "Note: turbo DDR nest — DDR_INFO → Calculation + Script chunk (halves the DDR long pole). Opt-out: FM_DDR_NEST=0."
fi
# DDR-2-level sub-chunk engagement is resolved further down, AFTER _avail_mb is known
# (the auto path keys off effectively-available RAM). The M itself is computed per file
# (see _ddr_recmap_for_file) so a single file never exceeds DDR_MAX_CHUNKS chunks.
if $_streaming_mode; then _mem_base=5000; _mem_per=1300; _job_cap=8
else                      _mem_base=10000; _mem_per=6000; _job_cap=4; fi   # DOM floor: measured per-file VmHWM ~10 GB (Artikel 9953, Belege 8712; libxml2 DOM blowup ~60-73× file size)
_nproc=$( (command -v nproc >/dev/null && nproc) || echo 4 )
# Turbo (chunk dispatch) has a different memory profile than the classic whole-doc
# path. Measured: small workers (DOM ~1.3 GB, SAX ~0.7 GB/worker), low floor
# (~baseline). The earlier W≈nproc/2 "saturation" cap was an ARTIFACT of thread
# oversubscription (W×DUCKDB_THREADS=8). With the per-worker budget t=⌊cores/W⌋
# (see TURBO_WORKER_THREADS) throughput scales cleanly up to W=nproc AND needs LESS
# RAM there (measured W16_t1 < W8_t8: −12% wall, −9% RAM) → raise the cap to nproc.
# The memory formula JOBS=(avail−base)/per still caps tight bands; FM_TURBO_JOB_CAP
# overrides. The classic path stays untouched (cap 8/4 as before; no per-worker
# thread fix there).
if $TURBO_MODE; then
    # Floor 2500 covers the measured heaviest single chunk: the DDR Calculation NEST
    # chunk peaks ~2275 MB even from only ~10 MB of XML (NEST-map, not recmap → not
    # --auto-resplittable). 1500 was too low for very tight VMs.
    _mem_base="${FM_TURBO_MEM_BASE:-2500}"
    if $_streaming_mode; then _mem_per="${FM_TURBO_MEM_PER:-800}"; else _mem_per="${FM_TURBO_MEM_PER:-1300}"; fi
    _job_cap="${FM_TURBO_JOB_CAP:-$_nproc}"; [ "$_job_cap" -lt 1 ] && _job_cap=1
fi
# Effectively available RAM: cgroup-aware (Linux) or vm_stat (macOS), see _detect_avail_mb.
_avail_mb=$(_detect_avail_mb)
[[ "$_avail_mb" =~ ^[0-9]+$ ]] || _avail_mb=0
# Test/diagnose override: pin MemAvailable to exercise the floor ladder deterministically.
[ -n "${FM_AVAIL_MB_OVERRIDE:-}" ] && _avail_mb="$FM_AVAIL_MB_OVERRIDE"

# ── DDR-2-level sub-chunk engagement (per-file M, capped — see the variable block) ──
# Resolves WHETHER it engages this run and the requested M floor. The actual per-file M
# (and the record gate) is applied in _ddr_recmap_for_file at split time. Requires
# turbo + NEST (the sub-chunk anchor sits inside the Calculation/Script NEST children).
if $TURBO_MODE && [ -n "$NEST_MAP" ]; then
    case "${DDR_SUBCHUNK:-}" in
        '')                                  # unset → auto path (RAM-pressure gated)
            if [ "${_avail_mb:-0}" -gt 0 ] && [ "${_avail_mb:-0}" -lt "$DDR_AUTO_AVAIL_MB" ]; then
                DDR_SUBCHUNK_ACTIVE=true; DDR_AUTO_MODE=true; DDR_REQ_M="$DDR_AUTO_M"
                echo "Note: DDR subchunk (auto — avail ${_avail_mb}MB < ${DDR_AUTO_AVAIL_MB}MB): Calculation only, files ≥${DDR_MIN_RECORDS} Calc records, M≥${DDR_AUTO_M}, per-file cap ${DDR_MAX_CHUNKS} chunks."
            fi ;;
        0|*[!0-9]*) : ;;                     # 0 or non-numeric → hard off
        *)                                   # explicit positive M → on for every DDR file
            DDR_SUBCHUNK_ACTIVE=true; DDR_AUTO_MODE=false; DDR_REQ_M="$DDR_SUBCHUNK"
            echo "Note: DDR subchunk (explicit): Calculation only, files ≥${DDR_MIN_RECORDS} Calc records, M≥${DDR_REQ_M}, per-file cap ${DDR_MAX_CHUNKS} chunks." ;;
    esac
fi

# Decodes $1 to UTF-8 on stdout: the FileMaker exports are UTF-16LE (BOM fffe); we
# → moved to ingestion/lib/convert_preprocess.sh (shell split)

# Dynamic --jobs default (only when neither a flag nor FM_JOBS nor 'auto').
if [ "$JOBS_SOURCE" = "dynamic" ]; then
    if [ "$_avail_mb" -gt 0 ]; then
        JOBS=$(( (_avail_mb - _mem_base) / _mem_per ))
        [ "$JOBS" -lt 1 ] && JOBS=1
        _cap=$(( _nproc < _job_cap ? _nproc : _job_cap ))
        [ "$JOBS" -gt "$_cap" ] && JOBS=$_cap
        echo "Note: --jobs dynamic = $JOBS ($($_streaming_mode && echo streaming || echo DOM), avail=${_avail_mb}MB, nproc=$_nproc). Override: --jobs N or FM_JOBS."
    else
        JOBS=1   # /proc/meminfo unreadable → conservatively sequential
    fi
fi

# Validation (positive integer).
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    echo "ERROR: Invalid --jobs '$JOBS'. Expected a positive integer, 'auto' or empty (dynamic)."
    exit 1
fi

# Adaptive ladder (only reached when the user explicitly forced a DOM strategy — the
# adaptive default is turbo+auto and never hard-aborts). Step 1: on a tight budget a
# plain classic-DOM run first DESCENDS to --split (lowers the per-file peak ~10 → ~8 GB,
# bit-identical) instead of aborting. This runs BEFORE the floor check so the floor is
# evaluated against the chosen (split-aware) strategy.
if ! $_streaming_mode && ! $TURBO_MODE && ! $SPLIT_MODE && [ "$_avail_mb" -gt 0 ] \
   && [ "$_avail_mb" -lt "$_mem_base" ] \
   && [ -f "$ENGINE_ROOT/engine/split_fm_xml.awk" ] && [ "${FM_SKIP_MEM_CHECK:-}" != "1" ]; then
    SPLIT_MODE=true
    echo "Note: classic DOM on tight RAM (avail=${_avail_mb}MB < ${_mem_base}MB) → --split automatically (lowers the per-file peak ~20 %, bit-identical). The robust default is --turbo --auto. FM_SKIP_MEM_CHECK=1 suppresses this."
fi

# Effective floor: --split lowers the classic-DOM peak (~10 → ~8 GB measured).
_eff_floor=$_mem_base
if ! $_streaming_mode && ! $TURBO_MODE && $SPLIT_MODE; then _eff_floor="${FM_DOM_SPLIT_FLOOR:-8000}"; fi

# avail floor: below it OOM looms / a silent partial build (the largest file fails,
# non-spillable). Turbo (resplit via --auto) and streaming (DuckDB spill) escape →
# warning only. Classic whole-doc DOM has NO spill escape → hard abort with guidance
# (point at the now-default turbo+auto). FM_SKIP_MEM_CHECK=1 disables the check.
if [ "$_avail_mb" -gt 0 ] && [ "$_avail_mb" -lt "$_eff_floor" ] && [ "${FM_SKIP_MEM_CHECK:-}" != "1" ]; then
    if $_streaming_mode || $TURBO_MODE; then
        echo "WARNING: MemAvailable ${_avail_mb}MB < floor ${_eff_floor}MB — large files spill/resplit (slower)$($AUTO_MODE && echo ', --auto catches OOM')."
    else
        echo "ERROR: MemAvailable ${_avail_mb}MB < DOM floor ${_eff_floor}MB. Classic DOM loads the whole document into RAM (NOT spillable, memory_limit does not apply) → OOM for large files."
        echo "       Robust default: --turbo --auto (chunked, spillable/resplittable, ~2.5 GB floor). Otherwise: --streamify (SAX, ~half the RAM + spill), more RAM, or FM_SKIP_MEM_CHECK=1 (at your own risk)."
        exit 1
    fi
fi
# Activate --streamify (opt-in, hybrid): arm the patched webbed (mandatory —
# otherwise a hard abort), pick the streamify SQL variant. Renamer rules + the
# streamify SQL path are defined above (shared with the adaptive-default gate).
# Without --streamify everything stays default/DOM (base SQL, no renamer).
# FM_FORCE_DOM=1 forces DOM even with --streamify.
if $STREAMIFY_MODE; then
    if [ "${FM_FORCE_DOM:-}" = "1" ]; then
        echo "ERROR: --streamify and FM_FORCE_DOM=1 are mutually exclusive."
        exit 1
    fi
    # Preconditions (renamer/awk, generate present + fresh). For EXPLICIT --streamify
    # a failure is a hard abort (power-user intent). The adaptive auto-SAX path has
    # already validated these above and would have fallen back to DOM otherwise, so it
    # never reaches here in a broken state — no need to re-run the ~1 s freshness gate.
    if $MODE_EXPLICIT && ! _streamify_preconditions_ok; then
        echo "ERROR: --streamify aborted — $_STREAMIFY_PRECOND_MSG."
        exit 1
    fi
    SQL_TEMPLATE="$STREAMIFY_SQL"
    # webbed binary decision. --streamify needs a webbed with the nested-attr SAX fix
    # (teaguesterling/duckdb_webbed#98):
    #   1) dev patch present under $WEBBED_PATCHED_EXT → load unsigned (-unsigned + LOAD redirect).
    #   2) stage b1: otherwise SIGNED stock webbed, PROVIDED it carries #98 — the proof comes from the
    #      startup capability probe (runs further below), so the final stock decision is made there.
    if [ -f "$WEBBED_PATCHED_EXT" ]; then
        PATCHED_WEBBED_ACTIVE=true
        echo "Note: --streamify active — renamer + patched (unsigned) webbed + streamify SQL (RAM reduction on the heavyweights)."
    else
        STREAMIFY_WANTS_STOCK=true
        echo "Note: --streamify active — renamer + streamify SQL; no dev patch → the signed stock webbed is checked after the capability probe (#98)."
    fi
fi

# Dry-run hook (test/diagnose): print the resolved strategy flags and exit before any
# build. Used by the mode-selection unit checks; never set in normal operation.
if [ "${FM_DRYRUN_MODES:-}" = "1" ]; then
    echo "RESOLVED MODE_EXPLICIT=$MODE_EXPLICIT TURBO=$TURBO_MODE SPLIT=$SPLIT_MODE AUTO=$AUTO_MODE STREAMIFY=$STREAMIFY_MODE CHANGED_ONLY=$CHANGED_ONLY streaming=$_streaming_mode jobs=$JOBS subchunk=$SUBCHUNK eff_floor=${_eff_floor:-?} mem_base=$_mem_base avail=$_avail_mb policy_source=$POLICY_SOURCE sentinel=$WS_SENTINEL_ON sentinel_source=$WS_SENTINEL_SOURCE sticky_policy=${STICKY_POLICY:-none} precond_class=${_STREAMIFY_PRECOND_CLASS:-none}"
    exit 0
fi

# ── AWK byte-clean self-probe (turbo only) ────────────────────────────────────
# The turbo Phase-S pass reimplements the tr byte clean in AWK (clean_line in the
# fuse awk). awk flavors differ in control-byte regex handling — a degenerated
# bracket class can turn the C0 strip into a silent no-op while gsub still
# reports matches (empty-string match), so a substitution-COUNT check cannot
# detect it. This probe pushes reference bytes through the REAL fuse pass and
# byte-compares (od) against the tr reference chain from preprocess_file.
# Divergence = hard abort with remediation; escape hatch FM_SKIP_AWK_PROBE=1.
# NUL input is probed separately as a WARNING only: input-NUL record handling of
# some awks is unverified terrain, and no real-world failure is on record — a
# hard abort there could ground platforms whose files never contain NUL.
if $TURBO_MODE && [ "${FM_SKIP_AWK_PROBE:-}" != "1" ]; then
    # Template form so BSD mktemp honors TMPDIR (bare `mktemp -d` on macOS always
    # goes via _CS_DARWIN_USER_TEMP_DIR to /var/folders/…). Guard explicitly:
    # without it an unwritable temp dir made the probe fail with a misleading
    # "install mawk/gawk" remediation.
    _probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fmlab.XXXXXX") || _probe_dir=""
    if [ -z "$_probe_dir" ]; then
        echo "ERROR: cannot create a temp directory under '${TMPDIR:-/tmp}' — the AWK self-probe needs one."
        echo "       Point TMPDIR at a writable directory and retry."
        echo "       Override at your own risk: FM_SKIP_AWK_PROBE=1."
        exit 1
    fi
    _probe_fuse() {  # $1 = printf format → od hex of the real fuse-pass output
        printf "$1" > "$_probe_dir/in"
        rm -f "$_probe_dir/chunk_000_main.xml"
        LC_ALL=C "$AWK_BIN" -v outdir="$_probe_dir" -v chunkmap="" -v counts="" -v rules="" \
            -f "$KATANA_COMMON_AWK" -f "$TURBO_FUSE_AWK" < "$_probe_dir/in" >/dev/null 2>&1
        od -An -tx1 "$_probe_dir/chunk_000_main.xml" 2>/dev/null | tr -d ' \n'
    }
    _probe_ref() {  # $1 = printf format → od hex of the tr reference chain
        printf "$1" | LC_ALL=C tr -d '\177' | tr '\r' '\177' | tr -d '\000-\010\013\014\016-\037' \
            | od -An -tx1 | tr -d ' \n'
    }
    # C0 mid-line + TAB (kept) + CR (sentinel) + DEL (guard) + multibyte UTF-8 (kept).
    _probe_in='P\001\003\010\013\014\016\037Q\tR\rS\177T\302\265U\n'
    if [ "$(_probe_fuse "$_probe_in")" != "$(_probe_ref "$_probe_in")" ]; then
        rm -rf "$_probe_dir"
        echo "ERROR: AWK self-probe failed — '$AWK_BIN' does not reproduce the byte clean"
        echo "       (control bytes survive or bytes get mangled; turbo output would silently"
        echo "       diverge from the tr reference). Remediation: install mawk or gawk (the"
        echo "       AWK cascade prefers them), or point FM_AWK_BIN at a capable awk."
        echo "       Override at your own risk: FM_SKIP_AWK_PROBE=1."
        exit 1
    fi
    _probe_nul='V\000W\003X\n'
    if [ "$(_probe_fuse "$_probe_nul")" != "$(_probe_ref "$_probe_nul")" ]; then
        echo "WARNING: AWK self-probe — '$AWK_BIN' diverges from the tr reference on NUL input"
        echo "         (files containing 0x00 may lose bytes on the turbo path). Please report"
        echo "         this platform/awk combination. mawk/gawk handle NUL input correctly."
    fi
    rm -rf "$_probe_dir"
fi

# --jobs + --split are ORTHOGONAL and combinable: --jobs parallelizes ACROSS files
# (each file its own part DB → merge), --split chunks WITHIN a file
# (process_single_file → run_p1_on writes all chunks into the worker's part DB,
# P1_TARGET_DB is passed through). Combined, --split lowers the per-file RAM peak
# (~12.7 → ~6 GB for one large file), so large files move out of the OOM zone and
# more workers fit the RAM band. Note: within a worker the chunks run sequentially —
# the aggregate peak of a wave is the max over the N files running simultaneously
# (no hard RAM cap).
if [ "$JOBS" -gt 1 ] && $SPLIT_MODE; then
    echo "Note: --jobs $JOBS with --split — parallelism across files + chunking per file."
fi

# Validate --attempt: positive integer, default 1 (analogous to --memory_limit).
if ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]] || [ "$ATTEMPT" -lt 1 ]; then
    echo "ERROR: Invalid --attempt '$ATTEMPT'. Expected a positive integer (>= 1)."
    exit 1
fi

# Normalize --retry-reason: the fixed enum is canonical; an unlisted value is
# ACCEPTED (not rejected) but marked 'custom'.
if [ -n "$RETRY_REASON" ]; then
    case "$RETRY_REASON" in
        oom|split-fallback|memory-limit|timeout|manual) RETRY_REASON_KNOWN=true ;;
        *) RETRY_REASON_KNOWN=false ;;
    esac
fi

# ── Multi-solution resolution (production modes only) ──
# Shared cascade (tools/lib/resolve_solution.sh): --solution flag →
# session (FMLAB_SOLUTION env / FMLAB_CONTEXT file) → active-solution pointer
# → 'default'. A bad id at any level is a hard error; only a pointer naming a
# missing solution heals to 'default' (invariant I1). An explicit --solution
# flag keeps its target even if the bundle does not exist yet — it is created
# below.
. "$PROJECT_ROOT/tools/lib/resolve_solution.sh"
fmlab_resolve_solution "$SOLUTION" || exit 1
SOLUTION="$FMLAB_RESOLVED_SOLUTION"
SOLUTION_DIR="$PROJECT_ROOT/solutions/$SOLUTION"
# Invariant I1: 'default' always exists — restore skeleton + minimal manifest
# silently (idempotent; API and tools/solution.sh do the same on their side).
if [ "$SOLUTION" = "default" ] && [ ! -f "$SOLUTION_DIR/solution.json" ]; then
    mkdir -p "$SOLUTION_DIR/xml" "$SOLUTION_DIR/db" "$SOLUTION_DIR/state/logs" 2>/dev/null
    _I1_UUID=$( (command -v uuidgen >/dev/null && uuidgen) || python3 -c 'import uuid;print(uuid.uuid4())' )
    printf '{\n  "manifest_version": 1,\n  "uuid": "%s",\n  "id": "default",\n  "display_name": "default",\n  "description": "",\n  "maintainer": "",\n  "url": "",\n  "contact": { "name": "", "email": "" },\n  "created_at": "%s",\n  "notes": ""\n}\n' \
        "$_I1_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SOLUTION_DIR/solution.json"
fi

# Interactive batch default: an argument-less invocation at a TTY should not hard
# abort — the most common case is the batch run anyway. Non-interactive (no TTY,
# e.g. CI / REST-API) keeps the behavior unchanged (argument required) so no
# automation is blocked.
if [ -z "$MODE" ]; then
    # Inbox of the resolved solution; a not-yet-migrated flat xml/ still counts.
    _INBOX="$SOLUTION_DIR/xml"
    { [ -d "$_INBOX" ] && ls "$_INBOX"/*.xml >/dev/null 2>&1; } || { ls "$PROJECT_ROOT/xml"/*.xml >/dev/null 2>&1 && _INBOX="$PROJECT_ROOT/xml"; }
    if [[ -t 0 ]] && ! $QUIET_MODE; then
        shopt -s nullglob
        _DEFAULT_XMLS=("$_INBOX"/*.xml)
        shopt -u nullglob
        _DEFAULT_N=${#_DEFAULT_XMLS[@]}
        if [ "$_DEFAULT_N" -gt 1 ]; then
            read -r -p "$_DEFAULT_N XML files found in $_INBOX/ — start batch processing? [Y/n] " _DEFAULT_ANS
            if [[ -z "$_DEFAULT_ANS" || "$_DEFAULT_ANS" =~ ^[Yy] ]]; then
                MODE="batch"
            else
                echo "Aborted."
                exit 0
            fi
        elif [ "$_DEFAULT_N" -eq 1 ]; then
            _DEFAULT_FILE=$(basename "${_DEFAULT_XMLS[0]}")
            read -r -p "One XML file found ($_DEFAULT_FILE) — process it? [Y/n] " _DEFAULT_ANS
            if [[ -z "$_DEFAULT_ANS" || "$_DEFAULT_ANS" =~ ^[Yy] ]]; then
                MODE="single"
                FILENAME="$_DEFAULT_FILE"
            else
                echo "Aborted."
                exit 0
            fi
        else
            echo "No XML files found in $_INBOX/."
            echo "Usage: $0 <xml-filename> [--force-rebuild] | --batch [--fail-fast] [--force-rebuild] [--no-auto-heal] [--memory_limit <value>] [--split] [--turbo] [--changed-only] [--auto] [--jobs <N>] [--solution <id>] | --test [--fail-fast] [--force-rebuild] [--split] [--turbo]"
            exit 1
        fi
    else
        echo "ERROR: No argument provided"
        echo "Usage: $0 <xml-filename> [--force-rebuild] | --batch [--fail-fast] [--force-rebuild] [--no-auto-heal] [--memory_limit <value>] [--split] [--turbo] [--changed-only] [--auto] [--jobs <N>] [--solution <id>] | --test [--fail-fast] [--force-rebuild] [--split] [--turbo]"
        exit 1
    fi
fi

# Set directories based on mode.
# Test mode stays OUTSIDE the solution tree (fixtures → throwaway fm_test.duckdb);
# production modes live entirely in the solution bundle solutions/<id>/:
#   XML inbox        solutions/<id>/xml/
#   master DB        solutions/<id>/db/fm_catalog.duckdb   (writers use the REAL
#                    path — never the db/ compat symlink)
#   run state + logs solutions/<id>/state/{logs,streaming,xml_convert.lock,…}
if $TEST_MODE; then
    XML_DIR="$PROJECT_ROOT/tools/tests/fixtures/xml"
    DB_DIR="$PROJECT_ROOT/db"
    DB_FILE="$DB_DIR/fm_test.duckdb"
    LOG_DIR="$PROJECT_ROOT/logs"
    LOG_PREFIX="test_batch_import"
    STREAMING_DIR="$DB_DIR/streaming"
    SOLUTION_STATE_DIR=""   # no solution context in test mode
else
    SOLUTION_STATE_DIR="$SOLUTION_DIR/state"
    XML_DIR="$SOLUTION_DIR/xml"
    DB_DIR="$SOLUTION_DIR/db"
    DB_FILE="$DB_DIR/fm_catalog.duckdb"
    LOG_DIR="$SOLUTION_STATE_DIR/logs"
    STREAMING_DIR="$SOLUTION_STATE_DIR/streaming"
    # Single-file run: its own log prefix so batch and single logs are
    # distinguishable (a JSON sidecar is written here too).
    if [[ "$MODE" == "single" ]]; then
        LOG_PREFIX="single_import"
    else
        LOG_PREFIX="batch_import"
    fi
    mkdir -p "$XML_DIR" "$DB_DIR" "$LOG_DIR" "$STREAMING_DIR" 2>/dev/null
    # Backward compatibility: a flat, not-yet-migrated xml/ is read as the
    # inbox of the 'default' solution — warn, do not hard-abort. The DB/state
    # still land in the bundle; tools/migrate-multisolution.sh is the real fix.
    if [ "$SOLUTION" = "default" ] && ! ls "$XML_DIR"/*.xml >/dev/null 2>&1 \
       && ls "$PROJECT_ROOT/xml"/*.xml >/dev/null 2>&1; then
        echo "WARNING: flat pre-multisolution xml/ detected — using it as the inbox of solution 'default'."
        echo "         Run tools/migrate-multisolution.sh to complete the layout migration."
        XML_DIR="$PROJECT_ROOT/xml"
    fi
fi

# (The webbed capability probe (#98 + #109) + the streaming-param floor check now run
#  FURTHER UP, BEFORE the adaptive default — so the auto-SAX decision can take the
#  probes into account. WEBBED_HAS_NESTED_ATTR_FIX/-CR_PARITY/-STREAMING_PARAM are
#  already set here.)

# stage b1 — final stock-streaming decision AFTER the capability probe (which
# sets WEBBED_HAS_NESTED_ATTR_FIX). Only when --streamify was requested WITHOUT a dev patch
# (STREAMIFY_WANTS_STOCK): the signed stock webbed must carry the nested-attr SAX fix (#98).
# Probe skipped (FM_SKIP_WEBBED_PROBE) ⇒ fix unconfirmed ⇒ conservative abort.
if [ "${STREAMIFY_WANTS_STOCK:-}" = "true" ]; then
    if [ "$WEBBED_HAS_NESTED_ATTR_FIX" = "true" ]; then
        STOCK_STREAMING_ACTIVE=true
        $QUIET_MODE || echo "Note: --streamify on signed stock webbed — #98 confirmed by the probe, no dev patch needed (stage b1)."
    else
        echo "ERROR: --streamify needs a webbed with the nested-attr SAX fix (teaguesterling/duckdb_webbed#98)."
        echo "       The loaded stock webbed does not carry it, or the probe was skipped"
        echo "       (nested-attr-SAX-fix=$WEBBED_HAS_NESTED_ATTR_FIX). → install signed webbed v2.2.1+,"
        echo "       set FM_WEBBED_EXT to a suitable artifact, or use the standard '--batch' (DOM)."
        exit 1
    fi
fi

# DDR sub-chunk plan dry-run (FM_DDR_PLAN=1): print the per-file plan (R, M, chunks) the
# resolved engagement would produce over $XML_DIR — using the SAME _ddr_recmap_for_file
# logic — then exit WITHOUT generating a single chunk. The safe way to preview the cap.
if [ -n "${FM_DDR_PLAN:-}" ]; then
    echo "=== DDR-Subchunk Plan-Dry-Run (XML_DIR=$XML_DIR) ==="
    echo "  engaged=$DDR_SUBCHUNK_ACTIVE  auto=$DDR_AUTO_MODE  M_floor=$DDR_REQ_M  cap=$DDR_MAX_CHUNKS/file  min_records=$DDR_MIN_RECORDS  avail=${_avail_mb}MB"
    if ! $DDR_SUBCHUNK_ACTIVE; then
        echo "  → DDR subchunk does NOT engage (default behavior: 1 Calculation + 1 Script chunk per file)."
    else
        _plan_tot=0; _plan_files=0; _plan_max=0
        for _pf in "$XML_DIR"/*.xml; do
            [ -f "$_pf" ] || continue
            _rm=$(_ddr_recmap_for_file "$_pf"); [ -n "$_rm" ] || continue
            _m="${_rm#Calculation:*:}"; _m="${_m%% *}"
            _r=$(_ddr_count_records "$_pf")
            _ch=$(( (_r + _m - 1) / _m ))
            printf "  %-32s R=%-6d M=%-5d → %d chunks\n" "$(basename "$_pf")" "$_r" "$_m" "$_ch"
            _plan_tot=$(( _plan_tot + _ch )); _plan_files=$(( _plan_files + 1 ))
            [ "$_ch" -gt "$_plan_max" ] && _plan_max="$_ch"
        done
        echo "  ----------------------------------------------------------------"
        echo "  $_plan_files file(s) sub-chunked · TOTAL $_plan_tot DDR chunks · max/file $_plan_max"
    fi
    exit 0
fi

LOG_FILE="$LOG_DIR/${LOG_PREFIX}_${TIMESTAMP}.log"
JSON_FILE="$LOG_DIR/${LOG_PREFIX}_${TIMESTAMP}.json"
ERROR_LOG_FILE="$LOG_DIR/${LOG_PREFIX}_${TIMESTAMP}_errors.log"
# Raw console mirror: captures EVERYTHING the run prints — including raw shell/kernel
# errors (e.g. "No space left on device", mktemp/cat failures) that bypass the
# structured LOG_FILE (which is rebuilt in-memory at the end by write_text_log) and
# would otherwise only ever reach the terminal. This is the authoritative "what
# actually happened" trace for post-mortem debugging.
CONSOLE_LOG="$LOG_DIR/${LOG_PREFIX}_${TIMESTAMP}_console.log"
# 2.2: additive — run.strategy gains 'source'/'sentinel_source' (policy-lock).
LOG_SCHEMA="fmlab.convert-log/2.2"

# Error-log run header, written lazily on the FIRST error append: the error log
# must not exist for error-free runs ([ -s ] gates the "Error details" hint at
# the end of the run), so no eager creation. The file-existence guard makes it
# safe from subshells/workers (a plain variable guard would not survive them).
errlog_header_once() {
    [ -e "$ERROR_LOG_FILE" ] && return 0
    printf 'fm-lab %s (commit %s) · converter %s · schema %s · run %s\n\n' \
        "$FMLAB_VERSION" "$FMLAB_SOURCE_COMMIT" "$CONVERTER_VERSION" \
        "${SCHEMA_VERSION_EXPECTED:-?}" "${LOG_PREFIX}_${TIMESTAMP}" >> "$ERROR_LOG_FILE" 2>/dev/null
}

# Activate the console mirror as early as possible (right after the log paths are
# known) so nothing downstream escapes it. Opt-out: FM_NO_CONSOLE_LOG=1.
#   * Non-quiet (CLI): merge stderr into stdout and tee both → terminal stays
#     interactive AND the file gets a full copy.
#   * Quiet (--quiet / REST-API NDJSON): keep stdout PRISTINE for the NDJSON stream
#     (only tee a copy to the file), and divert raw stderr to the file ONLY — never
#     into the NDJSON pipe, which the SSE bridge parses line-by-line.
if [ "${FM_NO_CONSOLE_LOG:-}" != "1" ] && [ "${_FM_CONSOLE_LOG_ACTIVE:-}" != "1" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null
    export _FM_CONSOLE_LOG_ACTIVE=1
    {
        echo "===== convert_fm_xml.sh console log ====="
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')  PID:$$  mode:$MODE  args:$ORIGINAL_ARGS"
        echo "fm-lab: $FMLAB_VERSION (commit $FMLAB_SOURCE_COMMIT) · converter $CONVERTER_VERSION"
        echo "========================================="
    } >> "$CONSOLE_LOG" 2>/dev/null
    if $QUIET_MODE; then
        exec > >(tee -a "$CONSOLE_LOG") 2>>"$CONSOLE_LOG"
    else
        exec > >(tee -a "$CONSOLE_LOG") 2>&1
    fi
fi

# Persist the resolved run strategy into a durable log: the decisive startup
# echoes (webbed capability probe, adaptive-default SAX/DOM decision, sentinel
# state, jobs resolution) all run BEFORE the console mirror above starts — in a
# non-interactive invocation they are gone, and precisely these choices are
# stamped into the Phase-S chunk bytes (streamify rename, chr(127) sentinel)
# and thus into every content_hash. One consolidated line, re-emitted here so
# it is guaranteed to reach _console.log; write_text_log/write_json_sidecar
# reuse it for the structured logs.
RUN_STRATEGY_TEXT="policy=$($STREAMIFY_MODE && echo sax || echo dom) policy-source=$POLICY_SOURCE · chr(127)-sentinel=$([ "$WS_SENTINEL_ON" = "true" ] && echo ON || echo OFF) sentinel-source=$WS_SENTINEL_SOURCE · webbed=$WEBBED_VERSION_DETECTED streaming-param=$WEBBED_HAS_STREAMING_PARAM #98=$WEBBED_HAS_NESTED_ATTR_FIX #109=$WEBBED_HAS_CR_PARITY #73=$WEBBED_HAS_WS_PRESERVE probe=$WEBBED_PROBE_RAN · turbo=$TURBO_MODE auto=$AUTO_MODE split=$SPLIT_MODE changed-only=$CHANGED_ONLY · jobs=$JOBS subchunk=$SUBCHUNK · avail=${_avail_mb}MB"
if $QUIET_MODE; then
    # Quiet stdout is a pristine NDJSON stream (SSE bridge) — file-only append.
    [ "${FM_NO_CONSOLE_LOG:-}" != "1" ] && printf 'Strategy: %s\n' "$RUN_STRATEGY_TEXT" >> "$CONSOLE_LOG" 2>/dev/null
else
    echo "Strategy: $RUN_STRATEGY_TEXT"
fi

# ── Turbo mode: streaming directory + chunkmap ──
# Transient operative DBs (schema separate from fm_catalog.duckdb). Location is
# per mode (set in the path block above): production → solutions/<id>/state/streaming/
# (manifests are keyed by DB filename and would collide across solutions in a
# shared dir), test → db/streaming/. Phase S builds the chunkmap (plan), Phase D
# dispatches chunks in parallel, Phase C merges.
STREAMING_DIR="${STREAMING_DIR:-$DB_DIR/streaming}"
# Name the chunkmap (transient, fresh per run) + manifest (persistent) after the
# master, so test (fm_test) and production (fm_catalog) runs do not overwrite each other.
_DB_BASE="$(basename "$DB_FILE" .duckdb)"
CHUNKMAP_DB="$STREAMING_DIR/chunkmap_${_DB_BASE}.duckdb"
MANIFEST_DB="$STREAMING_DIR/manifest_${_DB_BASE}.duckdb"

# ── Policy-flip diagnosis (policy-lock B1) ───────────────────────────────────
# Compare this run's policy fingerprint against manifest_run — the fingerprint
# of the run that wrote the currently stored catalog hashes (per solution, like
# the hashes themselves). The Phase-S chunk bytes are policy-stamped (streamify
# rename, chr(127) sentinel), so a flip devalues every content_hash: the
# catalog gate then reports "changed" for byte-identical XML and reloads the
# rename catalogs (false-changed — safe but expensive). This diagnosis NAMES
# that instead of leaving a silent hash mismatch. Warn level only, never a
# gate: the reload is the correct behavior and runs unchanged. A missing
# table/row (pre-policy-lock manifest) stays silent until the first successful
# run writes the fingerprint — deliberate, no forced rebuild.
POLICY_CHANGE_DIAG=""
_RUN_POLICY=$($STREAMIFY_MODE && echo sax || echo dom)
if [ -f "$MANIFEST_DB" ]; then
    _prev_fp=$("$DUCKDB_BIN" -readonly "$MANIFEST_DB" -noheader -list -c \
        "SELECT parser_policy || '|' || ws_sentinel FROM manifest_run WHERE id=1;" 2>/dev/null)
    if [ -n "$_prev_fp" ]; then
        _prev_pol="${_prev_fp%%|*}"; _prev_ws="${_prev_fp#*|}"
        if [ "$_prev_pol" != "$_RUN_POLICY" ] || [ "$_prev_ws" != "$WS_SENTINEL_ON" ]; then
            POLICY_CHANGE_DIAG="policy changed ${_prev_pol}/sentinel=$([ "$_prev_ws" = "true" ] && echo ON || echo OFF) → ${_RUN_POLICY}/sentinel=$([ "$WS_SENTINEL_ON" = "true" ] && echo ON || echo OFF) (source=$POLICY_SOURCE) — content hashes are policy-stamped; expect a one-time reload of the affected catalogs instead of a skip"
            # Console line right after the Strategy line; in quiet mode via
            # emit_log (NDJSON purity — reaches the web import log without any
            # server change). Re-surfaced as a post-check finding in P6.
            emit_log "Policy change: $POLICY_CHANGE_DIAG"
        fi
    fi
fi
TURBO_W=1
TURBO_WORKER_THREADS=""   # per-worker thread budget for Phase D (see below)
if $TURBO_MODE; then
    # Phase S builds the chunkmap sequentially in the main process (the only chunkmap
    # writer); only Phase D parallelizes over chunks. Hence no more JOBS=1 forcing —
    # the worker count W comes from the (dynamic) --jobs. Single-writer is preserved:
    # each chunk writes into its own chunk_<id>.duckdb.
    TURBO_W="${JOBS:-1}"; [ "$TURBO_W" -lt 1 ] 2>/dev/null && TURBO_W=1
    # Phase-D workers get their own thread budget ≈ cores/W (capped at the global
    # DUCKDB_THREADS) instead of each worker inheriting the full DUCKDB_THREADS —
    # otherwise W×threads oversubscription (−12% wall, −16% RAM from de-contention;
    # processes beat DuckDB threads ~7× on write-bound read_xml). Applies ONLY to the
    # chunk workers (Phase D); P2–P6 (batch-wide, single query) keep DUCKDB_THREADS
    # unchanged. FM_TURBO_WORKER_THREADS overrides.
    _tw_cores=$( (command -v nproc >/dev/null && nproc) || echo "$TURBO_W" )
    if [ -n "${FM_TURBO_WORKER_THREADS:-}" ]; then
        TURBO_WORKER_THREADS="$FM_TURBO_WORKER_THREADS"
    else
        TURBO_WORKER_THREADS=$(( _tw_cores / TURBO_W )); [ "$TURBO_WORKER_THREADS" -lt 1 ] && TURBO_WORKER_THREADS=1
        if [ -n "${DUCKDB_THREADS:-}" ] && [ "$TURBO_WORKER_THREADS" -gt "$DUCKDB_THREADS" ]; then
            TURBO_WORKER_THREADS="$DUCKDB_THREADS"
        fi
    fi
    $QUIET_MODE || echo "Note: turbo worker threads = $TURBO_WORKER_THREADS (≈cores/W; W=$TURBO_W, cores=$_tw_cores). P2–P6 keep DUCKDB_THREADS=${DUCKDB_THREADS:-default}. Override: FM_TURBO_WORKER_THREADS."
fi

# → moved to ingestion/lib/convert_turbo.sh (shell split)

# REST-API copy target (production mode only) — per-solution READ_ONLY copy.
# The compat symlink rest-api/db/fm_catalog.duckdb points into this directory
# for the active solution; the sync always writes the REAL per-solution path.
REST_API_DB_DIR="$PROJECT_ROOT/rest-api/db/solutions/$SOLUTION"
REST_API_DB_FILE="$REST_API_DB_DIR/fm_catalog.duckdb"
REST_API_RELOAD_URL="${REST_API_RELOAD_URL:-http://localhost:3003/api/admin/reload}"

# Lock file for concurrency protection between the skill and the REST-API.
# Content: owner PID + ISO timestamp + mode (cli|api).
# PER SOLUTION (solutions/<id>/state/) — imports of different solutions may run
# in parallel; the same solution twice is rejected (409/emit_error as before).
# NOT used in test mode — tests run against a separate DB.
FMLAB_DIR="$PROJECT_ROOT/.fmlab"
if $TEST_MODE; then
    LOCK_FILE="$FMLAB_DIR/xml_convert.lock"   # unused — test mode takes no lock
else
    LOCK_FILE="$SOLUTION_STATE_DIR/xml_convert.lock"
fi

# Global concurrency cap: the converter is RAM/CPU-heavy —
# N parallel batch runs can take the host down. Counts FOREIGN live per-solution
# locks (own solution's lock is handled by acquire_lock below). Source of the
# cap: FMLAB_MAX_CONVERTS env → .fmlab/instance.json limits.max_converts → 1.
# Enforced here for pure CLI parallelism; the REST-API hub enforces the same cap.
max_converts() {
    local cap=""
    if [ -n "${FMLAB_MAX_CONVERTS:-}" ]; then
        cap="$FMLAB_MAX_CONVERTS"
    elif [ -f "$PROJECT_ROOT/.fmlab/instance.json" ]; then
        cap=$(sed -n 's/.*"max_converts"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
              "$PROJECT_ROOT/.fmlab/instance.json" | head -n1)
    fi
    case "$cap" in
        ''|*[!0-9]*|0) echo 1 ;;
        *) echo "$cap" ;;
    esac
}

count_foreign_live_locks() {
    local n=0 f pid
    for f in "$PROJECT_ROOT"/solutions/*/state/xml_convert.lock; do
        [ -f "$f" ] || continue
        [ "$f" = "$LOCK_FILE" ] && continue
        pid=$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$pid" ] && [ "$pid" != "$$" ] \
           && printf '%s' "$pid" | grep -q '^[0-9][0-9]*$' \
           && kill -0 "$pid" 2>/dev/null; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

acquire_lock() {
    if $TEST_MODE; then
        return 0
    fi
    local _cap _live
    _cap=$(max_converts)
    _live=$(count_foreign_live_locks)
    if [ "$_live" -ge "$_cap" ]; then
        emit_error "Concurrent-import limit reached ($_live running, max $_cap) — wait for a running import to finish (FMLAB_MAX_CONVERTS / instance.json limits.max_converts)."
        return 1
    fi
    mkdir -p "$(dirname "$LOCK_FILE")"
    # Atomic creation via noclobber (O_EXCL) instead of check-then-write: the old
    # pattern had a TOCTOU window in which REST-API and CLI could take the lock
    # SIMULTANEOUSLY (A-B4). The file format (PID/timestamp/mode) stays unchanged —
    # the REST-API reads and writes the same file (xml-convert.js, recluster.service.js).
    # Up to 3 attempts: if the lock exists, the owner is checked; stale → remove
    # and retry atomically (no window between rm and re-creation).
    local attempt OWNER_PID OWNER_INFO
    for attempt in 1 2 3; do
        if ( set -C; {
                echo "$$"
                date -u +%Y-%m-%dT%H:%M:%SZ
                if $QUIET_MODE; then echo "api"; else echo "cli"; fi
             } > "$LOCK_FILE" ) 2>/dev/null; then
            LOCK_OWNED=true
            return 0
        fi
        # Lock exists: check the owner PID. Only pass numeric PIDs to kill -0
        # (A-S3 — garbage in the lock file is treated as stale instead of feeding kill).
        # Known limitation: PID reuse can misinterpret a foreign process as the owner
        # (false positive) — accepted, since locks are short-lived.
        OWNER_PID=$(head -n1 "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ "$OWNER_PID" =~ ^[0-9]+$ ]] && kill -0 "$OWNER_PID" 2>/dev/null; then
            OWNER_INFO=$(cat "$LOCK_FILE" 2>/dev/null | tr '\n' ' ')
            emit_error "Another conversion is already running (PID $OWNER_PID): $OWNER_INFO"
            return 1
        fi
        # Stale lock — the previous process no longer exists (or garbage PID)
        emit_warn "Removing stale lock file (owner PID ${OWNER_PID:-?} is gone)"
        rm -f "$LOCK_FILE"
    done
    emit_error "Lock could not be acquired: $LOCK_FILE"
    return 1
}

release_lock() {
    if [ "${LOCK_OWNED:-false}" = "true" ] && [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        LOCK_OWNED=false
    fi
}

# Concurrency cap, layer 2: with a concurrency cap > 1 and no explicit
# --memory_limit, split DuckDB's default RAM budget (~80% of host RAM) evenly
# across the possible parallel runs (percentage limits are DuckDB-native).
# The --auto OOM backoff remains the last line of defense.
if ! $TEST_MODE && [ -z "$MEMORY_LIMIT" ]; then
    _MC_CAP=$(max_converts)
    if [ "$_MC_CAP" -gt 1 ]; then
        MEMORY_LIMIT="$((80 / _MC_CAP))%"
        emit_log "Concurrency cap $_MC_CAP > 1 → per-run DuckDB memory_limit $MEMORY_LIMIT"
    fi
fi

# stamp_last_run <true|false> <exit_code> [<processed> <total>]
# CLI runs mirror their outcome to solutions/<id>/state/last_xml_run.json so the
# web frontend sees failures (and successes) of command-line runs too.
# Do NOT stamp: --quiet (the REST-API server persists the record itself,
# including event history — rest-api/src/services/xml-convert.js), test mode
# (fm_test.duckdb, not a production run) and runs without lock ownership (a
# second run rejected at the lock must not overwrite the record of the ACTIVE
# run). Schema additive to the API record ($schema_version 1); `source`
# marks the CLI origin. LAST_RUN_STAMPED prevents a double stamp
# (explicit call + EXIT-trap fallback).
LAST_RUN_STAMPED=false
stamp_last_run() {
    local _ok="$1" _rc="${2:-1}" _processed="${3:-0}" _total="${4:-0}"
    $QUIET_MODE && return 0
    [ "${TEST_MODE:-false}" = "true" ] && return 0
    [ "${LOCK_OWNED:-false}" = "true" ] || return 0
    [ -n "$SOLUTION_STATE_DIR" ] && mkdir -p "$SOLUTION_STATE_DIR" 2>/dev/null
    [ -d "$SOLUTION_STATE_DIR" ] || return 0
    LAST_RUN_STAMPED=true
    local _now; _now=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    printf '{\n  "$schema_version": 1,\n  "run_id": "%s",\n  "source": "cli",\n  "started_at": "%s",\n  "finished_at": "%s",\n  "duration_ms": null,\n  "ok": %s,\n  "exit_code": %s,\n  "processed": %s,\n  "total": %s,\n  "error_count": %s,\n  "events": []\n}\n' \
        "${RUN_STARTED_AT:-$_now}" "${RUN_STARTED_AT:-$_now}" "$_now" \
        "$_ok" "$_rc" "$_processed" "$_total" \
        "$([ "$_ok" = "true" ] && echo 0 || echo 1)" \
        > "$SOLUTION_STATE_DIR/last_xml_run.json.tmp" 2>/dev/null \
        && mv -f "$SOLUTION_STATE_DIR/last_xml_run.json.tmp" "$SOLUTION_STATE_DIR/last_xml_run.json" 2>/dev/null
    return 0
}

# anchor rate of the Calculation chunks — runs AFTER the analysis-views build
# (v_calc_anchors only comes into being there, postprocess_db would run too early). Reports the
# unresolved rate; >10 % = warn (anchor regression), otherwise info when >0.
postcheck_calc_anchors() {
    [ -f "$DB_FILE" ] || return 0
    local anchors_exist
    anchors_exist=$(pp_num "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'v_calc_anchors'")
    [ "$anchors_exist" -gt 0 ] || return 0
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unres total pct
    unres=$(pp_num "SELECT COUNT(*) FROM v_calc_anchors WHERE Owner_Type = 'unresolved'")
    total=$(pp_num "SELECT COUNT(*) FROM v_calc_anchors")
    if [ "$total" -gt 0 ] && [ "$unres" -gt 0 ]; then
        pct=$(awk -v u="$unres" -v t="$total" 'BEGIN { printf "%.1f", (u/t)*100 }')
        if awk -v p="$pct" 'BEGIN { exit !(p > 10) }'; then
            add_finding resolution warn "Calc anchors unresolved: $unres of $total ($pct%)" "Check anchor resolution (v_calc_anchors) for regression (AP-1 class)"
        else
            add_finding resolution info "Calc anchors unresolved: $unres of $total ($pct%)" "Expected partial-corpus remainder; if the rate rises, check anchor resolution"
        fi
    fi
    return 0
}

# EXIT-trap fallback : EVERY error exit before the regular completion
# (schema check, preflight, DuckDB error, …) stamps ok:false — without having to
# instrument every single exit path. Regular endings stamp
# explicitly (with processed/total) and set LAST_RUN_STAMPED.
_stamp_on_exit() {
    local _rc=$?
    if [ "$_rc" -ne 0 ] && [ "${LAST_RUN_STAMPED:-false}" = "false" ]; then
        stamp_last_run false "$_rc"
    fi
    release_lock
}

# SIGTERM/SIGINT handler: also kill long-running DuckDB children, otherwise the
# script keeps running despite the abort signal and the lock file disappears while
# something is still writing. On a clean EXIT (no signal) it is enough to remove
# the lock — the children are already done by then.
abort_handler() {
    # Hard-kill all children of this process (and their children). pkill -P
    # is available on macOS; if not, the loop falls back to jobs -p.
    if command -v pkill >/dev/null 2>&1; then
        pkill -P $$ 2>/dev/null || true
    else
        for child_pid in $(jobs -p 2>/dev/null); do
            kill -TERM "$child_pid" 2>/dev/null || true
        done
    fi
    release_lock
    exit 130
}

LOCK_OWNED=false
trap '_stamp_on_exit' EXIT
trap 'abort_handler' INT TERM

# ============================================================================
# Function: Sync master DB to rest-api/db/ and trigger server reload.
# Called after a successful import/catalog build in production mode only
# (test mode is explicitly excluded). Curl failure is non-fatal: it just
# means the REST-API server is not running.
# ============================================================================
sync_to_rest_api() {
    # Optional progress phase (default 'validate'). The batch pipeline routes the
    # sync into the final `cluster` segment (after P7) so the bar stays monotonic
    # — the sync has always been folded into whatever the last segment is.
    local _sync_phase="${1:-validate}"
    # Guard: production mode only
    if $TEST_MODE; then
        return 0
    fi
    if [ ! -f "$DB_FILE" ]; then
        emit_log "Skipping rest-api sync: master DB not found at $DB_FILE"
        return 0
    fi

    # a4 sanity: never publish a master whose catalog build did not
    # complete. The REST-API hard-depends on ObjectCatalog — a missing/empty table makes
    # /api/info,/count,/list return HTTP 500. Refuse the sync loudly instead of poisoning the
    # read copy. (With a1 the catmerge no longer half-builds; this is defense-in-depth.)
    local _oc_exists _oc_rows
    _oc_exists=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='ObjectCatalog';" 2>/dev/null)
    if [ "${_oc_exists:-0}" = "1" ]; then
        _oc_rows=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c \
            "SELECT COUNT(*) FROM ObjectCatalog;" 2>/dev/null)
    else
        _oc_rows=0
    fi
    if ! [ "${_oc_rows:-0}" -gt 0 ] 2>/dev/null; then
        emit_warn "Sync skipped: master without a populated ObjectCatalog (catalog build incomplete) — the REST-API would otherwise return HTTP 500."
        return 1
    fi

    phase_progress "$_sync_phase" 70 "Copying database to rest-api/..."
    mkdir -p "$REST_API_DB_DIR"

    # Atomic replace: copy to .tmp first, then mv
    if cp "$DB_FILE" "$REST_API_DB_FILE.tmp" && mv -f "$REST_API_DB_FILE.tmp" "$REST_API_DB_FILE"; then
        emit_log "Synced master DB to rest-api/db/solutions/$SOLUTION/fm_catalog.duckdb"
        phase_progress "$_sync_phase" 85 "Database synced"
    else
        emit_warn "Sync to rest-api/db/ failed"
        rm -f "$REST_API_DB_FILE.tmp" 2>/dev/null
        return 1
    fi

    # Reload trigger: only fire it ourselves in CLI mode. In --quiet/API mode
    # the reload is left to the Node service, which runs it synchronously after
    # receiving the `done` event — otherwise the server would reload during the
    # ongoing stream and disturb in-flight requests.
    if $QUIET_MODE; then
        phase_progress "$_sync_phase" 100 "Skipping reload (handled by API caller)"
        return 0
    fi

    # The body names the imported solution — the API reloads only when it is the
    # active one and otherwise answers with a no-op (the copy is already fresh),
    # so the hook may fire blindly.
    local CURL_ARGS=(-sS -X POST --max-time 5 -o /dev/null -w "%{http_code}"
                     -H "Content-Type: application/json"
                     -d "{\"solution\":\"$SOLUTION\"}")
    if [ -n "$ADMIN_RELOAD_TOKEN" ]; then
        CURL_ARGS+=(-H "X-Admin-Token: $ADMIN_RELOAD_TOKEN")
    fi

    local HTTP_CODE
    HTTP_CODE=$(curl "${CURL_ARGS[@]}" "$REST_API_RELOAD_URL" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        emit_log "REST-API reload triggered ($REST_API_RELOAD_URL)"
    elif [ "$HTTP_CODE" = "000" ]; then
        emit_log "REST-API not reachable at $REST_API_RELOAD_URL (ok if not running)"
    else
        emit_warn "REST-API reload returned HTTP $HTTP_CODE"
    fi
    phase_progress "$_sync_phase" 100 "Reload triggered"

    return 0
}

# ============================================================================
# stamp_solution_manifest — key-scoped merge of the convert-owned blocks
# (`technical` + `metrics`) into solutions/<id>/solution.json after a
# successful production import (manifest schema v1). Every writer only touches
# its OWN keys: the user-owned description block (root) is never rewritten;
# a missing manifest is created with a minimal root. Non-fatal — a failed
# stamp never fails the import.
# ============================================================================
stamp_solution_manifest() {
    $TEST_MODE && return 0
    [ -f "$DB_FILE" ] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        emit_warn "solution.json not stamped (python3 not available)"
        return 0
    fi
    local manifest="$SOLUTION_DIR/solution.json"
    local tech_json metrics_json
    tech_json=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c "
        SELECT to_json({
            filemaker_versions: (SELECT COALESCE(list(DISTINCT FileMaker_Version ORDER BY FileMaker_Version), []) FROM FilesCatalog WHERE FileMaker_Version IS NOT NULL),
            xml_versions:       (SELECT COALESCE(list(DISTINCT XML_Version ORDER BY XML_Version), []) FROM XMLMetadata WHERE XML_Version IS NOT NULL),
            has_ddr_info:       (SELECT COALESCE(bool_or(Has_DDR_INFO), false) FROM FilesCatalog)
        });" 2>/dev/null)
    metrics_json=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c "
        SELECT to_json({
            files:   (SELECT COUNT(*) FROM FilesCatalog),
            objects: (SELECT COUNT(*) FROM ObjectCatalog),
            links:   (SELECT COUNT(*) FROM ObjectLinks),
            by_type: (SELECT COALESCE(json_group_object(Object_Type, n), '{}'::JSON)
                      FROM (SELECT Object_Type, COUNT(*) AS n FROM ObjectCatalog GROUP BY 1 ORDER BY 1))
        });" 2>/dev/null)
    if [ -z "$tech_json" ] || [ -z "$metrics_json" ]; then
        emit_warn "solution.json not stamped (catalog queries failed)"
        return 0
    fi
    if MANIFEST_PATH="$manifest" SOL_ID="$SOLUTION" TECH_JSON="$tech_json" \
       METRICS_JSON="$metrics_json" SCHEMA_V="${SCHEMA_VERSION_EXPECTED:-}" \
       CONV_V="$CONVERTER_VERSION" python3 - <<'PYEOF'
import json, os, sys, uuid, datetime, tempfile

path = os.environ["MANIFEST_PATH"]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {
        "manifest_version": 1,
        "uuid": str(uuid.uuid4()),
        "id": os.environ["SOL_ID"],
        "display_name": os.environ["SOL_ID"],
        "description": "",
        "created_at": now,
    }

tech = json.loads(os.environ["TECH_JSON"])
tech["db_schema_version"] = os.environ["SCHEMA_V"]
tech["converter_version"] = os.environ["CONV_V"]
tech["last_import_at"] = now
metrics = json.loads(os.environ["METRICS_JSON"])
metrics["generated_at"] = now

# Key-scoped merge: replace ONLY the convert-owned blocks.
data["technical"] = tech
data["metrics"] = metrics

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PYEOF
    then
        emit_log "solution.json stamped (technical + metrics)"
    else
        emit_warn "solution.json stamp failed (import unaffected)"
    fi
    return 0
}

# ============================================================================
# prune_solution_logs — per-solution log retention: keep the last
# FM_LOG_KEEP_RUNS (default 10) convert runs (4 files each) in
# solutions/<id>/state/logs/. Trivial per directory; runs at the end of every
# production convert. Test-mode logs live in the top-level logs/ (untouched).
# ============================================================================
prune_solution_logs() {
    $TEST_MODE && return 0
    [ -d "$LOG_DIR" ] || return 0
    local keep="${FM_LOG_KEEP_RUNS:-10}"
    [ "$keep" -ge 1 ] 2>/dev/null || return 0
    ls -1 "$LOG_DIR" 2>/dev/null \
        | sed -En 's/^(single_import|batch_import)_([0-9]{8}_[0-9]{6}).*/\2/p' \
        | sort -u -r | tail -n +$((keep + 1)) | while read -r _ts; do
            rm -f "$LOG_DIR"/single_import_"${_ts}"* "$LOG_DIR"/batch_import_"${_ts}"* 2>/dev/null
        done
    return 0
}

# ============================================================================
# Phase 7 — auto clustering (raw) · cluster.json reuse
# ============================================================================

# read_cluster_json — echoes "engine|resolution|seed" for Auto-P7 / Re-Cluster.
# Source order: solutions/<id>/state/cluster.json (last /fm-graph-cluster sweep
# winner; pre-migration fallback .fmlab/cluster.json) → CLUSTER_* env
# overrides → cluster.sh defaults (auto|1.0|42). A stored 'leiden'
# engine is downgraded to 'auto' so a host without python3+igraph does not hard-
# abort cluster.sh (engine fallback); resolution/seed are preserved.
read_cluster_json() {
    # Shared reader (tools/lib/cluster_config.sh) — the same function cluster.sh
    # uses for its own defaults, so all bash callers agree on file, fallback and
    # the leiden→auto downgrade. Only the CLUSTER_* env overrides stay here.
    local dir="${SOLUTION_STATE_DIR:-$PROJECT_ROOT/.fmlab}"
    [ -f "$dir/cluster.json" ] || dir="$PROJECT_ROOT/.fmlab"
    . "$PROJECT_ROOT/tools/lib/cluster_config.sh"
    local cfg engine res seed
    cfg=$(fmlab_read_cluster_config "$dir" "$DUCKDB_BIN")
    engine="${cfg%%|*}"
    local rest="${cfg#*|}"
    res="${rest%%|*}"
    seed="${rest##*|}"
    engine="${CLUSTER_ENGINE:-$engine}"
    res="${CLUSTER_RES:-$res}"
    seed="${CLUSTER_SEED:-$seed}"
    [ "$engine" = "leiden" ] && engine="auto"
    printf '%s|%s|%s' "$engine" "$res" "$seed"
}

# run_phase7_clustering — Auto-Clustering as the last pipeline phase.
# Gate: runs only on a from-scratch build (fresh_build|force_rebuild|
# auto_heal_rebuild) OR when ObjectClusters is missing/empty (safety net). An
# incremental import into an already-clustered DB SKIPS P7 — the partition + the
# Semantic-/User-names stay, the drift gauges show the gap, the Rebuild button
# heals on demand. Why never re-partition incrementally: cluster.sh has no warm
# start (edges.csv only) → modularity clustering is globally unstable; re-running
# it on every import would churn community boundaries even in untouched files and
# mask the drift signal. Runs INSIDE the held xml_convert.lock (cluster.sh
# takes no own lock → no deadlock) and BEFORE the single pipeline sync (so the
# sync carries the fresh ObjectClusters/CommunityNames to the copy). P7 errors are
# non-fatal (downstream, not data-critical) — warn + warn-finish, never a
# fail_fast_stop. Production only (TEST_MODE uses a throwaway DB).
run_phase7_clustering() {
    if $TEST_MODE; then
        return 0
    fi

    # FM_SKIP_CLUSTER=1 skips the auto-clustering phase (P7) entirely.
    # Used by the converter quality test (tools/tests/quality/): community
    # detection is irrelevant to catalog quality and only costs runtime.
    # NOTE: --force-rebuild still wipes the cluster layer (that happens in the
    # schema reset, not here); P7 just does not rebuild it afterwards. So after a
    # test series, re-import the production set + re-run fm-graph-cluster.
    if [ "${FM_SKIP_CLUSTER:-}" = "1" ]; then
        phase_progress cluster 0 "Clustering skipped (FM_SKIP_CLUSTER=1)"
        $QUIET_MODE || echo "Phase 7 (Clustering): skipped (FM_SKIP_CLUSTER=1)"
        return 0
    fi

    local _from_scratch=false
    if [[ "$SCHEMA_ACTION_EXECUTED" =~ ^(fresh_build|force_rebuild|auto_heal_rebuild)$ ]]; then
        _from_scratch=true
    fi
    local _oc_rows
    _oc_rows=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c \
        "SELECT COUNT(*) FROM ObjectClusters;" 2>/dev/null)
    [ -z "$_oc_rows" ] && _oc_rows=0

    if ! $_from_scratch && [ "${_oc_rows:-0}" -gt 0 ] 2>/dev/null; then
        # Incremental into a clustered DB → skip. The bar reaches 100 via the sync
        # (which now fills the `cluster` segment); a single start marker keeps the
        # segment from looking stuck while avoiding a misleading "── P7 ──" banner.
        phase_progress cluster 0 "Clustering skipped (incremental)"
        $QUIET_MODE || echo "Phase 7 (Clustering): skipped (incremental import into an already-clustered DB)"
        return 0
    fi

    phase_begin P7 Clustering
    phase_progress cluster 0 "Community detection (Phase 7)…"
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Community detection (Phase 7)..."
        echo "========================================="
    fi

    local _cfg _eng _res _seed
    _cfg=$(read_cluster_json)
    _eng="${_cfg%%|*}"; _cfg="${_cfg#*|}"; _res="${_cfg%%|*}"; _seed="${_cfg##*|}"
    emit_log "Phase 7: cluster.sh (engine=$_eng resolution=$_res seed=$_seed, no-sync)"

    local _p7_log _rc=0
    _p7_log=$(mktemp "${TMPDIR:-/tmp}/fmlab-p7.XXXXXX")
    # FMLAB_SOLUTION reicht unseren AUFGELÖSTEN Scope an cluster.sh weiter. Das Kind
    # ist ein eigener Prozess und durchläuft die Kaskade (tools/lib/resolve_solution.sh)
    # von vorn; unser `--solution` ist ein K0, das nur in DIESER argv existiert. Ohne
    # die Weitergabe fiele cluster.sh auf K2 (Pointer) zurück und würde die AKTIVE
    # Lösung clustern statt der importierten — es überschriebe still den Cluster-Layer
    # einer fremden Lösung. K1 (env) ist der Kanal, den das Kind versteht; die Zuweisung
    # gilt nur für diesen einen Aufruf und leakt nicht in den restlichen Lauf.
    if FMLAB_SOLUTION="$SOLUTION" \
       FMLAB_CLUSTER_NO_SYNC=1 \
       FMLAB_CLUSTER_ENGINE="$_eng" \
       FMLAB_CLUSTER_RESOLUTION="$_res" \
       FMLAB_CLUSTER_SEED="$_seed" \
       bash "$PROJECT_ROOT/tools/graph-export/cluster.sh" >"$_p7_log" 2>&1; then
        _rc=0
    else
        _rc=$?
    fi
    # Surface the key cluster.sh lines into the run log (no flood).
    while IFS= read -r _line; do
        [ -n "$_line" ] && emit_log "P7 $_line"
    done < <(grep -iE 'engine|cache:|communit|node-reuse|modularity|floor|ERROR' "$_p7_log" 2>/dev/null | head -n 20)
    $QUIET_MODE || cat "$_p7_log"
    rm -f "$_p7_log"

    if [ "$_rc" -ne 0 ]; then
        emit_warn "Phase 7 (Clustering) failed (rc=$_rc) — the import stays successful, the partition unchanged."
        phase_finish "Clustering failed (rc=$_rc)" "{\"cluster_failed\":true,\"rc\":$_rc}"
        return 0
    fi

    local _comm
    _comm=$(pp_num "SELECT COUNT(DISTINCT Community) FROM CommunityNames")
    phase_finish "$(group_de "$_comm") communities (raw)" "{\"communities\":$_comm}"
    return 0
}

# ============================================================================
# Schema versioning & auto-heal
# ============================================================================

# Compute MD5 over the given files (cross-platform: macOS+Linux).
compute_files_hash() {
    local files=("$@")
    if command -v md5sum &>/dev/null; then
        cat "${files[@]}" 2>/dev/null | md5sum | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        cat "${files[@]}" 2>/dev/null | md5 -q
    else
        cat "${files[@]}" 2>/dev/null | shasum -a 256 | cut -c1-32
    fi
}

# Read the schema markers from the SQL template header.
# Sets SCHEMA_VERSION_EXPECTED and SCHEMA_HASH_EXPECTED (global).
read_template_schema_info() {
    SCHEMA_VERSION_EXPECTED=$(grep -m1 '^-- @SCHEMA_VERSION ' "$SQL_TEMPLATE" | awk '{print $3}')

    local hash_files_raw
    hash_files_raw=$(grep -m1 '^-- @SCHEMA_HASH_FILES ' "$SQL_TEMPLATE" | cut -d' ' -f3-)

    if [ -z "$SCHEMA_VERSION_EXPECTED" ] || [ -z "$hash_files_raw" ]; then
        echo "ERROR: SQL template is missing @SCHEMA_VERSION or @SCHEMA_HASH_FILES in the header."
        echo "       File: $SQL_TEMPLATE"
        exit 1
    fi

    # Resolve hash files relative to the engine root (paths in the
    # @SCHEMA_HASH_FILES header are engine-relative — self-contained dir)
    local -a abs_paths=()
    local f
    for f in $hash_files_raw; do
        abs_paths+=("$ENGINE_ROOT/$f")
        if [ ! -f "$ENGINE_ROOT/$f" ]; then
            echo "ERROR: SQL template reference missing: $ENGINE_ROOT/$f"
            exit 1
        fi
    done

    SCHEMA_HASH_EXPECTED=$(compute_files_hash "${abs_paths[@]}")
}

# Read the current schema state from the DB (if present).
# Sets SCHEMA_VERSION_DB and SCHEMA_HASH_DB (global) — empty if unknown.
read_db_schema_info() {
    SCHEMA_VERSION_DB=""
    SCHEMA_HASH_DB=""

    if [ ! -f "$DB_FILE" ]; then
        return 0
    fi

    local row
    row=$("$DUCKDB_BIN" -readonly "$DB_FILE" -csv -noheader -c \
        "SELECT Schema_Version, Schema_Hash FROM SchemaInfo ORDER BY Schema_Built_At DESC LIMIT 1" \
        2>/dev/null) || row=""

    if [ -n "$row" ]; then
        SCHEMA_VERSION_DB=$(echo "$row" | cut -d',' -f1)
        SCHEMA_HASH_DB=$(echo "$row" | cut -d',' -f2)
    fi
}

# Detection logic. Sets SCHEMA_ACTION and SCHEMA_REASON (global).
# Possible values: fresh_build | incremental | rebuild | warn
compute_schema_state() {
    read_template_schema_info
    read_db_schema_info

    if [ ! -f "$DB_FILE" ]; then
        SCHEMA_ACTION="fresh_build"
        SCHEMA_REASON="DB file does not exist — normal initial import"
    elif [ -z "$SCHEMA_VERSION_DB" ]; then
        SCHEMA_ACTION="rebuild"
        SCHEMA_REASON="DB without a SchemaInfo table (pre-versioning state or file corrupt)"
    elif [ "$SCHEMA_VERSION_DB" != "$SCHEMA_VERSION_EXPECTED" ]; then
        SCHEMA_ACTION="rebuild"
        SCHEMA_REASON="Schema version $SCHEMA_VERSION_DB → $SCHEMA_VERSION_EXPECTED"
    elif [ "$SCHEMA_HASH_DB" != "$SCHEMA_HASH_EXPECTED" ]; then
        SCHEMA_ACTION="warn"
        SCHEMA_REASON="Schema hash drift detected (version unchanged) — rebuild recommended via --force-rebuild"
    else
        SCHEMA_ACTION="incremental"
        SCHEMA_REASON="Schema OK (v$SCHEMA_VERSION_DB)"
    fi
}

# Write an auto-heal block into the batch log.
log_schema_action() {
    local logfile="$1"
    [ -z "$logfile" ] && return 0
    [ ! -f "$logfile" ] && return 0

    {
        echo ""
        echo "================================================================================"
        echo "Schema Auto-Heal Detection"
        echo "================================================================================"
        echo "DB Version (before):   ${SCHEMA_VERSION_DB:-<none>}"
        echo "DB Hash    (before):   ${SCHEMA_HASH_DB:-<none>}"
        echo "Template Version:      $SCHEMA_VERSION_EXPECTED"
        echo "Template Hash:         $SCHEMA_HASH_EXPECTED"
        echo "Reason:                $SCHEMA_REASON"
        echo "Action:                $SCHEMA_ACTION_EXECUTED"
        echo "--------------------------------------------------------------------------------"
        echo ""
    } >> "$logfile"
}

# Delete the DB file (with confirmation at a TTY, without one in non-interactive mode).
# $1: reason (for the user message)
delete_db_for_rebuild() {
    local reason="$1"
    if [ ! -f "$DB_FILE" ]; then
        return 0
    fi

    if [[ -t 0 ]] && ! $FORCE_REBUILD; then
        echo ""
        echo "  Reason: $reason"
        echo "  Delete $DB_FILE and rebuild from scratch? [y/N] "
        read -r CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "  Aborted."
            exit 6
        fi
    fi

    rm -f "$DB_FILE"
    echo "  ✓ DB deleted: $DB_FILE"

    # Co-invalidate the PERSISTENT turbo manifest: once the master is gone, its
    # per-catalog "already ingested" claims are false. Left behind, a subsequent
    # --changed-only/turbo run judges the streamed catalog blocks (StepsForScripts,
    # LayoutCatalog, Calculation/DDR …) "unchanged → skipped" and never loads them into
    # the fresh master — the catalog comes up partially empty and Phase 2 aborts with
    # "0 references". Applies to auto_heal_rebuild too (not just --force-rebuild, which
    # already ignores the manifest at read time).
    #
    # We EMPTY the manifest tables rather than delete the file: init_turbo_dbs() has
    # already opened the manifest AND chunkmap for this run (it runs earlier, right
    # after the lock), so removing the files would orphan those handles and Phase S
    # would fail with "Table with name chunkmap does not exist". The chunkmap is
    # transient (CREATE OR REPLACE per run) and must NOT be touched here at all — only
    # the persistent manifest carries stale cross-run state. No-op when the manifest
    # doesn't exist yet (non-turbo runs); missing tables are tolerated.
    if [ -n "${MANIFEST_DB:-}" ] && [ -f "$MANIFEST_DB" ]; then
        "$DUCKDB_BIN" "$MANIFEST_DB" -c "
            DELETE FROM manifest_catalog;
            DELETE FROM manifest_file;
            DELETE FROM pipeline_state;" >/dev/null 2>&1 \
            && echo "  ✓ Turbo manifest invalidated (emptied): $MANIFEST_DB"
    fi
}

# ============================================================================
# DuckDB settings helper
# Emits SET statements that are prepended to every DuckDB SQL stream
# (Convert/P1, Resolve/P2, Catalogs, Resolutions, Validate) — so they apply in the
# SAME DuckDB session as the ingestion query. The function name stays
# memory_limit_prefix on purpose (all call sites unchanged; minimally invasive).
#
# Output order:
#   1. memory_limit  — UNCHANGED, only when --memory_limit is set.
#   2. threads / temp_directory / max_temp_directory_size — each individually OPT-IN via
#      env var (DUCKDB_THREADS / DUCKDB_TEMP_DIR / DUCKDB_MAX_TEMP). They are set only
#      in the container (devcontainer.json containerEnv), so host runs and existing
#      tests stay unchanged.
#   3. preserve_insertion_order=false — ONLY when DUCKDB_PRESERVE_ORDER=false.
#
# Default (no env vars, no --memory_limit) = EMPTY output → the rendered prefix is
# byte-identical to before. Zero new dependencies (pure DuckDB SETs).
#
# preserve_insertion_order is opt-in on purpose (not default): for --split the script
# guarantees a "bit-identical" result to the unsplit run.
# preserve_insertion_order=false may reorder rows and could thus break
# diff/regression tests — hence it is only enableable on explicit request.
# ============================================================================
memory_limit_prefix() {
    if [ -n "$MEMORY_LIMIT" ]; then
        printf "SET memory_limit='%s';\n" "$MEMORY_LIMIT"
    fi
    if [ -n "$DUCKDB_THREADS" ];   then printf "SET threads=%s;\n" "$DUCKDB_THREADS"; fi
    if [ -n "$DUCKDB_TEMP_DIR" ];  then printf "SET temp_directory='%s';\n" "$DUCKDB_TEMP_DIR"; fi
    if [ -n "$DUCKDB_MAX_TEMP" ];  then printf "SET max_temp_directory_size='%s';\n" "$DUCKDB_MAX_TEMP"; fi
    if [ "$DUCKDB_PRESERVE_ORDER" = "false" ]; then printf "SET preserve_insertion_order=false;\n"; fi
}

# ============================================================================
# Phase 2 — reference resolution
# Runs convert_xml_02_resolve.sql exactly ONCE after all Phase-1 imports.
# Table-only (no read_xml, no fm_xml binding): rebuilds XMLStepReferences,
# XMLLayoutReferences, LayoutObjectSteps, MBS_SubnameMap, GetSubparameterMap,
# XMLCalcReferences and PluginFunctionUsages for ALL File_Names from the P1 tables.
# Must run before
# convert_xml_04_catalog.sql (ObjectLinks depends on the P2 tables).
# Writes stdout+stderr to $1. Returns: DuckDB exit code.
# ============================================================================
run_phase2_resolve() {
    local logfile="$1"
    { memory_limit_prefix; cat "$P2_TEMPLATE"; } | "$DUCKDB_BIN" "$DB_FILE" > "$logfile" 2>&1
}

# ============================================================================
# Phase 2 — File_Name-PARTITIONED. Lowers the runtime floor that P2 sets at high
# --jobs: P2 is table-only, batch-fixed and does NOT parallelize over DuckDB's
# intra-query threads (the xml_extract UDF path is serialized per row). Instead of
# a single pass, the files are split across K workers; each worker builds its file
# slice of the 7 target tables into its own part DB (read-only ATTACH on the master,
# filtered VIEWs as sources, then the UNCHANGED P2 template), followed by a central merge.
#
# CORRECTNESS: all P2 INSERTs are File_Name-scoped (every produced row carries the
# File_Name of its source row; all joins are File_Name equality joins → no
# cross-file dependency). Slicing all source tables on the same File_Name set
# yields exactly the rows of those files; the union over a file partition ==
# single-pass result (set-identity verified, all 6 tables 0/0 EXCEPT). There are no
# ordering dependencies (downstream P3–P6 reads via joins; MBS proximity pairing
# partitions by (Calc_UUID, File_Name) → within a slice).
# ============================================================================

# Effective P2 worker count: FM_P2_JOBS (env override) or JOBS, capped at the
# number of files in the DB. <2 ⇒ the caller takes the single-pass path.
_p2_effective_jobs() {
    local want explicit=false
    if [ -n "${FM_P2_JOBS:-}" ]; then want="$FM_P2_JOBS"; explicit=true; else want="$JOBS"; fi
    case "$want" in ''|*[!0-9]*) want=1 ;; esac   # 'auto'/empty/invalid → 1 (single-pass)
    # Memory cap: P2 runs K-way partitioned, EACH slice is its own DuckDB with
    # memory_limit → the SUM over the K workers must fit the RAM band, otherwise
    # OOM at a tight band × high --jobs (4-GiB measurement: P2 ×2 fits, ×4 OOMs).
    # Hence cap the DEFAULT (P2 jobs = --jobs) at available RAM (per-P2-worker
    # estimate FM_P2_PER_MB, default 1800 MB) — decouples P2 from a high P1 W. An
    # EXPLICIT FM_P2_JOBS stays a hard override (no memcap).
    if ! $explicit && [ "${_avail_mb:-0}" -gt 0 ]; then
        local per="${FM_P2_PER_MB:-1800}" memcap
        if [ "$per" -gt 0 ]; then
            memcap=$(( _avail_mb / per )); [ "$memcap" -lt 1 ] && memcap=1
            [ "$want" -gt "$memcap" ] && want="$memcap"
        fi
    fi
    # Thread-budget cap: the K slices run CONCURRENTLY and each gets ⌊cores/K⌋ threads
    # (see run_phase2_partitioned). Below ~4 threads/slice the per-slice xml_extract
    # INSERTs dominate — measured warm on the 59-file corpus (16 cores): K=4/thr=4 =
    # 22s vs K=16/thr=1 = 37s vs single-pass = 25s; the current UNCAPPED K=12/thr=16
    # oversubscribes to 39s. Capping the DEFAULT K at ⌊cores/4⌋ keeps thr≥4 (the
    # measured sweet spot K=2–4). An EXPLICIT FM_P2_JOBS bypasses this (RAM-pressure
    # release valve: more, smaller slices lower the peak DOM at the cost of speed).
    if ! $explicit; then
        local kcap=$(( _nproc / 4 )); [ "$kcap" -lt 1 ] && kcap=1
        [ "$want" -gt "$kcap" ] && want="$kcap"
    fi
    local nfiles
    nfiles=$("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list \
        -c "SELECT count(*) FROM FilesCatalog;" 2>/dev/null)
    case "$nfiles" in ''|*[!0-9]*) nfiles=1 ;; esac
    [ "$want" -gt "$nfiles" ] && want="$nfiles"
    echo "$want"
}

# One P2 slice worker: builds the 7 target tables for the files in $partdir/bin_$idx.list
# into its own part DB ($partdir/p2_$idx.duckdb). Writes rc to $partdir/$idx.rc.
_p2_worker() {
    local idx="$1" partdir="$2" threads="${3:-}"
    local pdb="$partdir/p2_${idx}.duckdb" list="$partdir/bin_${idx}.list"
    # Test hook: simulate an OOM SIGKILL for this slice without running DuckDB — writes
    # rc=137 (and no part DB) so run_phase2_partitioned records the OOM marker → the
    # post-P2 gate exercises the clean memory abort end-to-end. FM_P2_TEST_OOM="all"
    # kills every slice, a numeric value kills only that slice index. Never set in production.
    if [ -n "${FM_P2_TEST_OOM:-}" ] && { [ "$FM_P2_TEST_OOM" = "all" ] || [ "$FM_P2_TEST_OOM" = "$idx" ]; }; then
        echo "[FM_P2_TEST_OOM] simulated OOM: slice=$idx rc=137" > "$partdir/${idx}.log"
        echo 137 > "$partdir/${idx}.rc"
        return 0
    fi
    local ssql; ssql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    # IN list of this slice's File_Names (single-quoted, internal quotes doubled).
    local infiles
    infiles=$(awk '{gsub(/'"'"'/,"'"'"''"'"'"); printf "%s'"'"'%s'"'"'", (NR>1?",":""), $0}' "$list")
    {
        memory_limit_prefix
        # Per-slice thread budget (LAST SET wins over memory_limit_prefix's, if any):
        # K workers run at once → without this each slice inherits all cores and the
        # K×threads oversubscription makes every slice ≈ the full single pass.
        [ -n "$threads" ] && echo "SET threads=$threads;"
        echo "ATTACH '$DB_FILE' AS src (READ_ONLY);"
        # Filtered VIEWs as sources — the P2 template reads the tables under their
        # bare names and stays unchanged. Filter pushdown ensures xml_extract only
        # runs over the slice's portion.
        local t
        for t in StepsForScripts LayoutObjects DDR_Calculations DDR_ChunkListContexts TableOccurrenceCatalog FieldsForTables CustomFunctionsCatalog PrivilegeSetRecordAccess CustomMenuCatalog CustomMenuItemCatalog ScriptTriggers; do
            echo "CREATE VIEW $t AS SELECT * FROM src.$t WHERE File_Name IN ($infiles);"
        done
        cat "$P2_TEMPLATE"
    } > "$ssql"
    "$DUCKDB_BIN" "$pdb" < "$ssql" > "$partdir/${idx}.log" 2>&1
    echo $? > "$partdir/${idx}.rc"
    rm -f "$ssql"
}

# Orchestrates the partitioned P2 run. $1=K (≥2), $2=combined logfile.
# Returns: 0 = ok, otherwise error (worker or merge rc).
run_phase2_partitioned() {
    local K="$1" logfile="$2" p2_thr="${3:-}"
    local partdir; partdir="$(mktemp -d "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    : > "$logfile"
    [ -n "$p2_thr" ] && echo "P2 partitioned ×$K, ⌊cores/K⌋=$p2_thr threads/slice" >> "$logfile"

    # 1) File partition by weight (LayoutObjects + StepsForScripts = the
    #    xml_extract-heavy sources). Greedy LPT: heaviest file first into the
    #    currently lightest bin. With files ≥ K each bin gets ≥ 1 file.
    "$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c "
        SELECT f.File_Name || chr(9) || (COALESCE(lo.c,0)+COALESCE(s.c,0))
        FROM FilesCatalog f
        LEFT JOIN (SELECT File_Name fn,count(*) c FROM LayoutObjects   GROUP BY 1) lo ON lo.fn=f.File_Name
        LEFT JOIN (SELECT File_Name fn,count(*) c FROM StepsForScripts GROUP BY 1) s  ON s.fn=f.File_Name
        ORDER BY (COALESCE(lo.c,0)+COALESCE(s.c,0)) DESC, f.File_Name;" 2>>"$logfile" \
    | awk -F'\t' -v K="$K" -v dir="$partdir" '
        BEGIN { for (i=0;i<K;i++) load[i]=0 }
        { m=0; for (i=1;i<K;i++) if (load[i]<load[m]) m=i
          print $1 >> (dir"/bin_"m".list"); load[m]+=($2+0) }'

    # If the partition stayed empty (FilesCatalog empty / query error) → error;
    # the caller does NOT fall back to single-pass (it would see the same empty source).
    if ! ls "$partdir"/bin_*.list >/dev/null 2>&1; then
        echo "ERROR: P2 partition empty (FilesCatalog?)" >> "$logfile"
        rm -rf "$partdir"; return 1
    fi

    # 2) K slice workers concurrently (P2 is RAM-light: no DOM, only xml_extract
    #    over the slice's portion — a background loop + wait is enough).
    local i pids=()
    for ((i=0; i<K; i++)); do
        [ -f "$partdir/bin_${i}.list" ] || continue
        _p2_worker "$i" "$partdir" "$p2_thr" &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null

    # 3) Collect worker rc; mirror logs into the combined logfile.
    local rc=0 slices=()
    for ((i=0; i<K; i++)); do
        [ -f "$partdir/${i}.rc" ] || continue
        local wrc; wrc=$(cat "$partdir/${i}.rc")
        [ -s "$partdir/${i}.log" ] && { echo "--- slice $i (rc=$wrc) ---" >> "$logfile"; cat "$partdir/${i}.log" >> "$logfile"; }
        if [ "$wrc" = "0" ] && [ -f "$partdir/p2_${i}.duckdb" ]; then
            slices+=("$partdir/p2_${i}.duckdb")
        else
            rc=1
            # A slice worker runs as a bare redirect (no pipe), so its rc is the real
            # DuckDB exit — 137/143 means the kernel killed it under memory pressure.
            # This function runs in a subshell, so signal the cause to the parent via a
            # token in the shared logfile rather than a (lost) global assignment.
            case "$wrc" in 137|143) echo "P2_OOM_MARKER slice rc=$wrc" >> "$logfile" ;; esac
        fi
    done
    if [ "$rc" -ne 0 ] || [ ${#slices[@]} -eq 0 ]; then
        echo "ERROR: ≥1 P2 slice failed (rc=$rc, ok=${#slices[@]}/$K)" >> "$logfile"
        rm -rf "$partdir"; return 1
    fi

    # 4) Merge into the master: per target table freshly seed the schema from slice 0
    #    (DROP+CTAS LIMIT 0 — eliminates schema drift; P2 rebuilds these tables
    #    fully anyway, and between P2 and P3 nobody reads them), then fill additively
    #    from all slices. No persistent views depend on them.
    local msql ai=0 j s tbl
    msql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    {
        for s in "${slices[@]}"; do echo "ATTACH '$s' AS s${ai} (READ_ONLY);"; ai=$((ai+1)); done
        for tbl in XMLStepReferences XMLLayoutReferences LayoutObjectSteps MBS_SubnameMap GetSubparameterMap XMLCalcReferences PluginFunctionUsages; do
            echo "DROP TABLE IF EXISTS $tbl;"
            echo "CREATE TABLE $tbl AS SELECT * FROM s0.$tbl LIMIT 0;"
            j=0
            for s in "${slices[@]}"; do echo "INSERT INTO $tbl BY NAME SELECT * FROM s${j}.$tbl;"; j=$((j+1)); done
        done
    } > "$msql"
    { memory_limit_prefix; cat "$msql"; } | "$DUCKDB_BIN" "$DB_FILE" >> "$logfile" 2>&1; rc=$?
    rm -f "$msql"
    rm -rf "$partdir"
    # The merge is the last stage in a pipe → rc is DuckDB's own exit; a memory kill
    # here (137/143) is an OOM just as a slice kill is. Signal via the logfile (subshell).
    case "$rc" in 137|143) echo "P2_OOM_MARKER merge rc=$rc" >> "$logfile" ;; esac
    return $rc
}

# Dispatcher: partitioned (K≥2) or single-pass (run_pipeline_step). Mirrors the
# run_pipeline_step semantics (return 0=ok/continue, 2=fail-fast stop).
run_phase2() {
    local label="$1"
    # UUID-Healing-Kaskade (H1): zieht Fremd-UUID-Spalten (StepsForScripts.Script_UUID,
    # ScriptTriggers.Script_UUID, TO/BT/Field/VL-Träger) über den Zensus nach. Muss auf
    # der fertig gemergten Master-DB laufen (multi-fed Tabellen!) und VOR jedem
    # P2-Statement (P2 leitet XMLStepReferences aus StepsForScripts ab). run_phase2 ist
    # der eine gemeinsame Punkt aller Modi (Batch/Turbo/partitioniert/Single-File).
    # Zensus-getrieben: ohne 'healed'-Zeilen ein No-Op. Fehler sind HART (stille
    # Link-Verfälschung wäre schlimmer als ein Abbruch).
    run_pipeline_step "Heal Cascade (UUID-Healing)" "$ENGINE_ROOT/sql/convert_xml_01b_heal_cascade.sql"
    if ! $PIPELINE_STEP_OK; then
        P2_FAILED=true
        echo "✗ WARNING: Heal Cascade failed — aborting before Phase 2 (links would resolve against stale UUIDs)"
        return 1
    fi
    # Phase 1c (Design-function retype): FileMaker's SaXML tags the design
    # functions (WindowNames, DatabaseNames, …) as PluginFunctionRef chunks in
    # the authoring client's language. Retype them to FunctionRef BEFORE P2
    # reads the chunk stream (see convert_xml_01c_design_function_retype.sql);
    # the generated seed (gen_design_functions.sh) runs in the same DuckDB
    # session and provides the positive name list. Soft-fail by design: a
    # missing seed or a failed step degrades to the previous classification
    # (design functions counted as plug-in functions) with a visible WARNING —
    # never an abort (unlike the heal cascade, no link would resolve wrongly).
    local dfn_seed="$ENGINE_ROOT/sql/generated/design_functions_seed.sql"
    local dfn_sql="$ENGINE_ROOT/sql/convert_xml_01c_design_function_retype.sql"
    if [ -f "$dfn_seed" ]; then
        run_pipeline_step "Design-Function Retype (P1c)" "$dfn_seed" "$dfn_sql"
    else
        echo "✗ WARNING: design-function seed missing ($dfn_seed) — design functions stay classified as plug-in functions (regenerate: ingestion/gen_design_functions.sh)"
        run_pipeline_step "Design-Function Retype (P1c)" "$dfn_sql"
    fi
    if ! $PIPELINE_STEP_OK; then
        echo "✗ WARNING: Design-Function Retype failed — design functions stay classified as plug-in functions (Phase 2 continues)"
    fi
    local K; K=$(_p2_effective_jobs)
    if [ "${K:-1}" -lt 2 ]; then
        # Test hook: force a P2 failure without running the template. The natural
        # trigger (PK collision on a re-run) is gone since the clear-before-insert
        # fix, so the post-P2 gates (batch AND single-file) need a deterministic
        # switch to stay end-to-end testable. Single-pass branch only — force
        # K=1 via FM_P2_JOBS=1 on multi-file corpora. Never set in production.
        if [ -n "${FM_P2_TEST_FAIL:-}" ]; then
            echo "[FM_P2_TEST_FAIL] simulated P2 failure (template skipped)"
            P2_FAILED=true
            return 1
        fi
        run_pipeline_step "$label" "$P2_TEMPLATE"; local rc=$?
        # Mirror the partitioned path: surface a non-fatal SQL failure via P2_FAILED
        # so the post-P2 gate (batch) and the single-mode chain tracking see it.
        $PIPELINE_STEP_OK || P2_FAILED=true
        return $rc
    fi
    # Per-slice thread budget ≈ ⌊cores/K⌋ (mirrors TURBO_WORKER_THREADS for Phase D):
    # the K slice workers run concurrently, so each must cap its DuckDB threads or
    # K×threads oversubscription makes every slice ≈ the full single pass (measured:
    # uncapped K=12 = 39s vs capped K=4/thr=4 = 22s vs single-pass 25s). FM_P2_THREADS
    # overrides (e.g. force 1 under extreme RAM pressure).
    local p2_thr
    if [ -n "${FM_P2_THREADS:-}" ]; then p2_thr="$FM_P2_THREADS"
    else p2_thr=$(( _nproc / K )); [ "$p2_thr" -lt 1 ] && p2_thr=1; fi
    local templog; templog=$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX"); local rc=0
    if (cd "$PROJECT_ROOT" && run_phase2_partitioned "$K" "$templog" "$p2_thr"); then
        echo "✓ $label (partitioned ×$K, ${p2_thr} threads/slice)"
    else
        # Mark the phase as failed so the post-P2 gate stops the pipeline cleanly
        # instead of letting the universal catalogs fail on the missing reference
        # tables. An OOM marker (written by a killed slice/merge, subshell-safe via the
        # logfile) narrows the cause to memory pressure.
        P2_FAILED=true
        # OOM cause: a SIGKILL leaves the subshell marker; a clean DuckDB memory stop
        # (memory_limit exceeded) leaves its own stderr text. Match both.
        grep -qiE 'P2_OOM_MARKER|out of memory|failed to allocate|exceeds.*memory_limit' "$templog" 2>/dev/null && P2_OOM=true
        echo "✗ WARNING: $label (partitioned ×$K) failed"
        errlog_header_once
        {
            echo "================================================================================"
            echo "ERROR: $label (partitioned ×$K)"
            echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "================================================================================"
            cat "$templog"; echo ""
        } >> "$ERROR_LOG_FILE"
        # Suppress the raw DuckDB dump on stdout when it is an OOM — the post-P2 gate
        # prints a clean, actionable block instead (the full detail stays in the error
        # log). Non-OOM failures keep the inline detail for quick diagnosis.
        if ! $P2_OOM; then echo "Error details:"; sed 's/^/  /' "$templog"; fi
        $FAIL_FAST && rc=2
    fi
    rm -f "$templog"
    return $rc
}

# ============================================================================
# Apply Phase 1 to ONE XML file (full file or chunk).
# $1 = directory (FM_XML_DIR), $2 = filename, $3 = error log (appended to).
# fm_xml + schema markers are injected into the template via sed as before.
# Returns: DuckDB exit code.
# ============================================================================
run_p1_on() {
    local xdir="$1" xfile="$2" elog="$3"
    # Target DB: default master ($DB_FILE). In parallel mode (--jobs N) the worker
    # sets P1_TARGET_DB to its own part DB so N P1 runs can write concurrently
    # without a DuckDB file-lock conflict (merge afterwards).
    local target="${P1_TARGET_DB:-$DB_FILE}"
    # Sub-chunk offset for Sequence_ID: default 0; when sub-chunking a
    # Sequence_ID catalog the split loop passes the global record offset through.
    local seqoff="${P1_SEQ_OFFSET:-0}"
    case "$seqoff" in ''|*[!0-9]*) seqoff=0 ;; esac
    local tsql; tsql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    # $xfile lands as a sed replacement AND an SQL literal: first double the
    # quotes for the SQL ('→''), then escape the sed-active characters (\ & /) in the
    # replacement — otherwise e.g. O'Brien.xml breaks the SQL (injection into
    # the writable session) or '&' expands to the pattern on the sed side.
    local xfile_esc="${xfile//\'/\'\'}"
    xfile_esc="${xfile_esc//\\/\\\\}"
    xfile_esc="${xfile_esc//&/\\&}"
    xfile_esc="${xfile_esc//\//\\/}"
    sed -e "s/SET VARIABLE fm_xml = '.*';/SET VARIABLE fm_xml = '$xfile_esc';/" \
        -e "s/SET VARIABLE schema_version = '.*';/SET VARIABLE schema_version = '$SCHEMA_VERSION_EXPECTED';/" \
        -e "s/SET VARIABLE schema_hash = '.*';/SET VARIABLE schema_hash = '$SCHEMA_HASH_EXPECTED';/" \
        -e "s/SET VARIABLE seq_offset = [0-9]*;/SET VARIABLE seq_offset = $seqoff;/" \
        "$SQL_TEMPLATE" > "$tsql"

    # ---- Section dispatch (parse amplification) ----
    # In turbo mode a chunk contains exactly ONE catalog branch (the chunk map knows
    # it); nevertheless the FULL P1 script ran per chunk so far (~40 read_xml over
    # every chunk — parse volume ~40× the corpus size). The @P1_SECTION:<cat,...>@
    # markers in the template tag each extraction with its source catalogs —
    # mirrored exactly on _turbo_catalog_owned() + multi-fed (ScriptTriggers:
    # main+LayoutCatalog): the catalog-granular merge takes ONLY the owned tables
    # from a chunk anyway, so skipped sections would have delivered empty/
    # discarded results → the result is bit-identical by construction.
    # CREATE TABLE/prelude/SchemaInfo are untagged (they always run, so the schema parity
    # of the chunk DBs is preserved). Active ONLY when the caller sets FM_P1_CATALOG
    # (turbo chunk worker); opt-out FM_P1_DISPATCH=0. Unknown catalogs
    # run in full (fallback — the catalog-granular merge rejects them anyway).
    if [ -n "${FM_P1_CATALOG:-}" ] && [ "${FM_P1_DISPATCH:-1}" != "0" ]; then
        awk -v cat="$FM_P1_CATALOG" '
            /^-- @P1_SECTION:/ {
                spec = $0
                sub(/^-- @P1_SECTION:/, "", spec); sub(/@.*/, "", spec)
                # index() instead of ~ (no regex — match catalog names literally)
                skip = (index("," spec ",", "," cat ",") > 0) ? 0 : 1
                next
            }
            /^-- @END_P1_SECTION@/ { skip = 0; next }
            skip { next }
            { print }
        ' "$tsql" > "$tsql.2"
        mv "$tsql.2" "$tsql"
    fi

    # Inject the capability self-test at the @WEBBED_SELFTEST@ marker. Two independent parts:
    #   (1) #73 chr(127) sentinel (wa_ws_sentinel) — mode-INDEPENDENT (DOM as well as SAX): is
    #       injected as soon as the capability probe ran; otherwise the SQL default ON applies.
    #       WS_SENTINEL_ON is the single source (also for the bash/awk preproc gating) →
    #       SQL and preproc stay consistent per batch. true/false = SQL boolean literal.
    #   (2) nested-attr SAX (use_streaming/dom_threshold) — relevant ONLY in streaming mode:
    #       reads the #98 probe with forced SAX; only a webbed with the fix → use_streaming=
    #       true → dom_threshold lowered. ONLY the unsigned dev patch additionally needs
    #       the LOAD redirect + -unsigned; signed stock webbed loads via `LOAD webbed;`.
    local duck_flags=()
    local selftest=""
    if [ "$WEBBED_PROBE_RAN" = "true" ] || [ -n "${FM_FORCE_WS_SENTINEL:-}" ]; then
        selftest="SET VARIABLE wa_ws_sentinel = ${WS_SENTINEL_ON};"
    fi
    if $PATCHED_WEBBED_ACTIVE || $STOCK_STREAMING_ACTIVE; then
        selftest="${selftest:+$selftest }SET VARIABLE use_streaming = ((${_vc_nested_probe_sql}) = 1); SET VARIABLE dom_threshold = (CASE WHEN getvariable('use_streaming') THEN ${WEBBED_STREAM_THRESHOLD} ELSE getvariable('max_filesize') END);"
    fi
    # A-S2 + A-B6: marker replacement via awk/ENVIRON instead of `sed -i -e` —
    #   (1) sed with a '|' delimiter breaks as soon as the manifest SQL contains a legitimate
    #       '||' (SQL concat) or newlines; ENVIRON bypasses any
    #       delimiter/escape processing (even '\' stays raw).
    #   (2) BSD sed interprets `-i -e` as the backup suffix '-e' and leaked one
    #       `$tsql-e` file to TMPDIR per chunk call (macOS, turbo: hundreds).
    local _load_redirect=""
    if $PATCHED_WEBBED_ACTIVE; then
        duck_flags+=(-unsigned)
        _load_redirect="LOAD '${WEBBED_PATCHED_EXT}';"
    fi
    if [ -n "$selftest" ] || [ -n "$_load_redirect" ]; then
        FM_SELFTEST_SQL="$selftest" FM_WEBBED_LOAD="$_load_redirect" \
        "${AWK_BIN:-awk}" '
            /^-- @WEBBED_SELFTEST@/ && ENVIRON["FM_SELFTEST_SQL"] != "" { print ENVIRON["FM_SELFTEST_SQL"]; next }
            /^LOAD webbed;/         && ENVIRON["FM_WEBBED_LOAD"]  != "" { print ENVIRON["FM_WEBBED_LOAD"]; next }
            { print }
        ' "$tsql" > "$tsql.2"
        mv "$tsql.2" "$tsql"
    fi

    { memory_limit_prefix; cat "$tsql"; } | FM_XML_DIR="$xdir" "$DUCKDB_BIN" "${duck_flags[@]}" "$target" >> "$elog" 2>&1
    local rc=$?
    rm -f "$tsql"
    return $rc
}

# ============================================================================
# Error-log helpers + disk-space guard
# ----------------------------------------------------------------------------
# log_error_section <title> [body-file] — append a clearly delimited section to
# ERROR_LOG_FILE. Without a body-file, reads the body from stdin. Used so that
# problems which never make it into the structured LOG_FILE (chunk failures, disk
# pressure, …) are always traceable after the run.
# ============================================================================
log_error_section() {
    local title="$1" body="${2:-}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    errlog_header_once
    {
        echo "================================================================================"
        echo "ERROR: $title"
        echo "Time:  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================================"
        if [ -n "$body" ] && [ -f "$body" ]; then cat "$body"; else cat; fi
        echo ""
    } >> "$ERROR_LOG_FILE" 2>/dev/null
}

# _disk_free_mb <dir> — available space (MB) on the filesystem holding <dir>.
# Portable across Linux + macOS via POSIX `df -Pm` (field 4 = available 1 MiB blocks).
# Walks up to the nearest existing parent so it works before the dir is created.
# Echoes an integer, or nothing if undeterminable.
_disk_free_mb() {
    local d="$1"
    while [ -n "$d" ] && [ ! -d "$d" ]; do d="$(dirname "$d")"; [ "$d" = "/" ] && break; done
    [ -d "$d" ] || return 0
    df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}'
}

# _disk_snapshot <dir> [<dir2> …] — human-readable df dump (for the error log).
_disk_snapshot() {
    local d
    for d in "$@"; do
        [ -n "$d" ] || continue
        while [ -n "$d" ] && [ ! -d "$d" ]; do d="$(dirname "$d")"; [ "$d" = "/" ] && break; done
        [ -d "$d" ] && { echo "# df -h $d"; df -h "$d" 2>/dev/null; echo ""; }
    done
}

# check_disk_space <label> — verify every write target has >= FM_MIN_DISK_MB free
# (default 1024 MB). On shortfall: log a section (with a df snapshot) to the error
# log, emit a clear message, and return 1 so the caller can abort cleanly BEFORE the
# "No space left on device" cascade corrupts sidecars / hangs the dispatcher.
# Suppress entirely with FM_MIN_DISK_MB=0.
check_disk_space() {
    local label="${1:-}"
    local floor="${FM_MIN_DISK_MB:-1024}"
    case "$floor" in ''|*[!0-9]*) floor=1024 ;; esac
    [ "$floor" -eq 0 ] && return 0
    local dir worst="" worst_free="" free
    for dir in "$STREAMING_DIR" "$DB_DIR" "$LOG_DIR" "${TMPDIR:-/tmp}"; do
        [ -n "$dir" ] || continue
        free=$(_disk_free_mb "$dir")
        case "$free" in ''|*[!0-9]*) continue ;; esac
        if [ -z "$worst_free" ] || [ "$free" -lt "$worst_free" ]; then worst_free="$free"; worst="$dir"; fi
    done
    [ -z "$worst_free" ] && return 0   # df not parseable → don't block
    if [ "$worst_free" -lt "$floor" ]; then
        local msg="Not enough free disk space${label:+ ($label)}: only ${worst_free} MB free on $worst (at least ${floor} MB needed; override: FM_MIN_DISK_MB)."
        log_error_section "Disk space low${label:+ — $label}" < <(echo "$msg"; echo ""; _disk_snapshot "$STREAMING_DIR" "$DB_DIR" "$LOG_DIR" "${TMPDIR:-/tmp}")
        emit_error "$msg"
        return 1
    fi
    return 0
}

# preflight_disk_or_abort <label> — check_disk_space; on shortfall finalize the logs
# and abort cleanly (the structured log + JSON sidecar are still written, and the
# disk section is already in the error log). Used by the classic (non-turbo)
# Phase-1 paths, which would otherwise hit the same "No space left on device" cascade.
preflight_disk_or_abort() {
    check_disk_space "$1" && return 0
    finalize_logs
    emit_done false "Disk space too low: $1"
    echo "Error log: $ERROR_LOG_FILE" >&2
    exit 1
}

# ============================================================================
# Memory forensics (Linux/proc; a no-op on other platforms → empty values).
# Lets you trace how much RAM each file pulled and how tight system memory got
# meanwhile — important since the rolling pool can keep large files resident at the
# same time (OOM risk, exit 137).
# ============================================================================
# System-wide available memory in KB (MemAvailable); empty if not readable.
_mem_avail_kb() {
    [ -r /proc/meminfo ] && awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null
}
# Summed VmRSS (KB) of the process tree from PID $1 (recursive over /proc children).
# Captures duckdb + children under the worker subshell.
# NON-FORKING: the entire tree walk runs in ONE awk process (awk-internal
# recursion). The earlier recursive command substitution
# `sum=$(( sum + $(_tree_rss_kb "$k") ))` forked a bash subshell PER process-tree
# node — called by the per-worker sampler every 0.2 s (only the parallel path,
# --jobs ≥2) it spawned more subshells under load than were reaped → process
# explosion (thousands of bash) → non-reclaimable kernel slab → host OOM. That was
# the true cause of the `--batch --jobs N` OOM (previously wrongly blamed on DOM RAM).
# Now: 1 awk per sample instead of O(nodes) forks.
_tree_rss_kb() {
    [ -r "/proc/$1/status" ] || { echo 0; return 0; }
    awk -v root="$1" '
    function rss_of(p,   line,r,f,a) {
        r=0; f="/proc/" p "/status"
        while ((getline line < f) > 0) if (line ~ /^VmRSS:/) { split(line,a," "); r=a[2]+0; break }
        close(f); return r
    }
    function walk(p,   line,kids,n,i,f) {
        total += rss_of(p)
        f="/proc/" p "/task/" p "/children"
        if ((getline line < f) > 0) { close(f); n=split(line,kids," "); for(i=1;i<=n;i++) if(kids[i]!="") walk(kids[i]) }
        else close(f)
    }
    BEGIN { total=0; walk(root); print total }' 2>/dev/null
}
# KB → integer MB (for log lines/tables).
_kb_mb() { awk -v k="${1:-0}" 'BEGIN{ printf "%d", (k+0)/1024 }'; }

# → moved to ingestion/lib/convert_turbo.sh (shell split)

# → moved to ingestion/lib/convert_preprocess.sh (shell split)

# ============================================================================
# Function: Process a single XML file
# Arguments: $1 = filename (just the basename, not full path)
# Returns: 0 on success, non-zero on error
# ============================================================================
process_single_file() {
    local FILENAME="$1"

    # 1. Validate XML file exists
    if [ ! -f "$XML_DIR/$FILENAME" ]; then
        echo "ERROR: File not found: $FILENAME"
        return 1
    fi

    # 2. Create temporary working directory
    local TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fmlab.XXXXXX")
    trap "rm -rf '$TEMP_DIR'; trap - RETURN" RETURN  # A-B10: cleanup + clear the trap itself (otherwise it fires again on every later return)

    # 3. Pre-Processor (stage 1): encoding→UTF-8 (BOM sniffing) + special-char
    #    cleanup in one step. Produces the cleaned UTF-8 file directly.
    local BASENAME="${FILENAME%.xml}"
    local XML_FILE="${BASENAME}_clean.xml"
    local PRE_OUTPUT="$TEMP_DIR/$XML_FILE"

    preprocess_file "$XML_DIR/$FILENAME" "$PRE_OUTPUT"
    local PRE_RC=$?
    if [ $PRE_RC -eq 2 ]; then
        echo "  ERROR: UTF-8 conversion failed"
        return 2
    elif [ $PRE_RC -ne 0 ]; then
        echo "  ERROR: XML preprocessing failed"
        return 5
    fi
    echo "  Preprocessed (enc=$PRE_ENCODING): replaced_cr=$PRE_CR_COUNT del_guard=$PRE_DEL_GUARD_COUNT stripped_invalid=$PRE_STRIPPED"

    # 3b. --streamify: branch-aware element renaming on the cleaned file
    #     (TAB-indented, one element/line — exactly what the renamer expects).
    #     Makes the heavyweight anchors unique (LayoutCatalog>Layout→LC_Layout, …),
    #     so the streamify SQL can stream them via read_xml(record_element=…).
    #     Surgical: only the anchor tags change; all other bytes stay the same.
    if $STREAMIFY_MODE; then
        local RENAMED="$TEMP_DIR/${BASENAME}_streamify.xml"
        if awk -v rules="$STREAMIFY_RULES" -f "$KATANA_COMMON_AWK" -f "$STREAMIFY_RENAMER" < "$PRE_OUTPUT" > "$RENAMED" 2>"$TEMP_DIR/streamify_err.log"; then
            mv "$RENAMED" "$PRE_OUTPUT"
            echo "  Streamify renaming applied (rules: $STREAMIFY_RULES)"
        else
            echo "  ERROR: Streamify renaming failed"
            sed 's/^/    /' "$TEMP_DIR/streamify_err.log" 2>/dev/null
            return 5
        fi
    fi

    # 4. Validate XML root element — only FMSaveAsXML (SaXML v2.1.0.0+) is supported.
    #    Runs on the cleaned UTF-8 file; the byte cleanup leaves the ASCII pattern
    #    <FMSaveAsXML untouched.
    local ROOT_ELEMENT=$(head -c 4096 "$PRE_OUTPUT" | grep -oE '<(FMSaveAsXML|FMDynamicTemplate)[ >]' | head -1 | sed 's/[< >]//g')

    if [[ "$ROOT_ELEMENT" == "FMDynamicTemplate" ]]; then
        echo "  WARNING: Skipped — legacy SaXML v2.0.0.0 format (FMDynamicTemplate)"
        echo "  This format (FileMaker 18.x) is not supported. Minimum: SaXML v2.1.0.0 (FileMaker 19+)."
        return 4
    fi

    if [[ -z "$ROOT_ELEMENT" ]]; then
        echo "  WARNING: Skipped — could not detect XML root element (expected FMSaveAsXML)"
        return 4
    fi

    # 5. Run Phase 1 (extraction) — optionally split (--split).
    # Phase 2 (resolution) no longer runs per file: it is table-only and is called
    # exactly once after all P1 imports (run_phase2_resolve), analogous to the
    # universal catalogs.
    #   fm_xml/schema_version/schema_hash are injected by run_p1_on via sed.
    local ERROR_LOG="$TEMP_DIR/error.log"
    : > "$ERROR_LOG"
    local RESULT=0

    if $SPLIT_MODE; then
        # Split the XML into chunks (StepsForScripts + DDR_INFO separated out, the rest
        # = main). Each chunk runs as a standalone P1 run; the base catalogs are
        # chunk-safe (UPSERT or branch-guarded PrivilegeSet DELETE).
        echo "  Splitting XML into chunks (--split)..."
        local CHUNK_DIR="$TEMP_DIR/chunks"
        mkdir -p "$CHUNK_DIR"
        local NCHUNKS
        # subchunk>0 additionally cuts the safe heavy branches (SUBCHUNK_RECMAP) into
        # N-record pieces. 0 = unchanged --split behavior.
        # In --streamify mode the splitter runs AFTER the renamer, so it sees the
        # renamed record anchors (LayoutCatalog>Layout→LC_Layout, Script→SFS_Script,
        # see STREAMIFY_RULES). The recmap passed to the splitter must therefore match
        # the renamed record element name — otherwise the branch is separated but the
        # sub-chunk rotation never fires. (The BRANCH tag stays un-renamed → the offset
        # loop below keeps using the original SUBCHUNK_RECMAP.)
        local EFFECTIVE_RECMAP="$SUBCHUNK_RECMAP"
        if $STREAMIFY_MODE && [ -n "$STREAMIFY_RULES" ] && [ "${SUBCHUNK:-0}" -gt 0 ]; then
            local _erm="" _e _br _rec _new
            for _e in $SUBCHUNK_RECMAP; do
                _br="${_e%%:*}"; _rec="${_e##*:}"
                _new=$(printf '%s' "$STREAMIFY_RULES" | tr ',' '\n' \
                       | awk -F: -v b="$_br" -v r="$_rec" '$1==b && $2==r {print $3; exit}')
                [ -n "$_new" ] && _rec="$_new"
                _erm="$_erm${_erm:+ }$_br:$_rec"
            done
            EFFECTIVE_RECMAP="$_erm"
            echo "  Sub-Chunk recmap (streamify-aware): $EFFECTIVE_RECMAP"
        fi
        # DDR-2-level sub-chunk entries (`*` anchor, no rename): per-file M (capped).
        local _ddr_rm; _ddr_rm=$(_ddr_recmap_for_file "$PRE_OUTPUT")
        if [ -n "$_ddr_rm" ]; then
            EFFECTIVE_RECMAP="$EFFECTIVE_RECMAP $_ddr_rm"
            echo "  DDR-Subchunk: ${_ddr_rm%% *}"
        fi
        # Turbo (Phase S): the splitter additionally writes a chunkmap sidecar
        # (catalog/split_number/record_count/sub_m/chunk_file). On the classic path the
        # variable stays empty → no sidecar output, the splitter behaves unchanged.
        local CHUNKMAP_TSV=""
        $TURBO_MODE && CHUNKMAP_TSV="$CHUNK_DIR/chunkmap.tsv"
        NCHUNKS=$(awk -v outdir="$CHUNK_DIR" -v subchunk="$SUBCHUNK" -v recmap="$EFFECTIVE_RECMAP" \
                      -v nest="$NEST_MAP" \
                      -v chunkmap="$CHUNKMAP_TSV" \
                      -f "$KATANA_COMMON_AWK" -f "$SPLITTER_AWK" < "$PRE_OUTPUT" 2>>"$ERROR_LOG")
        if [ -z "$NCHUNKS" ] || [ ! -f "$CHUNK_DIR/chunk_000_main.xml" ]; then
            echo "  ERROR: XML split failed"
            sed 's/^/    /' "$ERROR_LOG"
            return 3
        fi
        echo "  Converting $NCHUNKS chunk(s) to DuckDB..."
        # chunk_000_main first (glob order), then the branch chunks.
        # Sub-chunks of a Sequence_ID catalog (LayoutCatalog) appear consecutively in
        # glob order (= XML order). The global record offset of a sub-chunk = (its
        # occurrence index for this branch) × SUBCHUNK. With that, ROW_NUMBER()+seq_offset
        # yields the global XML order. Branches without a Sequence_ID (StepsForScripts)
        # also get an offset — inconsequential there (no Sequence_ID read in the chunk).
        # Offset 0 ⇒ unsplit/coarse byte-identical.
        if $TURBO_MODE; then
            # Phase S (load): take this file's chunkmap from the sidecar into the run
            # chunkmap. seq_offset = split_number×sub_m is computed by the DB (replaces the
            # inline _seqocc loop); content_hash stays NULL until a later step,
            # est_bytes until the dispatch-weight step. chunk_id globally continuous.
            local _fn="${BASENAME//\'/\'\'}"
            local _pol; _pol=$($STREAMIFY_MODE && echo sax || echo dom)
            if ! "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "
                INSERT INTO chunkmap
                SELECT
                    (SELECT COALESCE(MAX(chunk_id),0) FROM chunkmap) + ROW_NUMBER() OVER () AS chunk_id,
                    '$_fn' AS file_name,
                    catalog,
                    '$_fn' || '::' || catalog AS split_group,
                    split_number,
                    '$CHUNK_DIR' || '/' || chunk_file AS chunk_path,
                    record_count,
                    CAST(split_number AS BIGINT) * CAST(sub_m AS BIGINT) AS seq_offset,
                    NULL AS content_hash,
                    '$_pol' AS parser_policy,
                    NULL AS est_bytes,
                    'pending' AS status,
                    1 AS attempt
                FROM read_csv('$CHUNK_DIR/chunkmap.tsv', delim='\t', header=false,
                     columns={'catalog':'VARCHAR','split_number':'INTEGER','record_count':'INTEGER','sub_m':'INTEGER','chunk_file':'VARCHAR'});
                " >>"$ERROR_LOG" 2>&1; then
                echo "  ERROR: Chunk map load failed"
                sed 's/^/    /' "$ERROR_LOG"
                return 3
            fi
            # Phase D: parse chunkmap-driven sequentially into the master. Order by
            # chunk_path (main=chunk_000 first, like the glob on the classic path);
            # seq_offset NOW comes from the chunkmap row. UPSERT makes the order
            # result-irrelevant, the master path is == classic.
            local _coff _cp
            while IFS=$'\t' read -r _coff _cp; do
                [ -z "$_cp" ] && continue
                P1_SEQ_OFFSET="$_coff" run_p1_on "$(dirname "$_cp")" "$(basename "$_cp")" "$ERROR_LOG" || RESULT=$?
            done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
                "SELECT seq_offset::VARCHAR || chr(9) || chunk_path FROM chunkmap WHERE file_name='$_fn' ORDER BY chunk_path;")
        else
        local chunk base ctag off _j _cur _found
        # _seqocc: ctag → occurrence count. bash-3.2-safe as parallel indexed arrays
        # (ctags are identifiers, small N) with a linear lookup; no associative array.
        local -a _seqocc_k _seqocc_v
        for chunk in "$CHUNK_DIR"/chunk_*.xml; do
            base="$(basename "$chunk" .xml)"
            ctag="${base#chunk_[0-9][0-9][0-9]_}"   # branch tag after chunk_NNN_
            off=0
            if [ "${SUBCHUNK:-0}" -gt 0 ]; then
                case " $SUBCHUNK_RECMAP " in
                    *" ${ctag}:"*)
                        _cur=0; _found=-1
                        for _j in "${!_seqocc_k[@]}"; do
                            if [ "${_seqocc_k[$_j]}" = "$ctag" ]; then _cur="${_seqocc_v[$_j]}"; _found=$_j; break; fi
                        done
                        off=$(( _cur * SUBCHUNK ))
                        if [ "$_found" -ge 0 ]; then _seqocc_v[$_found]=$(( _cur + 1 ))
                        else _seqocc_k+=("$ctag"); _seqocc_v+=("1"); fi
                        ;;
                esac
            fi
            P1_SEQ_OFFSET="$off" run_p1_on "$CHUNK_DIR" "$(basename "$chunk")" "$ERROR_LOG" || RESULT=$?
        done
        fi
    else
        echo "  Converting XML to DuckDB..."
        run_p1_on "$TEMP_DIR" "$XML_FILE" "$ERROR_LOG" || RESULT=$?
    fi

    # Report result (cleanup happens automatically via trap)
    if [ $RESULT -eq 0 ]; then
        return 0
    else
        echo "  ERROR: DuckDB conversion failed (exit code: $RESULT)"
        echo "  Error details:"
        sed 's/^/    /' "$ERROR_LOG"
        return 3
    fi
}

# ============================================================================
# Stage 3 — Post-Processor
# Pure DuckDB read queries against the finished DB, run AFTER the universal
# catalogs + resolutions and BEFORE the sync. Collects findings in POSTCHECK_FINDINGS[]
# (format: category|severity|message|fix-hint). No step hard-aborts here — the
# validity assessment happens centrally in finalize_run() (stage 4).
# ============================================================================
POSTCHECK_FINDINGS=()
POSTCHECK_WARN=0
CHECKS_RUN=0

# Single scalar read against the master DB (read-only). Empty output on a
# missing table/error → treated as 0 by the caller.
pp_query() {
    "$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -csv -c "$1" 2>/dev/null | head -n1
}

# Like pp_query, but guaranteed to return a non-negative integer (else 0).
pp_num() {
    local v; v=$(pp_query "$1")
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo 0; fi
}

# add_finding <category> <severity ok|warn|error> <message> <fix-hint>
add_finding() {
    POSTCHECK_FINDINGS+=("$1|$2|$3|$4")
    case "$2" in
        warn)  POSTCHECK_WARN=$((POSTCHECK_WARN + 1)); emit_warn "[check:$1] $3 — $4" ;;
        error) emit_error "[check:$1] $3 — $4" ;;
        info)  emit_log "[check:$1] $3 — $4" ;;  # visible, non-fatal, NOT counted as warn
    esac
    if $QUIET_MODE; then
        _emit_json check category "$1" severity "$2" message "$3" hint "$4"
    fi
}

postprocess_db() {
    POSTCHECK_FINDINGS=()
    POSTCHECK_WARN=0
    CHECKS_RUN=0
    [ ! -f "$DB_FILE" ] && return 0

    # Policy-flip diagnosis (policy-lock B1), detected at startup against
    # manifest_run — re-surfaced here so it lands in the post-check section of
    # the .log/JSON too (warn level, never gates: the reload is correct).
    if [ -n "${POLICY_CHANGE_DIAG:-}" ]; then
        add_finding consistency warn "$POLICY_CHANGE_DIAG" "One-time full reload under the new policy is expected; check the Strategy line (policy-source) and run.strategy in the JSON sidecar if the flip was not intended"
    fi

    # Phase 6: (re)create the check views — data logic in the SQL, assessment here.
    # CREATE OR REPLACE VIEW is idempotent; needs write access (master DB).
    # The views stay in the DB and are thus usable for REST-API/ad-hoc too.
    if [ -f "$VALIDATE_TEMPLATE" ]; then
        { memory_limit_prefix; cat "$VALIDATE_TEMPLATE"; } | "$DUCKDB_BIN" "$DB_FILE" >/dev/null 2>&1 \
            || emit_warn "Phase-6 check views could not be created (post-checks may be incomplete)"
    fi

    local files_n; files_n=$(pp_num "SELECT files_n FROM v_check_counts")

    # --- 4.1 Plausibility checks (counts) ---
    if [ "$files_n" -gt 0 ]; then
        CHECKS_RUN=$((CHECKS_RUN + 1))
        local bt; bt=$(pp_num "SELECT basetables_n FROM v_check_counts")
        if [ "$bt" -eq 0 ]; then
            add_finding plausibility warn "BaseTableCatalog empty despite $files_n imported file(s)" "Import incomplete? Check the convert_xml_01_extract.sql run"
        fi

        CHECKS_RUN=$((CHECKS_RUN + 1))
        local lay lobj
        lay=$(pp_num "SELECT layouts_n FROM v_check_counts")
        lobj=$(pp_num "SELECT layoutobjects_n FROM v_check_counts")
        if [ "$lay" -gt 0 ] && [ "$lobj" -eq 0 ]; then
            add_finding plausibility warn "$lay Layout(s), but 0 LayoutObjects" "Check the LayoutObject parser"
        fi

        CHECKS_RUN=$((CHECKS_RUN + 1))
        local scr steps
        scr=$(pp_num "SELECT scripts_n FROM v_check_counts")
        steps=$(pp_num "SELECT steps_n FROM v_check_counts")
        if [ "$scr" -gt 0 ] && [ "$steps" -eq 0 ]; then
            add_finding plausibility warn "$scr Script(s), but 0 StepsForScripts" "Check the script-step parser"
        fi
    fi

    # --- 4.2 Consistency checks ---
    # C1 — no empty/NULL Calc_UUID (primary regression guard).
    # By the slot-preserving regex '<(_[^\s>]+)' in convert_xml_01_extract.sql it is 0 by construction;
    # only catches future, unexpected ObjectList element forms.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local c1; c1=$(pp_num "SELECT bad_calc_uuid FROM v_check_calc_uuid")
    if [ "$c1" -gt 0 ]; then
        add_finding consistency warn "$c1 DDR_Calculations row(s) with an empty/NULL Calc_UUID" "Check the ObjectList element form (Calc_UUID slot regex in convert_xml_01_extract.sql)"
    fi

    # Orphan same-file link targets (true count, no cap): ObjectLinks targets
    # without an ObjectCatalog entry. Cross-file links are excluded (they resolve
    # cleanly). Severity is gated on corpus completeness: on an INCOMPLETE corpus
    # (referenced external files not imported) such orphans are EXPECTED — refs
    # point into files whose objects live in no catalog → report as info, not warn.
    # Only on a complete corpus (missing_ext_files=0) do orphans signal genuine
    # dangling references / an integrity problem.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local orphans missing_ext
    orphans=$(pp_num "SELECT orphan_n FROM v_check_orphan_links")
    missing_ext=$(pp_num "SELECT missing_ext_files FROM v_check_orphan_links")
    if [ "$orphans" -gt 0 ]; then
        if [ "$missing_ext" -gt 0 ]; then
            add_finding consistency info "$orphans orphaned reference target(s) — expected: $missing_ext referenced external file(s) not imported (partial corpus)" "For complete resolution, import all referenced FileMaker files into xml/"
        else
            add_finding consistency warn "$orphans orphaned same-file link target(s) missing in ObjectCatalog (corpus complete)" "Genuine dead references — check referential integrity"
        fi
    fi

    # Synthetic regression (guard): a derived role/object type must not be
    # empty while its source is populated — catches silent 0-row INSERTs after
    # pattern/naming drift (the PluginComponent 'MBS::%'-vs-'MBS:%' class).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local synth_bad
    synth_bad=$(pp_num "SELECT COUNT(*) FROM v_check_synthetic WHERE source_n > 0 AND derived_n = 0")
    if [ "$synth_bad" -gt 0 ]; then
        local synth_rules
        synth_rules=$(pp_query "SELECT string_agg(rule, ', ') FROM v_check_synthetic WHERE source_n > 0 AND derived_n = 0")
        add_finding regression warn "$synth_bad synthetic rule(s) violated: ${synth_rules:-?} (source populated, derived rows = 0)" "Check the silent 0-row INSERT of the associated P4 block (pattern/naming-convention drift)"
    fi

    # Numeric sentinel drift (guard): Validation_MaxChars is normalized at
    # extraction (NULLIF on 4294967295 = FileMaker's "unlimited" sentinel).
    # Any value still above the coarse plausibility bound means the sentinel
    # changed shape and the NULLIF no longer matches — detect, never mutate.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local sentinel_n
    sentinel_n=$(pp_num "SELECT sentinel_n FROM v_check_numeric_sentinels")
    if [ "$sentinel_n" -gt 0 ]; then
        local sentinel_sample
        sentinel_sample=$(pp_query "SELECT sample FROM v_check_numeric_sentinels")
        add_finding regression warn "$sentinel_n implausible Validation_MaxChars value(s) > 1e9: ${sentinel_sample:-?}" "Unrecognized sentinel or new serialization — check the NULLIF normalization in convert_xml_01_extract.sql"
    fi

    # Orphan link SOURCES + NULL-target stock (guard). Sources are same-file
    # by construction → an orphan source is an integrity problem even on a partial
    # corpus (unlike orphan targets above).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local orph_src null_tgt null_xf
    orph_src=$(pp_num "SELECT orphan_src_n FROM v_check_orphan_sources")
    null_tgt=$(pp_num "SELECT null_target_links FROM v_check_orphan_sources")
    null_xf=$(pp_num "SELECT null_crossfile_links FROM v_check_orphan_sources")
    if [ "$orph_src" -gt 0 ] || [ "$null_tgt" -gt 0 ]; then
        add_finding consistency warn "ObjectLinks hygiene: $orph_src orphaned link SOURCE(s), $null_tgt link(s) with a NULL target" "Check the source filter of the P4 link blocks or the LEFT-JOIN NULL pass-through"
    elif [ "$null_xf" -gt 0 ]; then
        add_finding consistency info "$null_xf link(s) with Is_Cross_File=NULL (consumers must be NULL-safe)" "Unify the Is_Cross_File semantics of the P4 blocks (COALESCE to FALSE)"
    fi

    # Resolution rate per Ref_Type (guard): the resolvers claim ≈97–99 % —
    # a join/scoping rework silently dropping links would show up here first.
    # Threshold 90 % on types with ≥ 50 rows (assessment here, data in the view).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local lowres_n
    lowres_n=$(pp_num "SELECT COUNT(*) FROM v_check_resolution WHERE total >= 50 AND quote_pct < 90")
    if [ "$lowres_n" -gt 0 ]; then
        local lowres_detail
        lowres_detail=$(pp_query "SELECT string_agg(source || '/' || ref_type || '=' || quote_pct || '%', ', ') FROM v_check_resolution WHERE total >= 50 AND quote_pct < 90")
        add_finding resolution warn "Resolution rate below 90%: ${lowres_detail:-?}" "Check the resolver joins in convert_xml_02_resolve.sql for drift (scoping/name join)"
    fi

    # MBS subname resolution (guard): after the P3.5 plain-text recovery only
    # genuinely dynamic first arguments (MBS($var; …)) may remain unqualified.
    # A rising remainder means a new DDR loss constellation the lexer does not
    # cover (or proximity-pairing drift). Threshold 3 % with ≥ 50 MBS calls.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local mbs_total mbs_unres
    mbs_total=$(pp_num "SELECT total FROM v_check_mbs_subname_resolution")
    mbs_unres=$(pp_num "SELECT unresolved FROM v_check_mbs_subname_resolution")
    if [ "$mbs_total" -ge 50 ] && [ $((mbs_unres * 100)) -gt $((mbs_total * 3)) ]; then
        local mbs_pct
        mbs_pct=$(pp_query "SELECT unresolved_pct FROM v_check_mbs_subname_resolution")
        add_finding resolution warn "MBS subname resolution: $mbs_unres of $mbs_total calls unqualified (${mbs_pct:-?}%)" "Check convert_xml_03b_plugin_subname_recovery.sql (lexer/pairing) and the MBS_SubnameMap proximity pairing in convert_xml_02_resolve.sql"
    fi

    # Design-function retype (informational): FileMaker's SaXML tags the design
    # functions (WindowNames, DatabaseNames, …) as plug-in references; phase 1c
    # re-types them so they resolve as built-in functions. Reported so the
    # classification correction stays visible per import (0 = nothing to report).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local dfn_chunks
    dfn_chunks=$(pp_num "SELECT chunks FROM v_check_design_function_retype")
    if [ "$dfn_chunks" -gt 0 ]; then
        local dfn_names dfn_files
        dfn_names=$(pp_query "SELECT names FROM v_check_design_function_retype")
        dfn_files=$(pp_num "SELECT files FROM v_check_design_function_retype")
        add_finding resolution info "Design functions re-typed from plug-in references: $dfn_chunks chunk(s) in $dfn_files file(s) — ${dfn_names:-?}" "Expected: the SaXML export tags design functions as PluginFunctionRef; they now resolve as BuiltinFunction (calls_function) — see convert_xml_01c_design_function_retype.sql"
    fi

    # Resolution rate of the relationship predicate fields (informational). External
    # TO sides carry empty field UUIDs; the cases without an imported target file legitimately
    # stay unresolved (partial corpus) → INFO, not an error.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local relfield_detail
    relfield_detail=$(pp_query "SELECT string_agg(ref_type || '=' || resolved || '/' || total || ' (' || quote_pct || '%)', ', ' ORDER BY ref_type) FROM v_check_relationship_field_resolution")
    if [ -n "${relfield_detail:-}" ]; then
        add_finding relationship_fields info "Relationship predicate field resolution: ${relfield_detail}" "Unresolved = external TO targets without an imported file (partial corpus, expected)"
    fi

    # Link-role registry completeness : every active role must be classified.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unreg_roles
    unreg_roles=$(pp_num "SELECT unregistered_roles FROM v_check_link_roles")
    if [ "$unreg_roles" -gt 0 ]; then
        local unreg_list
        unreg_list=$(pp_query "SELECT role_list FROM v_check_link_roles")
        add_finding registry warn "$unreg_roles link role(s) without a registry entry: ${unreg_list:-?}" "Add the new role(s) to LinkRoleRegistry in convert_xml_04_catalog.sql (usage/containment/restriction)"
    fi

    # (Object_UUID, File_Name) duplicates in ObjectCatalog (composite-UUID
    # collision) — 0 today, hence a cheap, hard guard.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local cat_dups
    cat_dups=$(pp_num "SELECT dup_n FROM v_check_catalog_dups")
    if [ "$cat_dups" -gt 0 ]; then
        local dup_sample
        dup_sample=$(pp_query "SELECT sample FROM v_check_catalog_dups")
        add_finding consistency warn "$cat_dups ObjectCatalog duplicate(s) (Object_UUID, File_Name): ${dup_sample:-?}" "Check the composite-UUID formulas (namespace prefixes) or doubly-registering catalog blocks in convert_xml_04_catalog.sql"
    fi

    # cardinalities (clone fan-out) — 1:1 structural edges must not fan out.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local card_bad
    card_bad=$(pp_num "SELECT COALESCE(SUM(violation_n),0) FROM v_check_cardinality")
    if [ "$card_bad" -gt 0 ]; then
        local card_detail
        card_detail=$(pp_query "SELECT string_agg(rule || '=' || violation_n, ', ') FROM v_check_cardinality")
        add_finding consistency warn "Cardinality violation(s): ${card_detail:-?}" "Check the UUID scoping of the affected P4 link blocks (clone-fan-out class)"
    fi

    # phantom links (clone fan-out, all operational roles) — an edge fanning over
    # >1 target files whose source file declares exactly ONE of them should have
    # been resolved by the prefer-declared-source pass in P4; leftovers with
    # declared=1 mean that pass leaks. undeclared/multi-declared groups are the
    # honest model boundary (reported as info by design, not an error).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local phantom_leak
    phantom_leak=$(pp_num "SELECT COALESCE(SUM(declared_one_groups),0) FROM v_check_phantom_links")
    if [ "$phantom_leak" -gt 0 ]; then
        local phantom_detail
        phantom_detail=$(pp_query "SELECT string_agg(Link_Role || '=' || declared_one_groups, ', ') FROM v_check_phantom_links WHERE declared_one_groups > 0")
        add_finding consistency warn "Phantom link group(s) with a unique declared source left unresolved: ${phantom_detail:-?}" "The prefer-declared-source pass in convert_xml_04_catalog.sql did not catch these — check DataSourceFileMap resolution for the affected files"
    else
        local phantom_rest
        phantom_rest=$(pp_num "SELECT COALESCE(SUM(undeclared_groups + multi_declared_groups),0) FROM v_check_phantom_links")
        if [ "$phantom_rest" -gt 0 ]; then
            local phantom_rest_detail
            phantom_rest_detail=$(pp_query "SELECT string_agg(Link_Role || '=' || (undeclared_groups + multi_declared_groups), ', ') FROM v_check_phantom_links WHERE undeclared_groups + multi_declared_groups > 0")
            add_finding consistency info "Ambiguous clone link group(s) without a unique declared source (model boundary): ${phantom_rest_detail:-?}" "Clone targets not disambiguable via data-source declarations — see the resolution doctrine in convert_xml_04_catalog.sql"
        fi
    fi

    # XML record count vs. catalog rows (Sequence_ID continuity) —
    # COUNT < MAX(Sequence_ID) ⇒ the UPSERT silently collapsed UUID duplicates.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local seq_bad
    seq_bad=$(pp_num "SELECT COUNT(*) FROM v_check_xml_counts")
    if [ "$seq_bad" -gt 0 ]; then
        local seq_detail
        seq_detail=$(pp_query "SELECT string_agg(catalog || '/' || File_Name || ' (' || rows_n || '≠' || max_seq || ')', ', ') FROM v_check_xml_counts")
        add_finding consistency warn "Sequence gap(s) — XML records vs. catalog rows: ${seq_detail:-?}" "UUID duplicates in the source file (merge artifact) — check the export or the dedup stage"
    fi

    # generic dup-absorption census (all censused UUID-PK catalogs).
    # Source_Records (P1 census) vs. live-counted catalog rows — Absorbed > 0
    # ⇒ silent row loss from UUID duplicates in the export, now visible across
    # all censused catalogs (previously only ScriptCatalog/Layouts).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local abs_bad
    abs_bad=$(pp_num "SELECT COUNT(*) FROM v_check_absorbed_dups")
    if [ "$abs_bad" -gt 0 ]; then
        local abs_total abs_detail
        abs_total=$(pp_num "SELECT COALESCE(SUM(Absorbed),0) FROM v_check_absorbed_dups")
        abs_detail=$(pp_query "SELECT string_agg(Catalog || '/' || File_Name || ' (−' || Absorbed || ')', ', ' ORDER BY Absorbed DESC) FROM v_check_absorbed_dups")
        add_finding consistency warn \
          "$abs_total absorbed UUID duplicate(s) across ${abs_bad} catalog/file combination(s): ${abs_detail:-?}" \
          "Source defect (duplicate UUIDs in the FileMaker export) — check the export. The converter deduplicates deterministically (last-write-wins); the fix is only a source correction"
    fi

    # Chunk_Type NULL in DDR_Calculations — P1-path drift detector.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local ct_null
    ct_null=$(pp_num "SELECT null_n FROM v_check_chunk_type_null")
    if [ "$ct_null" -gt 0 ]; then
        add_finding consistency warn "$ct_null DDR chunk(s) with Chunk_Type=NULL" "The P1 DDR extraction (Chunk_Type derivation) has changed — the P2 chunk logic otherwise works blind"
    fi

    # Phase-S/P1 chunk integrity — chunk classification vs. chunk content
    # (independent artifacts). Typed reference chunks with dead content are the
    # silent-P2=0 signature: P2 would scan fully and resolve nothing. Warn here,
    # per file with counts and a sample chunk, instead of at the P2 gate.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local chunkref_bad
    chunkref_bad=$(pp_num "SELECT COUNT(*) FROM v_check_chunk_refs")
    if [ "$chunkref_bad" -gt 0 ]; then
        local chunkref_detail
        chunkref_detail=$(pp_query "SELECT string_agg(File_Name || ' (FieldRef w/o UUID ' || fieldref_no_uuid || ', empty named refs ' || namedref_empty || ', e.g. ' || COALESCE(sample_chunk,'?') || ')', '; ') FROM v_check_chunk_refs")
        add_finding consistency warn "Reference chunk(s) with dead content after P1 ingest: ${chunkref_detail:-?}" "Phase-S/D content divergence or parse loss — P2 would silently resolve 0 references for these files. Check the fused chunk output (self-probe) and re-run the affected files"
    fi

    # Step-role curation (step-ID mapping): field references of uncurated
    # step types fall back to references_field — where-used stays correct,
    # only the role differentiation (sets/reads/…) is missing → info, not an error.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unmapped_steps
    unmapped_steps=$(pp_num "SELECT unmapped_types FROM v_check_step_roles")
    if [ "$unmapped_steps" -gt 0 ]; then
        local unmapped_detail
        unmapped_detail=$(pp_query "SELECT detail FROM v_check_step_roles")
        add_finding registry info "$unmapped_steps step type(s) without role curation (references_field fallback): ${unmapped_detail:-?}" "Add the step ID(s) to ScriptStepRoleMap in convert_xml_04_catalog.sql"
    fi

    # submenu target resolution — items with an unresolvable target menu ID (no
    # custom-menu match, e.g. a built-in menu) get no opens_menu link. It is
    # reported instead of silently swallowed; not an error (built-in submenus are legitimate).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local submenu_unres
    submenu_unres=$(pp_num "SELECT unresolved_n FROM v_check_submenu_unresolved")
    if [ "$submenu_unres" -gt 0 ]; then
        local submenu_files
        submenu_files=$(pp_query "SELECT files FROM v_check_submenu_unresolved")
        add_finding registry info "$submenu_unres submenu item(s) without a resolvable target menu (opens_menu): ${submenu_files:-?}" "The target @id points to a built-in menu or a menu outside the corpus"
    fi

    # „Function Missing" placeholder — a plugin function missing at export time.
    # P3 discards the chunks from the variable extraction; make it visible here as info
    # (export incomplete → the affected references are unresolvable).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local fm_missing
    fm_missing=$(pp_num "SELECT chunk_n FROM v_check_function_missing")
    if [ "$fm_missing" -gt 0 ]; then
        local fm_files
        fm_files=$(pp_query "SELECT files FROM v_check_function_missing")
        add_finding plugin info "$fm_missing „Function Missing\" chunk(s) — plugin function not loaded at export time: ${fm_files:-?}" "A plugin is missing on the exporting client; the affected function references are unresolvable in the DDR (discarded from the variable extraction)"
    fi

    # %X:-prefixed display-calculation chunks (FileMaker DDR defect): a TYPED layout
    # calculation with a single field reference is chunked as a VariableReference
    # ('%N:Zahl'). P3 discards these from the variable extraction (no phantom
    # variables), P2 A.5.1b recovers the field reference against the ChunkList's
    # context TO. Reported as info so the source defect stays visible.
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local disp_prefix
    disp_prefix=$(pp_num "SELECT chunk_n FROM v_check_display_prefix_chunks")
    if [ "$disp_prefix" -gt 0 ]; then
        local disp_prefix_files
        disp_prefix_files=$(pp_query "SELECT files FROM v_check_display_prefix_chunks")
        add_finding consistency info "$disp_prefix typed display-calculation chunk(s) misclassified by FileMaker (%X: prefix): ${disp_prefix_files:-?}" "DDR defect compensated: no phantom variables are created and the field reference is recovered against the context TO where resolvable"
    fi

    # Empty display-calculation ChunkLists (FileMaker DDR defect): a TYPED layout
    # calculation with an expression loses its complete chunk decomposition. P4
    # creates a fallback instance (formula recovered from the layout text), P2
    # A.5.1c recovers field edges of the context TO; function references in these
    # formulas remain lost (localized names).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local disp_empty
    disp_empty=$(pp_num "SELECT anchor_n FROM v_check_display_empty_chunklist")
    if [ "$disp_empty" -gt 0 ]; then
        local disp_empty_files
        disp_empty_files=$(pp_query "SELECT files FROM v_check_display_empty_chunklist")
        add_finding consistency info "$disp_empty display calculation(s) with an empty DDR ChunkList: ${disp_empty_files:-?}" "DDR defect compensated: instance + field edges recovered from the layout text; function references of these formulas are missing in where-used"
    fi

    # unknown LayoutObject types (after the P4 locale normalization). > 0 ⇒
    # a new locale name (extend the mapping) or a genuine new FileMaker type (canon set).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unk_types
    unk_types=$(pp_num "SELECT COUNT(*) FROM v_check_unknown_object_types")
    if [ "$unk_types" -gt 0 ]; then
        local unk_detail
        unk_detail=$(pp_query "SELECT string_agg(Object_Type || ' ×' || n, ', ' ORDER BY n DESC) FROM v_check_unknown_object_types")
        add_finding consistency warn "$unk_types unknown LayoutObject type(s): ${unk_detail:-?}" "Locale name? Add the DE→EN mapping in convert_xml_04_catalog.sql . Genuine new FileMaker type? Extend the canon set in v_check_unknown_object_types"
    fi

    # unknown LayoutPart types (after the P4 locale normalization). > 0 ⇒
    # a new locale name (extend the mapping) or a genuine new part type (canon set).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unk_parts
    unk_parts=$(pp_num "SELECT COUNT(*) FROM v_check_unknown_part_types")
    if [ "$unk_parts" -gt 0 ]; then
        local unkp_detail
        unkp_detail=$(pp_query "SELECT string_agg(Part_Type || ' ×' || n, ', ' ORDER BY n DESC) FROM v_check_unknown_part_types")
        add_finding consistency warn "$unk_parts unknown LayoutPart type(s): ${unkp_detail:-?}" "Locale name? Add the DE→EN mapping in convert_xml_04_catalog.sql (missed sub-summary names cost breaks_on_field links). Genuine new part type? Extend the canon set in v_check_unknown_part_types"
    fi

    # Calculation object type (schema 1.22.0): unresolved anchors, UUID collisions,
    # uncovered DDR anchors — all expected 0 (coverage/identity regression guards).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    # (unresolved_n is intentionally NOT re-reported here — the threshold-based
    # anchor-resolution check on v_calc_anchors already covers it, incl. the
    # expected partial-corpus remainder.)
    local calc_dups calc_uncov
    calc_dups=$(pp_num "SELECT dup_uuid_n FROM v_check_calculations")
    calc_uncov=$(pp_num "SELECT uncovered_anchor_n FROM v_check_calculations")
    if [ "$calc_dups" -gt 0 ]; then
        add_finding consistency warn "$calc_dups CalculationsCatalog UUID collision(s)" "Identity Owner × Calc_Role × Calc_Index is no longer unique — check the Calc_Index window in convert_xml_04_catalog.sql"
    fi
    if [ "$calc_uncov" -gt 0 ]; then
        add_finding consistency warn "$calc_uncov DDR anchor(s) without CalculationsCatalog row" "Coverage regression — the DDR side of the CalculationsCatalog union lost anchors"
    fi

    # Calc role vocabulary: roles outside the normalized set = unknown DDR
    # suffix (curation signal, not an error).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local unk_roles
    unk_roles=$(pp_num "SELECT COUNT(*) FROM v_check_calc_roles")
    if [ "$unk_roles" -gt 0 ]; then
        local unkr_detail
        unkr_detail=$(pp_query "SELECT string_agg(Calc_Role || ' ×' || n, ', ' ORDER BY n DESC) FROM v_check_calc_roles")
        add_finding consistency warn "$unk_roles unknown calc role(s): ${unkr_detail:-?}" "New DDR suffix — extend the role mapping in convert_xml_04_catalog.sql (CalculationsCatalog classification) and the vocabulary in v_check_calc_roles"
    fi

    # Conditional-formatting rules (schema 1.25.0): membercount guard (anti-
    # nesting/coverage, expected 0), reverse FK coverage (expected 0) and the
    # informational foreign-anchor remainder (small >0 is a known FM copy
    # artifact — the rule carries another object's DDRREF).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local cf_mm cf_norule cf_nofk
    cf_mm=$(pp_num "SELECT membercount_mismatch_n FROM v_check_cf_rules")
    cf_norule=$(pp_num "SELECT calc_without_rule_n FROM v_check_cf_rules")
    cf_nofk=$(pp_num "SELECT hash_without_fk_n FROM v_check_cf_rules")
    if [ "$cf_mm" -gt 0 ]; then
        add_finding consistency warn "$cf_mm layout object(s) with CF rule count ≠ Formatting/@membercount" "Depth-anchored extraction drifted (nested child rules counted, or own rules lost) — check LayoutObjectConditions in convert_xml_03_details.sql (A.12)"
    fi
    if [ "$cf_norule" -gt 0 ]; then
        add_finding consistency warn "$cf_norule conditional_format calc instance(s) without LayoutObjectConditions row" "Reverse FK coverage gap — the rule extraction lost rules the DDR anchors still see"
    fi
    if [ "$cf_nofk" -gt 0 ]; then
        add_finding consistency info "$cf_nofk CF rule(s) with DDRREF hash but no Calculation_UUID FK" "Expected small remainder: FM copy artifacts carrying a foreign object's DDRREF anchor"
    fi

    # Owner-exact layout script refs (converter 2.15.0, P2 ancestor guard):
    # both regression directions of the guard, expected 0 each — a deficit
    # means own trigger refs were over-filtered, container excess means
    # descendant refs hoist into containers again (phantom button_action).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local lsr_deficit lsr_container
    lsr_deficit=$(pp_num "SELECT trigger_deficit_n FROM v_check_layout_script_refs")
    lsr_container=$(pp_num "SELECT container_action_n FROM v_check_layout_script_refs")
    if [ "$lsr_deficit" -gt 0 ]; then
        add_finding consistency warn "$lsr_deficit layout-object script-ref group(s) with fewer rows than own triggers" "The P2 ancestor guard over-filtered OWN trigger refs — check the XMLLayoutReferences script block in convert_xml_02_resolve.sql"
    fi
    if [ "$lsr_container" -gt 0 ]; then
        add_finding consistency warn "$lsr_container container script-ref row(s) beyond own triggers (phantom button_action)" "Descendant refs hoist into containers again — check the ancestor guard in convert_xml_02_resolve.sql"
    fi

    # Trigger mirror symmetry (converter 2.17.0, P4 block 21a on all three owner
    # levels): per owner level, event mirrors == ScriptTriggers rows with a
    # script == granular trigger_script edges. The mirrors are the only
    # where-used truth since 2.17.0 — a broken 1:1 means double counting or a
    # where-used gap. WARN, no hard gate (pre-2.17.0 catalogs keep running).
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local tms_n
    tms_n=$(pp_num "SELECT COUNT(*) FROM v_check_trigger_mirror_symmetry WHERE mirror_n <> triggers_with_script_n OR granular_n <> triggers_with_script_n")
    if [ "$tms_n" -gt 0 ]; then
        local tms_sample
        tms_sample=$(pp_query "SELECT string_agg(owner_type || ': triggers=' || triggers_with_script_n || ' mirrors=' || mirror_n || ' granular=' || granular_n, ', ') FROM v_check_trigger_mirror_symmetry WHERE mirror_n <> triggers_with_script_n OR granular_n <> triggers_with_script_n")
        add_finding consistency warn "$tms_n owner level(s) with broken trigger mirror symmetry: ${tms_sample:-?}" "Event mirrors must be 1:1 with ScriptTriggers rows per owner level — check P4 block 21a / block 18 in convert_xml_04_catalog.sql"
    fi

    # Schema consistency: DB SchemaInfo == template version (double-check of the detection)
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local db_ver; db_ver=$(pp_query "SELECT db_version FROM v_check_schema")
    if [ -n "$db_ver" ] && [ -n "$SCHEMA_VERSION_EXPECTED" ] && [ "$db_ver" != "$SCHEMA_VERSION_EXPECTED" ]; then
        add_finding consistency warn "SchemaInfo version $db_ver ≠ template version $SCHEMA_VERSION_EXPECTED" "Rebuild via --batch --force-rebuild"
    fi

    local ok_n=$((CHECKS_RUN - POSTCHECK_WARN))
    [ "$ok_n" -lt 0 ] && ok_n=0
    emit_log "Post-Checks: $ok_n ok, $POSTCHECK_WARN warn"
    return 0
}

# ============================================================================
# Stage 4 — Error handling
# ============================================================================

# classify_error <exit_rc> <error_text> — sets ERR_CATEGORY and ERR_RETRY_HINT
# based on DuckDB/iconv stderr patterns (primary) or the exit code (fallback).
classify_error() {
    local rc="$1"
    local txt="$2"
    ERR_CATEGORY=""
    ERR_RETRY_HINT=""
    # OOM: on a clean memory stop DuckDB reports its own stderr text. An OS OOM kill
    # (cgroup/kernel), by contrast, sends SIGKILL → DuckDB exit 137 (=128+9), WITHOUT
    # stderr. process_single_file wraps this as
    # "DuckDB conversion failed (exit code: 137)" in $txt; hence additionally check
    # for 137 here, otherwise an OOM kill would go undetected. 143 (=128+15, SIGTERM)
    # is the same OOM in disguise on some VMs (macOS/Docker-Desktop) → treat it as OOM too.
    if echo "$txt" | grep -qiE 'out of memory|failed to allocate|exceeds.*memory_limit|exit code: 1(37|43)'; then
        ERR_CATEGORY="oom"
        ERR_RETRY_HINT="OOM (exit 137=SIGKILL / 143=SIGTERM): more RAM/spill (DUCKDB_TEMP_DIR) or --split/--turbo --auto or a reduced --memory_limit"
    elif echo "$txt" | grep -qiE 'invalid input error.*invalid|invalid xml|not well-formed|parser error'; then
        ERR_CATEGORY="invalid_xml"
        ERR_RETRY_HINT="Check the pre-processor/source — possibly invalid characters in the XML"
    # IMPORTANT: match only the REAL iconv message ("UTF-8 conversion failed") —
    # NOT the generic "DuckDB conversion failed", otherwise every DuckDB error
    # (incl. OOM) would be wrongly classified as encoding.
    elif echo "$txt" | grep -qiE 'iconv|UTF-8 conversion failed'; then
        ERR_CATEGORY="encoding"
        ERR_RETRY_HINT="Check the source encoding (BOM detection applies; binary detection points to an old file -I)"
    else
        case "$rc" in
            # 137=SIGKILL / 143=SIGTERM: an OS/cgroup OOM kill leaves NO stderr, so the
            # text match above cannot fire — classify by the numeric code so a killed
            # worker is reported as oom instead of masquerading as a generic sql_error.
            137|143) ERR_CATEGORY="oom";           ERR_RETRY_HINT="OOM (exit 137=SIGKILL / 143=SIGTERM): more RAM/spill (DUCKDB_TEMP_DIR), --turbo --auto, or a reduced --memory_limit" ;;
            2) ERR_CATEGORY="encoding";           ERR_RETRY_HINT="Check the source encoding" ;;
            4) ERR_CATEGORY="unsupported_format";  ERR_RETRY_HINT="Re-export from FileMaker 19+ as SaXML v2.1+" ;;
            5) ERR_CATEGORY="invalid_xml";         ERR_RETRY_HINT="Check the pre-processor/source" ;;
            6) ERR_CATEGORY="schema_drift";        ERR_RETRY_HINT="--batch --force-rebuild" ;;
            7) ERR_CATEGORY="lock";                ERR_RETRY_HINT="Retry later; remove a stale lock if needed" ;;
            *) ERR_CATEGORY="sql_error";           ERR_RETRY_HINT="Check the error log, pinpoint the location" ;;
        esac
    fi
}

# finalize_run — closing assessment: prints collected warnings (post-checks),
# skipped files and — for failed files — the error category + a copyable retry
# command. Reads the global batch variables (FAILED_FILES_INFO, SKIPPED_FILES,
# POSTCHECK_FINDINGS). Pure reporting logic, no abort decision of its own.
finalize_run() {
    local self="bash ingestion/convert_fm_xml.sh"

    # Show collected warn findings from the post-checks
    if [ "${#POSTCHECK_FINDINGS[@]}" -gt 0 ]; then
        echo ""
        echo "Post-Checks (Stage 3):"
        local f
        for f in "${POSTCHECK_FINDINGS[@]}"; do
            local cat="${f%%|*}"; local rest="${f#*|}"
            local sev="${rest%%|*}"; rest="${rest#*|}"
            local msg="${rest%%|*}"; local hint="${rest#*|}"
            echo "  [$sev/$cat] $msg"
            [ -n "$hint" ] && echo "      → $hint"
        done
    fi

    # Classify failed files + suggest a retry command
    if [ "${#FAILED_FILES_INFO[@]}" -gt 0 ]; then
        echo ""
        echo "Error classification & retry suggestions:"
        local entry
        for entry in "${FAILED_FILES_INFO[@]}"; do
            local file="${entry%%|*}"; local rest="${entry#*|}"
            local cat="${rest%%|*}"; local hint="${rest#*|}"
            echo "  ✗ $file  [$cat]"
            echo "      → $hint"
            if [ "$cat" = "oom" ]; then
                echo "      Retry: $self \"$file\" --memory_limit 4GB"
            elif [ "$cat" = "schema_drift" ]; then
                echo "      Retry: $self --batch --force-rebuild"
            fi
            if $QUIET_MODE; then
                _emit_json retry filename "$file" category "$cat" hint "$hint"
            fi
        done
    fi
}

# → moved to ingestion/lib/convert_report.sh (shell split)

# run_pipeline_step <label> <sql-file...> — runs a table-only SQL pass
# (cd PROJECT_ROOT for relative CSV paths, memory_limit_prefix prepended).
# Returns: 0 = ok/continue (even on a non-fatal error), 2 = fail-fast stop.
# PIPELINE_STEP_OK (global) carries the REAL outcome of the last call — for callers
# that must gate on success (single-mode manifest write) despite the tolerant rc.
run_pipeline_step() {
    local label="$1"; shift
    local templog; templog=$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")
    local rc=0
    PIPELINE_STEP_OK=true
    if (cd "$PROJECT_ROOT" && { memory_limit_prefix; cat "$@"; } | "$DUCKDB_BIN" "$DB_FILE") > "$templog" 2>&1; then
        echo "✓ $label"
    else
        PIPELINE_STEP_OK=false
        echo "✗ WARNING: $label failed"
        errlog_header_once
        {
            echo "================================================================================"
            echo "ERROR: $label"
            echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "================================================================================"
            cat "$templog"; echo ""
        } >> "$ERROR_LOG_FILE"
        echo "Error details:"; sed 's/^/  /' "$templog"
        $FAIL_FAST && rc=2
    fi
    rm -f "$templog"
    return $rc
}

# Safeguard the MBS component CSV before Phase 4 (batch and single mode):
# reference/mbs_component_exceptions.csv is produced by the install-mbs-docs skill
# from the MBS docset and is optional. If it is missing (docset not installed),
# create a header-only stub so the read_csv in P4 does not hard-fail — the component
# resolution then falls back via COALESCE to the name heuristic (documented intent in
# convert_xml_04_catalog.sql). NEVER overwrites an existing real CSV (only on non-existence).
ensure_mbs_component_csv() {
    if [ ! -f "$PROJECT_ROOT/reference/mbs_component_exceptions.csv" ]; then
        mkdir -p "$PROJECT_ROOT/reference"
        printf 'Funktionsname,Component\n' > "$PROJECT_ROOT/reference/mbs_component_exceptions.csv"
        $QUIET_MODE || echo "Note: MBS component CSV missing (MBS docset not installed) → header stub created; P4 uses the name heuristic. For an exact component mapping: run install-mbs-docs."
    fi
}

# fail_fast_stop <stage> — shared fail-fast abort (write logs + banner).
fail_fast_stop() {
    finalize_logs
    echo ""
    echo "========================================="
    echo "FAIL-FAST MODE: Stopping batch import"
    echo "========================================="
    echo "Failed during: $1"
    echo "Error log: $ERROR_LOG_FILE"
    echo ""
    emit_done false "Failed during: $1"
    stamp_last_run false 1 "${SUCCESS_COUNT:-0}" "${TOTAL:-0}"   # stamp fail-fast
    exit 1
}

# EXIT_INSUFFICIENT_MEMORY — dedicated exit code for a memory-induced clean abort.
# Distinct from the generic failure (1) so callers (the REST-API hub, the web import
# page) can branch and show the user a memory-specific, actionable message instead of
# a raw error. Frees a slot beyond the existing per-file categories (2/4/5/6/7).
EXIT_INSUFFICIENT_MEMORY=8

# _avail_mb_human — render the detected available RAM as a human string (GB), or a
# fallback token when it could not be determined on this platform.
_avail_mb_human() {
    if [ "${_avail_mb:-0}" -gt 0 ]; then
        awk -v m="$_avail_mb" 'BEGIN{ printf (m>=1024 ? "%.1f GB" : "%d MB"), (m>=1024 ? m/1024 : m) }'
    else
        echo "unknown"
    fi
}

# _retry_memory_limit — the conservative --memory_limit for an auto-retry: ~60 % of
# the detected available RAM (env override FM_RETRY_MEMORY_LIMIT wins). Echoes an empty
# string when RAM is unknown or too low for a safe profile → the caller then skips the
# retry and shows the memory message instead of launching a doomed second run.
_retry_memory_limit() {
    if [ -n "${FM_RETRY_MEMORY_LIMIT:-}" ]; then echo "$FM_RETRY_MEMORY_LIMIT"; return 0; fi
    [ "${_avail_mb:-0}" -gt 0 ] || return 0
    local lim=$(( _avail_mb * 60 / 100 ))
    [ "$lim" -lt 512 ] && return 0   # < 512 MB budget → no safe profile fits
    echo "${lim}MB"
}

# _maybe_auto_retry_oom <stage> — pre-flight-guarded, one-shot auto-retry on OOM.
# Re-runs the whole batch ONCE with a conservative memory profile (turbo+auto with a
# capped memory_limit, serialised resolve, single-file P1) when the current run was not
# already a retry AND the environment plausibly has room for the safe profile. On retry
# it exec's and never returns; otherwise it returns so the caller prints the memory
# message and exits. Opt out with FM_NO_AUTO_RETRY=1.
_maybe_auto_retry_oom() {
    local stage="${1:-conversion}"
    [ "$MODE" = "batch" ] || return 0
    # Test mode reuses MODE=batch but writes a throwaway DB — a re-exec would drop --test
    # and hit the production DB. Never auto-retry there.
    $TEST_MODE && return 0
    [ "${ATTEMPT:-1}" -ge 2 ] && return 0
    [ "${FM_NO_AUTO_RETRY:-0}" = "1" ] && return 0
    local lim; lim="$(_retry_memory_limit)"
    [ -n "$lim" ] || return 0   # unknown/too little RAM → no doomed retry, show the message
    finalize_logs               # close the failed attempt's logs before re-exec
    if $QUIET_MODE; then
        _emit_json retry filename "(batch)" category "oom" hint "auto-retry with --memory_limit $lim (attempt 2)"
    else
        echo "" >&2
        echo "↻ Auto-retry with a reduced memory profile (--memory_limit $lim, single-threaded resolve)…" >&2
        echo "  Reason: $stage ran out of memory. This is attempt 2 of 2; if it fails too, a clear memory message follows." >&2
        echo "" >&2
    fi
    # Conservative safe profile: turbo+auto (spillable/resplittable) + a capped
    # memory_limit, one P1 file at a time and a serialised single-slice resolve to keep
    # the peak low; force-rebuild starts from a clean state after the partial attempt.
    local -a retry=(--batch --auto --force-rebuild --memory_limit "$lim" --jobs 1
                    --attempt 2 --retry-reason oom)
    [ -n "$SOLUTION" ] && retry+=(--solution "$SOLUTION")
    $QUIET_MODE && retry+=(--quiet)
    # exec keeps the SAME PID and skips the EXIT trap → release the concurrency lock
    # first, otherwise the re-invoked attempt sees its own still-held lock ("already
    # running"). The retry re-acquires it fresh.
    release_lock
    # Re-invoke through `bash` explicitly: the script is normally launched as
    # `bash <script>` (no +x bit), so `exec "$0"` would fail with 126 (cannot execute).
    FM_P2_THREADS=1 FM_P2_JOBS=1 exec "${BASH:-bash}" "$0" "${retry[@]}"
}

# abort_insufficient_memory <stage> — clean, memory-specific stop. Prints ONE
# structured block (no raw SQL), writes the logs + JSON sidecar, emits a machine-
# readable `aborted` event (reason=oom) for the SSE consumers, and exits with the
# dedicated code. No catalogs are published on this path (the sync never runs), so the
# previously served database stays intact. Before giving up it may launch a single
# conservative auto-retry (guarded — see _maybe_auto_retry_oom).
abort_insufficient_memory() {
    local stage="${1:-conversion}"
    _maybe_auto_retry_oom "$stage"   # exec's on retry (never returns); else falls through
    finalize_logs
    local avail_h; avail_h="$(_avail_mb_human)"
    printf '%s\n' \
        "Stage: $stage" \
        "Available RAM: $avail_h" \
        "The DuckDB process was killed by the operating system (OOM) or hit its memory limit." \
        | log_error_section "Import aborted — not enough memory (stage: $stage)"
    if $QUIET_MODE; then
        _emit_json aborted reason "oom" stage "$stage" avail_mb "int=${_avail_mb:-0}"
    else
        echo "" >&2
        echo "=========================================" >&2
        echo "✗ IMPORT ABORTED — not enough memory" >&2
        echo "=========================================" >&2
        echo "Stage:      $stage" >&2
        echo "Available:  $avail_h RAM on this machine" >&2
        echo "Cause:      the DuckDB process was killed by the operating system (OOM)." >&2
        echo "" >&2
        echo "This solution is too large for this environment's memory. Next steps:" >&2
        echo "  1) Run it on a machine with more RAM (8 GB or more recommended), or" >&2
        echo "  2) retry with a reduced memory profile:" >&2
        echo "       convert-xml --batch --auto --memory_limit 4GB" >&2
        echo "" >&2
        echo "No catalogs were written from this run; the previously served database is unchanged." >&2
        [ -f "$ERROR_LOG_FILE" ] && echo "Error log:  $ERROR_LOG_FILE" >&2
        echo "" >&2
    fi
    emit_done false "Aborted (insufficient memory) during: $stage"
    stamp_last_run false "$EXIT_INSUFFICIENT_MEMORY" "${SUCCESS_COUNT:-0}" "${TOTAL:-0}"
    exit "$EXIT_INSUFFICIENT_MEMORY"
}

# abort_pipeline_incomplete <stage> — clean stop when a batch-wide phase failed for a
# non-memory reason and the downstream catalogs cannot be built. Avoids the
# "table does not exist" cascade from running the dependent phases anyway.
abort_pipeline_incomplete() {
    local stage="${1:-a pipeline stage}" detail="${2:-}"
    finalize_logs
    # Write the abort reason into the error log before pointing at it — on this
    # path the phase's SQL may have succeeded (just produced nothing), so no
    # runner has written the file yet.
    printf '%s\n' \
        "Stage: $stage" \
        "${detail:-The phase did not produce the tables/rows the downstream phases need.}" \
        "The pipeline stopped here instead of producing follow-up errors." \
        | log_error_section "Import aborted — build incomplete (stage: $stage)"
    if $QUIET_MODE; then
        _emit_json aborted reason "incomplete" stage "$stage"
    else
        echo "" >&2
        echo "=========================================" >&2
        echo "✗ IMPORT ABORTED — build incomplete" >&2
        echo "=========================================" >&2
        echo "Stage:      $stage" >&2
        [ -n "$detail" ] && echo "Detail:     $detail" >&2
        echo "The reference resolution did not complete, so the object catalog cannot be" >&2
        echo "built. The pipeline stops here instead of producing follow-up errors." >&2
        echo "" >&2
        echo "No catalogs were written from this run; the previously served database is unchanged." >&2
        [ -f "$ERROR_LOG_FILE" ] && echo "Error log:  $ERROR_LOG_FILE" >&2
        echo "" >&2
    fi
    emit_done false "Aborted (build incomplete) during: $stage"
    stamp_last_run false 1 "${SUCCESS_COUNT:-0}" "${TOTAL:-0}"
    exit 1
}

# ============================================================================
# Main Script Execution
# ============================================================================

# Concurrency lock before any write operation. Protects CLI ↔ REST-API against
# double runs on the same database. A no-op in test mode.
if ! acquire_lock; then
    if $QUIET_MODE; then
        emit_done false "Another conversion is already running"
    fi
    exit 7
fi

# Initialize the turbo DBs (chunkmap/manifest) only AFTER the lock (A-B2):
# the CREATE OR REPLACE of the chunkmap must not destroy the plan of a running
# import before the lock conflict is detected.
init_turbo_dbs

# Set the phase budget for the progress bar — the SQL pipeline phases as labelled
# segments in the web frontend.
# Opt 1 (v2): P1/extract is split into two visible segments — `chunk` (Phase S:
# split XML into chunks) and `import` (Phase D/C: chunks → DuckDB → master). The
# turbo path (always used by the web frontend) emits `chunk`/`import`. The
# CLI-only non-turbo paths (serial loop, --jobs parallel) keep emitting `extract`,
# which is retained here mapped to the full 0-70 union so their bar still fills
# smoothly (the frontend has no `extract` segment, but its fill math derives each
# segment's fill from the global pct, so chunk+import fill correctly regardless).
# P2–P5 are the fast catalog phases; P6/validate absorbs the post-processor checks
# AND the rest-api sync/reload at its tail.
set_phase_budget "chunk:0-25 import:25-70 extract:0-70 resolve:70-78 details:78-84 catalog:84-90 homes:90-94 validate:94-97 cluster:97-100"

# One-off start event in --quiet mode so clients immediately know the process is
# running. The controller streams this out anyway, but an explicit script-owned
# event decouples script ↔ stream.
if $QUIET_MODE; then
    emit_progress chunk 0 "Starting XML conversion"
fi

# ----------------------------------------------------------------------------
# Schema detection & auto-heal (before every import)
# ----------------------------------------------------------------------------
compute_schema_state
SCHEMA_ACTION_EXECUTED="$SCHEMA_ACTION"

if ! $QUIET_MODE; then
    echo "========================================="
    echo "Schema-Detection"
    echo "========================================="
    echo "Template Version:  $SCHEMA_VERSION_EXPECTED"
    echo "Template Hash:     ${SCHEMA_HASH_EXPECTED:0:12}…"
    if [ -n "$SCHEMA_VERSION_DB" ]; then
        echo "DB Version:        $SCHEMA_VERSION_DB"
        echo "DB Hash:           ${SCHEMA_HASH_DB:0:12}…"
    else
        echo "DB Version:        <no SchemaInfo / DB does not exist>"
    fi
    echo "Action:            $SCHEMA_ACTION"
    echo "Reason:            $SCHEMA_REASON"
else
    emit_log "Schema action: $SCHEMA_ACTION ($SCHEMA_REASON)"
fi
# Schema check is an early signpost inside the chunk phase → map it to a small
# within-phase value (Phase S then fills the remaining chunk range 5..100).
phase_progress chunk 5 "Schema check complete"

# 1. --force-rebuild overrides all detection results
if $FORCE_REBUILD && [ -f "$DB_FILE" ]; then
    echo ""
    echo "  ⚠ --force-rebuild active: the DB is deleted before the import"
    delete_db_for_rebuild "--force-rebuild explicitly set"
    SCHEMA_ACTION_EXECUTED="force_rebuild"
fi

# 2. Handle schema drift
if [ "$SCHEMA_ACTION" = "rebuild" ] && ! $FORCE_REBUILD; then
    if $NO_AUTO_HEAL; then
        echo ""
        echo "ERROR: Schema drift detected and --no-auto-heal active → abort."
        echo "       $SCHEMA_REASON"
        echo ""
        echo "       Manual rebuild: bash \"$0\" --batch --force-rebuild"
        exit 6
    fi

    if [[ "$MODE" == "single" ]]; then
        echo ""
        echo "ERROR: Schema drift detected — the DB is not compatible with the current SQL templates."
        echo "       DB version: ${SCHEMA_VERSION_DB:-<none>}   Template version: $SCHEMA_VERSION_EXPECTED"
        echo "       Reason: $SCHEMA_REASON"
        echo ""
        echo "Auto-heal is disabled in single-file mode (it would lose all other files"
        echo "from the DB). Choose one of the following paths:"
        echo ""
        echo "  Recommended:  bash \"$0\" --batch --force-rebuild"
        echo "                (deletes the DB, re-imports all XML files from xml/)"
        echo ""
        echo "  Manual:       rm \"$DB_FILE\" && bash \"$0\" \"$FILENAME\""
        echo "                (caution: other files are then no longer in the DB)"
        exit 6
    fi

    # Batch mode: perform auto-heal
    echo ""
    echo "  ⚠ Auto-heal: the DB is deleted and rebuilt in batch mode"
    delete_db_for_rebuild "$SCHEMA_REASON"
    SCHEMA_ACTION_EXECUTED="auto_heal_rebuild"
fi

# 3. Warn path (hash drift without a version bump)
if [ "$SCHEMA_ACTION" = "warn" ]; then
    echo ""
    echo "  ⚠ WARNING: $SCHEMA_REASON"
fi

echo ""

if [[ "$MODE" == "batch" ]]; then
    # ========================================================================
    # BATCH MODE: Process all XML files
    # ========================================================================
    echo "========================================="
    if $TEST_MODE; then
        echo "FileMaker XML TEST Import"
        echo "Source: tools/tests/fixtures/xml/ → db/fm_test.duckdb"
    else
        echo "FileMaker XML Batch Import"
    fi
    if $FAIL_FAST; then
        echo "(Fail-Fast Mode: Stop on first error)"
    fi
    echo "========================================="

    # 1. Discover all XML files
    shopt -s nullglob  # Return empty array if no matches
    XML_FILES=("$XML_DIR"/*.xml)
    shopt -u nullglob  # A-B10: do not leave it globally set (changes later glob semantics)
    TOTAL=${#XML_FILES[@]}

    if [ $TOTAL -eq 0 ]; then
        echo "ERROR: No XML files found in $XML_DIR"
        exit 1
    fi

    echo "Found $TOTAL XML files to process"
    echo ""

    # 2. Create logs directory (text log + JSON are written at the end of the run).
    mkdir -p "$LOG_DIR"

    # Collect environment context + derived header strings once.
    collect_environment
    collect_duckdb_settings
    build_run_meta

    # 3. Initialize counters + collection arrays
    SUCCESS_COUNT=0
    SKIPPED_COUNT=0
    UNCHANGED_COUNT=0   # Turbo --changed-only: files skipped via the manifest (unchanged)
    declare -a FAILED_FILES
    declare -a SKIPPED_FILES
    # FAILED_FILES_INFO: "file|category|hint" per failed file (stage 4)
    declare -a FAILED_FILES_INFO

    # 4. Start timer for entire batch + run start time
    BATCH_START=$(now_epoch)
    RUN_STARTED_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_STARTED_ISO=$(iso_now)

    # Disk preflight for the classic (non-turbo) paths — sequential, --split and the
    # --jobs part-DB merge all write into the master DB and (parallel path) part DBs
    # under $TMPDIR. Turbo runs its own (per-round) guard inside run_turbo_pipeline.
    $TURBO_MODE || preflight_disk_or_abort "Batch-Preflight (Phase 1)"

    # Phase 1 (Extract) timer start — wraps the entire file loop.
    phase_begin P1 Extract

    # Parallel mode (--jobs N>1). Run Phase 1 for all files concurrently up front
    # into part DBs and merge into the master DB. The telemetry loop below then
    # reads the pre-produced results ($PARTDB_DIR/<idx>.{rc,out,dur}) instead of
    # calling process_single_file itself — the entire report/error logic stays
    # unchanged. Bit-identical to the sequential run.
    # PARALLEL_P1 = "events arrived in waves up front" (file-parallel path only → the
    # telemetry loop then suppresses its own file events). P1_PREPROCESSED =
    # "results exist as $PARTDB_DIR/<i> sidecars" (file-parallel OR turbo → the loop
    # reads them instead of calling process_single_file). Turbo sets only
    # P1_PREPROCESSED (not PARALLEL_P1), so the loop fires the file events itself.
    PARALLEL_P1=false
    P1_PREPROCESSED=false
    if $TURBO_MODE; then
        # Turbo engine (phases S/D/C). Produces the master DB + per-file sidecars.
        P1_PREPROCESSED=true
        PARTDB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fmlab.XXXXXX")
        if $QUIET_MODE; then
            emit_log "Turbo: phase S/D/C ($TURBO_W workers, chunkmap-driven)"
        else
            echo "Turbo engine: phase S/D/C, $TURBO_W workers, $TOTAL files → chunkmap + chunk_<id>.duckdb"
        fi
        run_turbo_pipeline
        if [ "${TURBO_RC:-0}" -ne 0 ]; then
            echo "ERROR: Turbo consolidation failed (rc=$TURBO_RC)"
            [ -f "$PARTDB_DIR/merge.log" ] && sed 's/^/    /' "$PARTDB_DIR/merge.log"
            [ -f "$PARTDB_DIR/catmerge.log" ] && { echo "    --- catmerge.log ---"; sed 's/^/    /' "$PARTDB_DIR/catmerge.log"; }
            rm -rf "$PARTDB_DIR"
            exit 3
        fi
        # Free transient turbo artifacts (chunkmap.duckdb = plan stays for inspection;
        # cleanup later optionally via --keep-streaming). The chunk XML splits under
        # chunks/ can be hundreds of MB in production → remove them specifically here.
        if [ -n "${FM_T3_KEEP:-}" ]; then
            echo "@T3 PARTDB_DIR $PARTDB_DIR"   # keep artifacts (ATTACH/INSERT probe)
        else
            rm -f "$PARTDB_DIR"/part_*.duckdb
            rm -rf "$STREAMING_DIR/chunks"
            rm -f "$STREAMING_DIR"/chunk_*.duckdb "$STREAMING_DIR"/chunk_*.rc \
                  "$STREAMING_DIR"/chunk_*.out "$STREAMING_DIR"/chunk_*.done "$STREAMING_DIR"/chunk_*.dur "$STREAMING_DIR"/consolidate.log
        fi
    elif [ "$JOBS" -gt 1 ] && [ "$TOTAL" -gt 1 ]; then
        PARALLEL_P1=true
        P1_PREPROCESSED=true
        PARTDB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fmlab.XXXXXX")
        if $QUIET_MODE; then
            emit_log "Phase 1 parallel: $JOBS workers for $TOTAL files (part DBs + merge)"
        else
            echo "Phase 1 parallel: $JOBS workers, $TOTAL files → part DBs + merge"
        fi
        run_p1_parallel
        # Sign of life for the (otherwise silent) merge phase at the convert→catalog boundary.
        phase_progress extract 100 "Merging part DBs…"
        merge_part_dbs
        if [ "${MERGE_RC:-0}" -ne 0 ]; then
            echo "ERROR: Merge of the part DBs failed (rc=$MERGE_RC)"
            [ -f "$PARTDB_DIR/merge.log" ] && sed 's/^/    /' "$PARTDB_DIR/merge.log"
            [ -f "$PARTDB_DIR/catmerge.log" ] && { echo "    --- catmerge.log ---"; sed 's/^/    /' "$PARTDB_DIR/catmerge.log"; }
            rm -rf "$PARTDB_DIR"
            exit 3
        fi
        rm -f "$PARTDB_DIR"/part_*.duckdb   # free part DBs after the merge
    fi

    # 5. Process each file
    for i in "${!XML_FILES[@]}"; do
        FILE="${XML_FILES[$i]}"
        BASENAME=$(basename "$FILE")
        CURRENT=$((i + 1))

        # In quiet mode, continuous progress based on the file index, so the
        # progress bar does not stall during a long batch run. Per-file granularity
        # is enough — within a file the DuckDB phase is an opaque block.
        # On the quiet-parallel path run_p1_parallel already emitted file_start/progress
        # live in waves — do not fire them again here (else double counting). In all
        # other cases as before; the report work further below runs path-independently.
        # Opt 2 (log declutter): on the preprocessed path (turbo/parallel) the
        # file result already sits in the sidecars. Unchanged (manifest skip, rc 0 +
        # .unchanged) and skipped (unsupported format, rc 4) files
        # no longer produce a „Processing"/file_start line in the web log — the
        # ⏭️ status table (file_skip from Phase S) covers them anyway. The terminal
        # `file` event is preserved (Node counter processed/total) and is
        # not rendered as a line on the frontend side (eventToLine).
        PRE_QUIET_SKIP=false
        if $P1_PREPROCESSED; then
            PRE_RC=$(cat "$PARTDB_DIR/${i}.rc" 2>/dev/null); PRE_RC=${PRE_RC:-3}
            if { [ "$PRE_RC" -eq 0 ] && [ -f "$PARTDB_DIR/${i}.unchanged" ]; } || [ "$PRE_RC" -eq 4 ]; then
                PRE_QUIET_SKIP=true
            fi
        fi

        if $QUIET_MODE && $PARALLEL_P1; then
            :   # live events already came from the wave
        else
            # On the turbo path (preprocessed) Phase D already filled the import
            # segment AND the per-file import_* lifecycle gives finer live feedback —
            # re-emitting per-file progress here would make the bar jump
            # backwards. Only the truly-serial path (no preprocessing) needs it.
            if ! $P1_PREPROCESSED; then
                FILE_PCT=$(( (i * 100) / TOTAL ))
                phase_progress extract $(( 10 + (FILE_PCT * 90) / 100 )) "Processing: $BASENAME"
            fi

            if $QUIET_MODE; then
                if $PRE_QUIET_SKIP; then
                    :   # unchanged/skipped → no Processing/file_start line (see above)
                else
                    # file_start: carries the total and the current filename already
                    # before the (long) DuckDB block, so the frontend can fill the status
                    # line ("x of TOTAL") immediately and highlight the running file in the
                    # list.
                    _emit_json file_start filename "$BASENAME" index "int=$CURRENT" total "int=$TOTAL"
                    emit_log "[$CURRENT/$TOTAL] Processing: $BASENAME"
                fi
            else
                echo "[$CURRENT/$TOTAL] Processing: $BASENAME"
            fi
        fi

        # Start timer for this file + file size (JSON only)
        FILE_START=$(now_epoch)
        FILE_SIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null || echo "")

        # Call single-file processing function (capture error output).
        # Parallel/turbo mode: the result was produced up front → just read it.
        if $P1_PREPROCESSED; then
            ERROR_OUTPUT=$(cat "$PARTDB_DIR/${i}.out" 2>/dev/null)
            RESULT=$(cat "$PARTDB_DIR/${i}.rc" 2>/dev/null); RESULT=${RESULT:-3}
        else
            ERROR_OUTPUT=$(process_single_file "$BASENAME" 2>&1)
            RESULT=$?
        fi

        # Extract the encoding from the Preprocessed line (process_single_file runs
        # in a subshell, so PRE_ENCODING does not come back directly).
        FILE_ENC=$(printf '%s\n' "$ERROR_OUTPUT" | grep -oE 'enc=[^)]*' | head -1 | cut -d= -f2)
        FILE_FAILED=false
        FILE_ERR_CAT=""; FILE_ERR_RC=""; FILE_ERR_HINT=""

        if [ $RESULT -eq 0 ] && $P1_PREPROCESSED && [ -f "$PARTDB_DIR/${i}.unchanged" ]; then
            # Turbo --changed-only: unchanged file (manifest skip) — do not count as an import.
            ((UNCHANGED_COUNT++))
            FILE_STATUS="unchanged"
            if $QUIET_MODE; then
                _emit_json file filename "$BASENAME" index "int=$CURRENT" total "int=$TOTAL" ok "bool=true" status "unchanged"
            else
                echo "  ↻ Unchanged (skipped)"
            fi
        elif [ $RESULT -eq 0 ]; then
            ((SUCCESS_COUNT++))
            FILE_STATUS="success"
            if $QUIET_MODE; then
                # file event only emitted serially here; in parallel it came from the wave.
                $PARALLEL_P1 || _emit_json file filename "$BASENAME" index "int=$CURRENT" total "int=$TOTAL" ok "bool=true"
            else
                echo "  ✓ Success"
            fi
        elif [ $RESULT -eq 4 ]; then
            ((SKIPPED_COUNT++))
            SKIPPED_FILES+=("$BASENAME")
            FILE_STATUS="skipped"
            if $QUIET_MODE; then
                $PARALLEL_P1 || _emit_json file filename "$BASENAME" index "int=$CURRENT" total "int=$TOTAL" ok "bool=false" status "skipped"
            else
                echo "  ⊘ Skipped (unsupported format)"
            fi
        else
            FAILED_FILES+=("$BASENAME")
            FILE_STATUS="failed"
            FILE_FAILED=true
            # Stage 4: classify the error (for the retry suggestion in the final report)
            classify_error "$RESULT" "$ERROR_OUTPUT"
            FAILED_FILES_INFO+=("$BASENAME|$ERR_CATEGORY|$ERR_RETRY_HINT")
            FILE_ERR_CAT="$ERR_CATEGORY"; FILE_ERR_RC="$RESULT"; FILE_ERR_HINT="$ERR_RETRY_HINT"
            if $QUIET_MODE; then
                # file event only serially here; in parallel it came from the wave.
                # The detail logs (emit_warn) are log events without double counting
                # and therefore run on both paths.
                $PARALLEL_P1 || _emit_json file filename "$BASENAME" index "int=$CURRENT" total "int=$TOTAL" ok "bool=false" status "failed" category "$ERR_CATEGORY"
                # Wrap the single-file step's detail output in log events so the
                # browser log block can display it.
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    emit_warn "$BASENAME: $line"
                done <<< "$ERROR_OUTPUT"
            else
                echo "  ✗ Failed"
            fi

            # Write error details to separate error log file
            if [ -n "$ERROR_OUTPUT" ]; then
                errlog_header_once
                echo "================================================================================" >> "$ERROR_LOG_FILE"
                echo "ERROR: $BASENAME" >> "$ERROR_LOG_FILE"
                echo "Time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$ERROR_LOG_FILE"
                echo "================================================================================" >> "$ERROR_LOG_FILE"
                echo "$ERROR_OUTPUT" >> "$ERROR_LOG_FILE"
                echo "" >> "$ERROR_LOG_FILE"
            fi
        fi

        # End timer and calculate duration
        # awk instead of bc: bc is not installed in the devcontainer (→ "command not
        # found" and 0.000s in the logs); awk is a hard dependency anyway (splitter
        # + log formatting). %s.%N timestamps are floats.
        FILE_END=$(now_epoch)
        FILE_PEAKRSS_KB=""; FILE_MINAVAIL_KB=""
        if $P1_PREPROCESSED; then
            # The loop's wall-clock is ~0 here (work ran up front, parallel/turbo) —
            # the real per-file duration comes from the worker or (turbo) the Phase-S measurement.
            FILE_DURATION=$(cat "$PARTDB_DIR/${i}.dur" 2>/dev/null); FILE_DURATION=${FILE_DURATION:-0.000}
            # Worker memory forensics (".mem" = "<peak_rss_kb> <min_avail_kb>").
            FILE_PEAKRSS_KB=$(awk '{print $1}' "$PARTDB_DIR/${i}.mem" 2>/dev/null)
            FILE_MINAVAIL_KB=$(awk '{print $2}' "$PARTDB_DIR/${i}.mem" 2>/dev/null)
        else
            FILE_DURATION=$(awk -v a="$FILE_END" -v b="$FILE_START" 'BEGIN { printf "%.3f", a - b }')
        fi

        # Memory forensics as a log event (lands in the text log AND in JSON events[]
        # — without having to touch the typed JSON sidecar schema).
        if [ -n "$FILE_PEAKRSS_KB" ]; then
            emit_log "MEM $BASENAME: peak_rss=$(_kb_mb "$FILE_PEAKRSS_KB")MB sys_avail_min=$(_kb_mb "${FILE_MINAVAIL_KB:-0}")MB dur=${FILE_DURATION}s"
        fi

        # Collect the per-file record for the text log + JSON sidecar.
        FL_NAME+=("$BASENAME");        FL_SIZE+=("$FILE_SIZE")
        FL_ENC+=("$FILE_ENC");         FL_STATUS+=("$FILE_STATUS")
        FL_DUR+=("$FILE_DURATION");    FL_COMPLETED+=("$(iso_now)")
        FL_ERR_CAT+=("$FILE_ERR_CAT"); FL_ERR_RC+=("$FILE_ERR_RC"); FL_ERR_HINT+=("$FILE_ERR_HINT")
        FL_PEAKRSS+=("$FILE_PEAKRSS_KB"); FL_MINAVAIL+=("$FILE_MINAVAIL_KB")

        # Stop immediately if fail-fast mode is enabled (logs are written).
        if $FILE_FAILED && $FAIL_FAST; then
            fail_fast_stop "File: $BASENAME"
        fi

        echo ""
    done

    # Finish P1: determine object counts + load per-file objects.
    P1_OBJ=$(count_table_sum "${P1_OBJECT_TABLES[@]}")
    P1_DDR=$(pp_num "SELECT COUNT(*) FROM DDR_Calculations")
    phase_finish "$(group_de "$P1_OBJ") objects (+$(group_de "$P1_DDR") DDR chunks)" \
        "{\"objects_extracted\":$P1_OBJ,\"ddr_calc_chunks\":$P1_DDR}"
    load_per_file_objects

    # Clean up the part-DB/sidecar working directory (file-parallel OR turbo).
    # FM_T3_KEEP (T-3 probe) holds the artifacts back (otherwise deleted globally here).
    $P1_PREPROCESSED && [ -z "${FM_T3_KEEP:-}" ] && rm -rf "$PARTDB_DIR"

    # ── Short-circuit: nothing changed → skip P2–P6 + sync ──────────────────────
    # (set by run_turbo_pipeline: 0 pending chunks + catalogs already 'ok').
    # The entire catalog-rebuild + sync block runs ONLY when there is something to do; the
    # final report (BATCH_END/emit_done, further below) runs in BOTH cases. The
    # block body deliberately keeps its previous indentation (minimal diff).
    if ! $TURBO_NO_CHANGES; then
    # 6. Phase 2 (Resolve) — reference resolution (table-only, ONCE after all
    # imports). Rebuilds XMLStep/Layout/Calc refs, MBS/GetSub, PluginUsages from the
    # P1 tables. Must run BEFORE the universal catalogs.
    phase_progress resolve 0 "Resolving references (Phase 2)..."
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Resolving references (Phase 2)..."
        echo "========================================="
    fi
    phase_begin P2 Resolve
    run_phase2 "Phase 2 Reference Resolution"; rc=$?
    P2_REF=$(count_table_sum XMLCalcReferences XMLStepReferences XMLLayoutReferences PluginFunctionUsages MBS_SubnameMap GetSubparameterMap)
    # Integrity gate: Phase 2 builds the reference tables that Phase 4 (universal
    # catalogs) reads. If it failed — or produced nothing while Phase 1 did load
    # objects — stop cleanly here. Running P3–P7 on the missing tables would only spill
    # "table does not exist" cascades and leave the run without a usable catalog.
    P2_GATE=false
    if $P2_FAILED || { [ "${P1_OBJ:-0}" -gt 0 ] && [ "${P2_REF:-0}" -eq 0 ]; }; then P2_GATE=true; fi
    if $P2_GATE && ! $P2_FAILED; then
        # The runner already printed its ✓ for the SQL pass before the row count
        # was known — correct the record before the abort banner appears.
        echo "✗ Phase 2 resolved 0 references while Phase 1 loaded $(group_de "${P1_OBJ:-0}") objects — stopping (integrity gate)"
    fi
    phase_finish "$(group_de "$P2_REF") references" "{\"references_resolved\":$P2_REF}"
    [ "$rc" = 2 ] && fail_fast_stop "Phase 2 Reference Resolution"
    if $P2_GATE; then
        if $P2_OOM; then
            abort_insufficient_memory "Reference resolution (Phase 2)"
        elif $P2_FAILED; then
            abort_pipeline_incomplete "Phase 2 Reference Resolution"
        else
            abort_pipeline_incomplete "Phase 2 Reference Resolution" \
                "Phase 2 completed without error but resolved 0 references while Phase 1 loaded ${P1_OBJ:-0} objects."
        fi
    fi
    echo ""

    # 7. Phase 3 (Details) — variable parser. P3/P4 are now two separate DuckDB
    # invocations (individually measurable). The 03→04 order remains mandatory.
    # CWD = PROJECT_ROOT (relative CSV paths in convert_xml_03_details.sql).
    phase_progress details 0 "Building variable analysis (Phase 3)..."
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Building variable analysis (Phase 3)..."
        echo "========================================="
    fi
    phase_begin P3 Details
    run_pipeline_step "Phase 3 Details (Variables)" "$ENGINE_ROOT/sql/convert_xml_03_details.sql"; rc=$?
    P3_USAGES=$(pp_num "SELECT COUNT(*) FROM VariableUsages")
    P3_VARS=$(pp_num "SELECT COUNT(*) FROM VariablesCatalog")
    phase_finish "$(group_de "$P3_USAGES") usages · $(group_de "$P3_VARS") vars" \
        "{\"variable_usages\":$P3_USAGES,\"variables_distinct\":$P3_VARS}"
    [ "$rc" = 2 ] && fail_fast_stop "Phase 3 Details"

    # Phase 3.5 (Plugin Subname Recovery) — completes MBS_SubnameMap from the
    # calc plain text (FileMaker's DDR chunker drops NoRef argument chunks in
    # some constellations; see convert_xml_03b_plugin_subname_recovery.sql).
    # Order is mandatory: after P3 (needs StepCalculations), before P4 (catalog
    # block 26 / link block 34 read the map).
    MBS_UNRES_PRE=$(pp_num "SELECT COUNT(*) FROM PluginFunctionUsages WHERE Plugin_Function_Name = 'MBS'")
    run_pipeline_step "Phase 3.5 Plugin Subname Recovery" "$ENGINE_ROOT/sql/convert_xml_03b_plugin_subname_recovery.sql"; rc=$?
    MBS_UNRES_POST=$(pp_num "SELECT COUNT(*) FROM PluginFunctionUsages WHERE Plugin_Function_Name = 'MBS'")
    if ! $QUIET_MODE; then
        echo "  Plugin subnames recovered: $((MBS_UNRES_PRE - MBS_UNRES_POST)) · unresolved remaining: $MBS_UNRES_POST"
    fi
    [ "$rc" = 2 ] && fail_fast_stop "Phase 3.5 Plugin Subname Recovery"
    echo ""

    # Phase 4 (Catalog) — ObjectCatalog + ObjectLinks.
    phase_progress catalog 0 "Building universal catalogs (Phase 4)..."
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Building universal catalogs (Phase 4)..."
        echo "========================================="
    fi
    phase_begin P4 Catalog
    ensure_mbs_component_csv
    run_pipeline_step "Phase 4 Catalog (Objects+Links)" "$ENGINE_ROOT/sql/convert_xml_04_catalog.sql"; rc=$?
    P4_OBJ=$(pp_num "SELECT COUNT(*) FROM ObjectCatalog")
    P4_LINKS=$(pp_num "SELECT COUNT(*) FROM ObjectLinks")
    phase_finish "$(group_de "$P4_OBJ") objects · $(group_de "$P4_LINKS") links" \
        "{\"objects_registered\":$P4_OBJ,\"links\":$P4_LINKS}"
    [ "$rc" = 2 ] && fail_fast_stop "Phase 4 Catalog"
    echo ""

    # 7a. Phase 5 (Homes) — ObjectHomes + TableOccurrenceResolution (Cross-File).
    phase_progress homes 0 "Building resolution tables (Phase 5)..."
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Building resolution tables (Phase 5)..."
        echo "========================================="
    fi
    phase_begin P5 Homes
    run_pipeline_step "Phase 5 Homes (Cross-File)" "$ENGINE_ROOT/sql/convert_xml_05_homes.sql"; rc=$?
    P5_HOMES=$(pp_num "SELECT COUNT(*) FROM ObjectHomes")
    P5_TO=$(pp_num "SELECT COUNT(*) FROM TableOccurrenceResolution")
    phase_finish "$(group_de "$P5_HOMES") homes · $(group_de "$P5_TO") TO" \
        "{\"object_homes\":$P5_HOMES,\"to_resolutions\":$P5_TO}"
    [ "$rc" = 2 ] && fail_fast_stop "Phase 5 Homes"
    echo ""

    # 7aa. Phase 6 (Validate) — post-processor (stage 3): plausibility/
    # consistency checks against the finished DB. Non-fatal — findings feed into
    # the final report (finalize_run). Runs BEFORE the sync.
    if ! $QUIET_MODE; then
        echo "========================================="
        echo "Running post-processor checks (Phase 6)..."
        echo "========================================="
    fi
    phase_begin P6 Validate
    phase_progress validate 0 "Running checks (Phase 6)..."
    postprocess_db
    phase_finish "$CHECKS_RUN checks · $POSTCHECK_WARN warnings" \
        "{\"checks_run\":$CHECKS_RUN,\"warnings\":$POSTCHECK_WARN}"
    if ! $QUIET_MODE; then echo ""; fi

    # 7aa2. Analysis views (static code analysis) — its own batch-wide, table-only
    # phase AFTER P6. Rebuilt on every run, like the universal catalogs. Non-fatal:
    # an error here must not block the publication of the finished catalogs.
    if [ -f "$ANALYSIS_VIEWS_TEMPLATE" ]; then
        $QUIET_MODE || echo "Building analysis views (static code analysis)..."
        run_pipeline_step "Analysis Views (SCA)" "$ANALYSIS_VIEWS_TEMPLATE" >/dev/null 2>&1 \
            && { $QUIET_MODE || echo "✓ Analysis views built"; } \
            || echo "✗ WARNING: Analysis views failed (run --batch first?)"
        postcheck_calc_anchors   # needs v_calc_anchors (only comes into being here)
        $QUIET_MODE || echo ""
    fi

    # Catalogs fully built (P2–P6) for the current manifest state → set the marker
    # to 'ok' (gate for the next „nothing changed" short-circuit). A turbo concept
    # (the manifest exists only there) → restricted to the turbo path.
    $TURBO_MODE && _catalogs_state_set ok

    # The post-processor checks now fill the WHOLE validate segment (94..97); the
    # sync/reload tail moved into the `cluster` segment (97..100, after P7) so the
    # bar stays monotonic when Auto-P7 runs between the checks and the sync.
    phase_progress validate 100 "Checks complete"

    # 7a2. Phase 7 (Clustering) — auto community detection (raw), BEFORE the
    # sync so the single pipeline sync carries the fresh ObjectClusters/
    # CommunityNames to the copy. Gated: only on a from-scratch build or a
    # DB without a partition; incremental imports skip it. Non-fatal.
    run_phase7_clustering

    # 7b. Sync to rest-api/db/ (production mode). Routed into the `cluster` segment.
    # a4: a single failed
    # file must not block the publication of all the others. The master is rebuilt (P2–P6) from
    # whatever imported successfully → internally consistent. So sync when at least one file
    # succeeded, even if others failed. FM_SYNC_STRICT=1 restores the strict gate (sync only on a
    # fully clean batch). sync_to_rest_api additionally refuses a master without ObjectCatalog.
    # Heal runs sync too: reaching this point means P2–P6 were rebuilt THIS run (the
    # nothing-changed short-circuit exits earlier). A heal run after an aborted import
    # has SUCCESS_COUNT=0 with every file "unchanged", yet its read copy can be stale —
    # the run that stamped the file manifests aborted before publishing. Requiring
    # SUCCESS_COUNT>0 here left that copy stale forever ("DB already up to date" checks
    # only the master). Only an all-failed batch stays unpublished.
    DO_SYNC=false
    if ! $TEST_MODE; then
        if [ -n "${FM_SYNC_STRICT:-}" ]; then
            [ ${#FAILED_FILES[@]} -eq 0 ] && DO_SYNC=true
        else
            if [ "${SUCCESS_COUNT:-0}" -gt 0 ] || [ ${#FAILED_FILES[@]} -eq 0 ]; then DO_SYNC=true; fi
        fi
    fi
    if $DO_SYNC; then
        [ ${#FAILED_FILES[@]} -gt 0 ] && emit_warn "Sync despite ${#FAILED_FILES[@]} failed file(s) (successful: $SUCCESS_COUNT). FM_SYNC_STRICT=1 enforces strict behavior."
        if ! $QUIET_MODE; then
            echo "========================================="
            echo "Syncing database to rest-api/..."
            echo "========================================="
        fi
        sync_to_rest_api cluster
        if ! $QUIET_MODE; then echo ""; fi
    else
        # No sync (test mode / nothing published): still drive the bar to 100 so
        # the `cluster` segment completes instead of sticking at its start.
        phase_progress cluster 100 "done"
    fi

    # 7c. Manifest stamp: refresh the convert-owned technical/metrics
    # blocks of solutions/<id>/solution.json after any batch that imported
    # at least one file. Key-scoped merge, never fails the run.
    if ! $TEST_MODE && [ "${SUCCESS_COUNT:-0}" -gt 0 ]; then
        stamp_solution_manifest
    fi
    fi   # ── End of short-circuit block (! $TURBO_NO_CHANGES): P2–P6 + sync ──

    # 8. End timer for entire batch + run end time
    BATCH_END=$(now_epoch)
    RUN_ENDED_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_ENDED_ISO=$(iso_now)
    # awk instead of bc (see FILE_DURATION above). BATCH_MINUTES truncated via int() —
    # matches the old bc behavior (scale=0 for integer division).
    BATCH_DURATION=$(awk -v a="$BATCH_END" -v b="$BATCH_START" 'BEGIN { printf "%.3f", a - b }')

    # Calculate minutes and seconds
    BATCH_MINUTES=$(awk -v d="$BATCH_DURATION" 'BEGIN { printf "%d", int(d / 60) }')
    BATCH_SECONDS=$(awk -v d="$BATCH_DURATION" -v m="$BATCH_MINUTES" 'BEGIN { printf "%.3f", d - (m * 60) }')

    # 8. Final report
    echo "========================================="
    echo "Batch Import Complete"
    echo "========================================="
    echo "Total files: $TOTAL"
    echo "Successful: $SUCCESS_COUNT"
    [ "${UNCHANGED_COUNT:-0}" -gt 0 ] && echo "Unchanged (skipped): $UNCHANGED_COUNT"
    echo "Skipped: $SKIPPED_COUNT"
    echo "Failed: ${#FAILED_FILES[@]}"
    awk -v m="$BATCH_MINUTES" -v s="$BATCH_SECONDS" -v d="$BATCH_DURATION" \
        'BEGIN { printf "Total duration: %dm %.3fs (%.3f seconds)\n", m, s+0, d+0 }'

    if [ $SKIPPED_COUNT -gt 0 ]; then
        echo ""
        echo "Skipped files (unsupported format):"
        printf '  - %s\n' "${SKIPPED_FILES[@]}"
    fi

    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        echo ""
        echo "Failed files:"
        printf '  - %s\n' "${FAILED_FILES[@]}"
    fi

    # Conversion log v2: write the text log + JSON sidecar once.
    finalize_logs

    # Stage 4 — Error-Handling: show collected warnings + retry suggestions
    finalize_run

    # Per-solution log retention: keep the last FM_LOG_KEEP_RUNS runs.
    prune_solution_logs

    # Inform user about log location
    echo ""
    echo "Log file:  $LOG_FILE"
    echo "JSON file: $JSON_FILE"
    [ "${FM_NO_CONSOLE_LOG:-}" != "1" ] && echo "Console:   $CONSOLE_LOG"

    # Inform user about error log if errors occurred
    if { [ ${#FAILED_FILES[@]} -gt 0 ] || [ -s "$ERROR_LOG_FILE" ]; } && [ -f "$ERROR_LOG_FILE" ]; then
        echo "Error details: $ERROR_LOG_FILE"
    fi

    # Exit with appropriate code. Validity decision: FAILED files → invalid
    # (exit 1). Post-check `warn` findings do NOT change the exit code
    # (the result stays 0 = valid-with-warning).
    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        emit_progress validate 100 "Done with errors"
        emit_done false "Failed files: ${#FAILED_FILES[@]}, Post-Check warnings: $POSTCHECK_WARN"
        stamp_last_run false 1 "$SUCCESS_COUNT" "$TOTAL"   # stamp CLI failure
        exit 1
    fi

    emit_progress validate 100 "Done"
    if [ "$POSTCHECK_WARN" -gt 0 ]; then
        emit_done true "Successful: $SUCCESS_COUNT, Skipped: $SKIPPED_COUNT, Warnings: $POSTCHECK_WARN (valid-with-warning)"
    else
        emit_done true "Successful: $SUCCESS_COUNT, Skipped: $SKIPPED_COUNT"
    fi
    # Policy lock: persist the successfully used policy as the sticky
    # fallback state — written ONLY at the end of successful runs, so a
    # sticky-adopted policy never perpetuates itself while runs fail.
    # (No-op in test mode unless FM_POLICY_STATE_FILE is set.)
    _policy_state_write "$_RUN_POLICY" "$WS_SENTINEL_ON"
    stamp_last_run true 0 "$SUCCESS_COUNT" "$TOTAL"        # mirror CLI success too
    exit 0

elif [[ "$MODE" == "single" ]]; then
    # ========================================================================
    # SINGLE FILE MODE: Process one XML file
    # ========================================================================
    # Runs the COMPLETE table-only chain after P1 (P2→P3→P4→P5→P6 + SCA views) —
    # a single-file import leaves the same catalog state as a batch run — and, when
    # the whole chain succeeded, writes the file's manifest row so a subsequent
    # --batch --changed-only skips it instead of re-parsing.
    # Conversion log v2: the single-file run also writes a text log + JSON sidecar
    # (files[] of length 1).
    mkdir -p "$LOG_DIR"
    collect_environment
    collect_duckdb_settings
    build_run_meta
    TOTAL=1; SUCCESS_COUNT=0; SKIPPED_COUNT=0
    declare -a FAILED_FILES=(); declare -a SKIPPED_FILES=(); declare -a FAILED_FILES_INFO=()
    BATCH_START=$(now_epoch)
    RUN_STARTED_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_STARTED_ISO=$(iso_now)

    BASENAME="$FILENAME"
    FILE_SIZE=$(stat -c%s "$XML_DIR/$FILENAME" 2>/dev/null || stat -f%z "$XML_DIR/$FILENAME" 2>/dev/null || echo "")

    # Disk preflight (classic single-file path; turbo single files go through their
    # own per-round guard).
    $TURBO_MODE || preflight_disk_or_abort "Single-Preflight (Phase 1)"

    # Phase 1 (Extract) — capture output (derive encoding/status) but keep it visible.
    phase_begin P1 Extract
    FILE_START=$(now_epoch)
    SINGLE_OUT=$(process_single_file "$FILENAME" 2>&1); SINGLE_RC=$?
    printf '%s\n' "$SINGLE_OUT"
    FILE_END=$(now_epoch)
    FILE_DURATION=$(awk -v a="$FILE_END" -v b="$FILE_START" 'BEGIN { printf "%.3f", a - b }')
    FILE_ENC=$(printf '%s\n' "$SINGLE_OUT" | grep -oE 'enc=[^)]*' | head -1 | cut -d= -f2)

    FILE_ERR_CAT=""; FILE_ERR_RC=""; FILE_ERR_HINT=""
    if [ "$SINGLE_RC" -eq 0 ]; then
        SUCCESS_COUNT=1; FILE_STATUS="success"
        echo "SUCCESS: Database created successfully from $FILENAME"
    elif [ "$SINGLE_RC" -eq 4 ]; then
        SKIPPED_COUNT=1; SKIPPED_FILES+=("$BASENAME"); FILE_STATUS="skipped"
    else
        FAILED_FILES+=("$BASENAME"); FILE_STATUS="failed"
        classify_error "$SINGLE_RC" "$SINGLE_OUT"
        FAILED_FILES_INFO+=("$BASENAME|$ERR_CATEGORY|$ERR_RETRY_HINT")
        FILE_ERR_CAT="$ERR_CATEGORY"; FILE_ERR_RC="$SINGLE_RC"; FILE_ERR_HINT="$ERR_RETRY_HINT"
        if [ -n "$SINGLE_OUT" ]; then
            errlog_header_once
            {
                echo "================================================================================"
                echo "ERROR: $BASENAME"
                echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "================================================================================"
                echo "$SINGLE_OUT"; echo ""
            } >> "$ERROR_LOG_FILE"
        fi
    fi

    FL_NAME+=("$BASENAME");        FL_SIZE+=("$FILE_SIZE")
    FL_ENC+=("$FILE_ENC");         FL_STATUS+=("$FILE_STATUS")
    FL_DUR+=("$FILE_DURATION");    FL_COMPLETED+=("$(iso_now)")
    FL_ERR_CAT+=("$FILE_ERR_CAT"); FL_ERR_RC+=("$FILE_ERR_RC"); FL_ERR_HINT+=("$FILE_ERR_HINT")
    FL_PEAKRSS+=("");              FL_MINAVAIL+=("")   # single-file path: no worker sampler

    # P1 object counts for EXACTLY this file (the DB may already contain other files).
    load_per_file_objects
    P1_OBJ=$(lookup_file_objects "${BASENAME}"); [ -z "$P1_OBJ" ] && P1_OBJ=0
    P1_DDR=$(pp_num "SELECT COUNT(*) FROM DDR_Calculations WHERE File_Name = '${BASENAME%.xml}'")
    phase_finish "$(group_de "$P1_OBJ") objects (+$(group_de "$P1_DDR") DDR chunks)" \
        "{\"objects_extracted\":$P1_OBJ,\"ddr_calc_chunks\":$P1_DDR}"

    if [ "$SINGLE_RC" -eq 0 ]; then
        # Track the table-only chain: manifest row + catalogs_built marker may only be
        # written when every phase the batch path guarantees also succeeded here.
        SINGLE_CHAIN_OK=true
        # Master changed (P1 done) → invalidate the marker until the chain completed,
        # so an abort mid-chain cannot let a later --changed-only run short-circuit on
        # a half-built catalog. (Classic path: manifest tables may not exist yet.)
        init_manifest_db
        _catalogs_state_set building

        # Phase 2 (Resolve) — table-only, rebuilds all File_Names (no read_xml).
        echo ""
        echo "Resolving references (Phase 2)..."
        phase_begin P2 Resolve
        run_phase2 "Phase 2 Reference Resolution" >/dev/null 2>&1
        P2_REF=$(count_table_sum XMLCalcReferences XMLStepReferences XMLLayoutReferences PluginFunctionUsages MBS_SubnameMap GetSubparameterMap)
        # Hard P2 gate (batch parity): a P2 failure — or 0 references while P1
        # loaded objects — aborts BEFORE P3, with the same conditions and abort
        # helpers as the batch gate. Running the dependent phases on missing or
        # stale reference tables would build a hollow catalog, publish it via
        # the unconditional sync below, and still report "successful"; the a4
        # sync guard cannot catch this case (after an incremental P2 failure
        # the stale ObjectCatalog is non-empty). P3+ failures stay chain
        # warnings via SINGLE_CHAIN_OK, exactly like in batch mode.
        P2_GATE=false
        if $P2_FAILED || { [ "${P1_OBJ:-0}" -gt 0 ] && [ "${P2_REF:-0}" -eq 0 ]; }; then P2_GATE=true; fi
        if $P2_GATE; then
            if $P2_FAILED; then
                echo "✗ Phase 2 reference resolution failed"
            else
                echo "✗ Phase 2 resolved 0 references while Phase 1 loaded $(group_de "${P1_OBJ:-0}") objects — stopping (integrity gate)"
            fi
        else
            echo "✓ Phase 2 references resolved"
        fi
        phase_finish "$(group_de "$P2_REF") references" "{\"references_resolved\":$P2_REF}"
        if $P2_GATE; then
            if $P2_OOM; then
                abort_insufficient_memory "Reference resolution (Phase 2)"
            fi
            # Unlike batch, P1 has already re-imported this file into the master
            # (no transaction bracket around P1/P2) — only the SERVED read copies
            # are guaranteed unchanged, because the abort sits before the sync
            # hook. The detail text states that explicitly.
            SINGLE_P2_DETAIL="Single-file mode: Phase 1 already re-imported ${FILENAME} into the master DB, which now holds a partial state; the served read copies are unchanged (no sync ran). If this failure repeats, rebuild with: convert-xml --batch --force-rebuild"
            if ! $P2_FAILED; then
                SINGLE_P2_DETAIL="Phase 2 completed without error but resolved 0 references while Phase 1 loaded ${P1_OBJ:-0} objects. ${SINGLE_P2_DETAIL}"
            fi
            abort_pipeline_incomplete "Phase 2 Reference Resolution" "$SINGLE_P2_DETAIL"
        fi

        # Phase 3 (Details) — variable parser; table-only and catalog-wide like in
        # batch (03→04 order mandatory).
        echo ""
        echo "Building variable analysis (Phase 3)..."
        phase_begin P3 Details
        run_pipeline_step "Phase 3 Details (Variables)" "$ENGINE_ROOT/sql/convert_xml_03_details.sql" >/dev/null 2>&1
        if $PIPELINE_STEP_OK; then echo "✓ Variable analysis built"
        else SINGLE_CHAIN_OK=false; echo "✗ WARNING: Variable analysis failed"; fi
        P3_USAGES=$(pp_num "SELECT COUNT(*) FROM VariableUsages")
        P3_VARS=$(pp_num "SELECT COUNT(*) FROM VariablesCatalog")
        phase_finish "$(group_de "$P3_USAGES") usages · $(group_de "$P3_VARS") vars" \
            "{\"variable_usages\":$P3_USAGES,\"variables_distinct\":$P3_VARS}"

        # Phase 3.5 (Plugin Subname Recovery) — same step and ordering as in
        # batch mode (after P3, before P4); catalog-wide like P3/P4.
        echo ""
        echo "Recovering plugin subnames (Phase 3.5)..."
        run_pipeline_step "Phase 3.5 Plugin Subname Recovery" "$ENGINE_ROOT/sql/convert_xml_03b_plugin_subname_recovery.sql" >/dev/null 2>&1
        if $PIPELINE_STEP_OK; then echo "✓ Plugin subnames recovered"
        else SINGLE_CHAIN_OK=false; echo "✗ WARNING: Plugin subname recovery failed"; fi

        # Phase 4 (Catalog) — ObjectCatalog + ObjectLinks (basis of the analysis skills).
        echo ""
        echo "Building universal catalogs (Phase 4)..."
        phase_begin P4 Catalog
        ensure_mbs_component_csv
        run_pipeline_step "Phase 4 Catalog (Objects+Links)" "$ENGINE_ROOT/sql/convert_xml_04_catalog.sql" >/dev/null 2>&1
        if $PIPELINE_STEP_OK; then echo "✓ Universal catalogs built"
        else SINGLE_CHAIN_OK=false; echo "✗ WARNING: Universal catalogs failed"; fi
        P4_OBJ=$(pp_num "SELECT COUNT(*) FROM ObjectCatalog")
        P4_LINKS=$(pp_num "SELECT COUNT(*) FROM ObjectLinks")
        phase_finish "$(group_de "$P4_OBJ") objects · $(group_de "$P4_LINKS") links" \
            "{\"objects_registered\":$P4_OBJ,\"links\":$P4_LINKS}"

        # Phase 5 (Homes) — rebuild resolutions on the fresh ObjectCatalog.
        echo ""
        echo "Building resolution tables (Phase 5)..."
        phase_begin P5 Homes
        run_pipeline_step "Phase 5 Homes" "$ENGINE_ROOT/sql/convert_xml_05_homes.sql" >/dev/null 2>&1
        if $PIPELINE_STEP_OK; then echo "✓ Resolution tables built"
        else SINGLE_CHAIN_OK=false; echo "✗ WARNING: Resolution tables failed"; fi
        P5_HOMES=$(pp_num "SELECT COUNT(*) FROM ObjectHomes")
        P5_TO=$(pp_num "SELECT COUNT(*) FROM TableOccurrenceResolution")
        phase_finish "$(group_de "$P5_HOMES") homes · $(group_de "$P5_TO") TO" \
            "{\"object_homes\":$P5_HOMES,\"to_resolutions\":$P5_TO}"

        # Phase 6 (Validate) — post-processor: consistency checks (Calc_UUID guard C1).
        echo ""
        phase_begin P6 Validate
        postprocess_db
        phase_finish "$CHECKS_RUN checks · $POSTCHECK_WARN warnings" \
            "{\"checks_run\":$CHECKS_RUN,\"warnings\":$POSTCHECK_WARN}"

        # Analysis views (static code analysis) — batch-wide, table-only phase after P6.
        if [ -f "$ANALYSIS_VIEWS_TEMPLATE" ]; then
            echo ""
            echo "Building analysis views (static code analysis)..."
            run_pipeline_step "Analysis Views (SCA)" "$ANALYSIS_VIEWS_TEMPLATE" >/dev/null 2>&1
            if $PIPELINE_STEP_OK; then echo "✓ Analysis views built"
            else echo "✗ WARNING: Analysis views failed"; fi
            postcheck_calc_anchors
        fi

        # Manifest row + catalogs_built marker — only when the full chain (P1–P5)
        # succeeded: the manifest promises "master holds this file's state, catalogs
        # current", which is exactly what a later --batch --changed-only skip relies
        # on. P6/SCA stay non-gating (batch parity: checks, not build steps).
        echo ""
        if $SINGLE_CHAIN_OK; then
            _manifest_write_single "$XML_DIR/$FILENAME"
            _catalogs_state_set ok
            echo "✓ Manifest updated ($FILENAME) — a later --batch --changed-only skips this state"
        else
            echo "Note: chain incomplete → no manifest row written; the next --batch --changed-only re-parses $FILENAME"
        fi

        # Sync hook also in single-file mode (production mode).
        if ! $TEST_MODE; then
            if ! $QUIET_MODE; then
                echo ""
                echo "Syncing database to rest-api/..."
            fi
            sync_to_rest_api
            # Manifest stamp — single-file imports refresh the
            # convert-owned blocks too (metrics change with every import).
            stamp_solution_manifest
        fi
    fi

    BATCH_END=$(now_epoch)
    RUN_ENDED_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    RUN_ENDED_ISO=$(iso_now)
    BATCH_DURATION=$(awk -v a="$BATCH_END" -v b="$BATCH_START" 'BEGIN { printf "%.3f", a - b }')

    finalize_logs
    finalize_run
    prune_solution_logs
    echo ""
    echo "Log file:  $LOG_FILE"
    echo "JSON file: $JSON_FILE"
    [ "${FM_NO_CONSOLE_LOG:-}" != "1" ] && echo "Console:   $CONSOLE_LOG"
    [ -s "$ERROR_LOG_FILE" ] && echo "Error details: $ERROR_LOG_FILE"

    if [ "$SINGLE_RC" -eq 0 ]; then
        if [ "$POSTCHECK_WARN" -gt 0 ]; then
            emit_done true "Single-file import successful, Warnings: $POSTCHECK_WARN"
        else
            emit_done true "Single-file import successful"
        fi
        # Policy lock: sticky state only after a fully successful run
        # (same contract as the batch writer above).
        _policy_state_write "$_RUN_POLICY" "$WS_SENTINEL_ON"
        stamp_last_run true 0 1 1
        exit 0
    else
        emit_done false "Single-file import failed (exit $SINGLE_RC)"
        stamp_last_run false "$SINGLE_RC" 0 1
        exit $SINGLE_RC
    fi
fi
