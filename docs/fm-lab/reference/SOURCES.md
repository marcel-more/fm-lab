# **fm-spec** Data Sources & Attribution

This file documents the sources behind the bundled FileMaker reference database
(`reference/fm_spec.duckdb`). The shipped data is **source-neutral**: it
contains no source citations, author/company names or corpus artifacts. The
database points at this file through its `reference_meta.attribution` key.

## Manufacturer documentation (normative)

- **Claris FileMaker Pro help** (help.claris.com) — names, descriptions,
  parameter prose, version information and per-object documentation deep links.
  Documentation content © Claris International Inc. FileMaker and Claris are
  trademarks of Claris International Inc. This project is not affiliated with,
  authorized, or endorsed by Claris.

## Plug-in vendor documentation (`plugin_spec.duckdb`)

- **MBS FileMaker Plugin documentation** (monkeybreadsoftware.com) — per-function
  platform support tables, components, plugin version information, deprecation
  markers and function renames, parsed from the locally installed documentation
  mirror (`docs/mbs`, installed by the `install-mbs-docs` skill).
  Documentation content © MonkeyBread Software / Christian Schmitz Software GmbH.
  This project is not affiliated with, authorized, or endorsed by MonkeyBread
  Software. The curated runtime interpretation (`plugin_runtime_map`,
  `plugin_generic_rules`) is fm-lab curation with per-row provenance
  (`tools/plugin-spec/curated/`).

## CC BY 4.0 (attribution required)

- **"Canonical XML Format for FileMaker Script Steps"** — Andrew Kear, Clockwork
  Creative Technology  
  https://github.com/andykear/FileMaker-XMLsnippet-Claude-Skill  
  Licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).  
  Used for roundtrip-verified fmxmlsnippet skeletons, paste/silent-failure semantics and save constraints.

## MIT

- **fmCheckMate-XSLT** — Russell Watson  
  https://github.com/mrwatson-de/fmCheckMate-XSLT  
  Full-surface test corpus used as primary structural evidence
  for the step grammar and options.
- **fm-xml-export-exploder** — Malte Bastian  
  https://github.com/bc-m/fm-xml-export-exploder  
  Used to validate the SaXML parameter-type classification.
- **ooe-fm** ("One Of Everything") — Mislav Kos, Soliant Consulting  
  https://github.com/mislavkos/ooe-fm  
  Used for SaXML version diffs.
- **fmIDE** — Russell Watson  
  https://github.com/fmIDE/fmIDE  
  Source of action layer (`action_catalog`, `step_action_map`):
  the fmIDE ActionScript vocabulary, its step mappings
  and execution metadata.
- **fmJAML** — Russell Watson  
  https://github.com/fmIDE/fmJAML  
  Authoring notation targeted by the ActionScript emitter;
  no data imported into reference tables.

## Additional public sources

- **FileMaker Clipboard Bugs** — ai2fm · Dimitris Kokoutsidis  
  https://axelareu.github.io/ai2fm-community/claris_bugs/claris_clipboard_bugs.html  
  18 FileMaker Clipboard Bugs — verified, with reproducible test files

---

Example payloads (`step_xml_map.saxml_example`) were originally derived from the
MIT-licensed full-surface corpus. Since reference schema 1.7.1 all payload
content (comments, calculations, URLs) is synthetic and instance identity is
removed; the corpus attribution therefore covers structural evidence only, not
any shipped content.
