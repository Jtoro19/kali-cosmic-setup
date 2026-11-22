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

# Other display managers to turn off so Debian's greetd.service owns
# display-manager.service (greetd itself is the one we keep).
_DESKTOP_OTHER_DM=(gdm3 lightdm sddm lxdm ly xdm slim nodm)

# A Kali "default tools" install still ships GDM and GNOME Shell; they are
# purged (under guards) once greetd is the display manager.
_DESKTOP_GDM_PKGS=(gdm3 gnome-shell)

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
    apt_update_once --force || return 1
  fi
}

# _desktop_files: the files the package does not ship. daemon-reload only when
# a unit or drop-in changed. install_file reports through the global
# FILE_CHANGED (see lib/common.sh), so it is read right after each call.
_desktop_files() {
  local src="$REPO_ROOT/files/desktop" units_changed=0
  install_file "$src/cosmic-greeter-daemon.service" \
    "$(rootpath /etc/systemd/system/cosmic-greeter-daemon.service)" 0644 || return 1
  units_changed=$((units_changed | FILE_CHANGED))
  install_file "$src/greetd-cosmic.conf" \
    "$(rootpath /etc/systemd/system/greetd.service.d/cosmic-greeter.conf)" 0644 || return 1
  units_changed=$((units_changed | FILE_CHANGED))
  install_file "$src/cosmic-greeter.toml" \
    "$(rootpath /etc/greetd/cosmic-greeter.toml)" 0644 || return 1
  install_file "$src/cosmic-greeter.pam" \
    "$(rootpath /etc/pam.d/cosmic-greeter)" 0644 || return 1
  if ((units_changed)); then
    run_sudo systemctl daemon-reload || return 1
  fi
}

# _desktop_migrate_old_unit: an earlier version of this module installed its
# own /etc/systemd/system/cosmic-greeter.service as the display manager alias.
# Debian's greetd postinst would overwrite that alias, so disable and remove it
# (with a backup). Called only after the greetd link exists, so a failure
# earlier never leaves the machine without a display-manager link.
_desktop_migrate_old_unit() {
  local old
  old="$(rootpath /etc/systemd/system/cosmic-greeter.service)"
  [[ -e "$old" || -L "$old" ]] || return 0
  log_change "remove the old cosmic-greeter.service (replaced by the greetd drop-in)"
  run_sudo_may_fail systemctl disable cosmic-greeter.service ||
    log_warn "could not disable the old cosmic-greeter.service, removing the file anyway"
  backup_file "$old"
  _priv_run "$old" rm -f -- "$old" || return 1
  run_sudo systemctl daemon-reload || return 1
}

# _desktop_greeter_user: the package has no maintainer scripts, so create the
# cosmic-greeter system user and its directories from the files it ships.
_desktop_greeter_user() {
  local created=0
  if ! getent passwd cosmic-greeter >/dev/null 2>&1; then
    log_change "create system user cosmic-greeter (systemd-sysusers)"
    run_sudo systemd-sysusers cosmic-greeter.conf || return 1
    created=1
  fi
  if ((created)) || [[ ! -d "$(rootpath /var/lib/cosmic-greeter)" ]]; then
    log_change "create cosmic-greeter directories (systemd-tmpfiles)"
    run_sudo systemd-tmpfiles --create cosmic-greeter.conf || return 1
  fi
}

# _desktop_link_target <link>: where a link resolves to (readlink -f, or the
# plain link text when a parent directory is missing).
_desktop_link_target() {
  readlink -f -- "$1" 2>/dev/null || readlink -- "$1" 2>/dev/null || true
}

# _desktop_dm_is_greetd: true when display-manager.service resolves to
# greetd.service.
_desktop_dm_is_greetd() {
  local target
  target="$(_desktop_link_target "$(rootpath /etc/systemd/system/display-manager.service)")"
  [[ "${target##*/}" == greetd.service ]]
}

# _desktop_verify_dm: greetd must be the display manager by both the unit link
# and /etc/X11/default-display-manager. Logs the reason and returns 1 if not.
_desktop_verify_dm() {
  local dm_file dm_link target
  dm_file="$(rootpath /etc/X11/default-display-manager)"
  dm_link="$(rootpath /etc/systemd/system/display-manager.service)"
  if ! _desktop_dm_is_greetd; then
    target="$(readlink -- "$dm_link" 2>/dev/null || true)"
    if [[ -z "$target" && ! -e "$dm_link" ]]; then
      log_error "display-manager.service is missing: $dm_link was not created. Fix it and run the installer again"
    else
      log_error "display-manager.service points to ${target:-$dm_link}, not greetd.service. Fix it and run the installer again"
    fi
    return 1
  fi
  if [[ ! -f "$dm_file" || "$(<"$dm_file")" != /usr/sbin/greetd ]]; then
    log_error "/etc/X11/default-display-manager is not /usr/sbin/greetd"
    return 1
  fi
}

# _desktop_debconf_dm: the current answer of shared/default-x-display-manager
# (empty when unknown). debconf's database is root-only, hence sudo_read.
# Read-only.
_desktop_debconf_dm() {
  local out
  out="$(sudo_read debconf-show greetd)" || out=""
  printf '%s\n' "$out" |
    awk '/shared\/default-x-display-manager:/ { sub(/^.*: */, ""); print; exit }'
}

# _desktop_link_greetd: make display-manager.service link to greetd.service,
# like Debian's postinst (`ln -sf`), only when it does not resolve there yet.
# Never touches a link masked to /dev/null: fails instead. Sets
# _DESKTOP_LINK_CHANGED to 1 when it linked (or would, in dry-run), else 0.
_DESKTOP_LINK_CHANGED=0
_desktop_link_greetd() {
  local dm_link
  dm_link="$(rootpath /etc/systemd/system/display-manager.service)"
  _DESKTOP_LINK_CHANGED=0
  if [[ "$(readlink -- "$dm_link" 2>/dev/null)" == /dev/null ]]; then
    log_error "display-manager.service is masked (links to /dev/null); not unmasking it. Unmask it yourself if that is intended, then run the installer again"
    return 1
  fi
  if ! _desktop_dm_is_greetd; then
    log_change "link display-manager.service to greetd.service"
    _priv_run "$dm_link" mkdir -p -- "$(dirname "$dm_link")" || return 1
    _priv_run "$dm_link" ln -sfn -- /lib/systemd/system/greetd.service "$dm_link" || return 1
    _DESKTOP_LINK_CHANGED=1
  fi
}

# _desktop_display_manager: make Debian's greetd.service the display manager,
# the same three things its postinst does: the debconf answer, the
# /etc/X11/default-display-manager file and the display-manager.service link.
# The drop-in (installed earlier) points greetd at the COSMIC config. The
# module never disables or masks any getty unit; greetd runs on VT7 and
# conflicts only with getty@tty7, so getty@tty1 stays free for recovery.
_desktop_display_manager() {
  local s link_changed=0

  if ! systemctl is-enabled --quiet cosmic-greeter-daemon.service >/dev/null 2>&1; then
    log_change "enable cosmic-greeter-daemon.service"
    run_sudo systemctl enable cosmic-greeter-daemon.service || return 1
  fi

  if [[ "$(_desktop_debconf_dm)" != greetd ]]; then
    log_change "debconf: shared/default-x-display-manager = greetd"
    run_sudo debconf-set-selections <<<"greetd shared/default-x-display-manager select greetd" || return 1
  fi

  ensure_file_content "$(rootpath /etc/X11/default-display-manager)" /usr/sbin/greetd || return 1

  _desktop_link_greetd || return 1
  ((_DESKTOP_LINK_CHANGED)) && link_changed=1
  if [[ "$DRY_RUN" != "1" ]]; then
    _desktop_verify_dm || return 1
  fi

  # `systemctl disable` also processes the unit's [Install] Alias=: gdm3 and the
  # old cosmic-greeter.service both declare Alias=display-manager.service, so
  # on some systemd versions disabling them deletes display-manager.service
  # even though it now points at greetd. Hence the link is ensured and verified
  # again afterwards. The old unit is only touched after the first verified
  # link, so an earlier failure never leaves the machine without one.
  for s in "${_DESKTOP_OTHER_DM[@]}"; do
    if systemctl is-enabled --quiet "$s.service" >/dev/null 2>&1; then
      log_change "disable $s.service"
      run_sudo systemctl disable "$s.service" || return 1
    fi
  done

  _desktop_migrate_old_unit || return 1

  # Dry-run never creates the link, so the second pass would only repeat it.
  if [[ "$DRY_RUN" != "1" ]]; then
    _desktop_link_greetd || return 1
    ((_DESKTOP_LINK_CHANGED)) && link_changed=1
    _desktop_verify_dm || return 1
  fi
  if ((link_changed)); then
    log_warn "reboot to reach the COSMIC login"
  fi
}

# _desktop_in_graphical_session: true when this installer runs inside an X11 or
# Wayland session.
_desktop_in_graphical_session() {
  case "${XDG_SESSION_TYPE:-}" in x11 | wayland) return 0 ;; esac
  [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]
}

# _desktop_purge_gdm: remove gdm3 and gnome-shell, only after greetd is the
# verified display manager. A runtime simulation decides: a kali-* package in
# it means the purge is skipped (GDM stays installed but disabled). Inside a
# graphical session served by gdm3 the purge is skipped too, since it would
# stop gdm3 and kill the session running the installer. autoremove is never
# run for real: it is only simulated and the result reported.
_desktop_purge_gdm() {
  local p out
  local -a present=() would=() kali=() orphans=()
  for p in "${_DESKTOP_GDM_PKGS[@]}"; do
    if pkg_installed "$p"; then
      present+=("$p")
    fi
  done
  ((${#present[@]})) || return 0

  if [[ "$DRY_RUN" != "1" ]]; then
    _desktop_verify_dm || return 1
  fi

  if ! out="$(apt-get -s purge "${present[@]}" 2>&1)"; then
    log_error "cannot simulate the purge of ${present[*]}: $out"
    return 1
  fi
  mapfile -t would < <(printf '%s\n' "$out" | awk '/^(Purg|Remv) / { print $2 }' | sort -u)
  if ((${#would[@]} == 0)); then
    log_error "the simulated purge of ${present[*]} lists no package; not purging"
    return 1
  fi
  mapfile -t kali < <(printf '%s\n' "${would[@]}" | { grep '^kali-' || true; })
  if ((${#kali[@]} > 0)); then
    log_warn "not purging ${present[*]}: it would also remove Kali packages (${kali[*]}). GDM is kept installed but disabled; greetd is the display manager"
    return 0
  fi

  if _desktop_in_graphical_session && systemctl is-active --quiet gdm3.service >/dev/null 2>&1; then
    log_warn "not purging ${present[*]} now: this installer runs inside the graphical session of gdm3, and the purge would end it. Reboot (greetd takes over), then run ./install.sh --only desktop again from the new session or a text console"
    return 0
  fi

  log_change "purge ${present[*]} (removes: ${would[*]})"
  _apt_get purge "${present[@]}" || return 1
  if [[ "$DRY_RUN" != "1" ]]; then
    _desktop_verify_dm || return 1
  fi

  if out="$(apt-get -s autoremove 2>&1)"; then
    mapfile -t orphans < <(printf '%s\n' "$out" | awk '/^Remv / { print $2 }')
  else
    log_warn "could not simulate autoremove: $out"
  fi
  log_info "orphans (not removed, report to the owner): ${orphans[*]:-none}"
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
    run_sudo systemctl set-default graphical.target || return 1
  fi

  _desktop_purge_gdm || return 1
}
