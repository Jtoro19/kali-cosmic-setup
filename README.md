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
(`sudo -v`) and keeps it valid in the background, so the rest runs unattended;
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
