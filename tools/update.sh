#!/usr/bin/env bash
# tools/update.sh — update fm-lab to the newest release without a dead end.
#
# One script, two ways in:
#   bash tools/fmlab.sh update                          # update (saves first, never stops halfway)
#   bash -c "$(git show origin/main:tools/update.sh)"   # after `git pull` stopped and listed files
#
# Why: `git pull` refuses the WHOLE update as soon as one file it changes or deletes
# was edited locally, or an untracked file sits where it adds one ("Your local
# changes … would be overwritten by merge" / "untracked working tree files would be
# overwritten"). An IGNORED file at such a path it overwrites without a word. This
# script saves exactly those files to .fmlab/update-backup/<stamp>/, puts the edited
# ones back to their shipped state, moves the others aside and fast-forwards. Nothing
# is deleted; update.json in the backup folder lists every file and why it was saved.
#
# The rescue call runs the script of the NEW release — the failed pull has already
# fetched it — inside the OLD working tree. This file is therefore self-contained: it
# never sources anything from tools/lib/ (that would be the old version) and needs
# only git and bash. bash-3.2 discipline (macOS system bash): no bash-4 constructs,
# empty arrays only via the ${arr[@]+…} guard.
#
# Release-specific migrations (run before saving):
#   CLAUDE.md with a pinned `language: <code>` → .fmlab/user.local.json agent_language
#
# Options:  --dry-run   show what would be saved and why, change nothing
#           --no-fetch  use the release fetched earlier (offline)
#           -h, --help
# Exit:     0 updated · already up to date · dry run
#           1 cannot update — the message says why, nothing was changed
#           2 usage
#           3 the final step failed after saving — the backup folder is kept

set -euo pipefail

DRY_RUN=0
FETCH=1
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --no-fetch) FETCH=0 ;;
        -h|--help)
            # The rescue call (bash -c) has no file to read the header from.
            if [ -f "${BASH_SOURCE[0]:-}" ]; then
                sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            else
                echo "Usage: update.sh [--dry-run] [--no-fetch] — see tools/update.sh"
            fi
            exit 0 ;;
        *) echo "update.sh: unknown option: $arg (use --dry-run, --no-fetch or --help)" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
info()    { echo "${C_CYAN}▶${C_RESET} $*"; }
success() { echo "${C_GREEN}✅${C_RESET} $*"; }
warn()    { echo "${C_YELLOW}⚠${C_RESET}  $*" >&2; }
die()     { echo "${C_YELLOW}✗${C_RESET}  $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is not installed — it is needed to update fm-lab."

# --- Where are we? -----------------------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "This is not an fm-lab folder. Open a terminal in your fm-lab folder and run the command there."
cd "$ROOT"
[ -d rest-api ] && [ -d tools ] \
    || die "This git folder does not look like fm-lab ($ROOT). Run the command in your fm-lab folder."

GIT_DIR="$(git rev-parse --git-dir)"
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ -e "$GIT_DIR/$marker" ] && die "A git operation is still in progress (${marker}). Finish or cancel it first, e.g. 'git merge --abort' or 'git rebase --abort', then run this again."
done

BRANCH="$(git symbolic-ref -q --short HEAD)" \
    || die "fm-lab is not on a branch (detached HEAD). Run 'git switch main', then this command again."
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -z "$UPSTREAM" ]; then
    git rev-parse --verify -q "origin/$BRANCH^{commit}" >/dev/null \
        || die "The branch '$BRANCH' has no update source (no 'origin/$BRANCH'). Run 'git switch main', then this command again."
    UPSTREAM="origin/$BRANCH"
fi
REMOTE="${UPSTREAM%%/*}"

if [ "$FETCH" = "1" ]; then
    info "Fetching the newest release …"
    git fetch --quiet "$REMOTE" \
        || warn "Could not reach '$REMOTE' — continuing with the release fetched earlier."
fi
git rev-parse --verify -q "$UPSTREAM^{commit}" >/dev/null \
    || die "No release has been fetched yet. Check the internet connection, run 'git fetch', then this command again."

OLD="$(git rev-parse HEAD)"
NEW="$(git rev-parse "$UPSTREAM^{commit}")"

version_of() {  # $1 = commit → global version from version.json (empty if none)
    git show "$1:version.json" 2>/dev/null | sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' | head -n 1
}
OLD_VERSION="$(version_of "$OLD")"; OLD_VERSION="${OLD_VERSION:-${OLD:0:8}}"
NEW_VERSION="$(version_of "$NEW")"; NEW_VERSION="${NEW_VERSION:-${NEW:0:8}}"

AHEAD="$(git rev-list --count "$UPSTREAM..HEAD")"
if [ "$AHEAD" != "0" ]; then
    die "This fm-lab folder contains $AHEAD own commit(s) the release does not have. This command only applies releases on top of an unchanged folder; combine them yourself with 'git pull', or ask for help."
fi
if [ "$(git rev-list --count "HEAD..$UPSTREAM")" = "0" ]; then
    success "fm-lab is up to date (version $OLD_VERSION)."
    exit 0
fi

# --- What would stop the update or be overwritten? ---------------------------------
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t fmlab-update)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/touched"; : > "$TMP/added"; : > "$TMP/collisions"

# Paths the release changes/deletes (touched) or newly adds (added).
git diff --no-renames --name-status -z "$OLD" "$NEW" | while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in
        A) printf '%s\n' "$path" >> "$TMP/added" ;;
        *) printf '%s\n' "$path" >> "$TMP/touched" ;;
    esac
done

# 1) tracked files edited here that the release changes or deletes → `git pull` stops
git diff --no-renames --name-status -z HEAD | while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in
        M|T) grep -Fxq -- "$path" "$TMP/touched" && printf 'edited\t%s\n' "$path" >> "$TMP/collisions" ;;
    esac
    true
done

# 2) anything at a path the release adds → untracked: `git pull` stops; ignored: overwritten.
#    On a case-insensitive file system a tracked file renamed only in case is no collision.
IGNORECASE="$(git config --bool core.ignorecase 2>/dev/null || echo false)"
[ "$IGNORECASE" = "true" ] && git ls-files > "$TMP/tracked"
classify_present() {  # $1 = path that exists although HEAD does not track it
    if [ "$IGNORECASE" = "true" ] && grep -Fxiq -- "$1" "$TMP/tracked"; then return; fi
    if git check-ignore -q -- "$1" 2>/dev/null; then
        printf 'ignored\t%s\n' "$1" >> "$TMP/collisions"
    else
        printf 'untracked\t%s\n' "$1" >> "$TMP/collisions"
    fi
}
while IFS= read -r path; do
    if [ -e "$path" ] || [ -L "$path" ]; then classify_present "$path"; fi
done < "$TMP/added"
# a file where the release needs a folder
sed -e 's|/[^/]*$||' -e '/^[^/]*$/d' "$TMP/added" | sort -u > "$TMP/added_dirs"
while IFS= read -r dir; do
    probe="$dir"
    while [ -n "$probe" ] && [ "$probe" != "." ]; do
        if [ -e "$probe" ] && [ ! -d "$probe" ]; then
            git ls-files --error-unmatch -- "$probe" >/dev/null 2>&1 || classify_present "$probe"
            break
        fi
        case "$probe" in */*) probe="${probe%/*}" ;; *) probe="" ;; esac
    done
done < "$TMP/added_dirs"
sort -u -o "$TMP/collisions" "$TMP/collisions"

COUNT="$(grep -c . "$TMP/collisions" || true)"

# Pinned language in an edited CLAUDE.md (the setting now lives in .fmlab/user.local.json).
PINNED_LANGUAGE=""
if grep -Fxq "$(printf 'edited\tCLAUDE.md')" "$TMP/collisions"; then
    PINNED_LANGUAGE="$(sed -n 's/.*`language: \([A-Za-z][A-Za-z-]*\)`.*/\1/p' CLAUDE.md | head -n 1)"
    [ "$PINNED_LANGUAGE" = "auto" ] && PINNED_LANGUAGE=""
fi

describe() {  # $1 = reason
    case "$1" in
        edited)    echo "changed here, the update brings a new version" ;;
        untracked) echo "your own file, the update adds one with this name" ;;
        ignored)   echo "your own file, the update would overwrite it without asking" ;;
    esac
}

info "Update fm-lab: version $OLD_VERSION → $NEW_VERSION"
if [ "$COUNT" = "0" ]; then
    echo "  No local changes are in the way."
else
    echo "  These files are in the way and will be saved first:"
    while IFS="$(printf '\t')" read -r reason path; do
        echo "    • $path — $(describe "$reason")"
    done < "$TMP/collisions"
    [ -n "$PINNED_LANGUAGE" ] && echo "  Your language setting '$PINNED_LANGUAGE' from CLAUDE.md moves to .fmlab/user.local.json."
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "Dry run — nothing was changed. Run the command without --dry-run to update."
    exit 0
fi

# --- Save, defuse, update ----------------------------------------------------------
json_str() {  # JSON string literal of $1
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g")"
}

set_agent_language() {  # $1 = language code → .fmlab/user.local.json (agent_language)
    local f=".fmlab/user.local.json"
    mkdir -p .fmlab
    if [ ! -s "$f" ] || [ "$(tr -d ' \t\r\n' < "$f")" = "{}" ]; then
        printf '{\n  "agent_language": "%s"\n}\n' "$1" > "$f"
    elif command -v node >/dev/null 2>&1 && node -e '
        const fs = require("fs"); const [f, v] = process.argv.slice(1);
        const d = JSON.parse(fs.readFileSync(f, "utf8")); d.agent_language = v;
        fs.writeFileSync(f, JSON.stringify(d, null, 2) + "\n");' "$f" "$1" 2>/dev/null; then
        :
    elif grep -q '"agent_language"' "$f"; then
        sed -e "s/\(\"agent_language\"[[:space:]]*:[[:space:]]*\)\"[^\"]*\"/\1\"$1\"/" "$f" > "$TMP/ul.json" && cat "$TMP/ul.json" > "$f"
    else
        awk -v v="$1" '!done && /\{/ { sub(/\{/, "{\n  \"agent_language\": \"" v "\","); done = 1 } { print }' "$f" > "$TMP/ul.json" \
            && cat "$TMP/ul.json" > "$f"
    fi
}

# Shipped unit an edited file belongs to (empty when none): the nearest folder with
# manifest.json below rest-api/templates/dashboards/ or with test.json below
# rest-api/templates/tests/; a .sql file outside a bundle is its own unit. The old
# places of shipped dashboards up to v0.9.16 count too: bundles below
# dashboards-custom/ and the queries in sql-custom/ (now single-file dashboards).
unit_of() {
    local p="$1" area marker dir
    case "$p" in
        rest-api/templates/dashboards/*)        area="rest-api/templates/dashboards";        marker="manifest.json" ;;
        rest-api/templates/dashboards-custom/*) area="rest-api/templates/dashboards-custom"; marker="manifest.json" ;;
        rest-api/templates/tests/*)             area="rest-api/templates/tests";             marker="test.json" ;;
        rest-api/templates/sql-custom/*.sql)    echo "$p"; return 0 ;;
        *) return 0 ;;
    esac
    dir="${p%/*}"
    while [ "$dir" != "$area" ] && [ -n "$dir" ]; do
        if [ -f "$dir/$marker" ]; then echo "$dir"; return 0; fi
        case "$dir" in */*) dir="${dir%/*}" ;; *) dir="" ;; esac
    done
    case "$p" in
        rest-api/templates/dashboards/*.sql) echo "$p" ;;
    esac
}

BACKUP=""
if [ "$COUNT" != "0" ]; then
    STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    BACKUP=".fmlab/update-backup/$STAMP"
    n=2
    while [ -e "$BACKUP" ]; do BACKUP=".fmlab/update-backup/$STAMP-$n"; n=$((n + 1)); done
    mkdir -p "$BACKUP"

    [ -n "$PINNED_LANGUAGE" ] && set_agent_language "$PINNED_LANGUAGE"

    entries=""
    units=""
    while IFS="$(printf '\t')" read -r reason path; do
        mkdir -p "$BACKUP/$(dirname "$path")"
        if [ "$reason" = "edited" ]; then
            # An edited shipped dashboard or test lives on as an own version: save the
            # whole unit as it is here (bundle folder, test folder or single .sql file).
            # The API picks units/ up at its next start (→ <id>-local under Custom).
            unit="$(unit_of "$path")"
            if [ -n "$unit" ] && [ ! -e "$BACKUP/units/$unit" ]; then
                mkdir -p "$BACKUP/units/$(dirname "$unit")"
                cp -pPR "$unit" "$BACKUP/units/$unit"
                units="${units:+$units, }$(json_str "$unit")"
            fi
            cp -pP "$path" "$BACKUP/$path"
            git checkout -q "$OLD" -- "$path"
            action="saved here, restored to the shipped version"
        else
            mv "$path" "$BACKUP/$path"
            # a file staged with `git add` would still block the update from the index
            git rm -q --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
            action="moved here"
        fi
        entries="${entries:+$entries,
}    { \"path\": $(json_str "$path"), \"reason\": \"$reason\", \"action\": \"$action\" }"
    done < "$TMP/collisions"

    {
        echo "{"
        echo "  \"version\": 1,"
        echo "  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"from_version\": $(json_str "$OLD_VERSION"),"
        echo "  \"to_version\": $(json_str "$NEW_VERSION"),"
        echo "  \"from_commit\": \"$OLD\","
        echo "  \"to_commit\": \"$NEW\","
        if [ -n "$PINNED_LANGUAGE" ]; then
            echo "  \"agent_language\": $(json_str "$PINNED_LANGUAGE"),"
        fi
        echo "  \"units\": [${units}],"
        echo "  \"files\": ["
        echo "$entries"
        echo "  ]"
        echo "}"
    } > "$BACKUP/update.json"
fi

if ! git merge --ff-only --quiet "$NEW"; then
    echo "" >&2
    warn "The last step of the update failed (see the git message above)."
    [ -n "$BACKUP" ] && warn "Your saved files are in $BACKUP — nothing was lost."
    exit 3
fi

# --- Done: what changed, what to do next -------------------------------------------
echo ""
success "fm-lab is now on version $NEW_VERSION."
if [ -n "$BACKUP" ]; then
    echo "  Your $COUNT saved file(s): $BACKUP/ (list: $BACKUP/update.json)"
    echo "  Edited dashboards and tests among them come back as own versions under Custom at the next start."
fi
[ -n "$PINNED_LANGUAGE" ] && echo "  Language for the AI agent: '$PINNED_LANGUAGE' (change with: bash tools/fmlab.sh language <code>)."

# Pathspec instead of `printf | grep -q`: under pipefail grep's early exit makes printf
# fail with SIGPIPE on a long file list, which hid this hint (seen with 2,800 files).
CONTAINER_CHANGES="$(git diff --name-only "$OLD" "$NEW" -- .devcontainer ':(glob)docker-compose*.yml')"
echo ""
echo "${C_BOLD}Next step — restart fm-lab so the new version runs:${C_RESET}"
if [ -n "$CONTAINER_CHANGES" ]; then
    echo "  (this release changes the container setup — the rebuild is needed)"
fi
echo "  • Docker:                 bash tools/fmlab.sh up"
echo "  • VS Code Dev Container:  Command Palette → Dev Containers: Rebuild Container"
echo "  • Native installation:    bash tools/init.sh"
exit 0
