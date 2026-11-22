#!/usr/bin/env bash
# tests/test-services.sh: modules/70-services.sh against fake systemctl and
# dpkg-query and a temporary root prefix (KCS_ROOT). Never touches the system.
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

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

SYSLOG="$FAKE_STATE/systemctl.log"
BASE_UNITS=(NetworkManager.service bluetooth.service power-profiles-daemon.service systemd-timesyncd.service fstrim.timer)
# Units that must never be touched: listening services and the VM's SSH.
FORBIDDEN='ssh|sshd|avahi|cups|firewalld|docker|mariadb|ollama'

reset_state() { # every wanted unit exists, nothing enabled, ifupdown has only lo
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT/etc/network/interfaces.d"
  : >"$FAKE_STATE/installed"
  printf '%s\n' "${BASE_UNITS[@]}" ssh.service avahi-daemon.service cups.service firewalld.service \
    systemd-networkd.service >"$FAKE_STATE/units"
  : >"$FAKE_STATE/enabled"
  printf '%s\n' 'source /etc/network/interfaces.d/*' 'auto lo' 'iface lo inet loopback' \
    >"$KCS_ROOT/etc/network/interfaces"
}

svc() { # svc <install.sh args...>: run the module; sets rc, output in $WORK/out
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only services "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

enabled_all() { # every base unit is enabled in the fake state
  local u
  for u in "${BASE_UNITS[@]}"; do grep -qx -- "$u" "$FAKE_STATE/enabled" || return 1; done
}

# --- dry-run ----------------------------------------------------------------
reset_state
svc --dry-run
[[ "$rc" == 0 ]] && ! grep -Eq '^(enable|disable|start|stop)' "$SYSLOG" 2>/dev/null && [[ ! -s "$FAKE_STATE/enabled" ]]
check "dry-run succeeds and enables nothing" $?
for u in "${BASE_UNITS[@]}"; do
  grep -q "enable.* $u" "$WORK/out"
  check "dry-run prints the enable of $u" $?
done

# --- fresh run ----------------------------------------------------------------
reset_state
before_files="$(find "$KCS_ROOT" -type f | sort | xargs md5sum)"
svc
[[ "$rc" == 0 ]] && enabled_all
check "fresh run: the five units are enabled" $?
for u in "${BASE_UNITS[@]}"; do
  [[ "$u" == NetworkManager.service ]] && continue
  grep -qx "enable --now -- $u" "$SYSLOG"
  check "fresh run: $u is enabled and started (enable --now)" $?
done
grep -qx 'enable -- NetworkManager.service' "$SYSLOG" && ! grep -qx 'enable --now -- NetworkManager.service' "$SYSLOG" &&
  ! grep -Eq '^(start|restart).*NetworkManager' "$SYSLOG"
check "fresh run: NetworkManager is enabled for the next boot, never started now" $?
! grep -Eq "$FORBIDDEN" "$FAKE_STATE/enabled" && ! grep -E '^(enable|disable|start|stop|restart|mask|unmask)' "$SYSLOG" | grep -Eq "$FORBIDDEN"
check "no sshd, avahi, cups, firewalld, docker, mariadb or ollama unit is touched" $?
! grep -Eq '^(disable|stop|restart|mask|reload)' "$SYSLOG"
check "nothing is disabled, stopped, restarted or masked (the running network is never cut)" $?
! grep -Eq '^(enable|start|disable|stop|restart).*(ifupdown|networking|networkd)' "$SYSLOG"
check "ifupdown's networking.service and systemd-networkd are not touched" $?
[[ "$(find "$KCS_ROOT" -type f | sort | xargs md5sum)" == "$before_files" ]]
check "the module writes or changes no file (interfaces and NetworkManager.conf stay as they are)" $?
! grep '\[warn\]' "$WORK/out" | grep -vq 'next reboot'
check "fresh run on a plain system: no warning but the reboot notice" $?

# --- second run changes nothing ----------------------------------------------
svc
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" &&
  ! grep -Eq '^(enable|disable|start|stop|restart)' "$SYSLOG"
check "second run: total changes: 0 and no systemctl change" $?
svc --dry-run
grep -q 'Nothing to change' "$WORK/out"
check "dry-run after a real run says Nothing to change" $?

# --- units that do not exist are skipped --------------------------------------
reset_state
grep -vx 'bluetooth.service' "$FAKE_STATE/units" >"$FAKE_STATE/units.new" && mv "$FAKE_STATE/units.new" "$FAKE_STATE/units"
svc
[[ "$rc" == 0 ]] && ! grep -qx 'bluetooth.service' "$FAKE_STATE/enabled" && grep -qx 'fstrim.timer' "$FAKE_STATE/enabled"
check "a missing unit file is skipped, the others are enabled" $?

# --- NetworkManager vs ifupdown ------------------------------------------------
reset_state
printf '%s\n' 'auto lo' 'iface lo inet loopback' 'allow-hotplug eth0' 'iface eth0 inet dhcp' \
  >"$KCS_ROOT/etc/network/interfaces"
svc
[[ "$rc" == 0 ]] && grep -qx 'enable -- NetworkManager.service' "$SYSLOG" && ! grep -qx 'enable --now -- NetworkManager.service' "$SYSLOG"
check "ifupdown owns eth0: NetworkManager is enabled for the next boot, not started now" $?
grep -q '\[warn\].*eth0' "$WORK/out"
check "ifupdown owns eth0: warns that NetworkManager leaves it unmanaged" $?
grep -qx 'enable --now -- bluetooth.service' "$SYSLOG" && grep -qx 'enable --now -- fstrim.timer' "$SYSLOG"
check "ifupdown owns eth0: the other units are still enabled and started" $?
svc
grep -q 'total changes: 0' "$WORK/out"
check "ifupdown case: second run changes nothing" $?
reset_state
printf '%s\n' 'iface eth1 inet6 auto' >"$KCS_ROOT/etc/network/interfaces.d/extra"
svc
grep -qx 'enable -- NetworkManager.service' "$SYSLOG" && grep -q '\[warn\].*eth1' "$WORK/out"
check "an interface in interfaces.d is detected too" $?
reset_state
printf '%s\n' '# iface eth0 inet dhcp' 'auto lo' 'iface lo inet loopback' >"$KCS_ROOT/etc/network/interfaces"
svc
grep -qx 'enable -- NetworkManager.service' "$SYSLOG" && ! grep '\[warn\]' "$WORK/out" | grep -vq 'next reboot'
check "a commented iface and the loopback do not count as ifupdown-managed (no warning but the reboot notice)" $?
reset_state
rm -rf -- "$KCS_ROOT/etc/network"
svc
grep -qx 'enable -- NetworkManager.service' "$SYSLOG"
check "no /etc/network/interfaces at all: plain enable, not started" $?
reset_state
svc
grep -q '\[warn\].*NetworkManager.*next reboot' "$WORK/out"
check "NetworkManager enabled but not active: a warning says it starts after the next reboot" $?
reset_state
echo NetworkManager.service >"$FAKE_STATE/active"
svc
! grep -q 'next reboot' "$WORK/out"
check "NetworkManager already active: no reboot warning" $?
reset_state
echo NetworkManager.service >"$FAKE_STATE/active"
svc
[[ "$rc" == 0 ]] && grep -qx 'enable -- NetworkManager.service' "$SYSLOG" && ! grep -Eq '^(stop|restart)' "$SYSLOG"
check "NetworkManager already active but not enabled: enabled, never restarted" $?

# --- masked units (the admin's decision, never unmasked) -----------------------
reset_state
echo bluetooth.service >"$FAKE_STATE/masked"
svc
[[ "$rc" == 0 ]] &&
  ! grep -qx 'bluetooth.service' "$FAKE_STATE/enabled" && grep -qx 'fstrim.timer' "$FAKE_STATE/enabled" &&
  ! grep -Eq '^(enable|unmask|mask).*bluetooth' "$SYSLOG" && grep -q '\[info\].*bluetooth.*masked' "$WORK/out"
check "a masked unit is skipped with an info line; the run succeeds and the rest is enabled" $?
svc
grep -q 'total changes: 0' "$WORK/out"
check "masked unit: second run changes nothing" $?
reset_state
echo NetworkManager.service >"$FAKE_STATE/masked"
svc
[[ "$rc" == 0 ]] && ! grep -Eq '^(enable|unmask).*NetworkManager' "$SYSLOG" && grep -q '\[info\].*NetworkManager.*masked' "$WORK/out"
check "a masked NetworkManager is skipped with an info line" $?
reset_state
echo NetworkManager.service >"$FAKE_STATE/masked"
printf '%s\n' 'iface eth0 inet dhcp' >"$KCS_ROOT/etc/network/interfaces"
svc
[[ "$rc" == 0 ]] && ! grep -Eq '^(enable|unmask).*NetworkManager' "$SYSLOG"
check "a masked NetworkManager with ifupdown config is skipped too" $?
reset_state
echo systemd-networkd.service >"$FAKE_STATE/active"
svc
[[ "$rc" == 0 ]] && ! grep -Eq '^(enable|start).*NetworkManager' "$SYSLOG" && grep -q '\[warn\].*systemd-networkd' "$WORK/out"
check "systemd-networkd active: NetworkManager is left alone with a warning" $?
reset_state
echo NetworkManager.service >"$FAKE_STATE/enabled"
printf '%s\n' 'iface eth0 inet dhcp' >"$KCS_ROOT/etc/network/interfaces"
svc
! grep -Eq '^(enable|start).*NetworkManager' "$SYSLOG"
check "NetworkManager already enabled: not touched even with ifupdown config" $?

# --- time daemon conflicts -----------------------------------------------------
reset_state
echo chrony >"$FAKE_STATE/installed"
svc
[[ "$rc" == 0 ]] && ! grep -Eq '^(enable|start).*systemd-timesyncd' "$SYSLOG" && grep -q 'chrony' "$WORK/out"
check "chrony installed: systemd-timesyncd is not enabled (one time daemon only)" $?

# --- failure -------------------------------------------------------------------
reset_state
FAKE_FAIL='systemctl enable --now -- fstrim.timer' svc
[[ "$rc" != 0 ]]
check "a failing enable fails the module" $?

# --- source guards ------------------------------------------------------------
! grep -v '^[[:space:]]*#' "$REPO_ROOT/modules/70-services.sh" | grep -Eq 'ssh|avahi|cups|firewalld'
check "the module source names no listening service as something to enable" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
