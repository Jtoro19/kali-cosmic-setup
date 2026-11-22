#!/usr/bin/env bash
# tests/test-mic-agc.sh: modules/83-mic-agc.sh (the PipeWire rule that blocks
# microphone volume changes from browsers and Electron apps) against a fake
# systemctl and a temporary HOME. Never touches the real system.
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
SRC="$REPO_ROOT/files/mic-agc/20-block-mic-agc.conf"
DIR="$HOME_DIR/.config/pipewire/pipewire-pulse.conf.d"
RULE="$DIR/20-block-mic-agc.conf"
OLD="$DIR/99-block-mic-agc.conf"

failures=0
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

# ma <install.sh args...>
ma() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  : >"$FAKE_STATE/systemctl.log"
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only mic-agc "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# regex: the application.process.binary regex of the shipped rule (without ~).
regex="$(sed -n 's/.*application\.process\.binary = "~\(.*\)".*/\1/p' "$SRC" 2>/dev/null)"
matches() { [[ "$1" =~ $regex ]]; }

# --- metadata and the shipped rule ---------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^mic-agc +no ' <<<"$out" >/dev/null
check "metadata: mic-agc is a default (not opt-in) module" $?
[[ -n "$regex" ]]
check "the rule has one application.process.binary regex" $?
grep -q 'block-source-volume' "$SRC" && grep -q '^pulse.rules = \[' "$SRC"
check "the rule applies the block-source-volume quirk through pulse.rules" $?
ok=0
for b in firefox-esr firefox brave chromium code electron; do matches "$b" || ok=1; done
check "regex: Kali's Firefox (firefox-esr), Brave, Chromium, VS Code and Electron match" $ok
ok=0
for b in pactl wpctl pw-record cosmic-applet-audio pavucontrol firefox-esr-x xfirefox vesktop Vesktop discord librewolf; do matches "$b" && ok=1; done
check "regex: anchored; the sound applet, pavucontrol and apps outside this setup do not match" $ok
! grep -qi 'vesktop\|librewolf\|eos' "$SRC"
check "the shipped file names no app and no repository that is not part of this setup" $?

# --- dry-run --------------------------------------------------------------------------------
reset_state
ma --dry-run
[[ "$rc" == 0 && -z "$(find "$HOME_DIR" -type f 2>/dev/null)" ]] && ! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log" && grep -q '20-block-mic-agc.conf' "$WORK/out"
check "dry-run: exit 0, no file, no restart, the install is reported" $?

# --- fresh run, no running PipeWire ----------------------------------------------------------
reset_state
ma
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
cmp -s "$SRC" "$RULE" && [[ "$(stat -c %a "$RULE")" == 644 ]]
check "rule: installed to ~/.config/pipewire/pipewire-pulse.conf.d, mode 0644" $?
! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log" && grep -q 'next login' "$WORK/out"
check "no running pipewire-pulse: nothing is restarted, the run says it applies at next login" $?
ma
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && ! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log"
check "second run: total changes: 0, no restart" $?

# --- running pipewire-pulse -------------------------------------------------------------------
reset_state
printf 'pipewire-pulse.service\n' >"$FAKE_STATE/user-active"
ma
[[ "$rc" == 0 ]] && grep -qx -- '--user restart pipewire-pulse' "$FAKE_STATE/systemctl.log" && [[ "$(grep -c -- '--user restart' "$FAKE_STATE/systemctl.log")" == 1 ]]
check "running pipewire-pulse: only pipewire-pulse is restarted (the rule is read there)" $?
grep -q '\[warn\].*restart apps' "$WORK/out"
check "the restart is announced (apps using audio must reconnect)" $?
ma
! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log"
check "unchanged rule: no restart on the next run" $?
printf 'pulse.rules = []\n' >"$RULE"
ma
cmp -s "$SRC" "$RULE" && compgen -G "$RULE.bak.*" >/dev/null && grep -qx -- '--user restart pipewire-pulse' "$FAKE_STATE/systemctl.log"
check "drift: an edited rule is restored with a .bak.<timestamp> and the service restarts" $?
reset_state
printf 'pipewire-pulse.service\n' >"$FAKE_STATE/user-active"
FAKE_NO_USER_BUS=1 ma
[[ "$rc" == 0 && -f "$RULE" ]] && ! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log" && grep -q 'next login' "$WORK/out"
check "no reachable user manager: the file is written, no restart, applies at next login" $?

# --- legacy rule ---------------------------------------------------------------------------------
reset_state
mkdir -p "$DIR"
printf 'pulse.rules = [ ]\n' >"$OLD"
ma
[[ "$rc" == 0 && ! -e "$OLD" && -f "$RULE" ]] && compgen -G "$OLD.bak.*" >/dev/null
check "legacy: 99-block-mic-agc.conf is backed up (not ending in .conf) and removed" $?
! compgen -G "$DIR/*.bak.*.conf" >/dev/null
check "legacy: no backup ends in .conf (PipeWire would load it)" $?
ma
grep -q 'total changes: 0' "$WORK/out"
check "legacy: a second run changes nothing" $?

# --- files owned by someone else, symlinks ----------------------------------------------------------
reset_state
mkdir -p "$DIR"
printf 'pulse.rules = []\n' >"$RULE"
printf 'pulse.rules = []\n' >"$OLD"
printf 'pipewire-pulse.service\n' >"$FAKE_STATE/user-active"
FAKE_NOT_OWNED="$RULE:$OLD" ma
[[ "$rc" == 0 && "$(<"$RULE")" == 'pulse.rules = []' && -e "$OLD" ]] && grep -q '\[warn\].*not owned' "$WORK/out" &&
  ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log" 2>/dev/null && ! grep -q -- '--user restart' "$FAKE_STATE/systemctl.log"
check "ownership: a rule and a legacy file owned by someone else are skipped with a warning, no sudo, no restart" $?
reset_state
mkdir -p "$HOME_DIR/.config" "$WORK/outside"
ln -s "$WORK/outside" "$HOME_DIR/.config/pipewire"
ma
[[ "$rc" == 0 && -z "$(find "$WORK/outside" -type f 2>/dev/null)" ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a pipewire directory linked outside the home directory is not written through" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
