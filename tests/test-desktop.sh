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
  # DISPLAY, WAYLAND_DISPLAY and XDG_SESSION_TYPE are pinned so the result does
  # not depend on the session running the tests (T_DISPLAY / T_SESSION override).
  PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    DISPLAY="${T_DISPLAY:-}" WAYLAND_DISPLAY="" XDG_SESSION_TYPE="${T_SESSION:-}" \
    "$REPO_ROOT/install.sh" --only desktop "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# real_apt: the apt-get calls that are not simulations (-s).
real_apt() { grep -Ev -- '(^| )-s ' "$FAKE_STATE/apt.log"; }

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
  '/etc/systemd/system/greetd.service.d/cosmic-greeter.conf' \
  '/etc/systemd/system/cosmic-greeter-daemon.service' \
  '/etc/greetd/cosmic-greeter.toml' \
  '/etc/pam.d/cosmic-greeter' \
  'systemd-sysusers cosmic-greeter.conf' \
  'debconf-set-selections' \
  '/etc/X11/default-display-manager' \
  'ln -sfn -- /lib/systemd/system/greetd.service' \
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
  greetd-cosmic.conf:/etc/systemd/system/greetd.service.d/cosmic-greeter.conf \
  cosmic-greeter.toml:/etc/greetd/cosmic-greeter.toml \
  cosmic-greeter.pam:/etc/pam.d/cosmic-greeter; do
  cmp -s "$REPO_ROOT/files/desktop/${pair%%:*}" "$KCS_ROOT${pair#*:}" || files_ok=1
done
check "the four shipped files are installed unchanged (drop-in under greetd.service.d)" $files_ok
SYSLOG="$FAKE_STATE/systemctl.log"
[[ "$(grep -c '^daemon-reload' "$SYSLOG")" == 1 ]]
check "daemon-reload runs once, after the unit files changed" $?
grep -qx 'enable cosmic-greeter-daemon.service' "$SYSLOG" && ! grep -qx 'enable cosmic-greeter.service' "$SYSLOG"
check "the greeter daemon is enabled, the retired cosmic-greeter.service is not" $?
[[ ! -e "$SYSD/cosmic-greeter.service" && ! -e "$REPO_ROOT/files/desktop/cosmic-greeter.service" ]]
check "no cosmic-greeter.service alias is installed or shipped" $?
[[ "$(cat "$FAKE_STATE/debconf" 2>/dev/null)" == greetd ]] &&
  grep -qx 'greetd shared/default-x-display-manager select greetd' "$FAKE_STATE/debconf.log"
check "debconf shared/default-x-display-manager is set to greetd" $?
[[ "$(cat "$KCS_ROOT/etc/X11/default-display-manager")" == /usr/sbin/greetd ]]
check "/etc/X11/default-display-manager holds /usr/sbin/greetd" $?
[[ "$(readlink "$SYSD/display-manager.service")" == /lib/systemd/system/greetd.service ]]
check "display-manager.service links to /lib/systemd/system/greetd.service" $?
[[ -s "$APT" ]] && ! grep -Eq -- '(^| )-s |purge|autoremove' "$APT" &&
  [[ ! -e "$FAKE_STATE/purge-state.log" ]]
check "no gdm3 or gnome-shell installed: apt-get log has no purge, simulation or autoremove" $?
[[ ! -e "$FAKE_STATE/sudo.log" ]] || ! grep -q 'debconf-show' "$FAKE_STATE/sudo.log"
check "the debconf read never goes through the sudo binary under KCS_SKIP_SUDO" $?
# Positive control: without KCS_SKIP_SUDO the same read does call sudo, so the
# absence above is meaningful.
rm -f -- "$FAKE_STATE/sudo.log"
PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=0 bash -c 'source "$1/lib/common.sh"; sudo_read debconf-show greetd' _ "$REPO_ROOT" >/dev/null
grep -q 'debconf-show greetd' "$FAKE_STATE/sudo.log" 2>/dev/null
check "positive control: sudo_read calls sudo when KCS_SKIP_SUDO is not set" $?
grep -qx 'set-default graphical.target' "$SYSLOG"
check "the default target is graphical.target" $?
! grep -qi 'getty' "$SYSLOG" && ! grep -qw 'mask' "$SYSLOG"
check "getty units are never touched and nothing is masked" $?
! grep -Eqi '^[^#]*systemctl[^#]*(disable|mask)[^#]*getty' "$REPO_ROOT/modules/06-desktop.sh"
check "the module source never disables or masks getty" $?
! grep -qw 'mask' "$REPO_ROOT/modules/06-desktop.sh"
check "the module source never masks any unit" $?
DROPIN="$REPO_ROOT/files/desktop/greetd-cosmic.conf"
grep -qx 'Wants=cosmic-greeter-daemon.service' "$DROPIN" &&
  grep -qx 'After=cosmic-greeter-daemon.service' "$DROPIN" &&
  [[ "$(grep -n '^ExecStart=$' "$DROPIN" | cut -d: -f1)" -lt "$(grep -n '^ExecStart=/usr/sbin/greetd --config /etc/greetd/cosmic-greeter.toml$' "$DROPIN" | cut -d: -f1)" ]] &&
  ! grep -q '^\[Install\]' "$DROPIN" &&
  head -n1 "$REPO_ROOT/files/desktop/cosmic-greeter.pam" | grep -qx '#%PAM-1.0' &&
  grep -qx 'vt = 7' "$REPO_ROOT/files/desktop/cosmic-greeter.toml" &&
  grep -qx 'service = "cosmic-greeter"' "$REPO_ROOT/files/desktop/cosmic-greeter.toml"
check "shipped files: drop-in clears then sets ExecStart, vt 7, PAM header first" $?

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
printf '[Service]\nExecStart=\n' >"$SYSD/greetd.service.d/cosmic-greeter.conf"
desk
grep -q '^daemon-reload' "$SYSLOG" &&
  cmp -s "$REPO_ROOT/files/desktop/greetd-cosmic.conf" "$SYSD/greetd.service.d/cosmic-greeter.conf" &&
  compgen -G "$SYSD/greetd.service.d/cosmic-greeter.conf.bak.*" >/dev/null
check "a changed drop-in is backed up, replaced and followed by daemon-reload" $?

# --- apt refresh after the repo changed ---------------------------------------
reset_state
FAKE_APT_FAIL_UPDATE_NTH=2 desk
[[ "$rc" != 0 ]] && grep -q "module 'desktop' failed" "$WORK/out" &&
  [[ "$(wc -l <"$FAKE_STATE/update.count")" == 2 ]] && ! grep -q 'cosmic-epoch-monorepo' "$FAKE_STATE/apt.log"
check "a failing apt-get update after the repo changed (force refresh) fails the module" $?

# --- display manager switching ----------------------------------------------
reset_state
printf '%s\n' gdm3.service greetd.service lightdm.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn gdm3.service "$SYSD/display-manager.service"
desk
for dm in gdm3 lightdm; do
  grep -qx "disable $dm.service" "$SYSLOG"
  check "enabled display manager $dm is disabled" $?
done
! grep -Eq '^disable (sddm|lxdm|ly|greetd)\.service' "$SYSLOG"
check "display managers that are not enabled, and greetd itself, are left alone" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */greetd.service ]]
check "display-manager.service ends up at greetd.service" $?
! grep -qi 'getty' "$SYSLOG"
check "no getty unit touched while switching" $?
[[ "$(readlink "$SYSD/display-manager.service")" == /lib/systemd/system/greetd.service ]]
check "the link is the one Debian's postinst makes" $?

# A stale link to another unit is replaced; debconf already right is not set again.
reset_state
echo greetd >"$FAKE_STATE/debconf"
mkdir -p "$SYSD" && ln -sfn other-dm.service "$SYSD/display-manager.service"
desk
[[ "$rc" == 0 && "$(readlink -f "$SYSD/display-manager.service")" == */greetd.service ]]
check "a stale display-manager.service link is replaced by the greetd link" $?
[[ ! -e "$FAKE_STATE/debconf.log" ]]
check "debconf is not set again when it already says greetd" $?
reset_state
echo gdm3 >"$FAKE_STATE/debconf"
desk
grep -qx 'greetd shared/default-x-display-manager select greetd' "$FAKE_STATE/debconf.log" &&
  [[ "$(cat "$FAKE_STATE/debconf")" == greetd ]]
check "debconf saying gdm3 is switched to greetd" $?
reset_state
mkdir -p "$KCS_ROOT/etc/X11" && echo /usr/sbin/gdm3 >"$KCS_ROOT/etc/X11/default-display-manager"
desk
[[ "$(cat "$KCS_ROOT/etc/X11/default-display-manager")" == /usr/sbin/greetd ]] &&
  compgen -G "$KCS_ROOT/etc/X11/default-display-manager.bak.*" >/dev/null
check "default-display-manager is rewritten to greetd with a backup" $?
dm_line="$(grep -n 'debconf-set-selections' "$FAKE_STATE/all.log" | head -n1 | cut -d: -f1)"
ln_line="$(grep -n '^ln ' "$FAKE_STATE/all.log" | head -n1 | cut -d: -f1)"
[[ -n "$dm_line" && -n "$ln_line" ]] && ((dm_line < ln_line))
check "debconf is set before the display-manager link is made" $?

# A masked display-manager.service is never unmasked: the module fails.
reset_state
mkdir -p "$SYSD" && ln -sfn /dev/null "$SYSD/display-manager.service"
printf '%s\n' gdm3 gnome-shell >"$FAKE_STATE/installed"
desk
[[ "$rc" != 0 && "$(readlink "$SYSD/display-manager.service")" == /dev/null ]] &&
  grep -q 'masked' "$WORK/out" && ! grep -qw 'unmask' "$FAKE_STATE/systemctl.log" &&
  ! grep -q ' purge ' "$FAKE_STATE/apt.log"
check "a masked display-manager.service fails loudly, is not unmasked, nothing purged" $?

# --- migration from the earlier cosmic-greeter.service ----------------------
reset_state
mkdir -p "$SYSD"
printf '[Unit]\nDescription=old\n' >"$SYSD/cosmic-greeter.service"
ln -sfn cosmic-greeter.service "$SYSD/display-manager.service"
echo cosmic-greeter.service >"$FAKE_STATE/enabled"
desk
[[ "$rc" == 0 && ! -e "$SYSD/cosmic-greeter.service" ]] &&
  compgen -G "$SYSD/cosmic-greeter.service.bak.*" >/dev/null
check "the old cosmic-greeter.service is removed with a backup" $?
grep -qx 'disable cosmic-greeter.service' "$SYSLOG" && grep -q '^daemon-reload' "$SYSLOG"
check "the old unit is disabled first and systemd reloaded" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */greetd.service ]]
check "after the migration display-manager.service resolves to greetd.service" $?

# --- disabling a display manager can delete the alias link ---------------------
# Real `systemctl disable` follows the unit's Alias=display-manager.service, so
# the greetd link made earlier may be gone afterwards: it is made again.
reset_state
printf '%s\n' gdm3.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn /lib/systemd/system/gdm3.service "$SYSD/display-manager.service"
FAKE_DISABLE_DROPS_ALIAS="gdm3.service" desk
[[ "$rc" == 0 && "$(readlink "$SYSD/display-manager.service")" == /lib/systemd/system/greetd.service ]]
check "gdm3 disable deletes the alias: the greetd link is made again and the run succeeds" $?
[[ "$(grep -c '^ln ' "$FAKE_STATE/all.log")" == 2 ]]
check "the link was made twice (before and after the disables)" $?
reset_state
mkdir -p "$SYSD"
printf '[Unit]\nDescription=old\n' >"$SYSD/cosmic-greeter.service"
ln -sfn cosmic-greeter.service "$SYSD/display-manager.service"
echo cosmic-greeter.service >"$FAKE_STATE/enabled"
FAKE_DISABLE_DROPS_ALIAS="cosmic-greeter.service" desk
[[ "$rc" == 0 && "$(readlink "$SYSD/display-manager.service")" == /lib/systemd/system/greetd.service &&
  ! -e "$SYSD/cosmic-greeter.service" ]]
check "old unit disable deletes the alias: the greetd link is made again and the old unit is gone" $?
reset_state
printf '%s\n' gdm3.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn /lib/systemd/system/gdm3.service "$SYSD/display-manager.service"
FAKE_DISABLE_DROPS_ALIAS="gdm3.service" FAKE_LN_NOOP_NTH=2 desk
[[ "$rc" != 0 ]] && grep -q 'display-manager.service is missing' "$WORK/out"
check "a relink that cannot be made after the disables fails loudly" $?
reset_state
printf '%s\n' gdm3 gnome-shell >"$FAKE_STATE/installed"
printf '%s\n' gdm3.service >"$FAKE_STATE/enabled"
mkdir -p "$SYSD" && ln -sfn /lib/systemd/system/gdm3.service "$SYSD/display-manager.service"
FAKE_DISABLE_DROPS_ALIAS="gdm3.service" FAKE_LN_NOOP_NTH=2 desk
[[ "$rc" != 0 && ! -e "$FAKE_STATE/purge-state.log" ]]
check "no purge when the link is lost and cannot be restored" $?

# --- GDM purge --------------------------------------------------------------
# gdm_system: an up-to-date Kali "default tools" system with gdm3 and gnome-shell.
gdm_system() {
  reset_state
  printf '%s\n' gdm3 gnome-shell >"$FAKE_STATE/installed"
  printf '%s\n' gdm3.service >"$FAKE_STATE/enabled"
  echo gdm3 >"$FAKE_STATE/debconf"
  mkdir -p "$SYSD" "$KCS_ROOT/etc/X11"
  ln -sfn /lib/systemd/system/gdm3.service "$SYSD/display-manager.service"
  echo /usr/sbin/gdm3 >"$KCS_ROOT/etc/X11/default-display-manager"
}
gdm_system
printf '%s\n' 'Purg gdm3 [50.2]' 'Purg gnome-browser-connector [1]' 'Purg gnome-session [1]' \
  'Purg gnome-shell [50.4]' >"$FAKE_STATE/sim-purge"
printf '%s\n' 'Remv libgnome-orphan1 [1]' 'Remv some-orphan [2]' >"$FAKE_STATE/sim-autoremove"
desk
APT="$FAKE_STATE/apt.log"
[[ "$rc" == 0 ]] && grep -Eq -- '^(-y )?.*purge gdm3 gnome-shell \[DEBIAN_FRONTEND=noninteractive\]' "$APT" &&
  grep -q -- 'force-confold.* purge gdm3 gnome-shell' "$APT"
check "a clean simulation purges gdm3 and gnome-shell non-interactively" $?
grep -q -- '-s purge gdm3 gnome-shell' "$APT"
check "the purge is simulated first with only the installed packages" $?
grep -q 'gnome-browser-connector' "$WORK/out" && grep -q 'gnome-session' "$WORK/out"
check "the purge log lists everything that goes" $?
grep -qx 'default-dm=/usr/sbin/greetd' "$FAKE_STATE/purge-state.log" &&
  grep -qx 'link=/lib/systemd/system/greetd.service' "$FAKE_STATE/purge-state.log"
check "at purge time the display manager is already greetd" $?
set_line="$(grep -n 'debconf-set-selections' "$FAKE_STATE/all.log" | head -n1 | cut -d: -f1)"
ln_line="$(grep -n '^ln ' "$FAKE_STATE/all.log" | head -n1 | cut -d: -f1)"
purge_line="$(grep -nE '^apt-get .* purge gdm3' "$FAKE_STATE/all.log" | grep -Ev -- '(^|[ :])-s ' | head -n1 | cut -d: -f1)"
[[ -n "$set_line" && -n "$ln_line" && -n "$purge_line" ]] && ((set_line < purge_line && ln_line < purge_line))
check "command order: debconf and link first, purge after" $?
! grep -q 'autoremove' <(real_apt) && grep -q -- '-s autoremove' "$APT"
check "autoremove is only ever simulated" $?
grep -q 'orphans (not removed, report to the owner)' "$WORK/out" &&
  grep -q 'libgnome-orphan1' "$WORK/out" && grep -q 'some-orphan' "$WORK/out"
check "the autoremove simulation is reported under the orphans heading" $?
! grep -qi 'getty' "$SYSLOG" && ! grep -qw 'mask' "$SYSLOG"
check "no getty disabled or masked during the purge run" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */greetd.service ]]
check "after the purge display-manager.service still resolves to greetd.service" $?

# second run on the switched system without gdm3 changes nothing
desk
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/apt.log" ]] &&
  ! grep -Eq "$mutating" "$SYSLOG" && [[ ! -e "$FAKE_STATE/debconf.log" ]]
check "second run after the purge: zero changes, no apt call, no debconf set" $?

# a kali-* package in the simulation prevents the purge
gdm_system
printf '%s\n' 'Purg gdm3 [50.2]' 'Purg gnome-shell [50.4]' 'Purg kali-desktop-gnome [1]' >"$FAKE_STATE/sim-purge"
desk
[[ "$rc" == 0 ]] && ! grep -Eq -- ' purge ' <(real_apt) &&
  grep -q 'kali-desktop-gnome' "$WORK/out" && grep -q 'kept installed but disabled' "$WORK/out"
check "a kali-* package in the simulation prevents the purge and warns" $?
! grep -q 'autoremove' "$FAKE_STATE/apt.log"
check "no autoremove simulation when nothing was purged" $?
[[ "$(readlink -f "$SYSD/display-manager.service")" == */greetd.service ]] &&
  ! grep -qx 'gdm3.service' "$FAKE_STATE/enabled"
check "with GDM kept, greetd is the display manager and gdm3 is disabled" $?
desk
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "second run with GDM kept changes nothing" $?

# only one of the two installed: only that one is simulated and purged
gdm_system
printf '%s\n' gdm3 >"$FAKE_STATE/installed"
desk
grep -q -- '-s purge gdm3 \[' "$FAKE_STATE/apt.log" && ! grep -q 'gnome-shell' "$FAKE_STATE/apt.log"
check "only the installed ones are simulated and purged" $?

# the installer running inside the graphical session that gdm3 serves
gdm_system
echo gdm3.service >"$FAKE_STATE/active"
T_SESSION=wayland desk
[[ "$rc" == 0 ]] && ! grep -q ' purge ' <(real_apt) &&
  grep -qi 'reboot' "$WORK/out" && grep -q -- '--only desktop' "$WORK/out"
check "graphical session guard (wayland, gdm3 active): no purge, reboot advice" $?
gdm_system
echo gdm3.service >"$FAKE_STATE/active"
T_DISPLAY=:0 desk
! grep -q ' purge ' <(real_apt)
check "graphical session guard also triggers on DISPLAY" $?
gdm_system
T_SESSION=wayland desk
grep -q ' purge gdm3 gnome-shell ' <(real_apt)
check "graphical session without an active gdm3: the purge goes ahead" $?
gdm_system
echo gdm3.service >"$FAKE_STATE/active"
T_SESSION='tty' desk
grep -q ' purge gdm3 gnome-shell ' <(real_apt)
check "text session with gdm3 active: the purge goes ahead" $?

# dry-run: simulates, prints, never purges
gdm_system
desk --dry-run
[[ "$rc" == 0 ]] && ! grep -q ' purge ' <(real_apt) &&
  grep -q 'would run: sudo .*purge gdm3 gnome-shell' "$WORK/out" &&
  grep -q 'orphans (not removed, report to the owner)' "$WORK/out"
check "dry-run prints the purge and the orphans report without purging" $?

# a failing purge or simulation fails the module
gdm_system
FAKE_APT_RC=1 desk
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?

# --- sysusers only when the user is missing ---------------------------------
reset_state
echo cosmic-greeter >"$FAKE_STATE/users"
mkdir -p "$KCS_ROOT/var/lib/cosmic-greeter"
desk
[[ "$rc" == 0 && ! -e "$FAKE_STATE/sysusers.log" && ! -e "$FAKE_STATE/tmpfiles.log" ]]
check "an existing cosmic-greeter user means no sysusers and no tmpfiles" $?

# --- privileged step failures fail the module ---------------------------------
for cmd in 'systemd-sysusers cosmic-greeter.conf' 'systemd-tmpfiles --create cosmic-greeter.conf' \
  'systemctl daemon-reload' 'debconf-set-selections' \
  'systemctl enable cosmic-greeter-daemon.service' 'systemctl set-default graphical.target'; do
  reset_state
  FAKE_FAIL="|$cmd|" desk
  [[ "$rc" != 0 ]] && grep -q "module 'desktop' failed" "$WORK/out"
  check "a failing '$cmd' fails the module" $?
done
gdm_system
FAKE_FAIL="|systemctl disable gdm3.service|" desk
[[ "$rc" != 0 ]] && [[ ! -e "$FAKE_STATE/purge-state.log" ]] && [[ -L "$SYSD/display-manager.service" ]]
check "a failing 'systemctl disable' fails the module before the purge, link not missing" $?

# A failure between the old unit and the greetd link never leaves no link.
old_alias_system() {
  reset_state
  mkdir -p "$SYSD"
  printf '[Unit]\nDescription=old\n' >"$SYSD/cosmic-greeter.service"
  ln -sfn cosmic-greeter.service "$SYSD/display-manager.service"
  echo cosmic-greeter.service >"$FAKE_STATE/enabled"
}
for cmd in 'debconf-set-selections' 'systemctl enable cosmic-greeter-daemon.service'; do
  old_alias_system
  FAKE_FAIL="|$cmd|" desk
  [[ "$rc" != 0 && -L "$SYSD/display-manager.service" && -e "$SYSD/cosmic-greeter.service" ]]
  check "migration: '$cmd' failing leaves the old unit and a display-manager link" $?
done
old_alias_system
FAKE_NO_LN=1 desk
[[ "$rc" != 0 && -L "$SYSD/display-manager.service" && -e "$SYSD/cosmic-greeter.service" ]]
check "migration: the old unit stays until the greetd link exists" $?
old_alias_system
printf '%s\n' gdm3.service >>"$FAKE_STATE/enabled"
FAKE_FAIL="|systemctl disable gdm3.service|" desk
[[ "$rc" != 0 && -L "$SYSD/display-manager.service" ]]
check "migration: a failing disable of another display manager leaves a link" $?

# --- display-manager link is verified ---------------------------------------
reset_state
FAKE_NO_LN=1 desk
[[ "$rc" != 0 ]] && grep -q 'display-manager.service is missing' "$WORK/out"
check "a link that cannot be made: the message says the link is missing" $?
reset_state
mkdir -p "$SYSD" && ln -sfn /lib/systemd/system/other-dm.service "$SYSD/display-manager.service"
FAKE_NO_LN=1 desk
[[ "$rc" != 0 ]] && grep -q 'display-manager.service points to .*other-dm.service' "$WORK/out"
check "a link that stays elsewhere: the message shows where it points" $?
gdm_system
FAKE_NO_LN=1 desk
[[ "$rc" != 0 && ! -e "$FAKE_STATE/purge-state.log" ]]
check "no purge when the display manager switch did not verify" $?
reset_state
desk --dry-run
[[ "$rc" == 0 ]] && ! grep -q 'does not resolve' "$WORK/out"
check "dry-run does not verify the link" $?
reset_state
printf '%s\n' xdm.service slim.service nodm.service >"$FAKE_STATE/enabled"
desk
[[ "$rc" == 0 ]]
check "xdm, slim and nodm enabled: the run succeeds" $?
for dm in xdm slim nodm; do
  grep -qx "disable $dm.service" "$FAKE_STATE/systemctl.log"
  check "enabled display manager $dm is disabled" $?
done
! grep -Eq '^[^#]*(_apt_get|run_sudo)[^#]*autoremove' "$REPO_ROOT/modules/06-desktop.sh"
check "the module source never runs a real autoremove" $?

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
