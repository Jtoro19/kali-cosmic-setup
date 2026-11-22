#!/usr/bin/env bash
# modules/06-desktop.sh: COSMIC desktop, its greeter and the session base.
# Kali has no cosmic packages, so COSMIC comes from the community apt repo
# rickysarraf/debian-cosmic (see specs/desktop.md for the why and the risks).

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="desktop"
# shellcheck disable=SC2034
MODULE_DESC="COSMIC desktop and greeter (debian-cosmic repo) plus audio, bluetooth and network base for a no-desktop install"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

_DESKTOP_REPO_NAME="debian-cosmic"
_DESKTOP_REPO_URI="https://rickysarraf.github.io/debian-cosmic/"
_DESKTOP_KEY_URL="https://rickysarraf.github.io/debian-cosmic/debian-cosmic.gpg"
_DESKTOP_KEY_DEST="/etc/apt/keyrings/debian-cosmic.gpg"
# Full fingerprint of the "Debian COSMIC Repository" key, checked before the
# key is installed.
_DESKTOP_KEY_FPR="18575C957A7754E1C93B0EBA3DAEA102469D37CF"
_DESKTOP_META="cosmic-epoch-monorepo"

# Needed to fetch and verify the repository key.
_DESKTOP_PREREQS=(gnupg curl ca-certificates)

# Session base. cosmic-epoch-monorepo has no maintainer scripts and depends only
# on libraries, so everything a desktop session needs is listed here. No cups,
# avahi, firewalld, packagekit, flatpak or sshd.
_DESKTOP_BASE=(
  greetd
  xwayland
  pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth
  bluez
  network-manager
  power-profiles-daemon
  gnome-keyring libpam-gnome-keyring
  dbus-user-session
  polkitd
  xdg-desktop-portal
  xdg-user-dirs
  accountsservice
  upower
)

# Display managers to turn off so cosmic-greeter owns display-manager.service.
# greetd.service is Debian's own unit, which may be enabled by its package.
_DESKTOP_OTHER_DM=(gdm3 lightdm sddm lxdm ly greetd)

# apt preferences: the specific record comes first (apt uses the first match),
# so only the two COSMIC meta packages can come from the repo; every other
# package of the repo is blocked and can never replace a Kali package.
_desktop_pin_content() {
  cat <<'PIN'
Explanation: kali-cosmic-setup: only the COSMIC meta packages may come from the debian-cosmic repo
Package: cosmic-epoch-monorepo cosmic-utils-monorepo
Pin: origin "rickysarraf.github.io"
Pin-Priority: 100

Explanation: kali-cosmic-setup: everything else from the debian-cosmic repo is blocked, it never replaces a Kali package
Package: *
Pin: origin "rickysarraf.github.io"
Pin-Priority: -1
PIN
}

# _desktop_repo: key, sources file and pin; refresh the lists when any changed.
_desktop_repo() {
  local before="$CHANGES"
  ensure_packages "${_DESKTOP_PREREQS[@]}" || return 1
  apt_install_key "$_DESKTOP_KEY_URL" "$_DESKTOP_KEY_DEST" "$_DESKTOP_KEY_FPR" || return 1
  apt_ensure_sources "$_DESKTOP_REPO_NAME" "$_DESKTOP_REPO_URI" unstable main "$_DESKTOP_KEY_DEST" || return 1
  apt_ensure_pin "$_DESKTOP_REPO_NAME" "$(_desktop_pin_content)" || return 1
  if ((CHANGES > before)); then
    apt_update_once --force
  fi
}

# _desktop_files: the four files the package does not ship. daemon-reload only
# when a unit file changed.
_desktop_files() {
  local src="$REPO_ROOT/files/desktop" units_changed=0
  install_file "$src/cosmic-greeter-daemon.service" \
    "$(rootpath /etc/systemd/system/cosmic-greeter-daemon.service)" 0644 || return 1
  ((FILE_CHANGED)) && units_changed=1
  install_file "$src/cosmic-greeter.service" \
    "$(rootpath /etc/systemd/system/cosmic-greeter.service)" 0644 || return 1
  ((FILE_CHANGED)) && units_changed=1
  install_file "$src/cosmic-greeter.toml" \
    "$(rootpath /etc/greetd/cosmic-greeter.toml)" 0644 || return 1
  install_file "$src/cosmic-greeter.pam" \
    "$(rootpath /etc/pam.d/cosmic-greeter)" 0644 || return 1
  if ((units_changed)); then
    run_sudo systemctl daemon-reload
  fi
}

# _desktop_greeter_user: the package has no maintainer scripts, so create the
# cosmic-greeter system user and its directories from the files it ships.
_desktop_greeter_user() {
  local created=0
  if ! getent passwd cosmic-greeter >/dev/null 2>&1; then
    log_change "create system user cosmic-greeter (systemd-sysusers)"
    run_sudo systemd-sysusers cosmic-greeter.conf
    created=1
  fi
  if ((created)) || [[ ! -d "$(rootpath /var/lib/cosmic-greeter)" ]]; then
    log_change "create cosmic-greeter directories (systemd-tmpfiles)"
    run_sudo systemd-tmpfiles --create cosmic-greeter.conf
  fi
}

# _desktop_display_manager: cosmic-greeter owns display-manager.service. Other
# display managers are disabled first. getty units are never touched.
_desktop_display_manager() {
  local dm_link s
  dm_link="$(rootpath /etc/systemd/system/display-manager.service)"
  if [[ "$(readlink -f -- "$dm_link" 2>/dev/null)" != */cosmic-greeter.service ]]; then
    for s in "${_DESKTOP_OTHER_DM[@]}"; do
      if systemctl is-enabled --quiet "$s.service" >/dev/null 2>&1; then
        log_change "disable $s.service"
        run_sudo systemctl disable "$s.service"
      fi
    done
    log_change "enable display manager: cosmic-greeter"
    run_sudo systemctl enable cosmic-greeter.service
    log_warn "reboot to reach the COSMIC login"
  fi
  if ! systemctl is-enabled --quiet cosmic-greeter-daemon.service >/dev/null 2>&1; then
    log_change "enable cosmic-greeter-daemon.service"
    run_sudo systemctl enable cosmic-greeter-daemon.service
  fi
}

module_apply() {
  local p missing=0

  # First run on a fresh install: bring the system up to date before adding
  # the desktop, so the new packages match the rest of the system.
  for p in "${_DESKTOP_PREREQS[@]}" "${_DESKTOP_BASE[@]}" "$_DESKTOP_META"; do
    pkg_installed "$p" || missing=1
  done
  if ((missing)); then
    apt_update_once
    apt_full_upgrade
  fi

  _desktop_repo || return 1
  ensure_packages "${_DESKTOP_BASE[@]}" || return 1
  # The meta package's Recommends (flatpak, packagekit, appstream,
  # apt-config-icons) are deliberately not installed.
  ensure_packages --no-install-recommends "$_DESKTOP_META" || return 1

  _desktop_greeter_user || return 1
  _desktop_files || return 1
  _desktop_display_manager || return 1

  # Graphical target as the default boot target.
  if [[ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]]; then
    log_change "set default boot target: graphical.target"
    run_sudo systemctl set-default graphical.target
  fi
}
