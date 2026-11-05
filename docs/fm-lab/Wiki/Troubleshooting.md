If you have trouble with the technical setup, please refer to the following known issues.

- [Update stops — local changes would be overwritten](#update-stops-local-changes-would-be-overwritten)
- [Old Node.js or npm keeps winning](#old-nodejs-or-npm-keeps-winning-after-an-update)
- [Permission prompts for duckdb](#too-many-permission-prompts-for-duckdb)
- [Dev Container fails to reopen](#dev-container-fails-to-reopen-dockerfile-with-features-not-found)
- [Dev Container build fails](#dev-container-build-fails-additional-privileges-requested)
- [Claude Code sign-in in the terminal](#claude-code-sign-in-in-the-terminal)
- [Another conversion is already running](#another-conversion-is-already-running)
- [Import re-reads everything after an extension update](#import-re-reads-everything-after-an-extension-update)
- [IMPORT ABORTED — build incomplete](#import-aborted-build-incomplete)
- [FileMaker 22 and 26 exports of the same file](#filemaker-22-and-26-exports-of-the-same-file)
- [No plug-in references after an import](#no-plug-in-references-after-an-import)


---
### Update stops — local changes would be overwritten

`git pull` stops without updating anything and lists files:

```
error: Your local changes to the following files would be overwritten by merge:
	CLAUDE.md
Please commit your changes or stash them before you merge.
Aborting
```

or, in the second form, *The following untracked working tree files would be overwritten by merge*. Git prints this in the language of your system, so the wording can differ — the picture is the same: the update ends and names files.

The update changes or adds files that you changed or created yourself, and git refuses to replace them. Nothing is broken; fm-lab simply stays on the old version. Typical causes are a shipped dashboard or skill corrected in place, or the `language:` line that older versions asked you to edit in `CLAUDE.md`.

**Fix:** run this one command in the fm-lab folder:

```bash
bash -c "$(git show origin/main:tools/update.sh)"
```

The failed pull has already downloaded the new release; the command runs that release's update script. It saves the listed files to `.fmlab/update-backup/<timestamp>/` (`update.json` there lists every file and why it was saved), puts edited shipped files back to their shipped version and completes the update. At the end it names the next step — restart fm-lab with `bash tools/fmlab.sh up`, **Dev Containers: Rebuild Container** or `bash tools/init.sh`. At that start, edited dashboards and tests come back as own versions under **Custom** (`<id>-local`, title suffix *(own version)*); a language pinned in `CLAUDE.md` moves to `.fmlab/user.local.json`. Nothing is deleted. To only see what would be saved, append `update.sh --dry-run` to the command.

Two other answers you may get:

- `fatal: path 'tools/update.sh' does not exist in 'origin/main'` — the new release has not been downloaded yet, for example because the pull had no network. Run `git fetch`, then the command again.
- *This fm-lab folder contains … own commit(s)* — you work with git yourself; combine your commits with the release as usual (`git pull`), the script does not touch them.

From version 0.9.17 on, `bash tools/fmlab.sh update` does the same before git can stop — see [Updating fm-lab](Installation.md#updating-fm-lab).

---
### Old Node.js or npm keeps winning after an update

`bash tools/init.sh` insists on `Node.js v20… found, but ≥22 is required` (or the npm equivalent) although a current version was just installed. The installation is usually fine — the **`PATH` order** is not: an older `node`/`npm` lives in a directory that comes earlier in `PATH` and answers every call. Installing the new version again changes nothing, because the new one is never the one being asked.

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
### Dev Container fails to reopen — Dockerfile-with-features not found

**Reopen in Container** stops with *An error occurred setting up the container*, and the Dev Containers log ends with:

```
failed to solve: failed to read dockerfile: open …/Dockerfile-with-features: no such file or directory
```

The container worked before; typically the error shows up after Docker images were cleaned up, or — on a checkout that has not been updated for a while — after a restart of the computer or a few days without opening the container. (If the log reports *additional privileges requested* instead, see [the next entry](#dev-container-build-fails-additional-privileges-requested).)

When the Dev Containers extension builds the container, it writes a generated Dockerfile (`Dockerfile-with-features`) into the temporary folder of the host and records its path in the extension's own storage. A reopen starts the existing image and builds nothing. It builds only when Docker no longer has the image — for example after `docker image prune` or a reset of Docker Desktop; older fm-lab checkouts also rebuild on every reopen. Such a build reads the recorded path again, but the operating system clears temporary folders: on a restart, and on macOS also for files that have not been used for a few days. The recorded path then points at nothing.

**Fix:** run **Dev Containers: Rebuild Container** from the command palette — or, from a local VS Code window, **Dev Containers: Rebuild and Reopen in Container**. The rebuild generates the file anew; afterwards a reopen starts the image without building. On an older checkout, update fm-lab (`git pull`) so the error does not come back. Nothing gets lost: the catalog, conversions and settings live in the repository on the host, the `node_modules` volumes and the Claude Code login in named Docker volumes.

Make the rebuild your routine after every `git pull` as well: because a reopen does not build, changes to the container definition that an update brings in take effect only with **Rebuild Container**. When you reopen after an update, VS Code points this out with a short-lived notification *Configuration file(s) changed … The container might need to be rebuilt* — its **Rebuild** button does the same. To check the result, the version line under **Settings** shows the DuckDB of the REST API and the DuckDB CLI of the XML import; after the rebuild both carry the DuckDB version of the release.

---
### Dev Container build fails — additional privileges requested

Building the Dev Container stops, and the log shows:

```
additional privileges requested: pass "--allow=fs.read=…/Dockerfile-with-features" to grant requested privileges
```

often only as `failed to execute bake: exit status 1`.

Docker Compose builds images through Buildx Bake, which reads files outside the build context only with an explicit grant. Compose grants the build context, but not the generated `Dockerfile-with-features` that the Dev Containers extension places in the temporary folder of the host — and current Buildx versions enforce the grant. This affects every Compose-based Dev Container, not only fm-lab. Docker Compose grants this file once it contains the fix [docker/compose#14325](https://github.com/docker/compose/pull/14325); with a Docker Desktop that ships such a Compose release, the error is gone without any of the steps below.

**Alternative without touching your system:** start fm-lab the plain Docker way — `bash tools/fmlab.sh up` (`--claude` for the Claude variant) or `docker compose up` is not affected, because its Dockerfile lies inside the build context. To work in VS Code inside the running stack, use **Dev Containers: Attach to Running Container…** and pick the `api` container; attaching builds nothing.

**Workaround for the Dev Container:** switch off Bake's file-system check with the environment variable `BUILDX_BAKE_ENTITLEMENTS_FS=0`. VS Code must already see the variable when it starts:

- **macOS:** `launchctl setenv BUILDX_BAKE_ENTITLEMENTS_FS 0` — applies to every program started afterwards, until the Mac restarts. To keep it across restarts, also add `export BUILDX_BAKE_ENTITLEMENTS_FS=0` to `~/.zprofile` (zsh, the default shell) or `~/.bash_profile` (bash).
- **Windows:** `setx BUILDX_BAKE_ENTITLEMENTS_FS 0` sets it as a user environment variable. With the repository inside WSL2, add the `export` line to `~/.profile` in the distribution as well.
- **Linux:** add the `export` line to `~/.profile`, then log out and back in.

Then quit VS Code completely — on macOS with ⌘Q, closing the window is not enough — start it again and run **Dev Containers: Rebuild and Reopen in Container**. `COMPOSE_BAKE=false` does not help here: Docker Compose builds through Bake either way.

The variable switches the check off for **every** Bake build of your user account, not only for fm-lab — and the check is what keeps a build definition from reading arbitrary files on your machine. Treat it as temporary and remove it once your Docker Compose grants the Dockerfile itself: delete the `export` line, and on macOS run `launchctl unsetenv BUILDX_BAKE_ENTITLEMENTS_FS`; on Windows remove it under *Edit environment variables for your account*.

---
### Claude Code sign-in in the terminal

Claude Code in the Docker container cannot open your browser itself, and the sign-in link it prints wraps across several terminal lines. Selected by hand, the link breaks at the line ends and the sign-in page answers _“Invalid response_type”_ or _“Unknown scope”_.

- **Start the agent with `bash tools/fmlab.sh up --claude`** (or `bash tools/fmlab.sh agent` for a running stack). For this session the wrapper opens links from the container in your host browser, the sign-in page included: confirm there, copy the short code the page shows and paste it at the `Paste code here` prompt. Should the page not open, the wrapper's log `.fmlab/open-bridge.log` names the reason.
- **Started any other way** (`docker compose exec -it api claude`), Claude Code puts the link on the clipboard where the terminal allows it (OSC 52, e.g. iTerm2 — macOS Terminal does not); otherwise paste it into a text editor, remove every line break, open the result in your browser and paste the code back.
- **Without a browser sign-in:** put `ANTHROPIC_API_KEY=…` (API-key billing) or `CLAUDE_CODE_OAUTH_TOKEN=…` (from `claude setup-token`) into a `.env` next to the compose files and restart the stack.
- In the **VS Code Dev Container** the Claude Code extension handles the sign-in; nothing to copy.

**Login expired** — a saved login can expire. The start message only sees that one exists (*saved login found*); if the session reports _Login expired_, run `/login` in it.

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
### No importable file — FileMaker 18 exports

The import stops before it begins with *No importable file* (CLI: `IMPORT ABORTED — no importable files`, exit code `4`), and the inbox marks the files with ⛔ and **FM 18**. The XML files were exported from FileMaker 18 or older; FM-Lab reads exports from FileMaker 19 and later. Nothing was written — open the files in FileMaker Pro 19 or newer, export them again via *Save a Copy as XML* and import again. Details: [Exports from FileMaker 18](../xml/XML.md#exports-from-filemaker-18).

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
