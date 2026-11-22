# 000 - Approved port plan

Status: approved by the owner on 2026-11-22. This file records the plan from
step 1 of BRIEF.md, the owner's answers and the changes made at approval.
Per-module details go in `specs/<module>.md`.

## Testing workflow

- No test machine is reachable from the development machine. The owner clones
  the public repo on a Kali KVM virtual machine (virtio GPU) and runs
  `./install.sh` there, then reports results.
- Locally, verification is limited to shellcheck, `tests/run-tests.sh` (fake
  sudo) and `--dry-run`. No real changes are applied on the development
  machine.
- At each testable milestone: push, give the exact Kali commands and the checks
  to report, then wait for the results.
- Repo: https://github.com/Jtoro19/kali-cosmic-setup (public, created by the
  owner), branch main.

## COSMIC install method

Verified on 2026-11-22: no `cosmic-*` packages exist in kali-rolling or in
Debian testing/sid (Debian has only RFP bugs #1120089 and #1120090). Kali has
`greetd` 0.10.3.

Chosen: the community apt repo rickysarraf/debian-cosmic.

- Source: `deb [signed-by=/etc/apt/keyrings/debian-cosmic.gpg]
  https://rickysarraf.github.io/debian-cosmic/ unstable main`, key from
  https://rickysarraf.github.io/debian-cosmic/debian-cosmic.gpg, dearmored into
  `/etc/apt/keyrings/`. The repo is signed (InRelease and Release.gpg).
- Package: `cosmic-epoch-monorepo` (1.11.0-1.build198 at research time), the
  full upstream epoch built with `just install` on a `debian:testing` base, so
  it includes cosmic-greeter. `cosmic-utils-monorepo` is not used.
- Pinning: an apt preferences file that gives the repo a priority below Kali's
  for every package and allows only the repo's own packages
  (`cosmic-epoch-monorepo`, `cosmic-utils-monorepo`). It must never replace a
  Kali package.
- The package has no maintainer scripts, so the desktop module sets up the
  greetd config, the `cosmic-greeter` system user and the display manager
  itself.
- TTY login must keep working even if cosmic-greeter fails: never mask or
  disable getty, and document the recovery path (switch to another VT, log in,
  disable the greeter).
- The README revert column documents how to remove the repo, the key, the pin
  and the packages.
- Fallback: if the repo does not install or run on Kali, stop the desktop
  module and report it. No source build of the full desktop.
- Risk: single maintainer, weekly rebuilds, not supported by Kali or Debian.

## Module map

Tentative order (dependencies first, keyboard late):

| Module | Status | Kali implementation |
|---|---|---|
| desktop | port | community repo with key and pin, `greetd`, session base: xwayland, pipewire, pipewire-pulse, wireplumber, bluez, network-manager, power-profiles-daemon, gnome-keyring, xdg-user-dirs. No cups, avahi or firewalld. pacman-conf dependency removed. |
| locale | port | `locales`, en_US.UTF-8 plus es_CO formats, `/etc/default/locale` via `update-locale`. |
| drivers | port | amd64-microcode or intel-microcode, mesa-vulkan-drivers, mesa-va-drivers, intel-media-va-driver. No i386. AMD must be handled correctly for real hardware (owner host: RX 7900 XTX), virtio GPU in the test VM. NVIDIA: warn only and point to Kali's nvidia-driver. |
| packages | port | core everyday tools from Kali, Brave from its vendor repo, PeaZip from its upstream .deb with SHA256 check. |
| packages-dev | opt-in | Kali packages, VS Code vendor repo, Claude Code by the method Anthropic officially documents today (source cited in the spec), uv, engram and gentle-ai from GitHub releases with checksum verification. Enables Docker and MariaDB, localhost only. |
| cosmic-settings | port | config keys copied; check key versions against COSMIC 1.11. `papirus-icon-theme`. Alt+S shortcut removed (moves to aura). |
| packages-ai | opt-in | Ollama release tarball with sha256 check, ROCm build on AMD. May enable the service bound to 127.0.0.1. |
| dark-mode | port | `adw-gtk3-kali` (verify theme directory name), qt5ct, qt6ct, Electron flags. No flatpak part. |
| clipboard | port | `wl-clipboard` from Kali, `wl-clip-persist` built with cargo from upstream (tag v0.5.0). |
| kitty | port | kitty from Kali; managed blocks in `~/.zshrc` or `~/.bashrc` by login shell. |
| fastfetch | port | fastfetch, imagemagick 7, git, git-lfs from Kali; same rc rule as kitty. |
| applets | port | workspace-icons and lock-keys built with cargo (Kali rustc 1.98.1) plus -dev build deps. Now Playing dropped. |
| panel | port | reference panel layout. |
| audio-resync | port | as is. |
| aura | opt-in | release tarball with sha256, plus the Alt+S shortcut. |
| services | port | NetworkManager, bluetooth, power-profiles-daemon, systemd-timesyncd, fstrim.timer. No sshd, avahi, cups or firewalld. |
| mime | port | Brave and PeaZip defaults; Vesktop entry dropped. |
| mic-agc | port | as is (PipeWire 1.6.9 supports pulse.rules quirks). |
| keyboard | new | see below; runs late in the order. |

Dropped (reasons in PORTING.md): flatpak, LibreWolf, Now Playing applet,
pacman-conf, steam-icons, packages-gaming, packages-media, vesktop-mic,
packages-vmware, packages-printing, packages-office, wacom, kvm.

## Service policy

- Default modules never enable a listening service (no sshd, avahi, cups,
  firewalld).
- Opt-in modules may enable services that listen only on localhost: Ollama
  bound to 127.0.0.1, Docker (unix socket only), MariaDB (bind-address
  127.0.0.1). Nothing listens on external interfaces.

## Package mapping highlights

- Name changes: bat (binary `batcat`), fd-find (binary `fdfind`), tealdeer for
  tldr, firefox-esr, `fonts-*` for `ttf-*` and noto, manpages, build-essential,
  golang-go, rustc and cargo, python3-*, docker.io, adb and fastboot,
  android-udev-rules, gstreamer1.0-* plugins.
- unrar comes from Kali's non-free component.
- Dropped: yay, downgrade, pacman-contrib, rebuild-detector, pkgfile (apt-file
  replaces it), nano-syntax-highlighting, which (debianutils is essential),
  librewolf.
- Full table: PORTING.md.

## Keyboard design

- Menu shown once, right after `sudo -v` and before stdin is closed, only when
  the keyboard module is selected. Plain bash numbered menu: 1 us, 2 us
  altgr-intl, 3 us intl, 4 latam, 5 es, 6 Keep current (shows the current
  layout and variant from /etc/default/keyboard), 7 Other (layout and optional
  variant, validated against the system XKB rules list). No default; empty or
  invalid input asks again.
- `--keyboard <layout>[:<variant>]` and `--keyboard keep` skip the menu. Both
  are validated the same way. `--dry-run` prints the choice and the files it
  would change.
- Apply: `/etc/default/keyboard` (XKBMODEL="pc105", chosen layout and variant,
  empty XKBOPTIONS), matching keyboard-configuration debconf selections applied
  non-interactively, `update-initramfs -u` only when something changed,
  `localectl set-x11-keymap`, and the COSMIC cosmic-comp `xkb_config` for the
  user and the greeter user (reuse the eos logic).
- Keep current changes nothing. A chosen layout becomes the only configured
  one. COSMIC keyboard settings are never removed, hidden or locked.
- After applying, verify that the installer layout appears nowhere
  (/etc/default/keyboard, debconf, localectl, COSMIC configs for user and
  greeter) and fail loudly if it does.
- Backups of original files; no second sudo prompt; full effect may need a
  reboot.

## Build order

1. Repo scaffolding: install.sh, lib/common.sh (apt layer), tests with fake
   sudo, module contract.
2. desktop first, with an early Kali test, since COSMIC is the biggest risk.
3. Remaining modules, one commit each, Kali tests at testable milestones.
4. keyboard, PORTING.md, README table, final full run and second idempotent run.

## Risks

1. COSMIC from a single-maintainer community repo; greetd setup is ours.
2. COSMIC config keys written for the Arch version may have moved in 1.11.
3. debconf and dpkg-reconfigure can restore the installer layout; the
   post-apply check guards against it.
4. Applet builds against libcosmic are slow and the -dev deps are unverified.
5. Unverified: adw-gtk3-kali theme directory name, `~/.local/bin` in the zsh
   PATH (use absolute paths), greeter user name and home.
6. Each real check costs the owner a run on Kali; maximize fake-sudo tests and
   dry-run coverage first.
