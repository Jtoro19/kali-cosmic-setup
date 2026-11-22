#!/usr/bin/env bash
# modules/70-services.sh: enable the base system services (see specs/services.md).
# It only enables; it never disables, stops, restarts or masks anything, and it
# never enables a service that listens on the network.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="services"
# shellcheck disable=SC2034
MODULE_DESC="base system services: NetworkManager, bluetooth, power-profiles-daemon, systemd-timesyncd, fstrim.timer"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Enabled when their unit file exists (the desktop module installs the
# packages). None of them listens on a network port.
_SERVICES_BASE=(
  NetworkManager.service
  bluetooth.service
  power-profiles-daemon.service
  systemd-timesyncd.service
  fstrim.timer
)

# Packages that provide another time daemon; only one may run.
_SERVICES_OTHER_TIME=(chrony ntpsec ntp openntpd)

# _services_ifupdown_ifaces: print the interfaces (not lo) that ifupdown
# configures in /etc/network/interfaces and /etc/network/interfaces.d/*, one
# per line. NetworkManager leaves those unmanaged (its [ifupdown] managed=false
# default).
_services_ifupdown_ifaces() {
  local f
  local -a files=()
  files+=("$(rootpath /etc/network/interfaces)")
  for f in "$(rootpath /etc/network/interfaces.d)"/*; do
    [[ -f "$f" ]] && files+=("$f")
  done
  for f in "${files[@]}"; do
    [[ -f "$f" ]] && awk '$1 == "iface" && $2 != "lo" { print $2 }' "$f"
  done | sort -u
}

# _services_networkmanager: NetworkManager must never cut the network of the
# running system. It is never stopped, restarted or started now: it is only
# enabled (`systemctl enable`, no --now) and starts at the next boot. When
# ifupdown configures an interface, a warning says NetworkManager leaves it to
# ifupdown. When systemd-networkd is in use, two network managers would fight,
# so NetworkManager is left alone. A masked unit is the admin's decision.
_services_networkmanager() {
  local unit=NetworkManager.service ifaces
  system_unit_exists "$unit" || return 0

  if systemctl is-enabled --quiet systemd-networkd.service >/dev/null 2>&1 ||
    systemctl is-active --quiet systemd-networkd.service >/dev/null 2>&1; then
    log_warn "systemd-networkd is in use; not enabling NetworkManager (two network managers would fight over the interfaces)"
    return 0
  fi
  if systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
    return 0
  fi
  if system_unit_masked "$unit"; then
    log_info "$unit is masked: leaving it alone"
    return 0
  fi

  ifaces="$(_services_ifupdown_ifaces | tr '\n' ' ')"
  ifaces="${ifaces% }"
  if [[ -n "$ifaces" ]]; then
    log_warn "ifupdown configures ${ifaces} in /etc/network/interfaces: NetworkManager leaves it unmanaged and your network stays as it is"
  fi
  log_change "enable $unit (for the next boot, not started now)"
  run_sudo systemctl enable -- "$unit"
}

module_apply() {
  local unit pkg
  for unit in "${_SERVICES_BASE[@]}"; do
    case "$unit" in
      NetworkManager.service)
        _services_networkmanager || return 1
        ;;
      systemd-timesyncd.service)
        for pkg in "${_SERVICES_OTHER_TIME[@]}"; do
          if pkg_installed "$pkg"; then
            log_info "$pkg is installed: leaving systemd-timesyncd alone (one time daemon only)"
            continue 2
          fi
        done
        ensure_system_unit_enabled "$unit" || return 1
        ;;
      *)
        ensure_system_unit_enabled "$unit" || return 1
        ;;
    esac
  done
}
