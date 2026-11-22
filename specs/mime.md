# mime

## Purpose

Set the user's default applications in `~/.config/mimeapps.list`: Brave for the
web and PDF, PeaZip for zip. `MODULE_OPTIN=0`, `MODULE_DEPS="packages"` (the
packages module installs Brave and PeaZip, so the desktop entries exist).

## Source of truth

eos `75-mime.sh` and `specs/mime.md`, ported with the plan decisions (Brave and
PeaZip defaults, Vesktop entry dropped). Desktop ids checked on the Kali VM
(`odd/verified-facts.md` sections 6 and 7): `brave-browser.desktop` (Brave deb)
and `peazip.desktop` (the upstream PeaZip deb; eos's `peazip-extract.desktop`
is an Arch package id and does not exist here).

## Mappings

| MIME type | Desktop entry |
|-----------|---------------|
| text/html, x-scheme-handler/http, https, about, unknown | brave-browser.desktop |
| application/pdf | brave-browser.desktop |
| application/zip | peazip.desktop |

`firefox-esr` stays installed (packages module) and is not made the default;
eos does not do it either.

## Files and packages touched

- `~/.config/mimeapps.list`, `[Default Applications]` section only. A new file
  is written in one step; an existing one is merged key by key
  (`ensure_ini_line ... replace`, backup `.bak.<timestamp>`): other keys, the
  `[Added Associations]` and `[Removed Associations]` sections and comments are
  kept.
- No packages.

## Decisions on ambiguities

1. **A mapping is applied only when its desktop entry is installed** in the
   user, `/usr/local` or `/usr` applications directory (the Flatpak
   directories of eos are dropped: no Flatpak in this setup). A missing app
   gives an info line `skip <type>: <id> is not installed`.
2. **Archive type.** Only `application/zip` is set, as in eos. PeaZip lists many
   more archive types in its `MimeType`; the other types keep the system
   default (file-roller, for example `application/x-7z-compressed`), so the
   module does not take over types the reference did not.
3. **Which file COSMIC reads.** `xdg-mime query default` and GLib (`gio mime`,
   which COSMIC Files and `xdg-open` use) read `~/.config/mimeapps.list` before
   the system `/usr/share/applications/cosmic-mimeapps.list` (the COSMIC
   defaults, which hold only COSMIC apps such as Edit); `cosmic-files` and
   `cosmic-settings` themselves read the `mimeapps.list` files too (the string
   is in both binaries). The user's desktop-specific
   `~/.config/cosmic-mimeapps.list` (written by the kitty module for the terminal
   and by COSMIC Settings) is read before `mimeapps.list`; the module never edits
   it and warns when it sets a different handler for one of our types, because
   that entry would win.
4. **Ownership guard.** `ensure_ini_line` and `ensure_file_content` apply the
   shared `user_path_writable` guard: a list owned by someone else, or a
   symlink pointing outside `$HOME`, is skipped with a warning, never written
   through sudo.
5. **Not managed:** COSMIC app defaults, the terminal (kitty module),
   `x-scheme-handler/claude-cli` (Claude Code registers it), `mailto`.

## Hardware detection

None.

## Idempotency check

Each key is checked in `[Default Applications]`: an identical line is skipped, a
different value is replaced, a missing key is added. A second run reports
`total changes: 0`.

## Revert

Restore `~/.config/mimeapps.list.bak.<timestamp>`, or delete the seven lines.

## Verification

```bash
./install.sh --only mime --dry-run
./install.sh --only mime                  # then again: "total changes: 0"
xdg-mime query default x-scheme-handler/https    # brave-browser.desktop
xdg-mime query default application/pdf           # brave-browser.desktop
xdg-mime query default application/zip           # peazip.desktop
tests/test-mime.sh
```
