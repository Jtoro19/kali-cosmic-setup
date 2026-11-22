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
keyboard module without the menu (`keep` leaves the current one); see
[Keyboard](#keyboard).

**Type the password once.** A real run asks for the sudo password at the start
(`sudo -v`) and keeps it valid in the background, so the rest runs unattended
(with passwordless sudo there is no prompt at all);
if the password is wrong the installer stops before changing anything. The one
exception to non-interactivity is the keyboard menu, shown once right after
`sudo -v` when the keyboard module runs; `--keyboard` skips it. Every
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

## Keyboard

The layout chosen in the Kali installer does not survive: the keyboard module
replaces it with the one you pick. It runs last. Right after the sudo prompt
and before any module, `install.sh` shows a numbered menu once (only when the
keyboard module is selected):

1. English (US), `us`
2. English (US), intl. with AltGr dead keys, `us` + `altgr-intl`
3. English (US), intl. with dead keys, `us` + `intl`
4. Spanish (Latin American), `latam`
5. Spanish (Spain), `es`
6. Keep current: shows the current layout and variant from
   `/etc/default/keyboard` and changes nothing
7. Other: any XKB layout and an optional variant, checked against
   `/usr/share/X11/xkb/rules/evdev.lst`

There is no default: an empty or invalid answer asks again.
`--keyboard <layout>[:<variant>]` (for example `us:altgr-intl`) and
`--keyboard keep` skip the menu and are validated the same way; without
`--keyboard` and without a terminal the run stops before any module (it never
guesses). `--dry-run` prints the choice and the files it would change.

A chosen layout is written, and the installer layout is removed, from
`/etc/default/keyboard`, the `keyboard-configuration` debconf answers, the
initramfs and console keymap cache (so the text console and a disk-unlock
prompt use it), `localectl` (the X11 keymap the login screen reads) and COSMIC
(the `xkb_config` of your user and of the login screen user). The module then
checks all of them and fails loudly if the installer layout is left anywhere.
The console and the login screen use the new layout in full after a reboot.
The list of valid layouts comes from the `xkb-data` package; if it is missing, a
real run installs it right after the sudo prompt, before checking `--keyboard`.
Until it is installed a malformed but pattern-valid `--keyboard` value is not
rejected: that happens only after the packages are installed (exit 2, nothing
applied).

COSMIC Settings can still add more layouts afterwards, and Super+Space still
switches between them. The panel here has no Input Sources applet; add it in
COSMIC Settings > Desktop > Panel (or right-click the panel) when you want it.
Picking a layout in the menu makes it the only configured one again; "Keep
current" never touches layouts you added.

## Modules

Modules run in file-name order (`modules/NN-name.sh`); the table below is in that
order and matches `./install.sh --list`. Opt-in modules only run when named with
`--only`. What was ported from the EndeavourOS setup, what was dropped and every
package rename is in [PORTING.md](PORTING.md).

| Module | Opt-in | What it does | How to revert |
|--------|--------|--------------|---------------|
| desktop | no | COSMIC desktop for a no-desktop Kali install, from the community apt repo `rickysarraf.github.io/debian-cosmic` (key fingerprint verified, apt pin so it can never replace a Kali package): `cosmic-epoch-monorepo` without recommends, greetd (Debian's greetd.service plus a drop-in) with cosmic-greeter as the only display manager, GDM and GNOME Shell purged under guards, PipeWire, BlueZ, NetworkManager, keyring and session base, `kali-defaults-desktop` (Kali's Firefox ESR and Chromium settings, homepage and bookmarks, as on any Kali desktop install); full upgrade on first run; graphical boot target. Risk: single-maintainer community repo, not supported by Kali or Debian | see "Revert" in `specs/desktop.md`: remove the drop-in, toml, PAM file and daemon unit, reinstall `gdm3 gnome-shell gnome-session`, restore the debconf answer, `/etc/X11/default-display-manager` and the `display-manager.service` link to gdm3, then `sudo apt-get purge cosmic-epoch-monorepo`, remove the repo `.sources`, pin and key, `sudo apt-get update` |
| locale | no | English system language (`en_US.UTF-8`) with Colombian formats (`es_CO.UTF-8` for dates, numbers, money, paper): `locales` package, enables those two locales in `/etc/locale.gen` and generates them, values written with `update-locale`. The keyboard is not touched | restore `/etc/default/locale` and `/etc/locale.gen` from their `.bak.<timestamp>` files, then `sudo locale-gen` |
| drivers | no | CPU microcode by vendor (`amd64-microcode` or `intel-microcode`, non-free-firmware), the mesa base (`mesa-vulkan-drivers`, `mesa-va-drivers`, `libgl1-mesa-dri`), `firmware-amd-graphics` on AMD GPUs, `intel-media-va-driver` on Intel GPUs; works in a VM (virtual GPU: vendor parts skipped). NVIDIA: warning only, install Kali's `nvidia-driver` yourself. No i386 | `sudo apt-get purge` the packages you do not want; nothing else is changed |
| packages | no | Everyday packages from Kali (`firefox-esr`, CLI tools `bat` `eza` `fd-find` `ripgrep` `tealdeer`, fonts, GStreamer codecs, `unrar` from non-free; list in `files/packages/core.apt`), Brave from its vendor apt repo (key fingerprints verified, apt pin so the repo only provides `brave-browser` and `brave-keyring`) and PeaZip 11.4.0 from its upstream GitHub `.deb` (SHA-256 verified). In a virtual machine only (any hypervisor, no physical GPU): makes Chromium (`/etc/chromium.d/` drop-in) and Brave (generated `/usr/local/share/applications/brave-browser.desktop`) start with `--ozone-platform=x11` (see Known issues). Skips what is installed; Arch-only tools (yay, pacman-contrib, ...) are dropped | `sudo apt-get purge brave-browser brave-keyring peazip`, then `sudo apt-get autoremove` (review: drops `libgtk2.0-0t64`), `sudo rm -f /etc/apt/sources.list.d/brave-browser.sources /etc/apt/preferences.d/brave-browser /etc/apt/keyrings/brave-browser-archive-keyring.gpg /etc/apt/trusted.gpg.d/brave-browser-release.gpg` (the last is a symlink `brave-keyring` creates; the module removes it), then `sudo apt-get update`; delete `/etc/chromium.d/kali-cosmic-setup-virtual-gpu` (older installs: `kali-cosmic-setup-virtio-gpu`) and `/usr/local/share/applications/brave-browser.desktop` if they exist (VM workaround); purge any core package you do not want (see `specs/packages.md`) |
| packages-dev | yes | Development tools: Kali toolchains (`build-essential`, `golang-go`, `rustc`, `cargo`, Python libs, `docker.io` with Compose v2 and buildx, `mariadb-server`, `adb`, `shellcheck`, ...; list in `files/packages/dev.apt`), VS Code from Microsoft's apt repo and Claude Code from Anthropic's signed apt repo (key fingerprints verified, apt pins so each repo only provides its one package; the VS Code deb is told not to add its own repo), uv 0.13.9, engram 3.7.2 and gentle-ai 4.6.0 from GitHub releases in `/usr/local/bin` (SHA-256 verified). Enables Docker (unix socket only) and MariaDB bound to 127.0.0.1; adds you to `docker` (root-equivalent, re-login needed) and `plugdev` | see "Revert" in `specs/packages-dev.md`: `sudo systemctl disable --now docker.service docker.socket mariadb.service`, `sudo gpasswd -d $USER docker`, `sudo apt-get purge code claude-code docker.io docker-buildx docker-compose mariadb-server`, remove the two vendor `.sources`, pins and keys, the MariaDB drop-in and the four binaries in `/usr/local/bin`, then `sudo apt-get update` |
| cosmic-settings | no | COSMIC settings written as key files into `~/.config/cosmic` of the invoking user: tiling, dark theme and purple accent (seeded once, never overwritten), Papirus-Dark icons (`papirus-icon-theme`), compact UI, Super+Shift+S screenshot shortcut (merged into the shortcuts map, other entries are kept), idle, Files, Terminal, clock and audio applets. No keyboard layout, no terminal action | restore a key from its `<key>.bak.<timestamp>` file or delete the key file to get the COSMIC default (the `.bak` files sit next to the keys inside the watched v1 directories: delete them once you have restored what you wanted); remove the Super+Shift+S entry from `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`; `sudo apt-get purge papirus-icon-theme` |
| packages-ai | yes | Ollama 0.40.17 from its official release archives (SHA-256 verified against the release checksum file): the generic CPU build, plus the ROCm build on AMD GPUs; unpacked into `/usr/local`, a system user `ollama` and `ollama.service` bound to `127.0.0.1:11434` only (never the network). Downloads about 1.5 GB (2.6 GB with ROCm). No model is pulled | see "Revert" in `specs/packages-ai.md`: `sudo systemctl disable --now ollama`, `sudo rm /etc/systemd/system/ollama.service /usr/local/bin/ollama; sudo rm -r /usr/local/lib/ollama`, `sudo userdel ollama`, optionally `sudo rm -r /usr/share/ollama` (the models), then `sudo systemctl daemon-reload` |
| dark-mode | no | Dark GTK3/GTK4 and Qt5/Qt6 apps: `adw-gtk3-kali` with GSettings `gtk-theme='adw-gtk3-dark'` and `color-scheme='prefer-dark'` for your user (works over SSH or a TTY through the session bus or `dbus-run-session`), `~/.config/gtk-3.0` and `gtk-4.0` `settings.ini`, `qt5ct` and `qt6ct` with the `darker` color scheme and Papirus-Dark icons, `QT_QPA_PLATFORMTHEME=qt5ct` in `/etc/environment` (next login), and the empty `/etc/dconf/db/local` that Kali's dconf profile names (silences a dconf warning in every GSettings reader). No Flatpak, no Brave or Electron flag files (they follow the system color scheme) | `gsettings reset org.gnome.desktop.interface gtk-theme` and `... color-scheme`; remove the keys from the two `settings.ini` or restore their `.bak.<timestamp>`; `sudo sed -i '/^QT_QPA_PLATFORMTHEME=qt5ct$/d' /etc/environment` and log in again; restore or delete `~/.config/qt5ct/qt5ct.conf` and `~/.config/qt6ct/qt6ct.conf`; `sudo apt-get purge adw-gtk3-kali qt5ct qt6ct`; `sudo rm -f /etc/dconf/db/local` and `sudo rmdir /etc/dconf/db/local.d` if it is still empty |
| clipboard | no | Keeps the Wayland clipboard after the copying app closes: `wl-clipboard` from Kali, `wl-clip-persist` v0.5.0 (not packaged in Kali) built from the upstream tag with `cargo build --release --locked` after the checked-out commit is verified against the pinned `e26fde0` (cargo, rustc, git, gcc from Kali; nothing is built again while the installed version matches) and installed to `/usr/local/bin`, `COSMIC_DATA_CONTROL_ENABLED=1` in `/etc/environment` (next login) and the user service `~/.config/systemd/user/wl-clip-persist.service` (enabled; started in a graphical session only when the user manager already has `COSMIC_DATA_CONTROL_ENABLED=1`, otherwise the run says to log in again; the build commit is recorded in `~/.local/state/kali-cosmic-setup/clipboard`). Note: with data-control enabled any Wayland client can read the clipboard (that is how the persistence works) | `systemctl --user disable --now wl-clip-persist.service`; `rm ~/.config/systemd/user/wl-clip-persist.service` and `systemctl --user daemon-reload`; `sudo rm /usr/local/bin/wl-clip-persist`; `sudo sed -i '/^COSMIC_DATA_CONTROL_ENABLED=1$/d' /etc/environment` and log in again; `rm -r ~/.local/state/kali-cosmic-setup/clipboard` |
| kitty | no | The `kitty` terminal from Kali with the frosted-glass config (`~/.config/kitty/kitty.conf`), a user path unit that follows the COSMIC accent (it watches `CosmicTheme.{Dark,Light}/v2/accent`, theme version 2 hex colours, and `Mode/v1/is_dark`, and rewrites `~/.config/kitty/cosmic-colors.conf`), the `clear` alias (also clears scrollback) as a managed block in the rc file of your login shell (`~/.zshrc` for zsh, `~/.bashrc` for bash, any other shell gets a warning and no block; your shell is never changed), and kitty as the COSMIC default terminal: Super+T through the `Terminal` entry of the COSMIC `system_actions` map (the shipped map is copied with only `Terminal` changed; a terminal you chose yourself is kept) and `~/.config/cosmic-mimeapps.list` | `systemctl --user disable --now kitty-cosmic-colors.path`; delete `~/.config/kitty/kitty.conf`, `~/.config/kitty/cosmic-colors.conf`, `~/.local/bin/kitty-cosmic-colors.sh` and the two `kitty-cosmic-colors.*` units in `~/.config/systemd/user`, then `systemctl --user daemon-reload`; remove the `kitty-clear` block from the rc file (or restore its `.bak.<timestamp>`); restore `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions` from its `system_actions.bak.<timestamp>` (the `.bak` sits next to it; when the module created the file there is no `.bak`: delete it, back to `cosmic-term`) and remove the two kitty lines in `~/.config/cosmic-mimeapps.list`; `sudo apt-get purge kitty` |
| fastfetch | no | `fastfetch`, `imagemagick`, `git` and `git-lfs` from Kali (depends on `kitty`); builds a pool of images in `~/.config/fastfetch/images` by fetching six third-party GitHub repos, each pinned to a commit (fetched at run time with timeouts and size caps, validated with ImageMagick under a forced format and resource limits, resized to at most 600x600 and moved into the pool only after validation; invalid ones go to `~/.config/fastfetch/bad`; a source that is gone or offline only warns; `FASTFETCH_SKIP_IMAGES=1` skips them; no image is part of this repository) and a managed block in the rc file of your login shell (`~/.zshrc` or `~/.bashrc`) that shows `fastfetch --kitty <random image> --logo-width 20` in kitty windows | remove the `fastfetch` block from the rc file; if an older setup pasted the unmanaged snippet, the module removed it and the previous rc file is in `<rc>.bak.<timestamp>`: restore it from there to get the legacy snippet back; `rm -r ~/.config/fastfetch/images ~/.config/fastfetch/bad ~/.local/state/kali-cosmic-setup/fastfetch`; `sudo apt-get purge fastfetch imagemagick git-lfs` (only if nothing else needs them) |
| applets | no | The COSMIC panel applets Workspace Icons and Lock Keys, which Kali does not package: each is built with cargo from a pinned upstream commit (the checkout is verified against the pin; build packages `build-essential cargo rustc git pkg-config libxkbcommon-dev`, the minimal set found by a real build) as your user in `~/.cache/kali-cosmic-setup/src` (removed afterwards, never in this repository). Workspace Icons goes to `~/.local` (binary, desktop entry, icon, metainfo) with its eight config keys in `~/.config/cosmic`; Lock Keys goes to `/usr/local` (binary, desktop entry, caps/num lock icons). A marker with the built commit makes the second run build nothing; dry-run never builds. Now Playing is dropped. The applets are installed but not placed in the panel (the panel module does that) | remove the applets from the panel first; delete `~/.local/bin/cosmic-ext-applet-workspace-icons`, its `.desktop`, `.metainfo.xml` and `.svg` under `~/.local/share`, and `~/.config/cosmic/io.github.crocodile.cosmic-ext-applet-workspace-icons`; `sudo rm /usr/local/bin/cosmic-ext-lock-keys /usr/local/share/applications/com.lucianosb.cosmic-ext-lock-keys.desktop /usr/local/share/icons/hicolor/scalable/apps/{caps,num}-lock-symbolic.svg`; `rm -r ~/.local/state/kali-cosmic-setup/applets ~/.cache/kali-cosmic-setup/src`; `~/.cargo` (cargo's download cache from the builds, `rm -r ~/.cargo` if nothing else uses it); restore any `*.bak.<timestamp>` that sits next to a changed desktop entry or config key (for example in `~/.config/cosmic/io.github.crocodile.cosmic-ext-applet-workspace-icons/v3`); the build packages stay unless you purge them: `sudo apt-get purge libxkbcommon-dev pkg-config` (and `build-essential cargo rustc` if nothing else needs them) |
| panel | no | The COSMIC top panel layout of the reference setup (depends on `applets` and `cosmic-settings`): three cosmic-config keys in `~/.config/cosmic` of the invoking user, written only when they differ (with a `.bak.<timestamp>` of a different existing value): `com.system76.CosmicPanel/v1/entries` (`["Panel"]`: one top panel, the Dock is off), and in `com.system76.CosmicPanel.Panel/v1` the applet order `plugins_wings` (start: Workspace Icons; end: Date/Time, Lock Keys, Notifications Tray, Tiling, Sound, Bluetooth, Network, Power & Battery, Notifications Center, User Session) and `plugins_center` (`None`: Now Playing of the reference is dropped). Every other panel key (size, opacity, autohide, position) is yours and is never written; cosmic-panel reloads the keys live, nothing is restarted; a warning says when one of the two built applets is not installed | restore the `.bak.<timestamp>` next to each of the three keys, or delete the files `~/.config/cosmic/com.system76.CosmicPanel/v1/entries` and `~/.config/cosmic/com.system76.CosmicPanel.Panel/v1/{plugins_wings,plugins_center}` to fall back to the COSMIC default panel and dock (live, no restart) |
| audio-resync | no | Works around the COSMIC sound applet showing "No device selected" (pop-os/cosmic-settings-daemon#193): `~/.local/bin/cosmic-audio-resync` restarts `cosmic-settings-daemon` and then `cosmic-panel` a few seconds after login, once both run (the session respawns the panel with its applets; the daemon is started again only if the session does not), COSMIC sessions only, started by the XDG autostart entry `~/.config/autostart/cosmic-audio-resync.desktop`; the hand-made `fix-cosmic-audio.*` files are backed up and removed. Nothing is enabled or restarted during the install; the resync runs at your next login (by hand: `RESYNC_DELAY=0 ~/.local/bin/cosmic-audio-resync`) | `rm ~/.local/bin/cosmic-audio-resync ~/.config/autostart/cosmic-audio-resync.desktop`; if the module migrated hand-made files, restore the backed-up `~/.local/bin/fix-cosmic-audio.sh.bak.<timestamp>` and `~/.config/autostart/fix-cosmic-audio.desktop.bak.<timestamp>` (rename them back without the suffix) |
| aura | yes | Aura, the live wallpaper manager for COSMIC, from its official release `v1.11.2` (SHA-256 pinned in the module and verified twice, x86_64 only) installed like upstream's `--user` install (`~/.local/bin/aura`, `mpvpaper`, `aura-effects` and `aura-depth`, desktop entry, icon, the navbar and fire symbolic icons, metainfo; stale Aura PNG icons are removed); `mpv`, `libmpv2`, `ffmpeg` and `jq` from Kali; an `aura-restore` user unit that brings the last wallpaper back at login (legacy autostart entries removed, Aura's own autostart kept off); and the Alt+S shortcut for `aura switcher` (skipped with a warning when your home path has whitespace, a quote or a backslash); an `aura` or `mpvpaper` that is already there and was not installed by this setup is backed up first, and a newer Aura is never downgraded; the release archive is inspected before it is unpacked; the Alt+S shortcut is added as its own entry into the shared COSMIC shortcut map (other entries and a user binding on Alt+S are never touched). Aura keeps owning the accent color and dark mode while it runs | `systemctl --user disable --now aura-restore.service`; delete `~/.config/systemd/user/aura-restore.service`, `~/.local/bin/aura-restore`, `~/.local/bin/aura`, `~/.local/bin/mpvpaper`, `~/.local/bin/aura-effects`, `~/.local/bin/aura-depth` (and their `.bak.<timestamp>` copies of an earlier `aura` or `mpvpaper`, made at first adoption, to restore them), the `io.github.antwny.aura` desktop entry, icon and metainfo and the `navbar-open-symbolic.svg`, `navbar-closed-symbolic.svg` and `fire-symbolic.svg` icons (hicolor `scalable/actions`) under `~/.local/share` and `~/.local/state/kali-cosmic-setup/aura`; remove the Alt+S entry from `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom` (or restore its `.bak.<timestamp>`); restore autostart entries or the Aura config from their `.bak` files; wallpapers are never touched |
| services | no | Enables NetworkManager, bluetooth, power-profiles-daemon, systemd-timesyncd and fstrim.timer when installed; never disables, stops or restarts anything and never enables a listening service (no sshd, avahi, cups or firewall). If ifupdown configures an interface, NetworkManager is always enabled for the next boot only, never started now (it leaves an ifupdown-configured interface unmanaged); masked units are skipped; with systemd-networkd or another time daemon in use, the conflicting unit is left alone | `sudo systemctl disable --now <unit>` for any of the five units |
| mime | no | Default applications in `~/.config/mimeapps.list` (`[Default Applications]` only, merged key by key, the other entries and sections stay): Brave (`brave-browser.desktop`) for `text/html`, `x-scheme-handler/http`, `https`, `about`, `unknown` and `application/pdf`, PeaZip (`peazip.desktop`) for `application/zip`; a pair is skipped when its app is not installed. `firefox-esr` stays installed, not the default. Depends on `packages`. A different handler in your `~/.config/cosmic-mimeapps.list` would outrank these lines: the run warns and never edits that file | restore `~/.config/mimeapps.list.bak.<timestamp>`, or delete the lines this module added (the ones listed above) |
| mic-agc | no | Stops browsers and Electron apps from moving the microphone volume with their automatic gain control: a user PipeWire rule `~/.config/pipewire/pipewire-pulse.conf.d/20-block-mic-agc.conf` applies the `block-source-volume` quirk to clients whose binary is `firefox-esr` (Kali's Firefox), `firefox`, `chromium`, `brave`, `code` or `electron` (the COSMIC sound applet, `pavucontrol` and `wpctl` still set the volume). When the rule changes and a user `pipewire-pulse` is running, only that service is restarted (apps using audio reconnect); otherwise the rule applies at next login. A hand-made `99-block-mic-agc.conf` is backed up and removed | `rm ~/.config/pipewire/pipewire-pulse.conf.d/20-block-mic-agc.conf` then `systemctl --user restart pipewire-pulse` |
| keyboard | no | The keyboard layout you pick (menu, or `--keyboard <layout>[:<variant>]` or `--keyboard keep`, see [Keyboard](#keyboard)), applied everywhere and replacing the installer layout: `/etc/default/keyboard` (`pc105`, your layout and variant, no options), the `keyboard-configuration` debconf answers (set non-interactively), `update-initramfs -u` and the console keymap cache (only when something changed), `localectl set-x11-keymap`, and the COSMIC `xkb_config` of your user and of the login screen user (`cosmic-greeter`). Checks afterwards that the installer layout is nowhere. Runs last; full effect after a reboot. COSMIC's keyboard settings are never removed or locked | restore `/etc/default/keyboard.bak.<timestamp>` and `~/.config/cosmic/com.system76.CosmicComp/v1/xkb_config.bak.<timestamp>` (the greeter's is `/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicComp/v1/xkb_config.bak.<timestamp>`), run `sudo dpkg-reconfigure keyboard-configuration` and `sudo update-initramfs -u`, then `sudo localectl set-x11-keymap <layout> pc105 <variant>`; or just run `./install.sh --only keyboard --keyboard <other layout>` |

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

## Known issues

- **Virtual machines.** In any VM (KVM/QEMU, VMware, VirtualBox, Hyper-V,
  Xen, Parallels) without a passed-through GPU, Chromium and Brave can crash at
  start as native Wayland clients (`Trace/breakpoint trap`, after
  `create_immed failed and produced an invalid wl_buffer`; `import for wrong
  devices` in the journal). The `packages` module therefore applies the
  `--ozone-platform=x11` flag automatically there: a `/etc/chromium.d/` drop-in
  (every `chromium` launch, a terminal included) and a generated
  `/usr/local/share/applications/brave-browser.desktop` (the app menu,
  `xdg-open` and the default browser). Nothing is changed on bare metal or with
  a passed-through AMD, Intel or NVIDIA GPU. A `brave-browser` typed in a
  terminal reads neither, so in a VM it still needs `--ozone-platform=x11` by
  hand. Firefox ESR is not affected. To undo it, delete those two files.
  On KVM/QEMU with 3D acceleration (virtio-vga-gl, OpenGL) the COSMIC
  workspace overview (Super+W) can crash too (the same buffer import
  failure): turn 3D acceleration off (video model `virtio` without
  `accel3d`, SPICE OpenGL off).

## Not managed

- **Bootloader and kernel parameters.** The Kali installer configures them
  for each machine, and a wrong boot setting can leave a machine unbootable.
- **Personal data and secrets:** browser profiles, app state, SSH and GPG keys.
