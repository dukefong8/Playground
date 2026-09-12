#!/usr/bin/env bash
# coghci.sh — hand a failed build to codex, non-interactively.
#
# Hooked up by `make dev` as a ghciwatch --after-reload-shell command: test hooks
# are skipped when a reload fails, which is the only case we care about.
# ghciwatch discards hook output, so to see what a run did use:
#   codex exec resume "$(cat .coghci.session)" "what did you change?"
set -euo pipefail

cd "$(dirname "$0")"

GHCID=${GHCID:-ghcid.txt}
WORK=$PWD/.coghci            # lock, removed on exit
SESSION=$PWD/.coghci.session # this project's codex thread, kept between runs

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# codex edits source -> reload -> this hook runs again, so take a lock or every
# edit spawns another codex. mkdir is atomic; `ps -p` and not `kill -0`, which
# fails with EPERM on a process we don't own and reads a live lock as stale.
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  if [[ -n $owner ]] && ps -p "$owner" >/dev/null 2>&1; then
    echo "coghci: codex already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run: claim it in place.
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"
PROMPT="Make smallest edit to fix error in ghcid.txt **UNTIL ghcid.txt says All good**. For more context, use ghci -e ':hoogle NAME' / ':hdoc NAME', and :add <file> before :browse/:info/:type/:instances (pipe: printf ':add src/Foo.hs\n:info NAME\n' | ghci); qualify other names as Module.name. STOP after three turns. DO NOT run cabal/stack/make commands!"

# Disable the plugin/hook harness: ~10k of the ~23k input tokens, none of it
# useful for a compile error. (--ignore-user-config saves only ~640 more.)
# Compact when the thread passes 48k tokens (~18% of luna's 272k window; codex's
# own ~95% default never fires at our sizes). body_after_prefix excludes the
# ~12k harness, so this counts conversation, not the whole request.
FLAGS=(--disable plugins --disable hooks -m gpt-5.6-luna
  -c model_auto_compact_token_limit=48000 -c model_auto_compact_token_limit_scope='"body_after_prefix"')

# Resume this project's single thread, so a retry knows what the last attempt
# tried; sessions can't be named, so the uuid is pinned. `</dev/null` because on
# a non-TTY stdin codex blocks waiting for a prompt and would hang the lock.
if [[ -s $SESSION ]] && codex exec resume "${FLAGS[@]}" "$(<"$SESSION")" "$PROMPT" </dev/null; then
  exit 0
fi

# First run, or the thread is gone: create it, keeping output in memory. Only
# overwrite the pin if we got an id, so a failed run can't wipe it.
out=$(codex exec "${FLAGS[@]}" -C "$PWD" -s workspace-write "$PROMPT" </dev/null 2>&1) || true
id=$(grep -aoE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' <<<"$out" | head -1)
if [[ -n $id ]]; then
  printf '%s\n' "$id" >"$SESSION"
fi
