#!/usr/bin/env bash
# pighcid.sh — hand a failed build to pi, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch. For the full conversation
# (no `?` — the container shell globs unquoted arguments):
#   pi -p -c 'what did you change so far'   # -c = newest session for this cwd
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
WORK=$PWD/.pighcid        # lock, removed on exit
NOTES=$PWD/.pighcid-notes # per-run digest; the only memory between runs

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

# ghcid.txt reads "All good" again the moment pi fixes it, so the failing
# line has to be captured before the handover, not after.
# The hook can fire while ghcid.txt still holds a placeholder rather than the
# error, so poll briefly for a line carrying a real source location.
errline=
for _ in $(seq 1 15); do
  errline=$(grep -aE '[^ 	]+\.hs:[0-9]+:[0-9]+.*error:' "$GHCID" 2>/dev/null | head -n 1 | cut -c1-90 || true)
  [[ -n $errline ]] && break
  sleep 0.2
done
# ghcid.txt lists warnings alongside errors, and the first source location in the
# file is often a warning (a missing method, say) rather than the thing that broke
# the build. Keying the digest on a warning misdescribes what was wrong, so prefer
# an actual `error:` line and only fall back to any location if there is none.
if [[ -z $errline ]]; then
  errline=$(grep -aE '[^[:space:]]+\.hs:[0-9]+:[0-9]+' "$GHCID" 2>/dev/null | head -n 1 | cut -c1-90 || true)
fi

# Sessions rotate, so this digest is the only memory between runs. Five lines
# is deliberate: a stale or wrong line is worse than none.
recent=$(tail -n 5 "$NOTES" 2>/dev/null || true)

PROMPT="Fix the error ghcid.txt reports with the smallest correct edit; poll with sleep 3; cat ghcid.txt until All good. Use hole _ where a type is unknown and let the reload report what GHC expects. No cabal/stack/make. End with exactly one line: 'FIXED: <fix>' or 'STOPPED: <why>'."
if [[ -n ${recent:-} ]]; then
  PROMPT+=$(printf '\n\nEarlier attempts on this project, newest last. Do not repeat an approach that already failed:\n%s' "$recent")
fi

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

# Each run gets a fresh session: the pinned conversation made every run
# re-read all earlier ones, and per-turn cache reads grew with the session's
# length (~70k tokens/turn at 411 records, ~85k at 495). Continuity comes from
# the NOTES digest instead of a replayed transcript.
# --no-extensions drops the web-access tools a compile fix never calls;
# AGENTS.md stays, it carries the build and test rules.
#
# Capture pi's reply: it prints only its final message, so this stays small. stderr
# is merged because that is where pi puts warnings and hard failures.
rc=0
out=$(printf '%s\n' "$PROMPT" | pi -p --session-id "pighcid-$(date +%s)" \
  --provider deepseek --model deepseek-flash --thinking low \
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
# Cap the length: this line is prepended to every future prompt, and pi's last
# line is not guaranteed short. cut -c counts characters, so it cannot split a
# multi-byte one.
summary=$(printf '%s' "${summary:-pi exited $rc}" | tr -d '\r' | tr '\n' ' ' | cut -c1-200)

# One digest line per run, oldest dropped past 20. errline keys it to the
# failure, so a later run can tell whether it faces the same problem.
if [[ -n ${summary:-} ]]; then
  printf '%s  %s  ->  %s\n' "$(date '+%m-%d %H:%M')" "${errline:-no-line}" "$summary" >>"$NOTES"
  tail -n 20 "$NOTES" >"$NOTES.tmp" && mv -- "$NOTES.tmp" "$NOTES"
fi
report "${PIGHCID_STATUS_MS:-30000}" "pighcid: $summary"

exit "$rc"
