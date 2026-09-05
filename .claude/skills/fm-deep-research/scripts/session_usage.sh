#!/usr/bin/env bash
# session_usage.sh — run metrics of the current Claude Code session for the report (B.7).
# DuckDB-only: resolves the transcript path and runs session_usage.sql with -markdown output.
#
# Usage:  bash .claude/skills/fm-deep-research/scripts/session_usage.sh --since <ISO> [--until <ISO>]
#              [--marks "R0=<ISO>,R1=<ISO>,…"] [--session <id>] [--file <transcript.jsonl>]
# Transcript: ~/.claude/projects/<encoded cwd>/$CLAUDE_CODE_SESSION_ID.jsonl (fallback: newest
# file there). Timestamps UTC ISO-8601 (`date -u +%FT%TZ`).
# Exit: 0 ok · 2 usage · 3 no duckdb · 4 transcript not found
# bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SINCE=""; UNTIL=""; MARKS=""; SESSION=""; FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) shift; SINCE="${1:-}" ;;      --since=*) SINCE="${1#--since=}" ;;
    --until) shift; UNTIL="${1:-}" ;;      --until=*) UNTIL="${1#--until=}" ;;
    --marks) shift; MARKS="${1:-}" ;;      --marks=*) MARKS="${1#--marks=}" ;;
    --session) shift; SESSION="${1:-}" ;;  --session=*) SESSION="${1#--session=}" ;;
    --file) shift; FILE="${1:-}" ;;        --file=*) FILE="${1#--file=}" ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SINCE" ] || { echo "usage: session_usage.sh --since <ISO> [--until <ISO>] [--marks …] [--session <id>] [--file <jsonl>]" >&2; exit 2; }
DUCKDB="$(bash "$SCRIPT_DIR/../../_shared/scripts/resolve_duckdb_bin.sh")"
[ -z "$DUCKDB" ] && { echo "ERROR: duckdb binary not found." >&2; exit 3; }
if [ -z "$FILE" ]; then
  ENCODED="$(pwd | sed 's/[^A-Za-z0-9]/-/g')"
  BASE="$HOME/.claude/projects/$ENCODED"
  SID="${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$SID" ] && [ -f "$BASE/$SID.jsonl" ]; then
    FILE="$BASE/$SID.jsonl"
  else
    FILE="$(ls -t "$BASE"/*.jsonl 2>/dev/null | head -n1)"
  fi
fi
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "ERROR: transcript not found (set CLAUDE_CODE_SESSION_ID or pass --file)." >&2; exit 4; }
UNTIL_SQL="NULL"; [ -n "$UNTIL" ] && UNTIL_SQL="'$UNTIL'"
"$DUCKDB" -markdown \
  -c "SET VARIABLE transcript = '$FILE'; SET VARIABLE since = '$SINCE'; SET VARIABLE until = $UNTIL_SQL; SET VARIABLE marks = '$MARKS';" \
  -c ".read $SCRIPT_DIR/session_usage.sql"
