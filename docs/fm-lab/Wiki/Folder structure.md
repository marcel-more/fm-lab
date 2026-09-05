The repository is organized into separate sections for the different [Components](Components.md) and tasks within the overall workflow.

```
fm-lab/
├── .claude/                    Claude Code configuration (skills, settings)
├── .devcontainer/              VS Code Dev Container configuration (optional)
├── .fmlab/                     FM-Lab configuration (plugins, settings)
├── .git/                       Git repository metadata
├── apps/                       Frontend / application code
├── db/                         DuckDB databases (symlinks to active solution)
├── docs/                       Project documentation and optional references
├── ingestion/                  Katana XML import engine (orchestrator, awk, phase SQL)
├── logs/                       Log files
├── packages/                   Shared packages and modules
├── reference/                  fm-spec database (syntax and grammar definitions)
├── rest-api/                   REST API server with its own database copies
├── scripts/                    Reserved for generation of new scripts (output)
├── solutions/                  Solution bundles (FileMaker solution data)
├── solutions/<id>/xml/         FileMaker XML exports (input data)
├── solutions/<id>/db/          DuckDB object catalog (output data)
├── solutions/<id>/state/       Solution metadata (status, logs)
├── tools/                      XML Importer and CLI utilities
│
├── .gitignore                  Git ignore rules
├── README.md                   Project overview
├── CHANGELOG.md                Version history
├── CLAUDE.md                   Project instructions for Claude
├── LICENSE                     License
└── package.json                Node.js workspace configuration
```
