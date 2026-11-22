# desktop

## Purpose

Turn a Kali Linux install made with **no desktop** into a COSMIC desktop with
its graphical login (cosmic-greeter on greetd). On a machine that already has
it, it changes nothing.

Baseline (owner finding, 2026-11-22, verified on a real Kali install): choosing
"no desktop" in tasksel but keeping the default tools (`kali-linux-default`
metapackages) still leaves `gdm3` 50.2 and `gnome-shell` 50.4 installed, with
`/etc/X11/default-display-manager` = `/usr/sbin/gdm3`. `kali-linux-default` does
not depend on gdm3 or GNOME, and `apt-get -s purge gdm3 gnome-shell` removes
exactly `gdm3 gnome-browser-connector gnome-session gnome-shell` and no `kali-*`
package. So the module also makes greetd the display manager and then purges
GDM and GNOME Shell, under the guards below.

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
10. Display manager (all non-interactive, each step idempotent, in this
    order; see "Display manager design" below):
    1. enables `cosmic-greeter-daemon.service`;
    2. debconf: `greetd shared/default-x-display-manager select greetd` via
       `debconf-set-selections`, only when `debconf-show greetd` reports a
       different value;
    3. `/etc/X11/default-display-manager` = `/usr/sbin/greetd` (backup when it
       differs);
    4. `ln -sfn /lib/systemd/system/greetd.service
       /etc/systemd/system/display-manager.service`, only when the link does
       not already resolve to `greetd.service`. A link masked to `/dev/null`
       fails the module (never unmasked);
    5. verifies that `display-manager.service` resolves to `greetd.service`
       (the error says whether the link is missing or where it points);
    6. disables any other enabled display manager (`gdm3`, `lightdm`, `sddm`,
       `lxdm`, `ly`, `xdm`, `slim`, `nodm`), then disables and removes (with a
       backup) the `cosmic-greeter.service` of an earlier version of this
       module and reloads systemd. The old unit is removed only after the
       greetd link is verified, so a failure never leaves no
       display-manager link;
    7. because `systemctl disable` processes the units' `Alias=
       display-manager.service` and may delete the link, the link is ensured
       again (same idempotent `ln`, still failing on a masked link) and
       verified a second time.
    `getty@` units are never disabled or masked.
11. Sets `graphical.target` as the default boot target when it is not.
12. GDM purge (below), only after step 10 succeeded and was verified.

The extra packages beyond the plan's list (`pipewire-alsa`,
`libspa-0.2-bluetooth`, `libpam-gnome-keyring`, `dbus-user-session`,
`polkitd`, `xdg-desktop-portal`, `accountsservice`, `upower`, `greetd`) are
there because `cosmic-epoch-monorepo` has no maintainer scripts and depends
only on libraries: nothing else pulls in the audio/bluetooth plumbing, the
PAM keyring module, the user bus, polkit, portals, accounts and power
services, or the greetd binary that cosmic-greeter runs.

NetworkManager, bluetooth and the like are enabled by the `services` module,
not here (same split as the reference).

## Display manager design

Findings about Debian's `greetd` 0.10.3-7 (Kali ships the same):

- It is a debconf display manager like `gdm3`: templates `greetd/daemon_name`
  (default `/usr/sbin/greetd`) and `shared/default-x-display-manager`. Its
  postinst, on **every** configure (also upgrades), runs `ln -sf
  /lib/systemd/system/$(basename $(cat /etc/X11/default-display-manager)).service
  /etc/systemd/system/display-manager.service` (unless that link is masked to
  `/dev/null`). `gdm3`'s maintainer scripts do the same, and its prerm on
  removal only re-asks the question when gdm3 is the selected display manager,
  then relinks `display-manager.service` from the default file.
- Debian's `greetd.service`: `After=systemd-user-sessions.service
  plymouth-quit-wait.service`, `After=getty@tty7.service`,
  `Conflicts=getty@tty7.service`, `ExecStart=greetd`, `Restart=always`,
  `[Install] Alias=display-manager.service`; packaged with
  `dh_installsystemd --no-start --no-stop-on-upgrade`. Its default
  `/etc/greetd/config.toml` (a conffile, left untouched) uses vt 7 with
  agreety.

Decisions:

- The display manager is **Debian's own `greetd.service`**. The first version
  of this module installed a custom `cosmic-greeter.service` with
  `Alias=display-manager.service`; the next greetd or gdm3 configure would
  overwrite that alias link, so it was retired. The module removes it (with a
  backup) if an earlier run installed it.
- `files/desktop/greetd-cosmic.conf` is installed as the drop-in
  `/etc/systemd/system/greetd.service.d/cosmic-greeter.conf`: it clears and
  replaces `ExecStart` (`/usr/sbin/greetd --config
  /etc/greetd/cosmic-greeter.toml`) and orders greetd after, and wants,
  `cosmic-greeter-daemon.service`. A drop-in survives package upgrades.
- `cosmic-greeter.toml` uses `vt = 7` (upstream: "1"). It matches Debian's
  unit, which conflicts with `getty@tty7`, so `getty@tty1` stays free for text
  console recovery.
- The three Debian mechanisms (debconf answer, default file, link) are all
  set, so any later greetd or gdm3 configure keeps greetd selected.

## GDM and GNOME Shell purge

Runs last, only when `gdm3` or `gnome-shell` is installed (otherwise no apt
call at all), and only after the display manager switch verified (link and
default file). It purges only the installed ones of `gdm3 gnome-shell`:

1. `apt-get -s purge <installed ones>` is run at runtime and its `Purg` and
   `Remv` lines parsed. If any package matching `^kali-` would be removed, the
   purge is **skipped** with a warning naming those packages: GDM stays
   installed but disabled (greetd is the display manager). A failing or empty
   simulation fails the module.
2. Graphical session guard: if the installer runs inside a graphical session
   (`XDG_SESSION_TYPE` is `x11` or `wayland`, or `WAYLAND_DISPLAY` or `DISPLAY`
   is set) and `gdm3.service` is active, the purge is skipped, because it would
   stop gdm3 and kill the session that runs the installer. The module warns to
   reboot (greetd takes over) and to run `./install.sh --only desktop` again
   from the new session or a text console.
3. Otherwise `apt-get purge` runs non-interactively (`DEBIAN_FRONTEND=
   noninteractive`, same dpkg options as `ensure_packages`) and the list of
   removed packages is logged. Afterwards the display manager link and the
   default file are verified again.
4. `apt-get autoremove` is **never run**. After a purge (and in dry-run) `apt-get
   -s autoremove` is simulated and its packages logged under "orphans (not
   removed, report to the owner)", so the owner decides.

`--dry-run` simulates, prints the purge it would do and the orphans report, and
purges nothing.

## Shipped files (`files/desktop/`)

| Installed as | Origin and changes |
|--------------|--------------------|
| `/etc/systemd/system/cosmic-greeter-daemon.service` | upstream unit, verbatim plus a header comment |
| `/etc/systemd/system/greetd.service.d/cosmic-greeter.conf` | drop-in for Debian's `greetd.service` (source `greetd-cosmic.conf`): wants and orders after the daemon, `ExecStart` runs greetd with the COSMIC config. Replaces the retired custom `cosmic-greeter.service` |
| `/etc/greetd/cosmic-greeter.toml` | upstream plus a header comment; one change: `vt = 7` instead of "1" (matches Debian's greetd unit; keeps `getty@tty1` free). Debian's `/etc/greetd/config.toml` is left untouched |
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
`systemctl is-enabled`, `debconf-show greetd`, the content of
`/etc/X11/default-display-manager` and `/etc/systemd/system/display-manager.service`
resolving to `greetd.service`; `dpkg-query` for `gdm3` and `gnome-shell`. All
read-only. A second run reports "Nothing to change" (also when GDM was kept
because of a `kali-*` dependency: the warning repeats, nothing changes).

## Recovery (TTY)

If the graphical login fails, text consoles still work. The module never
disables or masks getty units; Debian's `greetd.service` conflicts only with
`getty@tty7` and the greeter runs on VT7, so VT1 to VT6 keep their gettys:

1. Press Ctrl+Alt+F2 (or F1) and log in.
2. `sudo rm /etc/systemd/system/display-manager.service` and
   `sudo systemctl set-default multi-user.target`.
3. `sudo reboot`.

`systemctl disable greetd.service` alone is not the documented way: the
display manager is selected through the `display-manager.service` link (which
greetd's postinst recreates), so remove that link and change the default
target. The next greetd or gdm3 configure may recreate the link, which is
harmless while the default target is `multi-user.target`.

## Revert

1. Remove the COSMIC display manager setup: `sudo systemctl disable cosmic-greeter-daemon.service`, then remove the
   drop-in `/etc/systemd/system/greetd.service.d/cosmic-greeter.conf` (and
   the empty directory), `/etc/systemd/system/cosmic-greeter-daemon.service`,
   `/etc/greetd/cosmic-greeter.toml` and `/etc/pam.d/cosmic-greeter`; then
   `sudo systemctl daemon-reload`.
2. Reinstall the desktop that was purged: `sudo apt-get install gdm3
   gnome-shell gnome-session`.
3. `echo "gdm3 shared/default-x-display-manager select gdm3" | sudo
   debconf-set-selections`, `echo /usr/sbin/gdm3 | sudo tee
   /etc/X11/default-display-manager` and `sudo ln -sf
   /lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service`.
4. `sudo apt-get purge cosmic-epoch-monorepo` (review what `apt-get autoremove`
   would remove before running it).
5. Remove `/etc/apt/sources.list.d/debian-cosmic.sources`,
   `/etc/apt/preferences.d/debian-cosmic` and
   `/etc/apt/keyrings/debian-cosmic.gpg`, then `sudo apt-get update`.
6. Restore any `*.bak.<timestamp>` files next to the files above.

## Verification

- `./install.sh --only desktop --dry-run` lists the repo, key, pin, packages,
  files, units and target, and changes nothing.
- On Kali after a real run: `readlink -f /etc/systemd/system/display-manager.service`
  ends in `greetd.service`, `cat /etc/X11/default-display-manager` is
  `/usr/sbin/greetd`, `debconf-show greetd` shows `greetd` for
  `shared/default-x-display-manager`, `dpkg -l gdm3 gnome-shell` shows them gone
  (or the log says why GDM was kept), `systemctl get-default` is
  `graphical.target`, `apt-cache policy cosmic-epoch-monorepo` shows the repo
  at priority 100, and after a reboot the COSMIC login appears.
- A second `./install.sh --only desktop --dry-run` reports nothing to change.
- `tests/test-desktop.sh` covers the logic with fake commands.
