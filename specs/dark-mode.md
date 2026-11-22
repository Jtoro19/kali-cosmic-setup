# dark-mode

## Purpose

Make non-COSMIC apps dark: GTK3/GTK4/libadwaita through `adw-gtk3-dark` and the
`prefer-dark` color scheme, Qt5/Qt6 through qt5ct/qt6ct with the `darker` color
scheme. COSMIC's own dark mode (`is_dark`) is seeded by the `cosmic-settings`
module, which this module depends on (it also supplies the Papirus-Dark icons the
Qt configs use). No font is set anywhere. `MODULE_OPTIN=0`.

## Source of truth

eos `modules/25-dark-mode.sh`, `specs/dark-mode.md`, `files/dark-mode/qt5ct.conf`
and `qt6ct.conf`, ported to apt. The Flatpak part is dropped (no Flatpak on this
setup). Shipped data: `files/dark-mode/qt5ct.conf` and `qt6ct.conf`
(`[Appearance]` only; no `[Fonts]` section so default fonts are kept). Facts
checked on the Kali VM are in `odd/verified-facts.md` section 3.

## Files and packages touched

- Packages: `adw-gtk3-kali` (ships `/usr/share/themes/adw-gtk3-dark`; the plain
  name `adw-gtk3` has no candidate on Kali), `qt5ct`, `qt6ct`.
- GSettings (invoking user, no sudo) `org.gnome.desktop.interface`:
  `gtk-theme='adw-gtk3-dark'` and `color-scheme='prefer-dark'`.
- `~/.config/gtk-3.0/settings.ini` `[Settings]`: `gtk-theme-name=adw-gtk3-dark`,
  `gtk-application-prefer-dark-theme=1`. For GTK3 apps that do not read
  GSettings (X11 apps with no XSETTINGS daemon, which is COSMIC, and apps that
  bundle their own GTK).
- `~/.config/gtk-4.0/settings.ini` `[Settings]`: `gtk-application-prefer-dark-theme=1`
  only (see decision 3).
- `/etc/environment`: one line `QT_QPA_PLATFORMTHEME=qt5ct` (sudo through the
  helpers). The qt6ct plugin registers both the `qt6ct` and `qt5ct` keys, so
  this single value makes Qt6 apps load qt6ct and Qt5 apps load qt5ct.
- `~/.config/qt5ct/qt5ct.conf` and `~/.config/qt6ct/qt6ct.conf`: the
  `[Appearance]` keys of the shipped files, key by key: `color_scheme_path`
  (`/usr/share/qt5ct/colors/darker.conf` and `/usr/share/qt6ct/colors/darker.conf`,
  each package ships its own directory), `custom_palette=true`,
  `icon_theme=Papirus-Dark`, `standard_dialogs=default`, `style=Fusion`. Other
  keys and sections that qt5ct/qt6ct write when their GUI opens (fonts, window
  geometry) are kept, so opening the GUI does not make the module report changes.
- Backups `<file>.bak.<timestamp>` for every file that changes.
- The `[Appearance]` keys are re-applied on every run: a key the user changed
  there (for example `style`) is put back to the shipped value, after a backup,
  while keys outside `[Appearance]` are never touched. To keep a different
  value, remove that line from `files/dark-mode/qt{5,6}ct.conf` in your copy.
- User files (`settings.ini`, `qt5ct.conf`, `qt6ct.conf`) go through the shared
  guard `user_path_writable`: a file or directory owned by another user is
  skipped with a warning (never written through sudo), and a symlink is
  followed only when its target is inside `$HOME`. `ensure_ini_line` accepts
  CRLF files and `key = value` spacing. `ensure_gsetting` runs under
  `timeout 20`, treats a failing `set` as a warning, and reads the value back to
  report a backend that does not persist it.

## Decisions on ambiguities

1. **Theme name.** `adw-gtk3-kali` ships `adw-gtk3-dark` (VM: `dpkg-deb -c`, and
   the directory exists after install). The module checks the directory after a
   real install; if it were missing it warns and sets only the dark preference
   (`color-scheme` and `gtk-application-prefer-dark-theme`), never a theme that
   does not exist.
2. **GSettings without a desktop session.** `ensure_gsetting` (ported from eos,
   `lib/common.sh`) picks the bus in this order and logs nothing extra when it
   works: (a) `DBUS_SESSION_BUS_ADDRESS` set (inside the session); (b)
   `$XDG_RUNTIME_DIR/bus` exists (SSH to a user whose session or systemd user
   manager runs: the variable is pointed at that bus, so the values land where the
   live session reads them); (c) neither (TTY): run under `dbus-run-session`,
   which starts a private bus and `dconf-service`, which writes
   `~/.config/dconf/user`. `gsettings` syncs before it exits, so nothing is lost
   when the private bus goes away; running sessions pick the file change up.
   Verified on the VM: with no session bus the module set `color-scheme` and a
   later read through the session bus returned `'prefer-dark'`. The private bus
   runs with `GIO_USE_VFS=local` and the value of a read goes through a temp file:
   without that, the GVfs modules activate `gvfsd-fuse` on the private bus, it
   outlives the command and keeps the pipe of `$(gsettings get ...)` open, which
   hung the installer on the VM (found by running it). If none of (a) to (c) is
   available, or the schema is unreadable, the module warns, skips GSettings and
   still writes the files. COSMIC's session uses `DCONF_PROFILE=user-db:cosmic,
   user-db:user`; writes outside the session go to the `user` db, which the
   session reads as the second layer, and the cosmic db holds no such keys.
3. **GTK4.** libadwaita apps follow `color-scheme`; plain GTK4 apps honour
   `gtk-application-prefer-dark-theme`. `gtk-4.0/settings.ini` therefore holds
   only that key: `adw-gtk3` is a GTK3 theme and is not forced on GTK4 apps.
4. **`QT_QPA_PLATFORMTHEME` in `/etc/environment`, not `environment.d`.** The
   COSMIC session on Kali starts through greetd with PAM service `cosmic-greeter`
   (`files/desktop/cosmic-greeter.pam`: `pam_env readenv=1` reads
   `/etc/environment`), then `start-cosmic`, which runs the user's login shell
   and keeps an existing `QT_QPA_PLATFORMTHEME`. Verified: the running session
   inherited the variables of `/etc/environment` (kali-defaults entries are in
   `cosmic-session`'s environment). `~/.config/environment.d` only feeds systemd
   user units, not what the compositor starts, so it would not reach apps
   launched from COSMIC; hence the eos approach. Note that `start-cosmic` already
   falls back to `qt5ct` when `libqt6ct.so` or `libqt5ct.so` is installed and
   CuteCosmic is not; the explicit line keeps the value stable. If
   `/etc/environment` already sets another `QT_QPA_PLATFORMTHEME`, the module
   warns and adds nothing (never a second line). Takes effect at the next login.
5. **Electron and Chromium flags are dropped.** eos wrote `--force-dark-mode` to
   `electron-flags.conf`, `brave-flags.conf` and `code-flags.conf`, which are
   Arch wrapper features. Verified on the VM: the Debian Brave wrapper
   (`/opt/brave.com/brave/brave-browser`) and VS Code's (`/usr/share/code/bin/code`)
   read no flags file and no `CHROME_FLAGS`-style variable, and the `brave`
   binary contains no `flags.conf` string. A managed policy or a `.desktop`
   override would be fragile and covers only some launch paths. They are not
   needed: Brave follows the system color scheme (xdg-desktop-portal reports
   `color-scheme` 1 in the session) and rendered dark in the live COSMIC session
   with a fresh profile and no flag; Electron apps follow the same portal value
   or have their own theme setting (VS Code defaults to a dark theme).
6. **No Flatpak.** The Flatpak runtime and override of eos are not ported.

## Hardware detection

None.

## Idempotency check

Every check is read-only: package presence, `gsettings get`, the exact line in
`/etc/environment`, per-key match of the settings.ini and qt `[Appearance]`
keys. A second run reports `total changes: 0` and no gsettings write, so
`--dry-run` is accurate.

## Revert

- `gsettings reset org.gnome.desktop.interface gtk-theme` and
  `gsettings reset org.gnome.desktop.interface color-scheme`.
- Remove the keys from `~/.config/gtk-3.0/settings.ini` and
  `~/.config/gtk-4.0/settings.ini` (or restore their `.bak.<timestamp>`).
- `sudo sed -i '/^QT_QPA_PLATFORMTHEME=qt5ct$/d' /etc/environment` (or restore
  `/etc/environment.bak.<timestamp>`), then log out and back in.
- Restore `~/.config/qt5ct/qt5ct.conf` and `~/.config/qt6ct/qt6ct.conf` from
  their `.bak.<timestamp>` files, or delete them.
- `sudo apt-get purge adw-gtk3-kali qt5ct qt6ct` if wanted.

## Verification

- `tests/test-dark-mode.sh` (fake apt, gsettings and dbus-run-session, temporary
  HOME and root): dry-run, fresh run, second run 0 changes, user keys kept,
  `/etc/environment` cases, the three bus variants, a daemon left by the private
  bus, missing theme, failing apt.
- On a COSMIC session (VM): `gsettings get org.gnome.desktop.interface
  color-scheme` prints `'prefer-dark'` and `gtk-theme` prints `'adw-gtk3-dark'`;
  the session's `QT_QPA_PLATFORMTHEME` is `qt5ct`; a GTK3 app
  (`nm-connection-editor`) and a Qt app (`qt6ct`) render dark
  (`odd/evidence/dark-mode-gtk.png`, `odd/evidence/dark-mode-qt.png`); Brave is
  dark without any flag.
- `./install.sh --only dark-mode --dry-run` reports nothing to change after a run.
