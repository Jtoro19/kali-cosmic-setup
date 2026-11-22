# packages

## Purpose

Install the everyday desktop and CLI packages of the reference machine on Kali:
Firefox ESR, the CLI tools, fonts and codecs from Kali's own repositories, plus
Brave from its official vendor apt repo and PeaZip from its official upstream
`.deb`. Default module (`MODULE_OPTIN=0`); no files outside the package
database and apt configuration, no services.

## Source of truth

The eos `core.pacman` and `core.aur` lists. The Kali port is the data file
`files/packages/core.apt` (one package per line, `#` comments) read by
`install_package_list core` in `lib/common.sh`; the two vendor packages are code
in `modules/15-packages.sh` because they need a key, a pin or a checksum.

## Files and packages touched

- `/etc/apt/keyrings/brave-browser-archive-keyring.gpg` (Brave key, only after
  the fingerprint check).
- `/etc/apt/sources.list.d/brave-browser.sources` (deb822, `Signed-By` that key,
  suite `stable`, component `main`).
- `/etc/apt/preferences.d/brave-browser`: the first record allows only
  `brave-browser` and `brave-keyring` from the Brave origin (priority 500); the
  second blocks every other package of that origin (priority -1), so the repo
  can never replace a Kali package.
- Packages: the core list below, `gnupg curl ca-certificates` (to fetch and
  verify the key), `brave-browser` (its dependency `brave-keyring` comes with
  it), `libgtk2.0-0t64` and `peazip`.
- Only on a virtio GPU (see "Browsers on a virtio GPU"):
  `/etc/chromium.d/kali-cosmic-setup-virtio-gpu` and
  `/usr/local/share/applications/brave-browser.desktop`, both root-owned 0644.
- Kali tools are not touched; packages already installed are skipped.
- Order: core list, Brave, browsers on a virtio GPU, PeaZip. A failure in a later step leaves the earlier
  ones installed (apt is idempotent, the next run continues).

## What the module installs

`files/packages/core.apt` (45 entries): `firefox-esr`, `bat`, `eza`, `fd-find`,
`ripgrep`, `direnv`, `htop`, `glances`, `nvtop`, `duf`, `tealdeer`, `tree`,
`plocate`, `apt-file`, `inxi`, `hwinfo`, `mesa-utils`, `rsync`, `wget`, `unzip`,
`unrar`, `bash-completion`, `neovim`, `nano`, `man-db`, `manpages`, `whois`,
`less`, `fonts-noto-core`, `fonts-noto-cjk`, `fonts-noto-color-emoji`,
`fonts-noto-extra`, `fonts-dejavu`, `fonts-liberation`, `fonts-open-sans`,
`ttf-bitstream-vera`, `fonts-cantarell`, `gstreamer1.0-libav`,
`gstreamer1.0-pipewire`, `gstreamer1.0-plugins-bad`, `gstreamer1.0-plugins-ugly`,
`pavucontrol`, `gnome-keyring`, `xdg-user-dirs`, `xdg-utils`. Vendor: Brave
(`brave-browser`), PeaZip 11.4.0.

## Package mapping (eos to Kali)

Names that changed: `firefox` to `firefox-esr` (Kali ships the ESR), `fd` to
`fd-find` (binary `fdfind`), `bat` stays `bat` (binary `batcat`), `tldr` to
`tealdeer` (binary `tldr`), `pkgfile` to `apt-file`, `man-pages` to `manpages`,
`noto-fonts` to `fonts-noto-core`, `noto-fonts-cjk` to `fonts-noto-cjk`,
`noto-fonts-emoji` to `fonts-noto-color-emoji`, `noto-fonts-extra` to
`fonts-noto-extra`, `ttf-dejavu` to `fonts-dejavu`, `ttf-liberation` to
`fonts-liberation`, `ttf-opensans` to `fonts-open-sans`, `cantarell-fonts` to
`fonts-cantarell`, `ttf-bitstream-vera` unchanged, `gst-libav` to
`gstreamer1.0-libav`, `gst-plugin-pipewire` to `gstreamer1.0-pipewire`,
`gst-plugins-bad` and `gst-plugins-ugly` to `gstreamer1.0-plugins-bad` and
`gstreamer1.0-plugins-ugly`. Same name: `eza ripgrep direnv htop glances nvtop
duf tree plocate inxi hwinfo mesa-utils rsync wget unzip unrar bash-completion
neovim nano man-db whois less pavucontrol gnome-keyring xdg-user-dirs xdg-utils`.
`brave-bin` (AUR) becomes the vendor repo package `brave-browser`; `peazip`
becomes the upstream `.deb`. Every name above was checked with `apt-cache
policy` on the test VM (kali-rolling) before it went into the list.

Dropped, with the reason:

| eos entry | Reason |
|-----------|--------|
| `yay`, `downgrade`, `pacman-contrib`, `rebuild-detector` | Arch tools (AUR helper, pacman utilities); nothing to do on apt |
| `pkgfile` | replaced by `apt-file`, which is listed; `apt-file update` is not run (it downloads indexes; run it once by hand) |
| `nano-syntax-highlighting` | Debian's `nano` already ships its syntax files |
| `which` | provided by `debianutils`, an essential package |
| `librewolf` | not in Kali; Firefox ESR plus Brave cover it (plan decision) |
| `gst-plugin-va` | no VA-API GStreamer package exists in Kali (`apt-cache search` finds none); VA-API comes from `mesa-va-drivers` (drivers module) |
| `flatpak` and its apps | no Flatpak on this setup (plan) |

## Decisions and ambiguities

- **unrar**: Kali's default `kali.sources` already lists `non-free` (and
  `contrib`, `non-free-firmware`), checked on the VM; `unrar` 7.x installs from
  there. The module never edits Kali's sources. When a listed package has no apt
  candidate (for example a user removed `non-free`), `install_package_list`
  warns and skips that package and installs the rest, so the run does not fail.
- **Brave key**: Brave's published instructions give no key fingerprint. The
  keyring file (`brave-browser-archive-keyring.gpg`) holds three primary keys
  (all "Brave Linux Release"): `DBF1A116C220B8C7164F98230686B78420038257`,
  `47D32A74E9A9E013A4B4926C68D513D36A73CD96`,
  `B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0`. They were read with `gpg
  --show-keys` on the downloaded file and cross-checked against a second source:
  all three are published on keys.openpgp.org under the same fingerprints. The
  module pins all three and `apt_install_key` now accepts a set: the file must
  hold exactly that set (an extra or a missing key refuses the install). If
  Brave rotates its keyring the module fails closed with a fingerprint error and
  the pin must be updated after the new keys are verified.
- **Brave repo URL**: deb822 file written by the repo's own helper (not the
  `brave-browser.sources` Brave serves), because it needs the key path under
  `/etc/apt/keyrings` and our `Signed-By`. The `brave-browser` deb's cron script
  exits at once (it never adds the Chrome repo) and no second sources file
  appears (checked on the VM).
- **Brave global trust symlink (removed).** The `brave-keyring` package's
  postinst runs `ln -sf /usr/share/keyrings/brave-browser-archive-keyring.gpg
  /etc/apt/trusted.gpg.d/brave-browser-release.gpg` (unless its own
  `brave-browser-release.{list,sources}` file is present). The link is not in
  the package's file list, and a key in `trusted.gpg.d` is trusted for every
  repository, which is wider than our `Signed-By` plus the pin (porting rule 3).
  Decision by the orchestrator: after installing brave-browser the module
  removes that symlink (`rm -f`, no backup, a symlink holds no data; the change
  is logged). It runs on every pass because each upgrade of `brave-keyring`
  recreates the link, so it is cleaned at the next run of the module. Only a
  symlink is removed; a regular file there is left alone with a warning.
  `apt update` keeps working because the repo is verified through `Signed-By`.
- **PeaZip build**: the GTK2 `.deb` (`peazip_11.4.0.LINUX.GTK2-1_amd64.deb`),
  not Qt6, so no Qt stack is pulled into a GTK/COSMIC desktop. The upstream
  `.deb` declares no dependencies, so the module installs `libgtk2.0-0t64`
  first (Kali's name of the GTK2 runtime; `ldd` on the VM shows no missing
  library). The package is named `peazip`, version `11.4.0`.
- **PeaZip checksum**: version 11.4.0 (latest stable release, published
  2026-10-17, not a prerelease). SHA-256
  `b4ec801e857f232518cfc91d74690d27d35dbf911308b671d5156fc5c631956c`. Two
  independent official values agree with each other and with the downloaded
  file: the project's own `SHA256.txt` asset of the release, and the digest
  GitHub computes for the asset (API `digest` field). No risk is accepted
  beyond trusting the GitHub release of `peazip/PeaZip`. Updating needs a new
  version, asset name and checksum in the module.
- **PeaZip idempotency**: skipped when the installed `peazip` is the pinned
  version or newer (`dpkg --compare-versions "$cur" ge "$want"`, so Debian
  version ordering such as `11.4.0-1` is right), so a newer version is never downgraded. An older
  one is upgraded with the verified `.deb`.
- **Download**: `download_verified` (`lib/common.sh`) refuses an empty or
  malformed checksum, downloads into a private temporary directory, compares
  with `sha256sum`, and moves the file into place only on a match. The module
  downloads into a 0700 directory of the invoking user, then copies the
  verified file with `sudo install -m0644` into a root-owned 0755 directory
  (`sudo mktemp -d`; apt reads it as `_apt`), re-checks the SHA-256 of that
  copy and installs from it. Root never installs a file that a user process
  could still change. Both directories are removed on every outcome, including
  a failed `apt-get install`, a fail-fast exit or a SIGTERM: the module sets an
  EXIT trap (`_packages_cleanup`, scoped like the one in packages-dev) that
  removes the user directory and, through sudo, the root-owned staging dir. The runtime dependency check loops over every
  package in `_PACKAGES_PEAZIP_RUNTIME`. Dry-run creates no temporary directory
  and downloads nothing.
- All downloads (`download_verified`, `apt_install_key`) use `curl --proto
  '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 600
  --retry 2`. There is no wget fallback: curl is a prerequisite (the desktop
  module installs it; this module also ensures `curl ca-certificates` before
  any download), and a missing curl is a clear error.
- **Test-only override**: `PACKAGES_PEAZIP_SHA256` replaces the pinned checksum
  only when `KCS_TEST` is set (the test harness sets it so the tests can serve
  a fixture). In a real run the variable is ignored and the pinned hash is
  always used.
- **Locale**: every parser of tool output runs under `LC_ALL=C` (`gpg
  --with-colons`, `dpkg-query`, `apt-cache policy`, `lspci`, `systemctl`).
- `apt-get update` runs when something is installed or the Brave repo changed
  (key, sources or pin file), and also when `brave-browser` has no apt
  candidate (a failed earlier update, or wiped lists), so a re-run recovers; it
  also runs before the PeaZip runtime install when `libgtk2.0-0t64` is
  missing. A no-op run runs none.

## Browsers on a virtio GPU

Problem (verified on the test VM, `virtio-vga-gl`, PCI `1af4:1050`): Chromium
156 and Brave, as native Wayland clients with GPU compositing, die at start with
`create_immed failed and produced an invalid wl_buffer` and `Trace/breakpoint
trap`; `cosmic-comp` logs `import for wrong devices`. From the COSMIC app menu
they simply do not open. Both start with `--ozone-platform=x11` and with
`--disable-gpu-compositing` (each tested).

Decision: run them as X11 clients (XWayland), only when every `cardN` under
`/sys/class/drm` has PCI vendor `0x1af4` and at least one exists
(`gpu_is_virtual` in `lib/common.sh`; connector entries such as
`card0-Virtual-1` are not cards; a mix of virtual and real GPUs is not virtual,
and a card whose vendor cannot be read counts as real hardware). Known
limitation: a VM with a passed-through real GPU next to the virtio one is not
treated as virtual, so the workaround is not applied there even if the
compositor renders on the virtio GPU.

- **Why x11 and not `--disable-gpu-compositing`**: both work; x11 keeps GPU
  rasterisation, so it is the lighter loss.
- **Why only on virtio**: on real hardware native Wayland works and the flag
  would only make the browsers worse (XWayland, blurry fractional scaling).
- **Chromium**: `/etc/chromium.d/kali-cosmic-setup-virtio-gpu` (a marker comment
  plus `export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=x11"`). Debian's
  `/usr/bin/chromium` wrapper sources `/etc/chromium.d/*`, so every launch path
  is covered, a terminal included. Decision: the file is written whether or not
  chromium is installed, because it is inert without the package and the user
  may install Chromium later.
- **Brave**: the wrapper `/usr/bin/brave-browser` and the binary read no flags
  file (verified), so the only launch path covered is the desktop entry. The
  module generates `/usr/local/share/applications/brave-browser.desktop` from
  `/usr/share/applications/brave-browser.desktop` (when it exists): the flag is
  inserted after the executable in every `Exec=` line that starts with a plain
  program path (an `env` or quoted `Exec=` line is left as is, with a warning;
  Brave's own entry has none), everything else is kept, a marker comment line
  goes first, and the main group gets `TryExec=` with Brave's executable when
  the source has none, so if Brave is removed launchers and the MIME lookup
  hide this copy instead of offering a dead entry. `/usr/local/share` precedes
  `/usr/share` in the default `XDG_DATA_DIRS`, and the COSMIC session does not
  set the variable (checked on the VM: unset for cosmic-comp, cosmic-panel and
  cosmic-launcher), so the app menu, `xdg-open` and the mime default
  (`brave-browser.desktop`, set by the mime module) use it. It is compared with
  the installed file and rewritten only when different, so a Brave update that
  changes its entry is picked up on the next run (until then the copy keeps
  the previous metadata, which only matters if Brave changes its Exec path);
  `update-desktop-database` runs on that directory only when something changed
  (non-fatal). A `brave-browser` typed in a terminal does not read it and
  still needs the flag by hand. No `$HOME` file is written.
- **Marker**: both files carry `kali-cosmic-setup: virtio-gpu browser
  workaround`. On a GPU that is not virtual, a file with the marker is removed
  (logged as a change); a file without the marker, at either path and on any
  GPU, is never replaced or removed: it is left alone with a warning (so no
  backup is ever needed).
- Dry-run writes and removes nothing; a second run reports `total changes: 0`.

## Hardware detection

The virtio check above (`gpu_is_virtual`); nothing else.

## Idempotency check

Packages are installed only when `dpkg-query` says they are missing; the key is
not downloaded when the installed keyring already holds the pinned set; the
sources and pin files are rewritten only when different (with a `.bak.<ts>`
backup); PeaZip is skipped at the pinned version. A second run reports `total
changes: 0` and runs no `apt-get` and no download.

## Revert

```bash
sudo apt-get purge brave-browser brave-keyring peazip
sudo apt-get autoremove          # review the list first: drops libgtk2.0-0t64 once peazip is gone
sudo rm -f /etc/apt/sources.list.d/brave-browser.sources /etc/apt/preferences.d/brave-browser \
  /etc/apt/keyrings/brave-browser-archive-keyring.gpg
# the module already removes the brave-keyring symlink below; purge removes it too
sudo rm -f /etc/apt/trusted.gpg.d/brave-browser-release.gpg
sudo apt-get update
# virtio GPU browser workaround (only exists on a virtio GPU)
sudo rm -f /etc/chromium.d/kali-cosmic-setup-virtio-gpu /usr/local/share/applications/brave-browser.desktop
# core packages: purge any you do not want, for example
sudo apt-get purge <package>      # one at a time; dependencies shared with other software are refused
```

Backups of replaced files are `<file>.bak.<timestamp>` next to them.

## Verification

```bash
./install.sh --only packages              # then again: "total changes: 0"
brave-browser --version
ls /usr/share/applications | grep -i -E 'peazip|brave'
batcat --version; fdfind --version; eza --version; rg --version; tldr --version
apt-cache policy brave-browser            # candidate from the Brave repo, priority 500
apt-cache policy brave-origin             # other Brave package: blocked, Candidate: (none)
ls -l /etc/apt/trusted.gpg.d/brave-browser-release.gpg   # must not exist
gpg --show-keys --with-colons /etc/apt/keyrings/brave-browser-archive-keyring.gpg | grep '^fpr'
ls /etc/chromium.d/kali-cosmic-setup-virtio-gpu /usr/local/share/applications/brave-browser.desktop   # virtio GPU only
./install.sh --only packages --dry-run    # "Nothing to change"
tests/test-packages.sh
```
