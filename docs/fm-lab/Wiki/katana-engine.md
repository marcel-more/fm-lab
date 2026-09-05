# Katana XML Engine

- [What it does](#what-it-does)
- [How it works](#how-it-works-in-one-sentence)
- [Partitioning, chunking and the import manifest](#partitioning-chunking-and-the-import-manifest)
- [Deep dive: Phase 1 + 2](#deep-dive-phase-1-2)
- [The seven processing phases](#the-seven-processing-phases)
- [Why this architecture matters](#why-this-architecture-matters)

The **Katana engine** 🔪 is the high-performance XML processing core of the FM-Lab [Ingestion Pipeline](How%20it%20works.md#ingestion-pipeline). It sits between the raw FileMaker SaXML export and the DuckDB-powered [Object Catalog](Architecture.md#duckdb-powered-object-catalog) and solves one central problem: **FileMaker exports can be huge** — hundreds of megabytes up to gigabytes of XML per file — while a naive DOM parse inflates to roughly **60–73× the file size in RAM**. Katana cuts these documents into well-planned chunks, processes them in parallel and merges the results back together **bit-identically**, so even multi-gigabyte solutions convert quickly on ordinary developer machines.

The engine lives in `ingestion/` and is driven by `ingestion/convert_fm_xml.sh` (see [Components](Components.md#katana-xml-engine)).

---

## What it does

Katana has four jobs:

1. **Normalize** — decode the UTF-16 export to UTF-8, strip control bytes and oversized embedded binary payloads (container images), and bring the document into a line-oriented form that can be processed as a stream.
2. **Partition** — split each document at safe structural boundaries into independent chunks, so no single parse ever has to hold the whole document in memory.
3. **Plan & dispatch** — record every chunk in a **chunk map** (its catalog, record count, size, parser policy) and feed the chunks to a pool of parallel workers.
4. **Track & skip** — maintain a persistent **import manifest** so that unchanged files — and even unchanged *catalogs inside changed files* — are skipped entirely on the next run.

All of this happens **before and around** the SQL conversion phases. The SQL templates in `ingestion/sql/` stay agnostic: they read whatever XML they are given, whether that is a whole document or a 25-record sub-chunk.

### How it works, in one sentence

Katana turns *"parse one giant document"* into *"parse many small, independent documents in parallel — and only the ones that actually changed."*

### Benefits

- **Bounded memory** — the peak RAM is set by the largest single chunk, not the largest file. The turbo path runs with a floor of roughly 2.5 GB where classic whole-document DOM needs 10 GB and more.
- **Parallel speed** — chunks convert concurrently in separate worker processes; conversion time scales with cores instead of file size.
- **Bit-identical results** — chunked and unchunked runs produce the same catalog, verified by identity gates. Chunking is an optimization, never a semantic change.
- **Incremental imports** — the manifest reduces a re-import of a mostly unchanged solution to the few catalogs that actually differ.
- **Self-tuning** — with no flags at all, the engine probes the available RAM, the CPU count and the capabilities of the loaded [webbed extension](Architecture.md#duckdb-powered-object-catalog) and picks the best strategy on its own.

---

## Partitioning, chunking and the import manifest

A FileMaker SaXML document is a set of top-level **catalogs** (branches) — scripts, layouts, fields, value lists and so on. Two of them dominate the memory profile in almost every real solution: `StepsForScripts` and the `DDR_INFO` block. Katana separates these heavy branches into their own chunk files and keeps everything else in a compact *main* chunk. The heaviest branches are additionally **sub-chunked** *inside* the branch at record boundaries (e.g. 25 layouts per chunk), each wrapped as a complete, self-contained SaXML document.

![Katana-1.png](../Assets/Katana-1.png)

Two bookkeeping structures make this safe and fast:

- **Chunk map** (transient, rebuilt per run) — one row per chunk with its source file, catalog, split number, record count, byte size, content hash, parser policy (`dom` or `sax`) and a dispatch status. It is the work queue of the run: the dispatcher pulls pending chunks from it, and the memory backoff writes retry attempts back into it.
- **Import manifest** (persistent, survives runs) — one row per source XML (mtime, size and an authoritative SHA-256 content hash — computed with `sha256sum`, `shasum` or `openssl`, whichever the host provides; without any of them the run warns once and writes no catalog rows, so nothing is ever skipped by mistake — plus converter and schema version stamps and the parser-policy fingerprint of the run that wrote the hashes) and one row per *file × catalog* (a hash over the ordered chunk hashes of that catalog). Converter, schema or policy drift invalidates the manifest and forces a clean rebuild — so a skip can never hide a stale format.

---

## Deep dive: Phase 1 + 2

Phases 1 (Extract) and 2 (Resolve) are the only compute-heavy stages of the pipeline — Phase 1 is the only phase that touches XML at all (see [The seven processing phases](#the-seven-processing-phases)). Katana concentrates all of its machinery on them.

### One-pass preprocessing

Early versions preprocessed each file in up to eight separate passes (encoding, byte cleaning, counting, element renaming, splitting). Katana fuses all structural work into a **single awk pass** over the decoded stream: byte cleanup, oversized-binary stripping, branch-aware element renaming and chunk splitting happen line by line in one go, streaming with constant memory. Only the encoding conversion remains as a separate native pass in front. This alone removed most of the per-file preprocessing wall time and all intermediate file round-trips.

### Parallelization

Chunks are converted by **independent worker processes**, each writing into its own small DuckDB part database. Because every chunk is a self-contained document and FileMaker records carry UUIDs, the part results merge back into the master conflict-free — order does not matter. After Phase 1, the part databases are consolidated (via Parquet slices) into the master catalog. One class of UUID conflicts is real rather than an artifact of chunking — the same UUID on two *different* objects in the source file — and is not collapsed but healed with deterministic replacement UUIDs (see [UUID auto-healing](#uuid-auto-healing-for-duplicate-objects)).

### Worker processes vs. native DuckDB threads

DuckDB itself is multi-threaded, so why processes? Measurements showed that for this write-bound `read_xml` workload, **separate processes outperform DuckDB threads by a wide margin** — and the two must not be combined naively: if each of *W* workers also inherits the full thread count, the resulting *W × threads* oversubscription slows everything down. Katana therefore gives each worker a thread budget of **⌊cores / W⌋**. With that fix, throughput scales cleanly up to one worker per core while *also* using less RAM (measured: 16 workers × 1 thread beat 8 workers × 8 threads by −12 % wall time and −9 % RAM). The batch-wide phases 2–6 keep the full native thread count — there, a single large query benefits from all cores.

Phase 2 gets the same treatment at file granularity: the resolve step runs **K-way partitioned**, with files distributed across slices by measured weight (heaviest first into the lightest bin). Each slice sees the master through read-only filtered views, gets ⌊cores/K⌋ threads, and K is capped so that every slice keeps at least ~4 threads — the measured sweet spot (a partitioned run at K=4 beats both the single pass and an oversubscribed high-K run).

### DOM vs. SAX

Katana knows two parser policies per chunk:

- **DOM** — the default: text-faithful in every corner case, but the whole chunk lives in memory (which is fine, because chunks are small).
- **SAX streaming** — reads records as a stream with a fraction of the memory, enabled by the webbed extension. Streaming needs unique record anchors, so Katana's renamer pass gives repeating elements branch-unique names (e.g. `Layout` inside `LayoutCatalog` becomes `LC_Layout`) — surgical renames of structural tags only, never content.

Which policy wins is not hardcoded. A **capability registry** (`ingestion/version_check.json`) describes known webbed fixes together with behavioral probes; at startup the driver probes the actually loaded extension and enables SAX as the default only when the probes confirm it is fully text-faithful. Older extensions transparently stay on the DOM path — correctness always outranks speed.

A confirmed policy is also **sticky** across runs, so a transient probe failure never flips it. And because the stored content hashes are policy-stamped, an actual policy change — typically after a webbed update — triggers a one-time full reload of the affected catalogs instead of manifest skips.

### Memory limiting and auto-backoff

Every worker is accompanied by a lightweight sampler that tracks its peak RSS and the lowest system-available memory — the numbers survive even an OOM kill. If the kernel kills a chunk worker (exit 137), the **auto mode** does not fail the run: it halves the sub-chunk size *for that split group only*, re-plans the affected chunks in the chunk map and re-dispatches them — repeatedly, until they fit or a retry budget is exhausted. Catalogs that cannot be split further escalate with a clear diagnosis instead of a silent partial import. A hard chunk-count guard (per file and corpus-wide) prevents the opposite failure mode: exploding a huge solution into hundreds of thousands of chunk files.

### Manifest matching at catalog granularity

Skipping works on two levels. First, whole files: a fast mtime + size prefilter, then the authoritative content hash — unchanged files never enter the pipeline (exports of the same internal FileMaker file are treated as a group, so a change in one always re-imports all). Second, and more finely: for a file that *did* change, Katana compares the **per-catalog hash** against the manifest. A changed script section does not force re-parsing the (usually much heavier) layout catalog of the same file. If a run ends with zero pending chunks and the catalogs were fully built for the current manifest state, the whole rebuild of phases 2–6 is short-circuited — the master is already byte-identical.

### UUID auto-healing for duplicate objects

Real exports occasionally carry the **same UUID on two different objects within one file** — a copy-paste artifact inside FileMaker. Since the catalogs key rows by `(UUID, File_Name)`, the second twin used to be silently absorbed by the import upsert. The engine heals these collisions instead: the twin with the smallest internal FileMaker ID keeps the original UUID, every other twin gets a **deterministic synthetic replacement UUID** — an md5 hash over the catalog, file, original UUID and the object's internal FileMaker ID.

Because the replacement UUID is a pure row function (no counters, no positions), parallel chunk workers need no coordination, the result is invariant under chunking, and re-imports of the same export produce the same replacement UUIDs. Duplicates that main-catalog chunks see locally are healed right in the Phase-1 upserts; pairs split across sub-chunks of the heavy catalogs are healed by a follow-up pass at the merge point, guarded by a fail-hard duplicate count. References follow along: Phase 2 extracts the internal reference IDs (SaXML references are `id`+`name`+`UUID` triples), and Phase 4 distributes incoming links onto the correct twin — healed objects are full graph citizens, not islands.

The whole path is **census-gated**: it only activates for UUIDs the duplicate census flags anyway, so duplicate-free imports pay effectively nothing, and every healed pair is recorded in the census as an auditable original↔replacement mapping. Mechanics, guarantees, limits (the unhealable clone-file case, the positional step discriminator) and the census tables: [UUID Healing and Duplicate Census](../schema/UUID%20Healing%20and%20Duplicate%20Census.md). The escape hatch `FM_UUID_HEAL=0` restores the old absorb-and-census behavior.

### Auto mode: self-tuning by heuristics

Invoked with no strategy flags, the engine configures itself:

1. **Detect resources** — effectively available memory (cgroup-aware inside containers, so Docker limits are respected) and CPU count.
2. **Pick the pipeline** — turbo (chunked) with auto-backoff is the default; SAX streaming is added when the capability probes allow it.
3. **Size the worker pool** — `workers = (available − base) / per-worker`, using measured per-mode profiles (a SAX worker needs roughly half the memory of a DOM worker), capped at the core count.
4. **Engage pressure valves** — under tight memory, additional sub-chunking of the heavy DDR calculation block engages automatically; explicitly forced classic-DOM runs on a too-small machine first degrade to a split strategy and only abort — with guidance — when even that cannot fit.

Every decision is printed as a note, and every heuristic has an explicit override (flags or environment variables) for reproducible runs.

### Optimization summary

| Optimization | Effect |
|---|---|
| Fused single-pass preprocessing | ~8 passes/file → ~2, no intermediate files |
| Branch separation + sub-chunking | peak RAM = largest chunk, not largest file |
| Parallel chunk workers (processes) | conversion scales with cores |
| Per-worker thread budget ⌊cores/W⌋ | removes oversubscription: faster *and* leaner |
| Partitioned Phase 2 (weight-balanced) | heavy resolve step parallelized the same way |
| SAX streaming (capability-gated) | ~half the per-worker memory when safe |
| OOM auto-backoff via chunk map | tight machines finish instead of failing |
| Manifest skips (file + catalog level) | re-imports touch only what changed |
| No-change short-circuit | an unchanged corpus re-imports in seconds |
| Census-gated UUID healing | duplicate-UUID objects survive with deterministic replacement UUIDs, ≈0 cost on clean imports |

---

## The seven processing phases

Around the Katana chunk machinery, the conversion itself runs as seven SQL phases. Only Phase 1 reads XML; everything after it is pure DuckDB table work — which is exactly why the chunking effort concentrates there.

![Katana-2.png](../Assets/Katana-2.png)

**P1 — Extract.** Reads the (chunked) XML via webbed's `read_xml` and lands every FileMaker catalog as raw tables: scripts and steps, layouts and layout objects, fields, value lists, custom functions, accounts and more, including the raw-XML columns for later fine-grained analysis. Runs once per chunk, in parallel; the part results merge into the master. Duplicate object UUIDs are healed right in the upsert step (see [UUID auto-healing](#uuid-auto-healing-for-duplicate-objects)); a small cascade template afterwards propagates healed parent UUIDs into dependent extracts.

**P2 — Resolve.** Extracts references out of the raw XML columns: which script step points to which field, layout, script or custom function. Besides the UUID, each reference's internal FileMaker `@id` is extracted — the key that later disambiguates references onto healed duplicate twins. This is the second compute-heavy phase and runs weight-partitioned across worker slices (see the [deep dive](#deep-dive-phase-1-2)).

**P3 — Details.** Derives detail structures from the resolved data — most prominently the variable analysis: every variable usage across all scripts and calculations, aggregated into a per-variable catalog.

**P4 — Catalog.** Builds the two universal tables at the heart of FM-Lab: the **ObjectCatalog** (every object of every type across all files, uniformly addressable) and **ObjectLinks** (every relationship between them). Before the edge list is built, a rewrite stage distributes incoming references onto healed duplicate twins via their internal reference IDs. This phase also materializes every calculation slot — auto-enter, validation, hide conditions, tooltips, conditional-formatting rules, merge fields, trigger parameters, script-step parameters and more — as a first-class [Calculation](../schema/object-types/Calculation.md) object of its own. This is the [knowledge graph](How%20it%20works.md#layer-3-links) the analysis workflows run on.

**P5 — Homes.** Resolves cross-file references — external table occurrences, scripts called across files — and builds the graph views that feed the Graph Explorer and clustering.

**P6 — Validate.** Runs plausibility and consistency checks over the finished catalogs — including the duplicate-census and phantom-link guards — and exposes them as check views, so import problems surface immediately instead of during a later analysis.

**P7 — Clustering.** Segments the object graph into modules/communities (community detection) so that freshly imported solutions immediately show a meaningful module structure. It runs only on full rebuilds and is non-fatal — a clustering hiccup never invalidates the import.

After P7 the master database is synced to the REST API's read copy and the running server reloads it — no restart needed (see [Architecture](Architecture.md#deployment-options)). Publishing is conditional on a valid build: a Phase-2 failure aborts the run before P3 and leaves the previously served catalog untouched, a healing re-run publishes like any successful run, and only a batch in which every file failed stays unpublished.

---

## Why this architecture matters

The practical effect of the Katana engine is a different working rhythm with FM-Lab.

Converting a large solution used to be the slow, memory-anxious part of the workflow — a long-running batch job that could exhaust RAM on the biggest file and had to start over from zero after every export. With chunked parallel processing, capability-gated streaming and self-tuning defaults, a full conversion of a multi-gigabyte, multi-file solution now completes in a fraction of the former time, on machines and containers with modest memory budgets — and without babysitting.

Just as important is what happens *after* the first import. Because the manifest tracks content down to the catalog level, the everyday loop — export from FileMaker, re-import, analyze — becomes a **fast roundtrip**: unchanged files are skipped outright, changed files only re-parse the catalogs that actually differ, and a no-change run short-circuits in seconds. That turns the Object Catalog from a periodically refreshed snapshot into something you can casually keep in sync while you work, and makes **ad-hoc imports** — quickly pulling a customer export or a single file into a fresh [solution](Components.md#xml-input) just to answer one question — a routine, low-cost operation instead of a planned batch job.

In short: Katana removes the ingestion bottleneck, so the [agentic workflows](Workflow.md#agentic-code-analytics) on top always operate on a catalog that is cheap to create and cheap to keep fresh.
