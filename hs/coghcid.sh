#!/usr/bin/env bash
# coghcid.sh — hand a failed build to codex, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch.
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
LOG=$PWD/.coghcid.log # stdout+stderr of the codex run; outside WORK so it
# survives the trap
WORK=$PWD/.coghcid # lock dir, removed on exit

# Where to report: the pane this runs in, which is the ghciwatch pane — ghciwatch
# starts hooks in the pane it itself runs in. Empty outside tmux, so reporting is
# skipped.
TARGET=${COGHCID_TMUX_TARGET:-${TMUX_PANE:-}}

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# Take a lock: codex edits source -> reload -> this hook runs again, so without one
# every edit would spawn another codex. mkdir is atomic and portable — macOS ships
# no flock(1).
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  # `kill -0` first: it is the portable probe. BusyBox ps has no -p, so there it
  # reports a live pid as dead and every lock would read as stale. `ps -p` stays as
  # the backstop for a process we do not own, which `kill -0` cannot signal.
  if [[ -n $owner ]] && { kill -0 "$owner" 2>/dev/null || ps -p "$owner" >/dev/null 2>&1; }; then
    echo "coghcid: codex already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run: claim it in place.
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Fix GHC errors with the smallest correct edit; read ghcid.txt until All good. No sleep poll; No cabal/stack/make. Try hole _ where a type is unknown and let the reload report what GHC expects. End with exactly one line: 'FIXED: <fix>' or 'STOPPED: <why>'."

# --disable plugins/hooks drops the harness: ~10k of the ~23k input tokens, none of
# it useful for a compile error.
#
# Reasoning effort is deliberately left to config, which is `medium`. Pinning it to
# `low` cut turns 30->21 and tokens by 23%, but broke correctness: on the scenario
# whose bounds check had been deleted, codex then "restored" checkedInt64 *without*
# its range guards. That compiles, and nothing in the test suite covers it — only
# the byte-identical check caught it. Cheap reasoning is a false economy here.
FLAGS=(--disable plugins --disable hooks -m gpt-5.6-luna)

# Status goes on the status line, and nothing is typed into any pane: the
# ghciwatch pane is a TUI, so text arriving there is read as keystrokes and could
# act on the live build. This is display only.
report() {
  [[ -n $TARGET ]] || return 0
  # Right-align the message so it doesn't sit at column 0 over the window list, and
  # yellow so it stands out. Set here rather than in message-style, which would
  # restyle every message including the command prompt.
  tmux display-message -t "$TARGET" -d "$1" "#[align=right,fg=yellow]$2" 2>/dev/null || true
  # Same text again, this time where it lasts: status-right interpolates
  # #{@ghcid_status}, which the overlay above cannot do — that one dies on the next
  # key press. -w keeps it to the window the hook ran in.
  tmux set-option -w -t "$TARGET" @ghcid_status "$2" 2>/dev/null || true
}
# Show "working" the moment codex starts, and let the result below replace it. The
# delay is finite so a run that dies without reporting doesn't leave it up.
report 300000 'coghcid: fixing the build error...'

# --ephemeral leaves no session file, so there is no thread to pin and no earlier
# conversation to re-read. The errors and the prompt ride in together on stdin,
# errors first; `-` is codex's "read the prompt from stdin".
#
# --json makes codex report the run as JSONL on stdout, so the final reply is read
# from the run's own output rather than guessed at afterwards. `|& tee` merges
# stderr into stdout and logs the whole stream to .coghcid.log, so a hard failure
# is in the log rather than lost. That merge is why the parse below reads with -R +
# fromjson?: given a mixed stream, plain jq aborts on the first stderr line and
# prints nothing at all, which would leave the raw JSONL as the status line.
rc=0
out=$(printf '%s\n\n%s\n' "$(<ghcid.txt)" "$PROMPT" | codex exec "${FLAGS[@]}" --json --ephemeral -C "$PWD" -s workspace-write - |& tee "$LOG") || rc=$?

# Relay one line into the ghciwatch window, which would otherwise show nothing of
# the run. Prefer codex's own FIXED:/STOPPED: line (the prompt asks for one), then
# its last non-empty line, then the exit code. The `|| true`s below are
# load-bearing: under `set -e` with pipefail, a grep that matches nothing exits 1
# and would take the whole script with it.
final=$(jq -Rr 'fromjson? | select(.item.type == "agent_message") | .item.text' <<<"$out" 2>/dev/null | tail -1 || true)
[[ -n $final ]] || final=$out
summary=$(grep -aoE '^(FIXED|STOPPED):.*' <<<"$final" 2>/dev/null | tail -1 || true)
if [[ -z ${summary:-} ]]; then
  summary=$(grep -av '^[[:space:]]*$' <<<"$final" 2>/dev/null | tail -1 || true)
fi
# Cap the whole status text, prefix included — capping the summary alone leaves the
# stored value 9 chars longer than the status line's budget.
summary=$(printf '%s' "coghcid: ${summary:-codex exited $rc}" | tr -d '\r' | tr '\n' ' ' | cut -c1-160)

report "${COGHCID_STATUS_MS:-60000}" "$summary"

exit "$rc"
