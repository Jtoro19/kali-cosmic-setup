#!/usr/bin/env bash
# tests/test-panel.sh: modules/55-panel.sh (the COSMIC panel layout keys) against
# a temporary HOME and a temporary root. Never touches the real system.
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
CFG="$HOME_DIR/.config/cosmic"
SRC="$REPO_ROOT/files/panel"
P="$CFG/com.system76.CosmicPanel.Panel/v1"
E="$CFG/com.system76.CosmicPanel/v1/entries"
M="$REPO_ROOT/modules/55-panel.sh"
WI_ID=io.github.crocodile.cosmic-ext-applet-workspace-icons
LK_ID=com.lucianosb.cosmic-ext-lock-keys

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
# applets_present: the desktop entries the applets module installs.
applets_present() {
  mkdir -p "$HOME_DIR/.local/share/applications" "$KCS_ROOT/usr/local/share/applications"
  : >"$HOME_DIR/.local/share/applications/$WI_ID.desktop"
  : >"$KCS_ROOT/usr/local/share/applications/$LK_ID.desktop"
}

# The dependencies are stubbed for the functional runs (the real applets module
# would build with cargo): the stub dir holds the real panel module plus empty
# `applets` and `cosmic-settings` modules. The dependency order itself is checked
# below with the real modules in dry-run.
STUBS="$WORK/modules"
mkdir -p "$STUBS"
cp "$REPO_ROOT/modules/55-panel.sh" "$STUBS/55-panel.sh"
for n in applets cosmic-settings; do
  printf 'MODULE_NAME="%s"\nMODULE_DESC="stub"\nMODULE_OPTIN=0\nMODULE_DEPS=""\nmodule_apply() { :; }\n' "$n" >"$STUBS/10-$n.sh"
done

# pn <install.sh args...>
pn() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 KCS_MODULES_DIR="$STUBS" \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only panel "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata and shipped data -------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^panel +no ' <<<"$out" >/dev/null
check "metadata: panel is a default (not opt-in) module" $?
HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --only panel --dry-run >"$WORK/out" 2>&1 </dev/null
a="$(grep -n 'module: applets$' "$WORK/out" | head -n 1 | cut -d: -f1)"
c="$(grep -n 'module: cosmic-settings$' "$WORK/out" | head -n 1 | cut -d: -f1)"
p="$(grep -n 'module: panel$' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$a" && -n "$c" && -n "$p" && "$a" -lt "$p" && "$c" -lt "$p" ]]
check "--only panel pulls in applets and cosmic-settings first" $?
! grep -rq 'Now[P]laying' "$REPO_ROOT/modules" "$REPO_ROOT/files" "$REPO_ROOT/tests" "$REPO_ROOT/specs/panel.md"
check "Now Playing is dropped: no Now-Playing id anywhere in the module, files, tests or spec" $?
grep -q 'Now Playing' "$REPO_ROOT/specs/panel.md" && grep -qi 'dropped' "$REPO_ROOT/specs/panel.md"
check "the spec says Now Playing is dropped" $?
[[ "$(<"$SRC/com.system76.CosmicPanel.Panel/v1/plugins_center")" == None ]]
check "plugins_center is None (the reference center applet is gone)" $?
[[ "$(<"$SRC/com.system76.CosmicPanel/v1/entries")" == $'[\n    "Panel",\n]' ]]
check "entries: only the Panel (no Dock)" $?
[[ "$(find "$SRC" -type f | wc -l)" == 3 ]]
check "the module manages exactly three keys: entries, plugins_wings, plugins_center" $?
# every applet id in the wings is a system id known to exist in COSMIC 1.11 or a built one
known="com.system76.CosmicAppletTime com.system76.CosmicAppletStatusArea com.system76.CosmicAppletTiling com.system76.CosmicAppletAudio com.system76.CosmicAppletBluetooth com.system76.CosmicAppletNetwork com.system76.CosmicAppletBattery com.system76.CosmicAppletNotifications com.system76.CosmicAppletPower $WI_ID $LK_ID"
ok=0
while IFS= read -r id; do
  [[ " $known " == *" $id "* ]] || { echo "unknown id $id"; ok=1; }
done < <(grep -o '"[^"]*"' "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" | tr -d '"')
[[ "$ok" == 0 ]]
check "wings: every applet id is a COSMIC 1.11 applet or one of the two built applets" $?
grep -q "$WI_ID" "$REPO_ROOT/modules/50-applets.sh" && grep -q "$LK_ID" "$REPO_ROOT/modules/50-applets.sh"
check "the two community ids equal the ones the applets module installs" $?
[[ "$(grep -o '"[^"]*"' "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" | head -n 1)" == "\"$WI_ID\"" ]]
check "start segment: Workspace Icons first" $?
grep -q 'AppletTime' <(sed -n '/^\], \[/,$p' "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" | head -n 3) && grep -q "$LK_ID" <(sed -n '/^\], \[/,$p' "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" | head -n 4)
check "end segment: Time then Lock Keys, as in the reference" $?

# --- dry-run -------------------------------------------------------------------------------
reset_state
applets_present
pn --dry-run
[[ "$rc" == 0 && ! -e "$CFG" ]] && [[ "$(grep -c '\[change\] install' "$WORK/out")" == 3 ]]
check "dry-run: exit 0, nothing written, the three keys are reported" $?

# --- fresh run -------------------------------------------------------------------------------
reset_state
applets_present
pn
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
cmp -s "$SRC/com.system76.CosmicPanel/v1/entries" "$E" && cmp -s "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" "$P/plugins_wings" &&
  cmp -s "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_center" "$P/plugins_center"
check "the three keys are installed byte for byte" $?
[[ "$(find "$CFG" -type f | wc -l)" == 3 ]]
check "no other key is written (size, opacity, autohide... stay the user's)" $?
! grep -q 'warn' "$WORK/out"
check "no warning when both built applets are installed" $?
pn
grep -q 'total changes: 0' "$WORK/out" && ! find "$HOME_DIR" -name '*.bak.*' | grep -q .
check "second run: total changes: 0, no backup files" $?

# --- the user's other panel settings are never clobbered ---------------------------------------------
reset_state
applets_present
mkdir -p "$P"
printf 'L' >"$P/size"
printf '0.5' >"$P/opacity"
printf 'Bottom' >"$P/anchor"
printf 'Some((["a"], ["b"]))' >"$P/plugins_wings"
pn
[[ "$(<"$P/size")" == L && "$(<"$P/opacity")" == 0.5 && "$(<"$P/anchor")" == Bottom ]] && ! compgen -G "$P/size.bak.*" >/dev/null
check "other keys: size, opacity and anchor the user set are left alone (no write, no backup)" $?
cmp -s "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" "$P/plugins_wings" && bak=("$P"/plugins_wings.bak.*) && [[ "$(<"${bak[0]}")" == 'Some((["a"], ["b"]))' ]]
check "layout key: a different plugins_wings is replaced after a backup" $?
pn
grep -q 'total changes: 0' "$WORK/out"
check "second run after the replacement: 0 changes" $?

# --- missing applets ------------------------------------------------------------------------------
reset_state
pn
[[ "$rc" == 0 && -f "$P/plugins_wings" ]] && grep -q "\[warn\].*$WI_ID" "$WORK/out" && grep -q "\[warn\].*$LK_ID" "$WORK/out"
check "missing applets: the layout is written and the run warns about each applet that is not installed" $?

# --- files owned by someone else, symlinks (never through sudo) -------------------------------------
reset_state
applets_present
mkdir -p "$P"
printf 'None' >"$P/plugins_center"
FAKE_NOT_OWNED="$P/plugins_wings:$P" pn
[[ "$rc" == 0 && ! -e "$P/plugins_wings" ]] && grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a panel directory owned by someone else is skipped with a warning, no sudo write" $?
[[ -f "$E" ]]
check "ownership: the key under a directory that is the user's is still written" $?
reset_state
applets_present
mkdir -p "$P" "$WORK/outside"
printf 'x' >"$WORK/outside/plugins_wings"
ln -s "$WORK/outside/plugins_wings" "$P/plugins_wings"
pn
[[ "$rc" == 0 && -L "$P/plugins_wings" && "$(<"$WORK/outside/plugins_wings")" == x ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a key linked outside the home directory is skipped with a warning, the link is not replaced" $?
reset_state
applets_present
mkdir -p "$P" "$HOME_DIR/dotfiles"
ln -s "$HOME_DIR/dotfiles/wings" "$P/plugins_wings"
pn
[[ -L "$P/plugins_wings" ]] && cmp -s "$SRC/com.system76.CosmicPanel.Panel/v1/plugins_wings" "$HOME_DIR/dotfiles/wings"
check "symlink: a key linked into the home directory is written through the link" $?

# --- static ---------------------------------------------------------------------------------------------
! grep -Eq 'sudo|run_sudo|pkill|killall' "$M"
check "the module never uses sudo and never restarts the panel (cosmic-panel reloads the keys live)" $?
grep '^| panel ' "$REPO_ROOT/README.md" | grep -q 'CosmicPanel'
check "README: the panel row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
