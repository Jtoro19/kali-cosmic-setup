#!/usr/bin/env bash
# tests/test-dark-mode.sh: modules/25-dark-mode.sh against fake apt, gsettings
# and dbus-run-session, a temporary HOME and a temporary root. Never touches the
# real system. `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2319
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
CFG="$HOME_DIR/.config"
ENVF="$KCS_ROOT/etc/environment"
GS="$FAKE_STATE/gsettings"
SRC="$REPO_ROOT/files/dark-mode"

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
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/run"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT/usr/share/themes/adw-gtk3-dark" "$HOME_DIR" "$WORK/run"
  : >"$FAKE_STATE/installed"
}

# dm <install.sh args...>: run the module. DM_BUS selects the session bus: "env"
# (default, DBUS_SESSION_BUS_ADDRESS set), "socket" (XDG_RUNTIME_DIR/bus
# exists) or "none" (nothing: gsettings must go through dbus-run-session).
dm() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  local bus="${DM_BUS:-env}"
  local -a e=(XDG_RUNTIME_DIR="$WORK/run")
  case "$bus" in
    env) e+=(DBUS_SESSION_BUS_ADDRESS="unix:path=/fake-session-bus") ;;
    socket) python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$WORK/run/bus" ;;
  esac
  rc=0
  env -u DBUS_SESSION_BUS_ADDRESS "${e[@]}" HOME="$HOME_DIR" PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" "$REPO_ROOT/install.sh" --only dark-mode "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}
gsget() { cat -- "$GS/org.gnome.desktop.interface.$1" 2>/dev/null; }

# --- shipped data -------------------------------------------------------------
[[ "$(sed -n 's/^color_scheme_path=//p' "$SRC/qt5ct.conf")" == /usr/share/qt5ct/colors/darker.conf &&
  "$(sed -n 's/^color_scheme_path=//p' "$SRC/qt6ct.conf")" == /usr/share/qt6ct/colors/darker.conf ]]
check "qt5ct and qt6ct each point at their own darker color scheme" $?
! grep -Eq 'fonts|^\[Fonts\]|/home/' "$SRC"/*.conf
check "the qt configs hold no font and no personal path" $?
! grep -Eq 'flatpak|flags\.conf|force-dark' "$REPO_ROOT/modules/25-dark-mode.sh"
check "the module has no flatpak part and no Brave or Electron flag file" $?

# --- dry-run ------------------------------------------------------------------
reset_state
dm --dry-run
[[ "$rc" == 0 && -z "$(find "$HOME_DIR" "$KCS_ROOT/etc" -type f 2>/dev/null)" && ! -s "$FAKE_STATE/apt.log" ]] &&
  ! grep -q 'gsettings set' "$FAKE_STATE/gsettings.log"
check "dry-run succeeds, writes nothing, runs no apt-get and no gsettings set" $?
grep -q 'adw-gtk3-kali' "$WORK/out" && grep -q 'gsettings set org.gnome.desktop.interface color-scheme' "$WORK/out"
check "dry-run reports the packages and the gsettings it would change" $?

# --- fresh run (session bus in the environment) -----------------------------
reset_state
dm
[[ "$rc" == 0 ]]
check "fresh run succeeds" $?
grep -qx adw-gtk3-kali "$FAKE_STATE/installed" && grep -qx qt5ct "$FAKE_STATE/installed" && grep -qx qt6ct "$FAKE_STATE/installed"
check "adw-gtk3-kali, qt5ct and qt6ct are installed" $?
[[ "$(gsget gtk-theme)" == "'adw-gtk3-dark'" && "$(gsget color-scheme)" == "'prefer-dark'" ]]
check "gsettings: gtk-theme adw-gtk3-dark and color-scheme prefer-dark read back" $?
grep -q 'gsettings set .* bus=unix:path=/fake-session-bus' "$FAKE_STATE/gsettings.log" && ! grep -q 'dbus-run-session' "$FAKE_STATE/gsettings.log"
check "gsettings uses the session bus of the environment, no private bus" $?
S3="$CFG/gtk-3.0/settings.ini"
grep -qx '\[Settings\]' "$S3" && grep -qx 'gtk-theme-name=adw-gtk3-dark' "$S3" && grep -qx 'gtk-application-prefer-dark-theme=1' "$S3"
check "gtk-3.0/settings.ini: theme name and prefer-dark" $?
grep -qx '\[Settings\]' "$CFG/gtk-4.0/settings.ini" && grep -qx 'gtk-application-prefer-dark-theme=1' "$CFG/gtk-4.0/settings.ini" &&
  ! grep -q 'gtk-theme-name' "$CFG/gtk-4.0/settings.ini"
check "gtk-4.0/settings.ini: prefer-dark only (libadwaita and GTK4 take the theme from the toolkit)" $?
[[ "$(grep -c '^QT_QPA_PLATFORMTHEME=' "$ENVF")" == 1 ]] && grep -qx 'QT_QPA_PLATFORMTHEME=qt5ct' "$ENVF"
check "/etc/environment gets exactly one QT_QPA_PLATFORMTHEME=qt5ct line" $?
ok=0
for t in qt5ct qt6ct; do
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \[* ]] && continue
    grep -qxF "$line" "$CFG/$t/$t.conf" || ok=1
  done <"$SRC/$t.conf"
done
grep -qx '\[Appearance\]' "$CFG/qt5ct/qt5ct.conf" && grep -qx '\[Appearance\]' "$CFG/qt6ct/qt6ct.conf" &&
  grep -qx 'color_scheme_path=/usr/share/qt6ct/colors/darker.conf' "$CFG/qt6ct/qt6ct.conf"
check "qt5ct.conf and qt6ct.conf have the [Appearance] keys, each with its own color scheme" $((ok + $?))
! find "$HOME_DIR" -name '*-flags.conf' | grep -q .
check "no Brave, Electron or code flag file is written" $?
dm
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/apt.log" ]] && ! grep -q 'gsettings set' "$FAKE_STATE/gsettings.log"
check "second run: total changes: 0, no apt-get, no gsettings set" $?
dm --dry-run
grep -q 'Nothing to change\|total changes: 0' "$WORK/out"
check "dry-run after a real run reports nothing to change" $?

# --- user keys survive, differing keys are replaced after a backup ------------
reset_state
mkdir -p "$CFG/gtk-3.0" "$CFG/qt5ct"
printf '[Settings]\ngtk-font-name=Cantarell 11\ngtk-theme-name=Adwaita\n' >"$S3"
printf '[Fonts]\ngeneral="Noto Sans,10"\n[Appearance]\nstyle=Windows\n[SettingsWindow]\ngeometry=abc\n' >"$CFG/qt5ct/qt5ct.conf"
dm
grep -qx 'gtk-font-name=Cantarell 11' "$S3" && grep -qx 'gtk-theme-name=adw-gtk3-dark' "$S3" && ! grep -q 'gtk-theme-name=Adwaita' "$S3" &&
  ls "$S3".bak.* >/dev/null 2>&1
check "settings.ini: other keys kept, a differing theme is replaced after a backup" $?
grep -qx 'general="Noto Sans,10"' "$CFG/qt5ct/qt5ct.conf" && grep -qx 'geometry=abc' "$CFG/qt5ct/qt5ct.conf" &&
  grep -qx 'style=Fusion' "$CFG/qt5ct/qt5ct.conf" && ! grep -q 'style=Windows' "$CFG/qt5ct/qt5ct.conf" && ls "$CFG"/qt5ct/qt5ct.conf.bak.* >/dev/null 2>&1
check "qt5ct.conf: fonts and other sections kept, [Appearance] keys replaced after a backup" $?
dm
grep -q 'total changes: 0' "$WORK/out"
check "user keys: second run changes nothing" $?

# --- /etc/environment ---------------------------------------------------------
reset_state
mkdir -p "$KCS_ROOT/etc"
printf 'PATH=/usr/bin\nQT_QPA_PLATFORMTHEME=gtk3\n' >"$ENVF"
dm
[[ "$rc" == 0 && "$(grep -c '^QT_QPA_PLATFORMTHEME=' "$ENVF")" == 1 && "$(sed -n 's/^QT_QPA_PLATFORMTHEME=//p' "$ENVF")" == gtk3 ]] &&
  grep -q '\[warn\].*QT_QPA_PLATFORMTHEME' "$WORK/out"
check "/etc/environment: another QT_QPA_PLATFORMTHEME value is kept, warned about, no second line" $?
reset_state
mkdir -p "$KCS_ROOT/etc"
printf 'PATH=/usr/bin\nQT_QPA_PLATFORMTHEME=qt5ct\n' >"$ENVF"
dm
[[ "$(grep -c '^QT_QPA_PLATFORMTHEME=' "$ENVF")" == 1 ]] && ! ls "$ENVF".bak.* >/dev/null 2>&1
check "/etc/environment: an existing qt5ct line is left alone (no backup)" $?

# --- session bus variants -----------------------------------------------------
reset_state
DM_BUS=socket dm
[[ "$rc" == 0 && "$(gsget color-scheme)" == "'prefer-dark'" ]] &&
  grep -q "gsettings set .* bus=unix:path=$WORK/run/bus" "$FAKE_STATE/gsettings.log" && ! grep -q 'dbus-run-session' "$FAKE_STATE/gsettings.log"
check "no bus variable but \$XDG_RUNTIME_DIR/bus exists (SSH to a logged-in user): that bus is used" $?
reset_state
DM_BUS=none dm
[[ "$rc" == 0 && "$(gsget gtk-theme)" == "'adw-gtk3-dark'" && "$(gsget color-scheme)" == "'prefer-dark'" ]] &&
  grep -q 'dbus-run-session -- gsettings set' "$FAKE_STATE/gsettings.log"
check "no session bus at all (TTY): gsettings runs under dbus-run-session and the values are set" $?
DM_BUS=none dm
grep -q 'total changes: 0' "$WORK/out" && ! grep -q 'gsettings set' "$FAKE_STATE/gsettings.log"
check "no session bus: the second run changes nothing" $?
# A daemon that outlives the private bus (gvfsd-fuse) must not block the read:
# ensure_gsetting is called directly, with its own output in a file, so only the
# pipe of a command substitution could hold it up.
reset_state
cat >"$WORK/gs-read.sh" <<EOS
source "$REPO_ROOT/lib/common.sh"
DRY_RUN=1
ensure_gsetting org.gnome.desktop.interface color-scheme "'prefer-dark'"
EOS
start=$SECONDS
env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$WORK/run" PATH="$WORK/bin:$PATH" FAKE_LINGER=1 \
  bash "$WORK/gs-read.sh" >"$WORK/gs.out" 2>&1
grep -q 'gsettings set org.gnome.desktop.interface color-scheme' "$WORK/gs.out" && ((SECONDS - start < 3))
check "a daemon left behind by the private bus does not block the gsettings read" $?
grep -q 'GIO_USE_VFS' "$REPO_ROOT/lib/common.sh"
check "the private bus runs with GIO_USE_VFS=local" $?
reset_state
DM_BUS=none FAKE_NO_DBUS_RUN=1 dm
[[ "$rc" == 0 ]] && grep -q '\[warn\].*gsettings' "$WORK/out" && [[ -f "$S3" && -f "$CFG/qt5ct/qt5ct.conf" ]]
check "no bus and no dbus-run-session: gsettings is skipped with a warning, files are still written" $?
reset_state
FAKE_GSETTINGS_FAIL=1 dm
[[ "$rc" == 0 ]] && grep -q '\[warn\].*gsettings\|\[warn\].*cannot read' "$WORK/out" && grep -qx 'gtk-theme-name=adw-gtk3-dark' "$S3"
check "an unreadable schema is skipped with a warning, the rest is applied" $?

# --- theme directory ----------------------------------------------------------
reset_state
rmdir "$KCS_ROOT/usr/share/themes/adw-gtk3-dark"
dm
[[ "$rc" == 0 && "$(gsget color-scheme)" == "'prefer-dark'" && -z "$(gsget gtk-theme)" ]] && ! grep -q 'gtk-theme-name' "$S3" &&
  grep -qx 'gtk-application-prefer-dark-theme=1' "$S3" && grep -q '\[warn\].*adw-gtk3-dark' "$WORK/out"
check "theme directory missing after the install: warn, set only the dark preference" $?

# --- failures -----------------------------------------------------------------
reset_state
FAKE_APT_RC=100 dm
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
