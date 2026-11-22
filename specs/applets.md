# applets

## Purpose

Install the COSMIC panel applets Workspace Icons and Lock Keys, which Kali does
not package, by building pinned upstream commits with cargo, plus the
configuration of Workspace Icons. Placing them in the panel is not done here (the
`panel` module owns `plugins_wings` / `plugins_center`), and cosmic-panel is never
restarted. `MODULE_OPTIN=0`, no dependencies.

## Source of truth

eos `50-applets.sh`, `specs/applets.md` and `files/applets/*`, ported to apt.

| Applet | Upstream | Pin | Panel id |
|--------|----------|-----|----------|
| Workspace Icons | https://github.com/crocodile/cosmic-ext-applet-workspace-icons | tag `v1.4.0`, commit `3cf946a85c4fd3eb3b5cf6cfb4ba43f14206ab77` | `io.github.crocodile.cosmic-ext-applet-workspace-icons` |
| Lock Keys | https://github.com/lucianosb/cosmic-applet-lock-keys | commit `1be12f5668dc449af6992944342a1f684764ce02` (no release carries its current id) | `com.lucianosb.cosmic-ext-lock-keys` |

Payload in `files/applets/`: the Workspace Icons desktop entry template
(`@HOME@`), its eight config key files (`cosmic/<id>/v3/*`, byte exact from eos)
and the Lock Keys desktop entry (upstream's, with an absolute `Exec`).

## Files and packages touched

- Packages (only when something has to be built): `build-essential`, `cargo`,
  `rustc` (Kali 1.98.1), `git`, `pkg-config`, `libxkbcommon-dev`,
  `ca-certificates`. This is the minimal set found by a real build of both
  applets on the test VM (see decision 2).
- Always compared (cheap): `~/.local/share/applications/<wi-id>.desktop`
  (rendered, absolute `Exec` in the user's home), the eight key files under
  `~/.config/cosmic/<wi-id>/v3/`, and `/usr/local/share/applications/<lk-id>.desktop`.
- Only when the recorded build is not the pin or the binary is missing:
  - Workspace Icons: `~/.local/bin/cosmic-ext-applet-workspace-icons` (0755),
    `~/.local/share/icons/hicolor/scalable/apps/<wi-id>.svg`,
    `~/.local/share/metainfo/<wi-id>.metainfo.xml` (the layout of upstream's
    install recipe with prefix `~/.local`).
  - Lock Keys: `/usr/local/bin/cosmic-ext-lock-keys` (0755),
    `/usr/local/share/icons/hicolor/scalable/apps/{caps,num}-lock-symbolic.svg`
    (sudo, outside dpkg's files; `/usr/local/share` is on the default XDG data
    path, so cosmic-panel finds the desktop entry).
  - Marker files `~/.local/state/kali-cosmic-setup/applets/<name>.commit` with the
    commit that was built.
- Build area `~/.cache/kali-cosmic-setup/src/<name>` (checkout and `target`),
  removed after the install and by an EXIT trap on failure. cargo's own download
  cache stays in `~/.cargo`.

No service or unit is enabled.

## Decisions on ambiguities

1. **Pins.** Each applet is fetched by commit (`git fetch --depth 1 origin <sha>`)
   and `git rev-parse HEAD` must equal the pin or nothing is built. The repository's
   own `Cargo.lock` is used (`--locked`). Workspace Icons v1.4.0 (config version 3)
   matches the shipped key files; its newest commits use config version 4 and are
   not pinned. Lock Keys v0.1.1 still uses the old id `com.lucianosb.CosmicAppletLockKeys`,
   so the first commit that names `com.lucianosb.cosmic-ext-lock-keys` is pinned.
2. **Minimal build dependencies.** A real build on the VM (Kali, COSMIC 1.11, no
   -dev library installed beforehand) failed only on `xkbcommon.pc`; with
   `pkg-config` and `libxkbcommon-dev` both applets built and link only to
   `libxkbcommon.so.0` (wayland is loaded at run time). `just`, `cmake`,
   `libwayland-dev`, `libinput-dev`, `libudev-dev`, `libssl-dev`, `libclang-dev`
   were candidates in `odd/verified-facts.md` and are not needed, so they are not
   installed. `just` is not used because the upstream recipe of Lock Keys names
   files that do not exist; the install steps are done by hand.
3. **Install locations.** Workspace Icons stays user-local as in eos. Lock Keys
   goes to `/usr/local` (eos used `/usr`), so nothing is placed in dpkg's tree.
   Both desktop entries have an absolute `Exec`, so no PATH assumption is needed.
4. **Idempotency by marker.** The applets have no `--version`, so the module
   records the commit it built. A second run builds nothing when the marker equals
   the pin and the binary exists. Bumping a pin rebuilds only that applet.
5. **User files.** The Workspace Icons files and the marker go through the shared
   guard `user_path_writable`: a file or directory owned by another user, or a
   symlink pointing outside `$HOME`, is skipped with a warning (the Workspace Icons
   build is then skipped too, so no work is done for a location that cannot be
   written). Never a write through sudo into `$HOME`; cargo never runs as root.
6. **Now Playing is dropped.** eos installed it from the AUR
   (`cosmic-ext-applet-now-playing-extended-git`); there is no Kali or Debian
   package and the reference setup does not justify a third unpinned source build,
   so the port has no Now Playing applet and the panel module leaves it out.
7. **Icon cache.** An existing `icon-theme.cache` in the target hicolor directory is
   refreshed with `gtk-update-icon-cache` (a failure only warns); none is created.

## Hardware detection

none

## Idempotency check

Binaries and icons: skipped when the marker equals the pin and the binary exists
(no network, no packages checked). Desktop entries and key files: compared byte
by byte. Dry-run reports `build and install ...` for each missing applet and runs
no git or cargo. A second run reports `total changes: 0`.

## Sudo and network needs

sudo for the apt packages and the `/usr/local` files of Lock Keys. Network only
when a build is needed: `git fetch` of the pinned commits and cargo's crate and
git dependencies (libcosmic). A build takes a few minutes per applet and about
1.5 GB of disk in the cache dir while it runs.

## Revert

1. Remove the applets from the panel first (COSMIC Settings, Desktop, Panel,
   Applets).
2. `rm -f ~/.local/bin/cosmic-ext-applet-workspace-icons
   ~/.local/share/applications/io.github.crocodile.cosmic-ext-applet-workspace-icons.desktop
   ~/.local/share/metainfo/io.github.crocodile.cosmic-ext-applet-workspace-icons.metainfo.xml
   ~/.local/share/icons/hicolor/scalable/apps/io.github.crocodile.cosmic-ext-applet-workspace-icons.svg`
   and `rm -r ~/.config/cosmic/io.github.crocodile.cosmic-ext-applet-workspace-icons`
   (or restore the `*.bak.<timestamp>` files).
3. `sudo rm /usr/local/bin/cosmic-ext-lock-keys
   /usr/local/share/applications/com.lucianosb.cosmic-ext-lock-keys.desktop
   /usr/local/share/icons/hicolor/scalable/apps/caps-lock-symbolic.svg
   /usr/local/share/icons/hicolor/scalable/apps/num-lock-symbolic.svg`
4. `rm -r ~/.local/state/kali-cosmic-setup/applets ~/.cache/kali-cosmic-setup/src`
   (and `~/.cargo` if nothing else uses it); `sudo apt-get purge libxkbcommon-dev`
   if wanted.

## Verification

```bash
./install.sh --only applets --dry-run          # nothing built
./install.sh --only applets                    # then again: "total changes: 0"
test -x ~/.local/bin/cosmic-ext-applet-workspace-icons
test -x /usr/local/bin/cosmic-ext-lock-keys
# the applets appear in COSMIC Settings, Desktop, Panel, Applets
tests/test-applets.sh
```
