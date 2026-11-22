# Porting from eos-cosmic-setup to kali-cosmic-setup

kali-cosmic-setup is a port of the EndeavourOS setup (eos-cosmic-setup, pacman,
AUR, Flatpak) to Kali Linux (kali-rolling, Debian based, apt). This file says what
happened to every eos module and package list and why. The per-module details are
in `specs/<module>.md`; the approved plan is `specs/000-plan.md`.

Ground rules of the port:

- Kali first, then Debian, then official upstream releases verified by checksum.
  A third-party apt repository is added only with a fingerprint-verified key in
  `/etc/apt/keyrings` and an apt pin (vendor repos only: Brave, VS Code, Claude
  Code, and the community COSMIC repo for the desktop).
- No AUR, no Flatpak, no Ubuntu or Pop!_OS repositories, no multilib or i386.
- Kali's own security tools and its services are never touched. Default modules
  never enable a listening service; opt-in modules listen on 127.0.0.1 only.
- Files are written to the invoking user's home, never root's.

Status words: **ported** (same job, adapted to apt), **opt-in** (ported, but only
runs when named with `--only`), **new** (does not exist in eos), **dropped** (not
ported).

## Modules

eos modules in their numbering order (`eos modules/`), with the Kali counterpart.

| eos module | Kali module | Status | What changed and why |
|------------|-------------|--------|----------------------|
| 05-pacman-conf | none | dropped | Pacman specific. Kali uses apt, and the desktop module no longer depends on it. |
| 06-desktop | desktop | ported | COSMIC comes from the community apt repo `debian-cosmic` (key fingerprint checked, apt pin) instead of the Arch packages. greetd and cosmic-greeter replace GDM, and GDM and GNOME Shell are purged (kept and disabled if a `kali-*` package depends on them). Audio, Bluetooth and network base are added for a "no desktop" install. |
| 08-locale | locale | ported | Debian reads `/etc/default/locale`, not `/etc/locale.conf`, so the same content is installed there. Package `locales`. Keyboard text removed (the keyboard module owns it). |
| 10-drivers | drivers | ported | `amd64-microcode` or `intel-microcode` by CPU vendor; `mesa-vulkan-drivers`, `mesa-va-drivers`, Intel VA-API driver and `firmware-amd-graphics` by GPU vendor. NVIDIA only warns and points to Kali's `nvidia-driver`. `nvidia-inst` and every lib32 and multilib step are dropped (no i386). |
| 14-flatpak | none | dropped | No Flatpak on Kali. Apps come from apt or vendor repos. The Flatpak part of dark mode is dropped with it. |
| 15-packages | packages | ported | The pacman list became `files/packages/core.apt`. Brave (AUR) comes from the Brave vendor repo, PeaZip from its upstream `.deb` (sha256 verified). See the package tables below. |
| 16-packages-dev | packages-dev | opt-in | `files/packages/dev.apt` plus VS Code and Claude Code from their vendor apt repos, and uv, engram and gentle-ai from checksum-verified GitHub releases (they were AUR or pacman packages). Docker and MariaDB stay local only. |
| 17-packages-gaming | none | dropped | Steam, GameMode, MangoHud, ProtonUp-Qt are outside the Kali use and need multilib or Flatpak. |
| 18-packages-media | none | dropped | The brief has no media extras (GIMP, Krita, OBS, Kdenlive, Spotify, Vesktop, Crunchyroll, Iriun). |
| 19-packages-office | none | dropped | No office extras (LibreOffice, Obsidian, aspell). |
| 20-cosmic-settings | cosmic-settings | ported | Same key files under `~/.config/cosmic`. Two parts moved out: the Alt+S aura shortcut moved to the aura module, and the keyboard layout generation (`xkb_config`) moved to the keyboard module. The shortcut map is shared, so each module merges only its own entry. |
| 21-packages-printing | none | dropped | cups and cups-browsed would be listening services, which the service policy forbids. |
| 22-packages-ai | packages-ai | opt-in | Ollama from its official release archive (generic CPU build, ROCm build on AMD), sha256 verified, run by a dedicated user on `127.0.0.1:11434`. eos used `ollama`, `ollama-rocm` and `ollama-cuda` from pacman. No CUDA build. |
| 23-packages-vmware | none | dropped | AUR only (VMware Workstation), not applicable. |
| 25-dark-mode | dark-mode | ported | GTK: `adw-gtk3-kali` with `adw-gtk3-dark` and `prefer-dark`. Qt: `qt5ct` and `qt6ct`. The Flatpak override part is dropped. |
| 30-clipboard | clipboard | ported | `wl-clipboard` from Kali. `wl-clip-persist` is not packaged on Kali, so it is built with cargo from a pinned upstream tag. |
| 40-kitty | kitty | ported | Same config and accent-color unit (theme keys read from `v2`). The rc block goes to `~/.zshrc` or `~/.bashrc` by login shell. |
| 45-fastfetch | fastfetch | ported | Same image pool and kitty logo. The block goes to the rc file of the login shell. Image sources are third-party repos cloned at run time. |
| 50-applets | applets | ported | Workspace Icons and Lock Keys are not packaged, so each is built with cargo from a pinned upstream commit. The Now Playing applet is dropped (AUR only). |
| 55-panel | panel | ported | Same single top panel and applet order, except that Now Playing is gone from the center. |
| 57-audio-resync | audio-resync | ported | Same workaround for the sound applet showing "No device selected"; the unit only runs under COSMIC. |
| 60-aura | aura | opt-in | Aura from its official release `v1.5.0` (sha256 pinned, tarball inspected before extracting), restore user unit, Alt+S shortcut. |
| 65-steam-icons | none | dropped | Depends on Steam, dropped with gaming. |
| 70-services | services | ported | Base services only: NetworkManager, bluetooth, power-profiles-daemon, systemd-timesyncd, fstrim.timer. firewalld, avahi, cups, VMware units and the sshd switch are dropped (service policy); Kali's `ssh` unit is never touched. |
| 75-mime | mime | ported | Same defaults (Brave for web and PDF, PeaZip for zip) for installed apps only; Vesktop dropped. |
| 80-kvm | none | dropped | A libvirt host setup is out of scope for the Kali desktop. |
| 82-wacom | none | dropped | Hardware specific to one machine. |
| 83-mic-agc | mic-agc | ported | Same PipeWire rule; the browser list gets `firefox-esr` and loses `librewolf`. |
| 84-vesktop-mic | none | dropped | Vesktop is dropped; the generic mic-agc rule stays. |
| none | keyboard | new | The layout is chosen in a menu or with `--keyboard` and replaces the Kali installer layout everywhere (`/etc/default/keyboard`, debconf, console, localectl, COSMIC for the user and the login screen). It runs last. See `specs/keyboard.md`. |

Other things dropped inside modules that were kept: LibreWolf, `nvidia-inst`,
lib32 packages, firewalld, avahi and cups services, the `SERVICES_SSHD` switch,
Flatpak dark mode, and the `mariadb-install-db` step (Debian's postinst
initializes the data directory).

The install order on Kali (`./install.sh --list`) is: desktop, locale, drivers,
packages, packages-dev (opt-in), cosmic-settings, packages-ai (opt-in), dark-mode,
clipboard, kitty, fastfetch, applets, panel, audio-resync, aura (opt-in),
services, mime, mic-agc, keyboard.

## Package lists

Every file of eos `files/packages/` and what happened to it.

| eos list | Contents (eos) | Kali | Why |
|----------|----------------|------|-----|
| core.pacman | 54 packages | `files/packages/core.apt` | Ported with renames; 8 entries dropped and PeaZip moved to its upstream `.deb` (below). |
| core.aur | brave-bin | Brave vendor apt repo (`brave-browser`) | Signed key with a checked fingerprint, apt pin. |
| dev.pacman | 18 packages | `files/packages/dev.apt` | Ported with renames (below). Opt-in module. |
| dev.aur | visual-studio-code-bin, claude-code, gentle-ai, engram-bin | VS Code and Claude Code vendor apt repos; gentle-ai and engram GitHub releases | Vendor repos with fingerprint-verified keys and pins, or releases verified by sha256. |
| gaming.pacman | steam, gamemode, mangohud | dropped | Needs multilib; outside the Kali use. |
| gaming.flatpak | net.davidotek.pupgui2 | dropped | No Flatpak. |
| media.pacman | gimp, krita, spotify-launcher, libdvdcss, libopenraw, libgsf | dropped | No media extras. |
| media.aur | vesktop, crunchyroll, iriunwebcam-bin | dropped | AUR only, no media extras. |
| media.flatpak | com.obsproject.Studio, org.kde.kdenlive | dropped | No Flatpak. |
| office.pacman | libreoffice-fresh, obsidian, aspell | dropped | No office extras. |
| printing.pacman | cups, cups-browsed, cups-filters, cups-pdf, foomatic-db, foomatic-db-engine, foomatic-db-gutenprint-ppds, foomatic-db-nonfree, foomatic-db-nonfree-ppds, foomatic-db-ppds, ghostscript, gsfonts, gutenprint, hplip, sane, system-config-printer | dropped | The service policy forbids the cups and avahi listeners. |
| vmware.aur | vmware-workstation, vmware-keymaps | dropped | AUR only. |
| (none) | (none) | `packages-ai` has no list | Ollama is an upstream release, not a package list. |

### core: pacman and AUR name to apt name

Source of truth: `files/packages/core.apt` and `specs/packages.md`.

| eos (pacman or AUR) | Kali apt | Note |
|---------------------|----------|------|
| firefox | firefox-esr | Kali ships the ESR build. |
| librewolf | DROP | Not in Kali; Firefox ESR plus Brave cover it. |
| bat | bat | Binary is `batcat`. |
| eza | eza | |
| fd | fd-find | Binary is `fdfind`. |
| ripgrep | ripgrep | |
| direnv | direnv | |
| htop | htop | |
| glances | glances | |
| nvtop | nvtop | |
| duf | duf | |
| tldr | tealdeer | Binary is `tldr`. |
| tree | tree | |
| plocate | plocate | |
| pkgfile | apt-file | Replaces pkgfile; `apt-file update` is not run automatically. |
| inxi | inxi | |
| hwinfo | hwinfo | |
| mesa-utils | mesa-utils | |
| rsync | rsync | |
| wget | wget | |
| unzip | unzip | |
| unrar | unrar | Kali non-free component. |
| bash-completion | bash-completion | |
| neovim | neovim | |
| nano | nano | |
| nano-syntax-highlighting | DROP | Debian's nano ships its syntax files. |
| man-db | man-db | |
| man-pages | manpages | Debian name. |
| which | DROP | `debianutils` (essential) provides `which`. |
| whois | whois | |
| less | less | |
| yay | DROP | AUR helper; there is no AUR on Kali. |
| downgrade | DROP | Pacman tool. |
| pacman-contrib | DROP | Pacman tool. |
| rebuild-detector | DROP | Arch specific. |
| noto-fonts | fonts-noto-core | |
| noto-fonts-cjk | fonts-noto-cjk | |
| noto-fonts-emoji | fonts-noto-color-emoji | |
| noto-fonts-extra | fonts-noto-extra | |
| ttf-dejavu | fonts-dejavu | |
| ttf-liberation | fonts-liberation | |
| ttf-opensans | fonts-open-sans | |
| ttf-bitstream-vera | ttf-bitstream-vera | Same name in Kali. |
| cantarell-fonts | fonts-cantarell | |
| peazip | upstream `.deb` (not in the list) | GitHub release, sha256 verified; needs `libgtk2.0-0t64`. |
| gst-libav | gstreamer1.0-libav | |
| gst-plugin-pipewire | gstreamer1.0-pipewire | |
| gst-plugin-va | DROP | No VA-API GStreamer package in Kali; VA-API comes from `mesa-va-drivers` (drivers module). |
| gst-plugins-bad | gstreamer1.0-plugins-bad | |
| gst-plugins-ugly | gstreamer1.0-plugins-ugly | |
| pavucontrol | pavucontrol | |
| gnome-keyring | gnome-keyring | |
| xdg-user-dirs | xdg-user-dirs | |
| xdg-utils | xdg-utils | |
| brave-bin (AUR) | brave-browser | Brave vendor apt repo (not in the list). |

### dev: pacman and AUR name to apt name

Source of truth: `files/packages/dev.apt` and `specs/packages-dev.md`.

| eos (pacman or AUR) | Kali apt or source | Note |
|---------------------|--------------------|------|
| base-devel | build-essential | |
| git | git | |
| go | golang-go | |
| rust | rustc, cargo | |
| python | python3, python3-venv, python3-pip | `python3` already ships with Kali. |
| python-pillow | python3-pil | |
| python-pyqt5 | python3-pyqt5 | |
| python-reportlab | python3-reportlab | |
| uv | GitHub release (astral-sh/uv) | Installed to `/usr/local/bin`, sha256 verified (not in the list). |
| docker | docker.io | |
| docker-buildx | docker-buildx | |
| docker-compose | docker-compose | Kali's package is Compose v2 and ships the `docker compose` plugin. |
| mariadb | mariadb-server | Bound to 127.0.0.1. |
| meld | meld | |
| just | just | |
| android-tools | adb, fastboot | |
| android-udev | android-udev-rules | |
| shellcheck | shellcheck | |
| visual-studio-code-bin (AUR) | code | Microsoft apt repo, fingerprint-verified key, pin (not in the list). |
| claude-code (AUR) | claude-code | Anthropic apt repo, fingerprint-verified key, pin (not in the list). |
| engram-bin (AUR) | GitHub release | `/usr/local/bin/engram`, sha256 verified (not in the list). |
| gentle-ai (AUR) | GitHub release | `/usr/local/bin/gentle-ai`, sha256 verified (not in the list). |

The vendor and release items are installed by `modules/16-packages-dev.sh`
instead of from `dev.apt`; every package in `dev.apt` comes from the rows above.
