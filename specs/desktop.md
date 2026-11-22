# desktop

## Purpose

Turn a Kali Linux install made with **no desktop** into a COSMIC desktop with
its graphical login (cosmic-greeter on greetd). On a machine that already has
it, it changes nothing.

## Source of truth

The EndeavourOS module (`eos-cosmic-setup`, `modules/06-desktop.sh`) and the
verified findings recorded in `specs/000-plan.md` (research of 2026-11-22).
The four files shipped under `files/desktop/` are copied from upstream
`pop-os/cosmic-greeter`, tag `epoch-1.11.0`, with the changes listed below.

## Why this install method

- Neither Kali (kali-rolling) nor Debian testing/sid has `cosmic-*` packages
  (Debian only has the RFP bugs #1120089 and #1120090). Building the full
  desktop from source on every install is out of scope.
- The community apt repo `rickysarraf/debian-cosmic` is signed, builds the full
  upstream epoch on a `debian:testing` base, and ships it as one package,
  `cosmic-epoch-monorepo` (1.11.0, about 228 MB, includes cosmic-greeter).
- Risk: it is a single-maintainer community repo with weekly rebuilds, not
  supported by Kali or Debian. Mitigations: the key fingerprint is verified
  before the key is installed (the module aborts on mismatch), and an apt pin
  stops the repo from ever replacing a Kali package.
- Fallback: if the repo does not install or run on Kali, stop the module and
  report it. There is no source-build fallback.

## What the module does

1. If any package below is missing (first run), `apt-get update` and one
   `apt-get full-upgrade` first, so the new packages match the system.
2. Installs `gnupg`, `curl` and `ca-certificates` (needed to fetch and check
   the key).
3. Installs the repository key `/etc/apt/keyrings/debian-cosmic.gpg` from
   `https://rickysarraf.github.io/debian-cosmic/debian-cosmic.gpg` (ASCII
   armored, dearmored), only after checking that it holds exactly one key with
   the fingerprint `18575C957A7754E1C93B0EBA3DAEA102469D37CF` (uid "Debian
   COSMIC Repository"). A mismatch aborts the module before anything is
   installed.
4. Writes `/etc/apt/sources.list.d/debian-cosmic.sources` (deb822: `Types:
   deb`, `URIs: https://rickysarraf.github.io/debian-cosmic/`, `Suites:
   unstable`, `Components: main`, `Signed-By` the key above).
5. Writes `/etc/apt/preferences.d/debian-cosmic`: the specific record first
   (`cosmic-epoch-monorepo`, `cosmic-utils-monorepo` at priority 100), then
   `Package: *` at priority -1 for the repo's origin. apt uses the first
   matching record, so only those two packages can come from the repo and it
   can never replace a Kali package. An `Explanation:` line documents it.
6. Runs `apt-get update` again when the key, sources or pin changed.
7. Installs the session base (Kali names): `greetd`, `xwayland`, `pipewire`,
   `pipewire-pulse`, `pipewire-alsa`, `wireplumber`, `libspa-0.2-bluetooth`,
   `bluez`, `network-manager`, `power-profiles-daemon`, `gnome-keyring`,
   `libpam-gnome-keyring`, `dbus-user-session`, `polkitd`,
   `xdg-desktop-portal`, `xdg-user-dirs`, `accountsservice`, `upower`.
   No cups, avahi, firewalld, packagekit, flatpak or sshd.
8. Installs `cosmic-epoch-monorepo` with `--no-install-recommends` (its
   Recommends pull flatpak, packagekit, appstream and apt-config-icons, which
   this repo drops). `cosmic-utils-monorepo` is not installed.
9. The package has **no maintainer scripts** and depends only on libraries, so
   the module does what they would do: creates the `cosmic-greeter` system
   user with `systemd-sysusers cosmic-greeter.conf` (only when the user is
   missing), runs `systemd-tmpfiles --create cosmic-greeter.conf` (when the
   user was just created or `/var/lib/cosmic-greeter` is missing), and
   installs four files from `files/desktop/` (below). `systemctl
   daemon-reload` runs only when a unit file changed.
10. Display manager: disables `greetd.service` (Debian's own unit, which may
    have been enabled by the package install), `gdm3`, `lightdm`, `sddm`,
    `lxdm`, `ly`, `xdm`, `slim` and `nodm` if enabled, then enables `cosmic-greeter.service` and
    `cosmic-greeter-daemon.service`. `getty@` units are never disabled or
    masked.
    After enabling, it checks that `display-manager.service` resolves to
    `cosmic-greeter.service` and fails with a clear message if not.
11. Sets `graphical.target` as the default boot target when it is not.

The extra packages beyond the plan's list (`pipewire-alsa`,
`libspa-0.2-bluetooth`, `libpam-gnome-keyring`, `dbus-user-session`,
`polkitd`, `xdg-desktop-portal`, `accountsservice`, `upower`, `greetd`) are
there because `cosmic-epoch-monorepo` has no maintainer scripts and depends
only on libraries: nothing else pulls in the audio/bluetooth plumbing, the
PAM keyring module, the user bus, polkit, portals, accounts and power
services, or the greetd binary that cosmic-greeter runs.

NetworkManager, bluetooth and the like are enabled by the `services` module,
not here (same split as the reference).

## Shipped files (`files/desktop/`)

| Installed as | Origin and changes |
|--------------|--------------------|
| `/etc/systemd/system/cosmic-greeter-daemon.service` | upstream unit, verbatim plus a header comment |
| `/etc/systemd/system/cosmic-greeter.service` | upstream unit with two changes: `ExecStart` uses `/usr/sbin/greetd` (Debian's path) and the `[Install]` section is active with `Alias=display-manager.service` |
| `/etc/greetd/cosmic-greeter.toml` | upstream, verbatim plus a header comment; Debian's `/etc/greetd/config.toml` is left untouched |
| `/etc/pam.d/cosmic-greeter` | upstream `debian/cosmic-greeter.pam`, verbatim plus a header comment (`#%PAM-1.0` stays first) |

A different existing file is saved as `<file>.bak.<timestamp>` first.

## Ordering

`06-desktop.sh` keeps the reference's number. `MODULE_DEPS` is empty: the
reference's `pacman-conf` dependency does not exist on Kali.

## Hardware detection

None here; see the `drivers` module.

## Idempotency check

`dpkg-query` per package, `cmp` per shipped file and per apt file, the key
fingerprint on the installed key, `getent passwd cosmic-greeter`,
`systemctl is-enabled` and `/etc/systemd/system/display-manager.service`
resolving to `cosmic-greeter.service`. All read-only. A second run reports
"Nothing to change".

## Recovery (TTY)

If the graphical login fails, text consoles still work. The module never
disables or masks getty units; the shipped `cosmic-greeter.service` conflicts
with `getty@tty1` by upstream design (the greeter takes VT1), and the other
VTs keep their gettys for recovery:

1. Press Ctrl+Alt+F2 and log in.
2. `sudo systemctl disable cosmic-greeter.service`
3. `sudo systemctl set-default multi-user.target`
4. `sudo reboot`

## Revert

1. `sudo systemctl disable cosmic-greeter.service cosmic-greeter-daemon.service`
   and `sudo systemctl set-default multi-user.target`.
2. Remove the four shipped files: `/etc/systemd/system/cosmic-greeter.service`,
   `/etc/systemd/system/cosmic-greeter-daemon.service`,
   `/etc/greetd/cosmic-greeter.toml`, `/etc/pam.d/cosmic-greeter`; then
   `sudo systemctl daemon-reload`.
3. `sudo apt-get purge cosmic-epoch-monorepo` and `sudo apt-get autoremove`.
4. Remove `/etc/apt/sources.list.d/debian-cosmic.sources`,
   `/etc/apt/preferences.d/debian-cosmic` and
   `/etc/apt/keyrings/debian-cosmic.gpg`, then `sudo apt-get update`.
5. Restore any `*.bak.<timestamp>` files next to the files above.

## Verification

- `./install.sh --only desktop --dry-run` lists the repo, key, pin, packages,
  files, units and target, and changes nothing.
- On Kali after a real run: `readlink -f /etc/systemd/system/display-manager.service`
  ends in `cosmic-greeter.service`, `systemctl get-default` is
  `graphical.target`, `apt-cache policy cosmic-epoch-monorepo` shows the repo
  at priority 100, and after a reboot the COSMIC login appears.
- A second `./install.sh --only desktop --dry-run` reports nothing to change.
- `tests/test-desktop.sh` covers the logic with fake commands.
