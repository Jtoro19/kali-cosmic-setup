# kali-cosmic-setup

Turns a fresh Kali Linux install (graphical installer, "no desktop" plus the
Kali tools) into a configured COSMIC desktop with one command. It is a set of
small, idempotent bash modules, ported from the EndeavourOS setup
(eos-cosmic-setup) to Kali (kali-rolling, Debian based, apt). The approved plan
is in [specs/000-plan.md](specs/000-plan.md).

## Requirements

- A fresh Kali Linux install (kali-rolling) made with the graphical installer,
  choosing "no desktop" in tasksel and the default Kali tools. That install
  still ships GDM and GNOME Shell; the `desktop` module installs COSMIC, makes
  greetd the display manager and purges GDM and GNOME Shell (kept, disabled, if
  a `kali-*` package depends on them)
- bash
- sudo (the installer refuses to run as root and calls sudo where needed)
- Network access to the Kali mirror and to the third-party repositories the
  modules use
- Time and disk space for the first run: it does a full system upgrade and
  then installs the COSMIC package (about 230 MB to download and about 1 GB
  once installed), so it can take a while. Keep a few GB of free disk space.

A real run is refused when `/etc/os-release` does not say kali or debian;
`--dry-run` works anywhere and changes nothing.

## Usage

```bash
./install.sh --list                    # list modules
./install.sh --all --dry-run           # show what would change, apply nothing
./install.sh --all                     # run all non-opt-in modules
./install.sh --only desktop            # one module plus its dependencies
./install.sh --only desktop,kitty      # comma-separated list
./install.sh --all --only packages-dev # all defaults plus an opt-in module
./install.sh --all --keyboard latam    # keyboard layout given up front
```

`--dry-run` shows every change without applying it. Whenever a file is
modified, the original is first saved as `<file>.bak.<timestamp>`
(`YYYYmmdd-HHMMSS`). Running a module twice changes nothing the second time.

`--keyboard <layout>[:<variant>]|keep` chooses the keyboard layout for the
keyboard module without the menu (`keep` leaves the current one). It is parsed
now and used once the keyboard module exists.

**Type the password once.** A real run asks for the sudo password at the start
(`sudo -v`) and keeps it valid in the background, so the rest runs unattended
(with passwordless sudo there is no prompt at all);
if the password is wrong the installer stops before changing anything. Every
step is non-interactive (`apt-get -y` with `DEBIAN_FRONTEND=noninteractive`,
existing config files kept, `GIT_TERMINAL_PROMPT=0`, stdin closed). A module
stops at its first failed command and the run ends with the list of failed
modules and a non-zero exit.

**Log.** Every run that executes modules (also `--dry-run`) copies all output
to `${XDG_CACHE_HOME:-~/.cache}/kali-cosmic-setup/install-<YYYYmmdd-HHMMSS>.log`
and prints that path at the start and in the summary. The terminal keeps its
colors; the log has them stripped.

**Tests.** `tests/run-tests.sh` runs every `tests/test-*.sh` (errexit, sudo
handling, the apt helpers, option parsing). They use fake modules and fake
system commands, need no privileges and change nothing on the machine.

See `modules/README.md` for the module contract and `specs/README.md` for the
spec template.

## Modules

Modules run in file-name order (`modules/NN-name.sh`). Opt-in modules only run
when named with `--only`.

| Module | Opt-in | What it does | How to revert |
|--------|--------|--------------|---------------|
| desktop | no | COSMIC desktop for a no-desktop Kali install, from the community apt repo `rickysarraf.github.io/debian-cosmic` (key fingerprint verified, apt pin so it can never replace a Kali package): `cosmic-epoch-monorepo` without recommends, greetd (Debian's greetd.service plus a drop-in) with cosmic-greeter as the only display manager, GDM and GNOME Shell purged under guards, PipeWire, BlueZ, NetworkManager, keyring and session base; full upgrade on first run; graphical boot target. Risk: single-maintainer community repo, not supported by Kali or Debian | see "Revert" in `specs/desktop.md`: remove the drop-in, toml, PAM file and daemon unit, reinstall `gdm3 gnome-shell gnome-session`, restore the debconf answer, `/etc/X11/default-display-manager` and the `display-manager.service` link to gdm3, then `sudo apt-get purge cosmic-epoch-monorepo`, remove the repo `.sources`, pin and key, `sudo apt-get update` |
| locale | no | English system language (`en_US.UTF-8`) with Colombian formats (`es_CO.UTF-8` for dates, numbers, money, paper): `locales` package, enables those two locales in `/etc/locale.gen` and generates them, values written with `update-locale`. The keyboard is not touched | restore `/etc/default/locale` and `/etc/locale.gen` from their `.bak.<timestamp>` files, then `sudo locale-gen` |
| drivers | no | CPU microcode by vendor (`amd64-microcode` or `intel-microcode`, non-free-firmware), the mesa base (`mesa-vulkan-drivers`, `mesa-va-drivers`, `libgl1-mesa-dri`), `firmware-amd-graphics` on AMD GPUs, `intel-media-va-driver` on Intel GPUs; works in a VM (virtio GPU: vendor parts skipped). NVIDIA: warning only, install Kali's `nvidia-driver` yourself. No i386 | `sudo apt-get purge` the packages you do not want; nothing else is changed |
| services | no | Enables NetworkManager, bluetooth, power-profiles-daemon, systemd-timesyncd and fstrim.timer when installed; never disables, stops or restarts anything and never enables a listening service (no sshd, avahi, cups or firewall). If ifupdown configures an interface, NetworkManager is always enabled for the next boot only, never started now (it leaves an ifupdown-configured interface unmanaged); masked units are skipped; with systemd-networkd or another time daemon in use, the conflicting unit is left alone | `sudo systemctl disable --now <unit>` for any of the five units |
| packages | no | Everyday packages from Kali (`firefox-esr`, CLI tools `bat` `eza` `fd-find` `ripgrep` `tealdeer`, fonts, GStreamer codecs, `unrar` from non-free; list in `files/packages/core.apt`), Brave from its vendor apt repo (key fingerprints verified, apt pin so the repo only provides `brave-browser` and `brave-keyring`) and PeaZip 11.4.0 from its upstream GitHub `.deb` (SHA-256 verified). Skips what is installed; Arch-only tools (yay, pacman-contrib, ...) are dropped | `sudo apt-get purge brave-browser brave-keyring peazip`, then `sudo apt-get autoremove` (review: drops `libgtk2.0-0t64`), `sudo rm -f /etc/apt/sources.list.d/brave-browser.sources /etc/apt/preferences.d/brave-browser /etc/apt/keyrings/brave-browser-archive-keyring.gpg /etc/apt/trusted.gpg.d/brave-browser-release.gpg` (the last is a symlink `brave-keyring` creates; the module removes it), then `sudo apt-get update`; purge any core package you do not want (see `specs/packages.md`) |
| packages-dev | yes | Development tools: Kali toolchains (`build-essential`, `golang-go`, `rustc`, `cargo`, Python libs, `docker.io` with Compose v2 and buildx, `mariadb-server`, `adb`, `shellcheck`, ...; list in `files/packages/dev.apt`), VS Code from Microsoft's apt repo and Claude Code from Anthropic's signed apt repo (key fingerprints verified, apt pins so each repo only provides its one package; the VS Code deb is told not to add its own repo), uv 0.13.9, engram 3.7.2 and gentle-ai 4.6.0 from GitHub releases in `/usr/local/bin` (SHA-256 verified). Enables Docker (unix socket only) and MariaDB bound to 127.0.0.1; adds you to `docker` (root-equivalent, re-login needed) and `plugdev` | see "Revert" in `specs/packages-dev.md`: `sudo systemctl disable --now docker.service docker.socket mariadb.service`, `sudo gpasswd -d $USER docker`, `sudo apt-get purge code claude-code docker.io docker-buildx docker-compose mariadb-server`, remove the two vendor `.sources`, pins and keys, the MariaDB drop-in and the four binaries in `/usr/local/bin`, then `sudo apt-get update` |
| packages-ai | yes | Ollama 0.40.17 from its official release archives (SHA-256 verified against the release checksum file): the generic CPU build, plus the ROCm build on AMD GPUs; unpacked into `/usr/local`, a system user `ollama` and `ollama.service` bound to `127.0.0.1:11434` only (never the network). Downloads about 1.5 GB (2.6 GB with ROCm). No model is pulled | see "Revert" in `specs/packages-ai.md`: `sudo systemctl disable --now ollama`, `sudo rm /etc/systemd/system/ollama.service /usr/local/bin/ollama; sudo rm -r /usr/local/lib/ollama`, `sudo userdel ollama`, optionally `sudo rm -r /usr/share/ollama` (the models), then `sudo systemctl daemon-reload` |
| cosmic-settings | no | COSMIC settings written as key files into `~/.config/cosmic` of the invoking user: tiling, dark theme and purple accent (seeded once, never overwritten), Papirus-Dark icons (`papirus-icon-theme`), compact UI, Super+Shift+S screenshot shortcut (merged into the shortcuts map, other entries are kept), idle, Files, Terminal, clock and audio applets. No keyboard layout, no terminal action | restore a key from its `<key>.bak.<timestamp>` file or delete the key file to get the COSMIC default (the `.bak` files sit next to the keys inside the watched v1 directories: delete them once you have restored what you wanted); remove the Super+Shift+S entry from `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`; `sudo apt-get purge papirus-icon-theme` |
| dark-mode | no | Dark GTK3/GTK4 and Qt5/Qt6 apps: `adw-gtk3-kali` with GSettings `gtk-theme='adw-gtk3-dark'` and `color-scheme='prefer-dark'` for your user (works over SSH or a TTY through the session bus or `dbus-run-session`), `~/.config/gtk-3.0` and `gtk-4.0` `settings.ini`, `qt5ct` and `qt6ct` with the `darker` color scheme and Papirus-Dark icons, and `QT_QPA_PLATFORMTHEME=qt5ct` in `/etc/environment` (next login). No Flatpak, no Brave or Electron flag files (they follow the system color scheme) | `gsettings reset org.gnome.desktop.interface gtk-theme` and `... color-scheme`; remove the keys from the two `settings.ini` or restore their `.bak.<timestamp>`; `sudo sed -i '/^QT_QPA_PLATFORMTHEME=qt5ct$/d' /etc/environment` and log in again; restore or delete `~/.config/qt5ct/qt5ct.conf` and `~/.config/qt6ct/qt6ct.conf`; `sudo apt-get purge adw-gtk3-kali qt5ct qt6ct` |
| clipboard | no | Keeps the Wayland clipboard after the copying app closes: `wl-clipboard` from Kali, `wl-clip-persist` v0.5.0 (not packaged in Kali) built from the upstream tag with `cargo build --release --locked` after the checked-out commit is verified against the pinned `e26fde0` (cargo, rustc, git, gcc from Kali; nothing is built again while the installed version matches) and installed to `/usr/local/bin`, `COSMIC_DATA_CONTROL_ENABLED=1` in `/etc/environment` (next login) and the user service `~/.config/systemd/user/wl-clip-persist.service` (enabled; started in a graphical session, otherwise the command to run is shown) | `systemctl --user disable --now wl-clip-persist.service`; `rm ~/.config/systemd/user/wl-clip-persist.service` and `systemctl --user daemon-reload`; `sudo rm /usr/local/bin/wl-clip-persist`; `sudo sed -i '/^COSMIC_DATA_CONTROL_ENABLED=1$/d' /etc/environment` and log in again |

## Recovery

- Every modified file has a `<file>.bak.<timestamp>` next to it: copy it back
  to undo a change.
- Each run is logged under `~/.cache/kali-cosmic-setup/`; start there when a
  module fails.
- If the graphical login does not come up, switch to a text console
  (Ctrl+Alt+F2 or F1), log in and run
  `sudo rm /etc/systemd/system/display-manager.service`,
  `sudo systemctl set-default multi-user.target`, then `sudo reboot`. The
  installer never disables or masks the text consoles (getty), so this always
  works. More in `specs/desktop.md`.

## Not managed

- **Bootloader and kernel parameters.** The Kali installer configures them
  for each machine, and a wrong boot setting can leave a machine unbootable.
- **Personal data and secrets:** browser profiles, app state, SSH and GPG keys.
