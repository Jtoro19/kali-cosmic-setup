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
- Kali tools are not touched; packages already installed are skipped.
- Order: core list, Brave, PeaZip. A failure in a later step leaves the earlier
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
  version or newer (`sort -V`), so a newer version is never downgraded. An older
  one is upgraded with the verified `.deb`.
- **Download**: `download_verified` (`lib/common.sh`) refuses an empty or
  malformed checksum, downloads into a private temporary directory, compares
  with `sha256sum`, and moves the file into place only on a match. The module
  keeps the `.deb` in a 0755 directory (apt reads it as `_apt`) and removes it
  on every outcome, including a failed `apt-get install`.
- Test-only override `PACKAGES_PEAZIP_SHA256` replaces the pinned checksum so
  the tests can serve a fixture; it is never set in a real run.
- `apt-get update` runs only when something is installed or the Brave repo
  changed (the key, sources or pin file), never on a no-op run.

## Hardware detection

None.

## Idempotency check

Packages are installed only when `dpkg-query` says they are missing; the key is
not downloaded when the installed keyring already holds the pinned set; the
sources and pin files are rewritten only when different (with a `.bak.<ts>`
backup); PeaZip is skipped at the pinned version. A second run reports `total
changes: 0` and runs no `apt-get` and no download.

## Revert

```bash
sudo apt-get purge brave-browser brave-keyring peazip
sudo rm /etc/apt/sources.list.d/brave-browser.sources /etc/apt/preferences.d/brave-browser \
  /etc/apt/keyrings/brave-browser-archive-keyring.gpg
sudo apt-get update
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
gpg --show-keys --with-colons /etc/apt/keyrings/brave-browser-archive-keyring.gpg | grep '^fpr'
./install.sh --only packages --dry-run    # "Nothing to change"
tests/test-packages.sh
```
