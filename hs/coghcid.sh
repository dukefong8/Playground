#!/usr/bin/env bash
# coghcid.sh — hand a failed build to codex, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch. For the full conversation:
#   codex exec resume "$(cat .coghcid.session)" 'what did you change so far'
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
WORK=$PWD/.coghcid            # lock, removed on exit
SESSION=$PWD/.coghcid.session # this project's codex thread, kept between runs

# Where to report: the pane this runs in, which is the ghciwatch pane — ghciwatch
# starts hooks in the pane it itself runs in. Empty outside tmux, so reporting is
# skipped.
TARGET=${COGHCID_TMUX_TARGET:-${TMUX_PANE:-}}

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# Take a lock: codex edits source -> reload -> this hook runs again, so without one
# every edit would spawn another codex. mkdir is atomic, and `ps -p` beats
# `kill -0`, which reads a live lock as stale when it cannot signal a process we do
# not own.
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  if [[ -n $owner ]] && ps -p "$owner" >/dev/null 2>&1; then
    echo "coghcid: codex already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run: claim it in place.
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Make minimal edit fix error in ghcid.txt STOP when ghcid.txt says All good. Use hole _ where the unknown goes and let the reload report what GHC expects there (expected type, relevant bindings). Use ghci -e ':hoogle TYPE' / ':hdoc NAME', and :add <file> before :browse/:info/:type/:instances (pipe: printf ':add src/Foo.hs\n:info NAME\n' | ghci); qualify other names as Module.name. DO NOT run cabal/stack/make commands! End your reply with exactly one line (be concise), either 'FIXED: <the fix you made>' or 'STOPPED: <explain why>'."

# --disable plugins/hooks drops the harness: ~10k of the ~23k input tokens, none of
# it useful for a compile error. The compaction limit is a token count, so it does
# not compare to pi's window-based setting; 48k is ~18% of luna's 272k window,
# where codex's own ~95% default would never fire at our sizes. body_after_prefix
# counts conversation rather than the ~12k harness.
#
# Reasoning effort is deliberately left to config, which is `medium`. Pinning it to
# `low` cut turns 30->21 and tokens by 23%, but broke correctness: on the scenario
# whose bounds check had been deleted, codex then "restored" checkedInt64 *without*
# its range guards. That compiles, and nothing in the test suite covers it — only
# the byte-identical check caught it. Cheap reasoning is a false economy here.
FLAGS=(--disable plugins --disable hooks -m gpt-5.6-luna
  -c model_auto_compact_token_limit=48000 -c model_auto_compact_token_limit_scope='"body_after_prefix"')

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
# Show "working" the moment codex starts and leave it up until the result below
# replaces it — `-d 0` is no timer, so a slow run is never left looking idle.
report 0 'coghcid: fixing the build error...'

# Whether a pinned thread was created in this directory. `codex exec resume`
# filters sessions by cwd, so a pin from elsewhere can never be resumed here.
session_is_local() {
  local f
  f=$(find "$HOME/.codex/sessions" -name "rollout-*$1*.jsonl" 2>/dev/null | head -1)
  [[ -n $f ]] || return 1
  grep -m1 '"type":"session_meta"' "$f" 2>/dev/null |
    jq -e --arg cwd "$PWD" '.payload.cwd == $cwd' >/dev/null 2>&1
}

# --json makes codex report the run as JSONL on stdout: `thread.started` carries
# the thread id and the last `agent_message` is the final reply, so both are read
# from the run's own output rather than guessed at afterwards. Stderr is kept
# separate so stdout stays parseable, and kept in a file because that is where
# hard failures appear.
#
# The prompt goes in on stdin exactly as pighcid.sh hands it over, so the two hooks
# differ only in which agent they drive. `-` is codex's "read the prompt from stdin".
rc=0
out=
err=$WORK/stderr
: >"$err"

# A pin from another directory can never resume here, because `exec resume`
# filters by cwd. Say so and start fresh rather than letting the create branch
# quietly rewrite the pin for whatever directory we happen to be in.
if [[ -s $SESSION ]] && ! session_is_local "$(<"$SESSION")"; then
  echo "coghcid: pinned thread $(<"$SESSION") was not created in $PWD — starting a fresh one" >&2
  rm -f "$SESSION"
fi

if [[ -s $SESSION ]]; then
  out=$(printf '%s\n' "$PROMPT" | codex exec resume "${FLAGS[@]}" --json "$(<"$SESSION")" - 2>"$err") || rc=$?
fi

# First run, or the thread is gone: create it, then pin the id codex reports.
if [[ ! -s $SESSION || $rc -ne 0 ]]; then
  rc=0
  out=$(printf '%s\n' "$PROMPT" | codex exec "${FLAGS[@]}" --json -C "$PWD" -s workspace-write - 2>"$err") || rc=$?
  id=$(jq -r 'select(.type == "thread.started") | .thread_id' <<<"$out" 2>/dev/null | head -1 || true)
  if [[ -n $id ]]; then
    printf '%s\n' "$id" >"$SESSION"
  fi
fi

# Relay one line into the ghciwatch window, which would otherwise show nothing of
# the run. Prefer codex's own FIXED:/STOPPED: line (the prompt asks for one), then
# its last non-empty line, then the exit code. The `|| true`s below are
# load-bearing: under `set -e` with pipefail, a grep that matches nothing exits 1
# and would take the whole script with it.
final=$(jq -r 'select(.item.type == "agent_message") | .item.text' <<<"$out" 2>/dev/null | tail -1 || true)
[[ -n $final ]] || final=$(cat "$err" 2>/dev/null || true)
summary=$(grep -aoE '^(FIXED|STOPPED):.*' <<<"$final" 2>/dev/null | tail -1 || true)
if [[ -z ${summary:-} ]]; then
  summary=$(grep -av '^[[:space:]]*$' <<<"$final" 2>/dev/null | tail -1 || true)
fi
summary=$(printf '%s' "${summary:-codex exited $rc}" | tr -d '\r' | tr '\n' ' ')

report "${COGHCID_STATUS_MS:-30000}" "coghcid: $summary"

exit "$rc"
