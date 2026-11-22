#!/usr/bin/env bash
# tests/test-audio-resync.sh: modules/57-audio-resync.sh (the login resync script
# and its autostart entry) against a temporary HOME. Never touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2251,SC2319,SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
make_fakes "$WORK/bin"
HOME_DIR="$WORK/home"
SRC="$REPO_ROOT/files/audio-resync"
SCRIPT="$HOME_DIR/.local/bin/cosmic-audio-resync"
DESKTOP="$HOME_DIR/.config/autostart/cosmic-audio-resync.desktop"
OLD_SH="$HOME_DIR/.local/bin/fix-cosmic-audio.sh"
OLD_DESKTOP="$HOME_DIR/.config/autostart/fix-cosmic-audio.desktop"

failures=0
rg_n() { grep -c "^$1" "$FAKE_STATE/proc.log" 2>/dev/null || true; }
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR"
  : >"$FAKE_STATE/installed"
}

# ar <install.sh args...>
ar() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only audio-resync "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata and shipped data -----------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^audio-resync +no ' <<<"$out" >/dev/null
check "metadata: audio-resync is a default (not opt-in) module" $?
bash -n "$SRC/cosmic-audio-resync"
check "the shipped script parses" $?
grep -q 'cosmic-settings-daemon' "$SRC/cosmic-audio-resync" && grep -q 'cosmic-panel' "$SRC/cosmic-audio-resync"
check "the script restarts cosmic-settings-daemon and then the panel" $?
grep -qx 'OnlyShowIn=COSMIC;' "$SRC/cosmic-audio-resync.desktop.in"
check "the autostart entry is limited to COSMIC (OnlyShowIn=COSMIC;)" $?
! grep -rqi 'eos' "$SRC"
check "no reference-repo name is left in the shipped files" $?


# --- execution of the shipped script with fake pkill/pgrep/setsid -----------------------------
# The fakes keep one pid file per process under $FAKE_STATE/procs; pkill removes the
# pids and, like cosmic-session, respawns the process with a new pid unless
# FAKE_NO_RESPAWN_<DAEMON|PANEL> is set. Every call is logged to proc.log.
run_script_fakes() {
  local b="$WORK/fakebin"
  rm -rf -- "$b" "$FAKE_STATE/procs" "$FAKE_STATE/proc.log"
  mkdir -p "$b" "$FAKE_STATE/procs"
  cat >"$b/pgrep" <<'EOS'
#!/bin/sh
echo "pgrep $*" >>"$FAKE_STATE/proc.log"
case "$*" in *cosmic-settings-daemon*) k=daemon ;; *cosmic-panel*) k=panel ;; *) exit 1 ;; esac
[ -s "$FAKE_STATE/procs/$k" ] || exit 1
cat "$FAKE_STATE/procs/$k"
EOS
  cat >"$b/pkill" <<'EOS'
#!/bin/sh
echo "pkill $*" >>"$FAKE_STATE/proc.log"
case "$*" in *cosmic-settings-daemon*) k=daemon ;; *cosmic-panel*) k=panel ;; *) exit 1 ;; esac
[ -s "$FAKE_STATE/procs/$k" ] || exit 1
: >"$FAKE_STATE/procs/$k"
eval "norespawn=\${FAKE_NO_RESPAWN_$(echo "$k" | tr a-z A-Z):-}"
[ -n "$norespawn" ] || echo "$(( $(cat "$FAKE_STATE/pidseq" 2>/dev/null || echo 1000) + 1 ))" | tee "$FAKE_STATE/pidseq" >"$FAKE_STATE/procs/$k"
EOS
  cat >"$b/setsid" <<'EOS'
#!/bin/sh
echo "setsid $*" >>"$FAKE_STATE/proc.log"
EOS
  printf '#!/bin/sh\nexit 0\n' >"$b/cosmic-settings-daemon"
  cat >"$b/sleep" <<'EOS'
#!/bin/sh
echo "sleep $*" >>"$FAKE_STATE/proc.log"
EOS
  chmod +x "$b"/*
  echo 100 >"$FAKE_STATE/procs/daemon"
  echo 200 >"$FAKE_STATE/procs/panel"
}
# rs <env...>: run the shipped script in the fake environment.
rs() {
  rc=0
  env "$@" PATH="$WORK/fakebin:$PATH" RESYNC_DELAY=0 RESYNC_TICK=0 RESYNC_WAIT=3 RESYNC_RESPAWN=2 "$SRC/cosmic-audio-resync" >"$WORK/rs.out" 2>&1 </dev/null || rc=$?
}
reset_state
run_script_fakes
rs XDG_CURRENT_DESKTOP=COSMIC
[[ "$rc" == 0 ]] && [[ "$(rg_n pkill)" == 2 ]]
check "script: in a COSMIC session it restarts the daemon and the panel (two pkill calls), exit 0" $?
[[ "$(grep -n '^pkill' "$FAKE_STATE/proc.log" | head -n 1)" == *cosmic-settings-daemon* && "$(grep '^pkill' "$FAKE_STATE/proc.log" | tail -n 1)" == *cosmic-panel* ]]
check "script: the daemon is restarted first, then the panel" $?
[[ "$(rg_n setsid)" == 0 ]] && [[ ! -s "$WORK/rs.out" ]]
check "script: a daemon the session respawns is not started by hand; nothing is logged when all respawn" $?
grep -q '^sleep 0$' "$FAKE_STATE/proc.log"
check "script: RESYNC_DELAY=0 means an immediate start (sleep 0)" $?
run_script_fakes
rs XDG_CURRENT_DESKTOP=GNOME
[[ "$rc" == 0 && ! -s "$FAKE_STATE/proc.log" ]]
check "script: outside COSMIC it exits 0 before touching any process" $?
run_script_fakes
rs XDG_CURRENT_DESKTOP=
[[ "$rc" == 0 && ! -s "$FAKE_STATE/proc.log" ]]
check "script: with no XDG_CURRENT_DESKTOP it exits 0 before touching any process" $?
run_script_fakes
rs XDG_CURRENT_DESKTOP=pop:COSMIC
[[ "$rc" == 0 ]] && [[ "$(rg_n pkill)" == 2 ]]
check "script: a colon separated COSMIC value is accepted" $?
run_script_fakes
: >"$FAKE_STATE/procs/daemon"
rs XDG_CURRENT_DESKTOP=COSMIC
[[ "$rc" == 0 && "$(rg_n pkill)" == 0 && "$(rg_n setsid)" == 0 ]] && grep -q 'not running' "$WORK/rs.out" && [[ "$(rg_n pgrep)" -le 6 ]]
check "script: a daemon that never appears is waited for a bounded time, then nothing is killed or started" $?
run_script_fakes
: >"$FAKE_STATE/procs/panel"
rs XDG_CURRENT_DESKTOP=COSMIC
[[ "$rc" == 0 && "$(rg_n pkill)" == 0 ]] && grep -q 'cosmic-panel is not running' "$WORK/rs.out"
check "script: no panel at all means no restart (bounded wait, logged)" $?
run_script_fakes
rs XDG_CURRENT_DESKTOP=COSMIC FAKE_NO_RESPAWN_PANEL=1
[[ "$rc" == 0 ]] && grep -q 'cosmic-panel did not come back' "$WORK/rs.out" && [[ "$(rg_n setsid)" == 0 ]]
check "script: a panel that does not respawn within the bound is logged, never started by hand, exit 0" $?
run_script_fakes
rs XDG_CURRENT_DESKTOP=COSMIC FAKE_NO_RESPAWN_DAEMON=1
[[ "$rc" == 0 && "$(rg_n pkill)" == 2 && "$(rg_n setsid)" == 1 ]] && grep -q '^setsid -f cosmic-settings-daemon' "$FAKE_STATE/proc.log" &&
  grep -q 'starting it' "$WORK/rs.out" && grep -q 'did not start' "$WORK/rs.out"
check "script: a daemon the session does not respawn is started once by the script (COSMIC 1.11), then the panel is restarted; a daemon that still does not start is logged" $?

# --- dry-run --------------------------------------------------------------------------------
reset_state
ar --dry-run
[[ "$rc" == 0 && -z "$(find "$HOME_DIR" -type f 2>/dev/null)" ]] && grep -q 'cosmic-audio-resync' "$WORK/out"
check "dry-run: exit 0, no file written, the install is reported" $?

# --- fresh run ------------------------------------------------------------------------------
reset_state
ar
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
cmp -s "$SRC/cosmic-audio-resync" "$SCRIPT" && [[ "$(stat -c %a "$SCRIPT")" == 755 ]]
check "script: installed to ~/.local/bin, mode 0755" $?
[[ -f "$DESKTOP" && "$(stat -c %a "$DESKTOP")" == 644 ]] &&
  grep -qx "Exec=$HOME_DIR/.local/bin/cosmic-audio-resync" "$DESKTOP" && ! grep -q '@HOME@' "$DESKTOP"
check "autostart: rendered with the absolute path of the script" $?
grep -qx 'NoDisplay=true' "$DESKTOP" && grep -qx 'Type=Application' "$DESKTOP"
check "autostart: a hidden application entry" $?
[[ ! -s "$FAKE_STATE/systemctl.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "no unit is enabled and no package is installed (XDG autostart only)" $?

# --- second run ---------------------------------------------------------------------------------
ar
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "second run: total changes: 0" $?

# --- a changed script is restored with a backup -------------------------------------------------
printf '#!/bin/sh\necho mine\n' >"$SCRIPT"
ar
cmp -s "$SRC/cosmic-audio-resync" "$SCRIPT" && compgen -G "$SCRIPT.bak.*" >/dev/null
check "drift: an edited script is restored and the edit is kept as .bak.<timestamp>" $?

# --- legacy files ------------------------------------------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/.config/autostart"
printf '#!/bin/sh\n' >"$OLD_SH"
printf '[Desktop Entry]\nExec=%s\n' "$OLD_SH" >"$OLD_DESKTOP"
ar
[[ "$rc" == 0 && ! -e "$OLD_SH" && ! -e "$OLD_DESKTOP" ]] && compgen -G "$OLD_SH.bak.*" >/dev/null && compgen -G "$OLD_DESKTOP.bak.*" >/dev/null
check "legacy: the hand-made fix-cosmic-audio files are removed with backups" $?
ar
grep -q 'total changes: 0' "$WORK/out"
check "legacy: a second run changes nothing" $?

# --- files owned by someone else (never through sudo) ------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/.config/autostart"
printf '#!/bin/sh\necho theirs\n' >"$SCRIPT"
printf '#!/bin/sh\n' >"$OLD_SH"
FAKE_NOT_OWNED="$SCRIPT:$OLD_SH" ar
[[ "$rc" == 0 && "$(sed -n 2p "$SCRIPT")" == 'echo theirs' && -e "$OLD_SH" ]] && grep -q '\[warn\].*not owned' "$WORK/out" &&
  ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log" 2>/dev/null
check "ownership: a script and a legacy file owned by someone else are skipped with a warning, no sudo, nothing removed" $?
reset_state
mkdir -p "$HOME_DIR/.local" "$WORK/outside"
ln -s "$WORK/outside" "$HOME_DIR/.local/bin"
ar
[[ "$rc" == 0 && -z "$(find "$WORK/outside" -type f 2>/dev/null)" ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a bin directory linked outside the home directory is not written through" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
