# services

## Purpose

Enable the base system services a desktop needs, and nothing that listens on
the network. The module only enables; it never disables, stops, restarts or
masks a unit, so it cannot cut the network of the running system.

## Source of truth

The reference module enabled a longer list. Kept here: NetworkManager,
bluetooth, power-profiles-daemon, systemd-timesyncd, fstrim.timer. Dropped
on purpose (plan: default modules never enable a listening service): the
firewall daemon, the mDNS daemon, the print server, the VMware units, the
`SERVICES_SSHD` switch and the MariaDB and Docker steps (those belong to the
opt-in `packages-dev` module, with localhost-only binding).

## Files and packages touched

- No files, no packages (the desktop module installs `network-manager`,
  `bluez` and `power-profiles-daemon`; `systemd-timesyncd` and `util-linux`
  ship with Kali).
- Units enabled, each only when its unit file exists, it is not enabled yet
  and it is not masked, with `systemctl enable --now` (NetworkManager is the
  exception: plain `systemctl enable`, see Decisions):
  `NetworkManager.service`, `bluetooth.service`,
  `power-profiles-daemon.service`, `systemd-timesyncd.service`,
  `fstrim.timer`. None of them opens a network port (the Bluetooth unit has
  its own start condition: it stays inactive without an adapter, which is not
  a failure).
- The SSH server unit is not touched in either direction: it is not part of
  this repo's policy (a test machine may rely on it).

## Hardware detection

None. `bluetooth.service` is enabled everywhere; it starts only when a
Bluetooth adapter exists.

## Decisions

- **NetworkManager and ifupdown.** Kali's installer writes
  `/etc/network/interfaces` (ifupdown) and ships NetworkManager with
  `[ifupdown] managed=false`, so an interface that `/etc/network/interfaces`
  configures is left unmanaged by NetworkManager. The safest behavior, because
  the machine may be reached over SSH:
  1. The module never edits `/etc/network/interfaces` or
     `NetworkManager.conf`, never stops or restarts any network unit and never
     disables ifupdown's `networking.service`.
  2. NetworkManager is enabled with plain `systemctl enable`, never
     `--now`, whether or not it is already active: it starts at the next boot.
     Starting it on a running machine could re-plumb a connection, and the
     machine may be reached over SSH ("never cut the network of the running
     system"). The cost is that NetworkManager is not running until a reboot; when it was
     just enabled and is not active, the module logs a warning saying it starts
     after the next reboot, so the notice shows in the run output.
  3. When ifupdown configures an interface (any `iface <name>` other than
     `lo` in `/etc/network/interfaces` or `interfaces.d/*`), a warning names the
     interface: NetworkManager leaves it to ifupdown, so the network stays
     exactly as it is. The user can later move that interface to NetworkManager
     by hand.
  4. When `systemd-networkd` is enabled or active, NetworkManager is not
     enabled at all (a warning): two network managers on one interface would
     fight, and the existing one keeps the network.
  5. When NetworkManager is already enabled, the module does nothing.
- **Masked units.** A unit the admin masked (`systemctl is-enabled` prints
  `masked`) is skipped with an info line: the module never unmasks or
  overrides, and `systemctl enable` would fail on it and end the whole run.
- **One time daemon.** If `chrony`, `ntpsec`, `ntp` or `openntpd` is
  installed, `systemd-timesyncd` is not enabled (info line). Only one time
  daemon may run.
- Units are enabled only when their unit file exists, so a trimmed system does
  not fail.
- Group membership (docker, adb) moves to `packages-dev`, where those packages
  are installed.

## Idempotency check

Each unit is checked with `systemctl is-enabled` before any change. A second
run prints `total changes: 0`.

## Revert

`sudo systemctl disable --now <unit>` for any of the five units. Nothing else
was changed.

## Verification

```bash
./install.sh --only services          # then again: "total changes: 0"
systemctl is-enabled NetworkManager bluetooth power-profiles-daemon systemd-timesyncd fstrim.timer
systemctl --failed                    # nothing new
ss -ltnup                             # no new listener
nmcli device                          # network unchanged
./install.sh --only services --dry-run   # "Nothing to change"
```
