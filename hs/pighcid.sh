#!/usr/bin/env bash
# pighcid.sh — hand a failed build to pi, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch.
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
LOG=$PWD/.pighcid.log # stdout+stderr of the pi run; outside WORK so the trap
# cannot remove it
WORK=$PWD/.pighcid # lock dir, removed on exit

# Where to report: the pane this runs in, which is the ghciwatch pane — ghciwatch
# starts hooks in the pane it itself runs in. Empty outside tmux, so reporting is
# skipped.
TARGET=${PIGHCID_TMUX_TARGET:-${TMUX_PANE:-}}

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# Take a lock: pi edits source -> reload -> this hook runs again, so without one
# every edit would spawn another pi. mkdir is atomic and portable — macOS ships no
# flock(1).
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  # `kill -0` first: it is the portable probe. BusyBox ps has no -p, so there it
  # reports a live pid as dead and every lock would read as stale. `ps -p` stays as
  # the backstop for a process we do not own, which `kill -0` cannot signal.
  if [[ -n $owner ]] && { kill -0 "$owner" 2>/dev/null || ps -p "$owner" >/dev/null 2>&1; }; then
    echo "pighcid: pi already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run. Steal it with `mv`, which only one process can win —
  # claiming it in place would let two hooks that both read the same dead pid fall through
  # together and start two pis, and the loser's exit trap would then delete the winner's
  # lock, admitting a third. `async:` hooks are never serialised by ghciwatch, so the
  # overlap this guards against is real.
  mv -- "$WORK" "$WORK.stale.$$" 2>/dev/null || exit 0
  rm -rf -- "$WORK.stale.$$"
  mkdir "$WORK" 2>/dev/null || exit 0
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Fix GHC errors with minimal correct edits; read ghcid.txt until it outputs 'All good'. Choose the fix from 'Valid hole fits' first, then try other fixes as needed. CRITICAL DIRECTIVE: once two consecutive edit commands leave errors on the exact same line number, do not run any further tools or commands. End with exactly one line: 'FIXED: <one-line summary of what you changed>' on success, or 'STOPPED: <reason>' if you stopped early."

# Status goes on the status line, and nothing is typed into any pane: the
# ghciwatch pane is a TUI, so text arriving there is read as keystrokes and could
# act on the live build. This is display only.
report() { # $1 = lifetime in ms, $2 = message, $3 = overlay colour, $4 = "clear" to retire after $1
  [[ -n $TARGET ]] || return 0
  # Overlay: right-aligned and coloured; -C keeps the pane redrawing, and no -N so
  # keys still work (a key just clears it).
  tmux display-message -C -t "$TARGET" -d "$1" "#[align=right,fg=${3:-white}]$2" 2>/dev/null || true
  # Persistent copy in status-right, which a key press cannot dismiss.
  tmux set-option -w -t "$TARGET" @ghcid_status "$2" 2>/dev/null || true
  # Only the final report retires it: the "working" line is meant to be replaced by
  # the summary, so a timer armed for it would just clear that summary early.
  [[ -n ${4:-} ]] || return 0
  tmux run-shell -b -d "$(($1 / 1000))" -t "$TARGET" -C \
    "set-option -w -t $TARGET -u @ghcid_status" 2>/dev/null || true
}
# Show "working" the moment pi starts; the result below replaces it. This call arms
# no timer, so a run that dies leaves the line up until the next report.
report 30000 'pighcid: fixing the build error...'

# The errors and the prompt ride in together on stdin, errors first.
#
# Capture pi's reply: it prints only its final message, so this stays small. `|&
# tee` merges stderr (where pi puts warnings and hard failures) into stdout and
# logs the whole stream to .pighcid.log.
rc=0
out=$(printf '%s\n\n%s\n' "$(<"$GHCID")" "$PROMPT" |
  pi -p --tools read,edit,find,git \
    --provider deepseek --model deepseek-flash --thinking low |&
  tee "$LOG") || rc=$?

# Relay one line into the ghciwatch window, which would otherwise show nothing of
# the run. Prefer pi's own FIXED:/STOPPED: line (the prompt asks for one), then its
# last non-empty line, then the exit code. The `|| true`s below are load-bearing:
# under `set -e` with pipefail, a grep that matches nothing exits 1 and would take
# the whole script with it.
summary=$(grep -aoE '^(FIXED|STOPPED):.*' <<<"$out" 2>/dev/null | tail -1 || true)
if [[ -z ${summary:-} ]]; then
  summary=$(grep -av '^[[:space:]]*$' <<<"$out" 2>/dev/null | tail -1 || true)
fi
# Cap the length for the status line: pi's last line is not guaranteed short.
# cut -c counts characters, so it cannot split a multi-byte one.
# Cap the whole status text, prefix included — capping the summary alone leaves the
# stored value 9 chars longer than the status line's budget.
summary=$(printf '%s' "pighcid: ${summary:-pi exited $rc}" | tr -d '\r' | tr '\n' ' ' | cut -c1-160)
report "${PIGHCID_STATUS_MS:-60000}" "$summary" yellow clear

exit "$rc"
