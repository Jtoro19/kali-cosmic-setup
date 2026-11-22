# aura

## Purpose

Install Aura (the animated wallpaper manager for COSMIC) from its official
release, make the last wallpaper come back at every login and bind Alt+S to
Aura's quick switcher. `MODULE_OPTIN=1` (run with `--only aura`), no module
dependencies.

## Source of truth

eos `60-aura.sh`, `specs/aura.md` and `files/aura/*`, ported (plan: release
tarball with sha256, plus the Alt+S shortcut that cosmic-settings no longer
ships). Aura upstream: `github.com/antwny/aura`.

- Pinned release `v1.5.0` (the one the reference machine runs; newer releases
  exist, for example v1.11.2, but the module does not follow `latest`):
  `https://github.com/antwny/aura/releases/download/v1.5.0/aura-v1.5.0-x86_64-linux.tar.gz`.
- Checksum: the project publishes `<tarball>.sha256` in every release and GitHub
  computes an asset digest; for v1.5.0 both are
  `0c6d7ea68e93e5e87a5d1e6f6bc31372646b65873d15175fdb10cecf26a4d1e8` (checked
  2026-11-22). That value is hard-coded in the module, so the checksum does not
  come from the same download as the tarball. Residual risk: there is no
  detached signature, so the pin is trust on first use of that release (the same
  stance as gentle-ai in packages-dev).
- The tarball holds `aura`, a bundled `mpvpaper`, the desktop entry, an SVG
  icon, the metainfo, `install.sh`/`uninstall.sh` and the licence. Both
  binaries are dynamically linked x86_64 ELF.
- eos Alt+S entry (`custom.in`): description `aurahud`, action
  `Spawn("$HOME/.local/bin/aura switcher")`.

## Files and packages touched

- Packages (only if missing): `mpv`, `libmpv2` (the bundled `mpvpaper` links `libmpv.so.2`, which Kali's `mpv` does not pull in), `ffmpeg`, `jq`, `curl` from Kali.
- User scope, like eos and the upstream `install.sh --user` (the upstream
  script itself is never run):
  - `~/.local/bin/aura`, `~/.local/bin/mpvpaper` (0755, no `.bak` of a
    reproducible binary)
  - `~/.local/share/applications/io.github.antwny.aura.desktop` (absolute
    `TryExec`/`Exec`, the same rewrite as upstream)
  - `~/.local/share/icons/hicolor/scalable/apps/io.github.antwny.aura.svg`
  - `~/.local/share/metainfo/io.github.antwny.aura.metainfo.xml`
  - `update-desktop-database` and `gtk-update-icon-cache` run only when files
    changed (the icon cache only if one exists).
- `~/.local/state/kali-cosmic-setup/aura/version`: the installed tag, written
  after every file was installed.
- `~/.local/bin/aura-restore` (0755) and
  `~/.config/systemd/user/aura-restore.service`; the unit is enabled (starts at
  once when a user manager is reachable, otherwise the run says how to enable it).
- Legacy cleanup, after a backup: `~/.config/autostart/aura.desktop`,
  `~/.local/bin/aura-autostart.sh`, and any other autostart entry whose `Exec=`
  runs aura (the program of `Exec=` is `aura`, with or without a directory, or
  the legacy `aura-autostart.sh`, or the file is Aura's own
  `io.github.antwny.aura.desktop`; a program such as `laura-player` or an
  `echo aura` is not matched).
- Aura autostart guard: `.autostart` in `~/.config/aura/config.json` is set to
  `false` with `jq` (other keys kept, file backed up); a missing file is
  reported, an invalid one is left alone with a warning.
- `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`: the Alt+S
  entry (see decision 3).

## How the restore works

Unchanged from eos: `aura-restore` exits when an `mpvpaper` of this user is
running, otherwise reads `.current` (and `.output`) from the Aura config, falls
back to the first media file in `~/Pictures/Wallpapers/Aura`, waits up to 15 s
for the Wayland socket and `exec`s `mpvpaper` so systemd supervises it. The
unit is `Restart=on-failure`. Wallpapers are user data and never touched.

## Decisions on ambiguities

1. **Pinned version and checksum, no `latest`.** The module installs `v1.5.0`
   with the hard-coded sha256 above. The checksum is verified by
   `download_verified` and again right before the archive is unpacked (the
   directory is user-owned). `AURA_SHA256` replaces the pin only when
   `KCS_TEST` is set (tests serve a fixture); a real run cannot override it.
   There is no `AURA_VERSION`: to move the pin edit the tag and the checksum
   together, after comparing the checksum with the release.
2. **Idempotent by version.** A marker file holds the installed tag (line 1) and
   `mpvpaper=bundled|none` (line 2, whether the release shipped mpvpaper). The
   install is skipped (no network) when the marker equals the pin and every
   artifact exists: `aura`, `mpvpaper` (when bundled), the desktop entry, the icon
   and the metainfo; a different marker (an upgrade of the pin) or any missing
   artifact installs again. Dry-run announces the download and never downloads.
3. **Alt+S follows the merge rule of specs/cosmic-settings.md.** The `custom`
   map is shared. The reader and merger live in `lib/common.sh`
   (`cosmic_shortcut_ensure`), and cosmic-settings now uses the same function for
   its Super+Shift+S entry, so there is one implementation. aura adds only its
   own entry inside the existing map after a backup, creates the file when it is
   missing or `{}`, never removes or edits other entries, repairs a missing
   trailing comma, ignores commented-out bindings, and leaves the file untouched
   with a warning when the map is not understood. A user binding on Alt+S (to
   anything but aura's own action) is left alone with a warning, so aura
   installs and works without the shortcut. Either order of the two modules gives
   both entries.
4. **Aura owns the accent color and dark mode while it runs.** eos let Aura
   manage them (its `auto_theme` and `auto_dark` keys) and cosmic-settings only
   seeds them once (specs/cosmic-settings.md decision 4). The module does not
   write any Aura theme key and only forces `autostart` off, so Aura's own
   settings win and nothing fights.
5. **One start mechanism.** The systemd user unit restores the wallpaper; the
   legacy autostart entries are removed and Aura's own autostart kept off, as in
   eos. The unit uses `graphical-session.target`, like the clipboard module.
6. **x86_64 only.** The release has no other architecture; the module fails on
   another machine before downloading.
7. **Failure stops the module.** A failed download, checksum or layout check
   fails the module with nothing installed, no marker, no unit and no shortcut.
8. **The tarball is inspected before it is extracted (M11b).** `tar -tzf` and
   `tar -tvzf` must show only members under `aura-<tag>-x86_64-linux/` (no absolute
   name, no `..` component, no other top-level name) and only regular files and
   directories (a symlink or hard link could point outside); `$pkg` and
   `mpvpaper` must not be symlinks. A release without `mpvpaper` still installs
   (the marker says `mpvpaper=none`; aura-restore falls back to one on PATH).
9. **Existing binaries (M11b).** `~/.local/bin/aura` or `mpvpaper` that is there
   without our marker and is not byte-identical is backed up once
   (`<file>.bak.<timestamp>`) before the pinned one replaces it; with the marker
   they are reproducible, so no backup. A newer Aura is never downgraded: when the
   marker or `aura --version` (5 s limit, no input; it prints `Aura Live
   Wallpaper v1.5.0` and exits) reports a version newer than the pin, the install
   is skipped with a warning and the rest of the module still runs.
10. **The shortcut needs a plain HOME (M11b).** `cosmic_shortcut_ensure` refuses a
    double quote or backslash in the modifiers, key or description, and in the
    action allows only the quotes that delimit its own strings (even count, no
    backslash). aura skips Alt+S with a warning when HOME holds whitespace, a
    double quote or a backslash; everything else still installs.
11. **aura-restore (M11b).** `--` precedes the output and wallpaper values (they
    come from the user's config), and the unit has `StartLimitIntervalSec=120`,
    `StartLimitBurst=5` and `RestartSec=5`, so a crash loop ends.

## Hardware detection

None. mpvpaper needs a Wayland compositor with layer-shell (COSMIC).

## Idempotency check

The install is skipped by the marker; files are compared byte for byte; the unit
is enabled only when not enabled yet; legacy files are removed only when
present; the config is edited only when `.autostart` is not `false`; the shortcut
is added only when the combination is free. A second run reports
`total changes: 0`.

## Revert

```bash
systemctl --user disable --now aura-restore.service
rm ~/.config/systemd/user/aura-restore.service ~/.local/bin/aura-restore
systemctl --user daemon-reload
rm ~/.local/bin/aura ~/.local/bin/mpvpaper ~/.local/state/kali-cosmic-setup/aura/version
rm ~/.local/share/applications/io.github.antwny.aura.desktop \
   ~/.local/share/icons/hicolor/scalable/apps/io.github.antwny.aura.svg \
   ~/.local/share/metainfo/io.github.antwny.aura.metainfo.xml
```

Remove the Alt+S entry from
`~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom` (or restore
its `.bak.<timestamp>`). Restore a removed autostart entry or the Aura config from
their `.bak.<timestamp>` files if wanted. The wallpapers are never touched.

## Verification

```bash
./install.sh --only aura --dry-run   # announces the download, writes nothing
./install.sh --only aura             # then again: "total changes: 0"
systemctl --user is-enabled aura-restore.service
bat ~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom
tests/test-aura.sh
```

### M11b VM evidence

- Rerun `--only aura` (marker from before: one line): 2 changes (the restore script and unit with the
  new restart limits), then `total changes: 0`; `systemctl --user show` reports StartLimitBurst=5,
  StartLimitIntervalUSec=2min, RestartUSec=5s. `--only cosmic-settings` 0 changes (the shortcut map
  holds both entries). With the marker deleted: the real v1.5.0 tarball passes the member check, 1 change
  (the marker, now with `mpvpaper=bundled`), no backup made (same bytes), repeat 0; no failed units.
