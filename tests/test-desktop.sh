#!/usr/bin/env bash
# tests/test-desktop.sh: modules/06-desktop.sh against fake commands (apt,
# dpkg-query, gpg, curl, systemctl, getent, systemd-sysusers/tmpfiles) and a
# temporary root prefix (KCS_ROOT). Never touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
export FAKE_KEY_FILE="$WORK/key.asc"
make_fakes "$WORK/bin"
FPR=18575C957A7754E1C93B0EBA3DAEA102469D37CF
fake_key_file "$FAKE_KEY_FILE" "$FPR"

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
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT"
  : >"$FAKE_STATE/installed"
}

# desk <install.sh args...>: run the desktop module; sets rc, output in $WORK/out.
# Clears the call logs first so each run is judged on its own.
desk() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only desktop "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

SYSD="$KCS_ROOT/etc/systemd/system"
mutating='^(enable|disable|set-default|daemon-reload)'

# --- dry-run ----------------------------------------------------------------
reset_state
desk --dry-run
[[ "$rc" == 0 ]]
check "dry-run succeeds" $?
[[ -z "$(find "$KCS_ROOT" -type f 2>/dev/null)" && ! -s "$FAKE_STATE/apt.log" ]]
check "dry-run creates no file and runs no apt-get" $?
! grep -Eq "$mutating" "$FAKE_STATE/systemctl.log" 2>/dev/null &&
  [[ ! -e "$FAKE_STATE/sysusers.log" && ! -e "$FAKE_STATE/tmpfiles.log" && ! -e "$FAKE_STATE/curl.log" ]]
check "dry-run changes no unit, user or tmpfiles and downloads nothing" $?
for what in 'key /etc/apt/keyrings/debian-cosmic.gpg' \
  '/etc/apt/sources.list.d/debian-cosmic.sources' \
  '/etc/apt/preferences.d/debian-cosmic' \
  'install packages: .*greetd' \
  'cosmic-epoch-monorepo' \
  '/etc/systemd/system/cosmic-greeter.service' \
  '/etc/systemd/system/cosmic-greeter-daemon.service' \
  '/etc/greetd/cosmic-greeter.toml' \
  '/etc/pam.d/cosmic-greeter' \
  'systemd-sysusers cosmic-greeter.conf' \
  'systemctl enable cosmic-greeter.service' \
  'systemctl enable cosmic-greeter-daemon.service' \
  'systemctl set-default graphical.target'; do
  grep -q -- "$what" "$WORK/out"
  check "dry-run prints: $what" $?
done

# --- real run on a fresh system --------------------------------------------
reset_state
desk
[[ "$rc" == 0 ]]
check "fresh run succeeds" $?
APT="$FAKE_STATE/apt.log"
grep -q ' update \[' "$APT" && grep -q 'full-upgrade' "$APT"
check "fresh run: apt update and a full-upgrade" $?
[[ "$(grep -c 'full-upgrade' "$APT")" == 1 ]]
check "fresh run: exactly one full-upgrade" $?
first_install="$(grep -n ' install ' "$APT" | head -n1)"
[[ "$first_install" == *gnupg* && "$first_install" == *curl* ]]
check "gnupg and curl are installed first" $?
[[ -f "$KCS_ROOT/etc/apt/keyrings/debian-cosmic.gpg" ]]
check "the repo key is installed" $?
SRC="$KCS_ROOT/etc/apt/sources.list.d/debian-cosmic.sources"
grep -qx 'Types: deb' "$SRC" &&
  grep -qx 'URIs: https://rickysarraf.github.io/debian-cosmic/' "$SRC" &&
  grep -qx 'Suites: unstable' "$SRC" &&
  grep -qx 'Components: main' "$SRC" &&
  grep -qx 'Signed-By: /etc/apt/keyrings/debian-cosmic.gpg' "$SRC"
check "the deb822 sources file has the repo fields" $?
grep -qx 'https://rickysarraf.github.io/debian-cosmic/debian-cosmic.gpg' "$FAKE_STATE/curl.log"
check "the key is fetched from the repo's key URL" $?
PIN="$KCS_ROOT/etc/apt/preferences.d/debian-cosmic"
specific="$(grep -n '^Package: cosmic-epoch-monorepo cosmic-utils-monorepo$' "$PIN" | cut -d: -f1)"
general="$(grep -n '^Package: \*$' "$PIN" | cut -d: -f1)"
[[ -n "$specific" && -n "$general" ]] && ((specific < general))
check "pin: the specific record comes before the general one" $?
awk '/^Package: cosmic-epoch-monorepo/ {f=1} /^Package: \*/ {f=0} f && /^Pin-Priority: 100$/ {ok=1} END {exit !ok}' "$PIN" &&
  awk '/^Package: \*$/ {f=1} f && /^Pin-Priority: -1$/ {ok=1} END {exit !ok}' "$PIN" &&
  [[ "$(grep -c '^Pin: origin "rickysarraf.github.io"$' "$PIN")" == 2 ]] &&
  grep -q '^Explanation:' "$PIN"
check "pin: priority 100 for the two packages, -1 for everything else, explained" $?
[[ "$(grep -c ' update \[' "$APT")" == 2 ]]
check "apt update runs again after the repo is added" $?
epoch_line="$(grep 'cosmic-epoch-monorepo' "$APT" | head -n1)"
[[ "$epoch_line" == *--no-install-recommends* && "$epoch_line" != *cosmic-utils-monorepo* ]]
check "cosmic-epoch-monorepo is installed with --no-install-recommends, alone" $?
base_line="$(grep 'greetd' "$APT" | head -n1)"
missing_base=""
for p in greetd xwayland pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth \
  bluez network-manager power-profiles-daemon gnome-keyring libpam-gnome-keyring \
  dbus-user-session polkitd xdg-desktop-portal xdg-user-dirs accountsservice upower; do
  [[ "$base_line" == *" $p"* ]] || missing_base="$missing_base $p"
done
[[ -z "$missing_base" ]]
check "the session base packages are installed (missing:${missing_base:- none})" $?
! grep -Eq 'cups|avahi|firewalld|packagekit|flatpak|openssh' "$APT"
check "no cups, avahi, firewalld, packagekit, flatpak or sshd" $?
[[ -s "$FAKE_STATE/sysusers.log" ]] && grep -qx 'cosmic-greeter.conf' "$FAKE_STATE/sysusers.log" &&
  grep -qx -- '--create cosmic-greeter.conf' "$FAKE_STATE/tmpfiles.log"
check "sysusers and tmpfiles run when the cosmic-greeter user is missing" $?
files_ok=0
for pair in cosmic-greeter-daemon.service:/etc/systemd/system/cosmic-greeter-daemon.service \
  cosmic-greeter.service:/etc/systemd/system/cosmic-greeter.service \
  cosmic-greeter.toml:/etc/greetd/cosmic-greeter.toml \
  cosmic-greeter.pam:/etc/pam.d/cosmic-greeter; do
  cmp -s "$REPO_ROOT/files/desktop/${pair%%:*}" "$KCS_ROOT${pair#*:}" || files_ok=1
done
check "the four shipped files are installed unchanged" $files_ok
SYSLOG="$FAKE_STATE/systemctl.log"
[[ "$(grep -c '^daemon-reload' "$SYSLOG")" == 1 ]]
check "daemon-reload runs once, after the unit files changed" $?
grep -qx 'enable cosmic-greeter.service' "$SYSLOG" && grep -qx 'enable cosmic-greeter-daemon.service' "$SYSLOG"
check "cosmic-greeter and its daemon are enabled" $?
grep -qx 'set-default graphical.target' "$SYSLOG"
check "the default target is graphical.target" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */cosmic-greeter.service ]]
check "display-manager.service resolves to cosmic-greeter.service" $?
! grep -qi 'getty' "$SYSLOG" && ! grep -qw 'mask' "$SYSLOG"
check "getty units are never touched and nothing is masked" $?
! grep -Eqi '^[^#]*systemctl[^#]*(disable|mask)[^#]*getty' "$REPO_ROOT/modules/06-desktop.sh"
check "the module source never disables or masks getty" $?
! grep -qw 'mask' "$REPO_ROOT/modules/06-desktop.sh"
check "the module source never masks any unit" $?
grep -q 'ExecStart=/usr/sbin/greetd --config /etc/greetd/cosmic-greeter.toml' "$REPO_ROOT/files/desktop/cosmic-greeter.service" &&
  grep -qx 'Alias=display-manager.service' "$REPO_ROOT/files/desktop/cosmic-greeter.service" &&
  head -n1 "$REPO_ROOT/files/desktop/cosmic-greeter.pam" | grep -qx '#%PAM-1.0'
check "shipped files: absolute greetd path, active Alias, PAM header first" $?

# --- second run changes nothing --------------------------------------------
desk
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "second run reports total changes: 0" $?
[[ ! -s "$APT" && ! -e "$FAKE_STATE/sysusers.log" && ! -e "$FAKE_STATE/tmpfiles.log" && ! -e "$FAKE_STATE/curl.log" ]]
check "second run: no apt-get, no download, no sysusers, no tmpfiles" $?
! grep -Eq "$mutating" "$SYSLOG"
check "second run: no enable, disable, set-default or daemon-reload" $?
! compgen -G "$KCS_ROOT/etc/*/*.bak.*" >/dev/null
check "second run: no backup files" $?
desk --dry-run
grep -q 'Nothing to change' "$WORK/out"
check "dry-run after a real run says Nothing to change" $?

# --- a changed non-unit file: backup, no daemon-reload ----------------------
printf '#%%PAM-1.0\nauth required pam_deny.so\n' >"$KCS_ROOT/etc/pam.d/cosmic-greeter"
desk
cmp -s "$REPO_ROOT/files/desktop/cosmic-greeter.pam" "$KCS_ROOT/etc/pam.d/cosmic-greeter" &&
  compgen -G "$KCS_ROOT/etc/pam.d/cosmic-greeter.bak.*" >/dev/null
check "a different existing file is backed up and replaced" $?
! grep -q '^daemon-reload' "$SYSLOG"
check "daemon-reload is skipped when no unit file changed" $?
printf '[Unit]\nDescription=other\n' >"$SYSD/cosmic-greeter.service"
desk
grep -q '^daemon-reload' "$SYSLOG"
check "daemon-reload runs when a unit file changed" $?

# --- display manager switching ----------------------------------------------
reset_state
printf '%s\n' gdm3.service greetd.service lightdm.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn gdm3.service "$SYSD/display-manager.service"
desk
for dm in gdm3 greetd lightdm; do
  grep -qx "disable $dm.service" "$SYSLOG"
  check "enabled display manager $dm is disabled" $?
done
! grep -Eq '^disable (sddm|lxdm|ly)\.service' "$SYSLOG"
check "display managers that are not enabled are left alone" $?
last_disable="$(grep -n '^disable' "$SYSLOG" | tail -n1 | cut -d: -f1)"
enable_line="$(grep -n '^enable cosmic-greeter.service' "$SYSLOG" | cut -d: -f1)"
((last_disable < enable_line))
check "other display managers are disabled before cosmic-greeter is enabled" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */cosmic-greeter.service ]]
check "display-manager.service ends up at cosmic-greeter.service" $?
! grep -qi 'getty' "$SYSLOG"
check "no getty unit touched while switching" $?

# --- sysusers only when the user is missing ---------------------------------
reset_state
echo cosmic-greeter >"$FAKE_STATE/users"
mkdir -p "$KCS_ROOT/var/lib/cosmic-greeter"
desk
[[ "$rc" == 0 && ! -e "$FAKE_STATE/sysusers.log" && ! -e "$FAKE_STATE/tmpfiles.log" ]]
check "an existing cosmic-greeter user means no sysusers and no tmpfiles" $?

# --- privileged step failures fail the module ---------------------------------
for cmd in 'systemd-sysusers cosmic-greeter.conf' 'systemd-tmpfiles --create cosmic-greeter.conf' \
  'systemctl daemon-reload' 'systemctl enable cosmic-greeter.service' \
  'systemctl enable cosmic-greeter-daemon.service' 'systemctl set-default graphical.target'; do
  reset_state
  FAKE_FAIL="|$cmd|" desk
  [[ "$rc" != 0 ]] && grep -q "module 'desktop' failed" "$WORK/out"
  check "a failing '$cmd' fails the module" $?
done
reset_state
printf '%s\n' gdm3.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn gdm3.service "$SYSD/display-manager.service"
FAKE_FAIL="|systemctl disable gdm3.service|" desk
[[ "$rc" != 0 ]] && ! grep -q '^enable cosmic-greeter.service' "$FAKE_STATE/systemctl.log"
check "a failing 'systemctl disable' fails the module before enabling the greeter" $?

# --- display-manager link is verified ---------------------------------------
reset_state
mkdir -p "$SYSD" && ln -sfn other-dm.service "$SYSD/display-manager.service"
FAKE_NO_ALIAS=1 desk
[[ "$rc" != 0 ]] && grep -q 'display-manager.service does not resolve to cosmic-greeter.service' "$WORK/out"
check "an alias still held by another unit fails with a clear message" $?
reset_state
desk --dry-run
[[ "$rc" == 0 ]] && ! grep -q 'does not resolve' "$WORK/out"
check "dry-run does not verify the link" $?
reset_state
printf '%s\n' xdm.service slim.service nodm.service >"$FAKE_STATE/enabled"
desk
for dm in xdm slim nodm; do
  grep -qx "disable $dm.service" "$FAKE_STATE/systemctl.log"
  check "enabled display manager $dm is disabled" $?
done

# --- key fingerprint mismatch aborts ---------------------------------------
reset_state
fake_key_file "$FAKE_KEY_FILE" "0000000000000000000000000000000000000000"
desk
[[ "$rc" != 0 ]] && grep -q 'fingerprint mismatch' "$WORK/out"
check "a wrong key fingerprint fails the module" $?
[[ ! -e "$KCS_ROOT/etc/apt/keyrings/debian-cosmic.gpg" &&
  ! -e "$KCS_ROOT/etc/apt/sources.list.d/debian-cosmic.sources" &&
  ! -e "$KCS_ROOT/etc/apt/preferences.d/debian-cosmic" ]]
check "nothing from the repo is installed on a mismatch" $?
! grep -q 'cosmic-epoch-monorepo' "$FAKE_STATE/apt.log" &&
  ! grep -Eq "$mutating" "$FAKE_STATE/systemctl.log" 2>/dev/null
check "no cosmic package and no unit change after a mismatch" $?
fake_key_file "$FAKE_KEY_FILE" "$FPR"

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
