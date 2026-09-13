#!/usr/bin/env bash
# pighcid.sh — hand a failed build to pi, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch. For the full conversation
# (no `?` — the container shell globs unquoted arguments):
#   pi -p --session-id pighcid 'what did you change so far'
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
WORK=$PWD/.pighcid # lock, removed on exit

# Where to report: the pane this runs in, which is the ghciwatch pane — ghciwatch
# starts hooks in the pane it itself runs in. Empty outside tmux, so reporting is
# skipped.
TARGET=${PIGHCID_TMUX_TARGET:-${TMUX_PANE:-}}

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# Take a lock: pi edits source -> reload -> this hook runs again, so without one
# every edit would spawn another pi. mkdir is atomic, and `ps -p` beats `kill -0`,
# which reads a live lock as stale when it cannot signal a process we do not own.
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  if [[ -n $owner ]] && ps -p "$owner" >/dev/null 2>&1; then
    echo "pighcid: pi already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run: claim it in place.
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Make minimal edit to fix error in ghcid.txt STOP when ghcid.txt says All good. To learn more context, put a hole _ where the unknown goes and let the reload report what GHC expects there (expected type, relevant bindings). Use ghci -e ':hoogle NAME' / ':hdoc NAME', and :add <file> before :browse/:info/:type/:instances (pipe: printf ':add src/Foo.hs\n:info NAME\n' | ghci); qualify other names as Module.name. DO NOT run cabal/stack/make commands! End your reply with exactly one line, either 'FIXED: <the fix you made>' or 'STOPPED: <what you changed and why the error remains>'."

# Status goes on the status line, and nothing is typed into any pane: the
# ghciwatch pane is a TUI, so text arriving there is read as keystrokes and could
# act on the live build. This is display only.
report() {
  [[ -n $TARGET ]] || return 0
  # Right-align the message so it doesn't sit at column 0 over the window list, and
  # yellow so it stands out. Set here rather than in message-style, which would
  # restyle every message including the command prompt.
  tmux display-message -t "$TARGET" -d "$1" "#[align=right,fg=yellow]$2" 2>/dev/null || true
}
# Show "working" the moment pi starts and leave it up until the result below
# replaces it — `-d 0` is no timer, so a slow run is never left looking idle.
report 0 'pighcid: fixing the build error...'

# --session-id pins one conversation for this project, so a retry sees what the
# last attempt tried. --no-extensions drops the web-access tools a compile fix
# never calls; AGENTS.md stays, it carries the build and test rules.
#
# Capture pi's reply: it prints only its final message, so this stays small. stderr
# is merged because that is where pi puts warnings and hard failures.
rc=0
out=$(printf '%s\n' "$PROMPT" | pi -p --session-id pighcid \
  --provider deepseek --model deepseek-v4-flash --thinking low \
  --no-extensions 2>&1) || rc=$?

# Relay one line into the ghciwatch window, which would otherwise show nothing of
# the run. Prefer pi's own FIXED:/STOPPED: line (the prompt asks for one), then its
# last non-empty line, then the exit code. The `|| true`s below are load-bearing:
# under `set -e` with pipefail, a grep that matches nothing exits 1 and would take
# the whole script with it.
summary=$(grep -aoE '^(FIXED|STOPPED):.*' <<<"$out" 2>/dev/null | tail -1 || true)
if [[ -z ${summary:-} ]]; then
  summary=$(grep -av '^[[:space:]]*$' <<<"$out" 2>/dev/null | tail -1 || true)
fi
summary=$(printf '%s' "${summary:-pi exited $rc}" | tr -d '\r' | tr '\n' ' ')

report "${PIGHCID_STATUS_MS:-30000}" "pighcid: $summary"

exit "$rc"
