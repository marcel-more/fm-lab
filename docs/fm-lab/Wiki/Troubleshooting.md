If you have trouble with the technical setup, please refer to the following known issues.

- [Old Node.js or npm keeps winning](#old-nodejs-or-npm-keeps-winning-after-an-update)
- [Permission prompts for duckdb](#too-many-permission-prompts-for-duckdb)
- [Another conversion is already running](#another-conversion-is-already-running)
- [Import re-reads everything after an extension update](#import-re-reads-everything-after-an-extension-update)
- [IMPORT ABORTED — build incomplete](#import-aborted-build-incomplete)
- [FileMaker 22 and 26 exports of the same file](#filemaker-22-and-26-exports-of-the-same-file)


---
### Old Node.js or npm keeps winning after an update

`bash tools/init.sh` insists on `Node.js v18… found, but ≥20 is required` (or the npm equivalent) although a current version was just installed. The installation is usually fine — the **`PATH` order** is not: an older `node`/`npm` lives in a directory that comes earlier in `PATH` and answers every call. Installing the new version again changes nothing, because the new one is never the one being asked.

The preflight names the culprit instead of just failing: it prints the binary that actually answers (`Active binary:`), plus every other `node`/`npm` it can see — either on `PATH` behind the active one (`Shadowed:`) or installed but not on `PATH` at all (`Not on PATH:`). Outside init, `type -a node` and `type -a npm` list the same candidates in resolution order. Note that npm runs on whichever `node` resolves first, so a stale Node drags npm down with it.

**Repair the order before you uninstall anything** — it is the cheapest fix and touches nothing else. Put the directory of the wanted version ahead of the stale one in your shell profile (`~/.zshrc`, `~/.bashrc`, …), then open a **new** shell: `init.sh` reads `PATH` once at startup, so a profile edit never reaches a shell that is already running.

Remove the old installation only if it really has to go. A typical source is a package manager that has not been used in a long time (an outdated Homebrew, for instance), and this is where it gets laborious: a stale package manager may need updating **before** it can uninstall its own old Node cleanly, and once the uninstall is through, the profile can keep pointing at directories that no longer exist. Afterwards `type -a node` should list exactly one binary — the intended one.

Version managers (nvm, Volta, asdf, …) put their own shim layer on top, and the exact steps differ per setup. The principle does not: exactly one `node` has to answer first, and it has to be the one you installed.

---
### Too many permission prompts for `duckdb`?
The bundled settings pre-approve DuckDB queries (`duckdb …`, and the standard binary locations `/usr/local/bin/duckdb` / `/opt/homebrew/bin/duckdb`). 

Two things make prompts reappear:

- **DuckDB not on `PATH`.** The allow-rule matches the command's first token, so the agent must be able to call the bare `duckdb …` form. In the container this is guaranteed; for a native setup `bash tools/init.sh` resolves the binary and writes its directory into `.claude/settings.json → env.PATH` — re-run it if the entry is missing (don't just add narrower `duckdb … -c:*` rules; they won't help).

- **Workspace not trusted.** If you see `Ignoring … permissions.allow entry … this workspace has not been trusted`, Claude Code ignores **all** allow-rules until you accept the trust dialog **once** (open the folder interactively and confirm). After that the pre-approvals take effect.

---
### Another conversion is already running

The CLI converter and the web import button share a single lock — only one conversion can run per workspace. A second caller fails fast instead of queueing: the CLI exits with code `7`, the REST API answers `409 ALREADY_RUNNING`. Wait for the running import to finish (its progress is visible in the web import log) and retry.

---
### Import re-reads everything after an extension update

After a webbed/DuckDB update the converter may switch its parser policy (DOM ↔ SAX streaming, see [Katana engine](katana-engine.md#dom-vs-sax)). The stored content hashes are policy-stamped, so the first import after such a switch re-reads the affected catalogs once instead of skipping them — expect a single longer run, not a permanent slowdown. Subsequent imports skip unchanged content as usual.

---
### IMPORT ABORTED — build incomplete

A failure in the resolve phase (Phase 2) aborts the import before anything is published: no catalogs from that run are written and the previously served database stays unchanged. The log names the cause — fix it and re-run; if the workspace state looks inconsistent, `--batch --force-rebuild` rebuilds the catalog from scratch.

---
### FileMaker 22 and 26 exports of the same file

A FileMaker 26 export of a file carries the **same object UUIDs** as its FileMaker 22 export — the UUIDs identify the objects, not the export. Importing both into one solution bundle therefore does not give you two files to compare: the two exports collide object by object, and the resulting catalog describes neither state correctly.

When you move a solution to FileMaker 26, re-export **every** file and replace the old exports in the inbox (`solutions/<id>/xml/`), then re-import with `--batch --force-rebuild`. To keep the old state around, put it in a **separate solution bundle** (`tools/solution.sh create <id>`) — bundles are fully isolated from each other.

Mixing profiles as such is fine: a solution whose files come from different FileMaker versions imports without trouble, as long as no *file* is present twice. See [the SaXML version notes](../xml/XML.md#version-notes-saxml-v22-and-v23).

---
### No plug-in references after an import

The import ran without errors, scripts, fields and layouts are all there — but the docs set shows no *used* plug-in functions, the object search finds no `PluginFunction` objects, and where-used looks thin. Installing or refreshing the plug-in documentation and importing again changes nothing: plug-in references come from the export's DDR chunk stream only, never from the documentation mirror or `plugin_spec`. Three export defects produce exactly this picture:

- **The file was exported without DDR info** — *Include details for analysis tools* was off. The catalog then holds no formula references at all for that file (fields, functions, custom functions, plug-in calls), although every formula text is present. The XML-import page marks such files in the file-list header (*DDR info missing*, probed from the root attribute of every file in the inbox before the import) and the import log reports them as a warning.
- **The plug-in was not loaded on the client that exported** — FileMaker writes `<Function Missing>` instead of the function name, in the formula text itself. The call never becomes an object or an edge, and the text no longer says which plug-in it was. The import log reports the `Function Missing` chunks as a warning.
- **The function name is dynamic** (`MBS($name; …)`) — nothing to resolve, so the converter keeps neither object nor edge for that call.

Run the [Plug-in reference integrity](Analysis%20Tests.md) test (`plugin-availability`, rubric [metadata integrity](../sca/SCA%20Metadata%20Integrity.md)): its census lists every file with text-side against graph-side counts and a verdict, and its rules name the affected files and formulas. None of the three can be repaired inside FM-Lab — re-export the file with the option enabled, on a client with the plug-in installed, and import again.
