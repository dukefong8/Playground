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
  # Stale lock from a killed run: claim it in place.
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Fix GHC errors with the smallest correct edit; read ghcid.txt until All good. If two consecutive edits leave an error around the same line, STOP. Never add pragmas or diagnostic splices. Try hole _ where a type is unknown and let the reload report what GHC expects. End with exactly one line: 'FIXED: <fix>' or 'STOPPED: <why>'."

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
# Show "working" the moment pi starts, and let the result below replace it. The
# delay is finite so a run that dies without reporting doesn't leave it up.
report 300000 'pighcid: fixing the build error...'

# --tools read,edit is the whole toolset: pi reads the error and the code, edits, and
# reads again to confirm — with no shell to block in. --no-extensions drops the
# web-access tools it never calls. The errors and the prompt ride in together on
# stdin, errors first.
#
# Capture pi's reply: it prints only its final message, so this stays small. `|&
# tee` merges stderr (where pi puts warnings and hard failures) into stdout and
# logs the whole stream to .pighcid.log.
rc=0
out=$(printf '%s\n\n%s\n' "$(<ghcid.txt)" "$PROMPT" |
  pi -p --no-extensions --tools read,edit,find,grep \
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
report "${PIGHCID_STATUS_MS:-60000}" "$summary"

exit "$rc"
