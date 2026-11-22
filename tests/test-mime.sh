#!/usr/bin/env bash
# tests/test-mime.sh: modules/75-mime.sh (default applications in
# ~/.config/mimeapps.list) against a temporary HOME and a temporary root with
# fake desktop entries. Never touches the real system.
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
LIST="$HOME_DIR/.config/mimeapps.list"
COSMIC_LIST="$HOME_DIR/.config/cosmic-mimeapps.list"
APPS="$KCS_ROOT/usr/share/applications"

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
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR" "$APPS"
  : >"$FAKE_STATE/installed"
}
# apps_present: the desktop entries the packages module installs.
apps_present() {
  : >"$APPS/brave-browser.desktop"
  : >"$APPS/peazip.desktop"
}
# value <key>: the value of a key under [Default Applications] in mimeapps.list.
value() { sed -n '/^\[Default Applications\]$/,/^\[.*\]$/{s|^'"$1"'=||p}' "$LIST"; }

# The packages dependency is stubbed for the functional runs (the real module
# installs software); the dependency order itself is checked with the real
# modules in dry-run below.
STUBS="$WORK/modules"
mkdir -p "$STUBS"
cp "$REPO_ROOT/modules/75-mime.sh" "$STUBS/75-mime.sh"
printf 'MODULE_NAME="packages"\nMODULE_DESC="stub"\nMODULE_OPTIN=0\nMODULE_DEPS=""\nmodule_apply() { :; }\n' >"$STUBS/15-packages.sh"

# mm <install.sh args...>
mm() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 KCS_MODULES_DIR="$STUBS" \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" XDG_DATA_HOME="$HOME_DIR/.local/share" \
    "$REPO_ROOT/install.sh" --only mime "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata ----------------------------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^mime +no ' <<<"$out" >/dev/null && grep -qx 'MODULE_DEPS="packages"' "$REPO_ROOT/modules/75-mime.sh"
check "metadata: mime is a default module that depends on packages" $?
HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --only mime --dry-run >"$WORK/out" 2>&1 </dev/null
a="$(grep -n 'module: packages$' "$WORK/out" | head -n 1 | cut -d: -f1)"
p="$(grep -n 'module: mime$' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$a" && -n "$p" && "$a" -lt "$p" ]]
check "--only mime pulls in packages first" $?
! grep -qi 'vesktop\|discord' "$REPO_ROOT/modules/75-mime.sh"
check "the Vesktop and Discord entry of the reference is dropped" $?

# --- dry-run ----------------------------------------------------------------------------------
reset_state
apps_present
mm --dry-run
[[ "$rc" == 0 && ! -e "$LIST" ]] && grep -q 'install .*/mimeapps.list' "$WORK/out"
check "dry-run: exit 0, no file written, the entries are reported" $?

# --- fresh run --------------------------------------------------------------------------------
reset_state
apps_present
mm
[[ "$rc" == 0 && -f "$LIST" ]]
check "fresh run: exit 0, mimeapps.list written" $?
ok=0
for t in text/html x-scheme-handler/http x-scheme-handler/https x-scheme-handler/about x-scheme-handler/unknown application/pdf; do
  [[ "$(value "$t")" == brave-browser.desktop ]] || ok=1
done
check "web and PDF types default to brave-browser.desktop" $ok
[[ "$(value application/zip)" == peazip.desktop ]]
check "application/zip defaults to peazip.desktop" $?
! grep -q 'discord' "$LIST" && [[ "$(grep -c '^\[Default Applications\]$' "$LIST")" == 1 ]]
check "no discord entry, one [Default Applications] section" $?
mm
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ -z "$(find "$HOME_DIR/.config" -name 'mimeapps.list.bak.*')" ]]
check "second run: total changes: 0, no backup" $?

# --- entries whose app is not installed are skipped -------------------------------------------------
reset_state
: >"$APPS/brave-browser.desktop"
mm
[[ "$rc" == 0 && "$(value text/html)" == brave-browser.desktop && -z "$(value application/zip)" ]] && grep -q 'skip application/zip: peazip.desktop is not installed' "$WORK/out"
check "missing app: its types are skipped with a message, the others are set" $?
reset_state
mm
[[ "$rc" == 0 && ! -e "$LIST" ]]
check "no app installed: nothing is written" $?
reset_state
mkdir -p "$HOME_DIR/.local/share/applications" "$KCS_ROOT/usr/local/share/applications"
: >"$HOME_DIR/.local/share/applications/brave-browser.desktop"
: >"$KCS_ROOT/usr/local/share/applications/peazip.desktop"
mm
[[ "$(value application/pdf)" == brave-browser.desktop && "$(value application/zip)" == peazip.desktop ]]
check "an entry in the user or /usr/local applications directory counts as installed" $?

# --- merge without clobbering ------------------------------------------------------------------------
reset_state
apps_present
mkdir -p "$HOME_DIR/.config"
cat >"$LIST" <<'EOT'
[Added Associations]
text/plain=mine.desktop;

[Default Applications]
x-scheme-handler/mailto=thunderbird.desktop
application/pdf=firefox-esr.desktop
text/plain=mine.desktop

[Removed Associations]
image/png=gimp.desktop;
EOT
mm
[[ "$rc" == 0 && "$(value application/pdf)" == brave-browser.desktop && "$(value text/html)" == brave-browser.desktop ]] &&
  [[ "$(value x-scheme-handler/mailto)" == thunderbird.desktop && "$(value text/plain)" == mine.desktop ]] &&
  grep -qx 'image/png=gimp.desktop;' "$LIST" && grep -qx '\[Added Associations\]' "$LIST" && compgen -G "$LIST.bak.*" >/dev/null
check "merge: our types are set or replaced in place; mailto, text/plain and the other sections stay; a backup is kept" $?
[[ "$(grep -c '^application/pdf=' "$LIST")" == 1 ]] && [[ "$(grep -c '^\[Default Applications\]$' "$LIST")" == 1 ]]
check "merge: no duplicate key, no duplicate section" $?
mm
grep -q 'total changes: 0' "$WORK/out"
check "merge: a second run changes nothing" $?

# --- cosmic-mimeapps.list wins over mimeapps.list: warn, never edit -------------------------------------
reset_state
apps_present
mkdir -p "$HOME_DIR/.config"
printf '[Default Applications]\nx-scheme-handler/terminal=kitty.desktop\napplication/pdf=com.system76.CosmicViewer.desktop\n' >"$COSMIC_LIST"
mm
[[ "$rc" == 0 && "$(value application/pdf)" == brave-browser.desktop ]] && grep -q '\[warn\].*cosmic-mimeapps.list.*application/pdf' "$WORK/out" &&
  [[ "$(grep -c '^application/pdf=' "$COSMIC_LIST")" == 1 ]] && grep -qx 'application/pdf=com.system76.CosmicViewer.desktop' "$COSMIC_LIST"
check "COSMIC list: a conflicting entry is reported (it outranks mimeapps.list) and left alone" $?
! grep -q '\[warn\].*text/html' "$WORK/out" && ! grep -q '\[warn\].*terminal' "$WORK/out"
check "COSMIC list: unrelated keys (kitty terminal) raise no warning" $?

# --- ownership and symlinks ------------------------------------------------------------------------------
reset_state
apps_present
mkdir -p "$HOME_DIR/.config"
printf '[Default Applications]\napplication/pdf=mine.desktop\n' >"$LIST"
FAKE_NOT_OWNED="$LIST" mm
[[ "$rc" == 0 && "$(<"$LIST")" == $'[Default Applications]\napplication/pdf=mine.desktop' ]] && grep -q '\[warn\].*not owned' "$WORK/out" &&
  ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log" 2>/dev/null
check "ownership: a mimeapps.list owned by someone else is skipped with a warning, no sudo" $?
reset_state
apps_present
mkdir -p "$HOME_DIR/.config" "$WORK/outside"
printf 'x\n' >"$WORK/outside/mimeapps.list"
ln -s "$WORK/outside/mimeapps.list" "$LIST"
mm
[[ "$rc" == 0 && -L "$LIST" && "$(<"$WORK/outside/mimeapps.list")" == x ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a list linked outside the home directory is not written through" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
