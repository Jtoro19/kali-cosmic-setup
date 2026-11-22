# locale

## Purpose

Set the system language to English (`en_US.UTF-8`) and the regional formats
(dates, numbers, money, paper, units) to Colombian Spanish (`es_CO.UTF-8`),
the same split as the EndeavourOS setup. The keyboard is not part of this
module (the keyboard module owns it).

## Source of truth

`files/locale/locale.conf` (copied from the reference repo, no personal data;
the es_CO formats are a preference): `LANG=en_US.UTF-8` and nine `LC_*`
variables set to `es_CO.UTF-8`. The module reads that file, so the data lives
in one place. The locales to generate are the two values it uses, listed in
the module (`_LOCALE_GEN`).

## Files and packages touched

- Package `locales` (Kali main), installed when missing.
- `/etc/locale.gen`: `en_US.UTF-8 UTF-8` and `es_CO.UTF-8 UTF-8` uncommented
  (appended when absent, created when the file is missing); every other line
  is kept. Backup `/etc/locale.gen.bak.<timestamp>` when it changes.
- `/etc/default/locale`: written with `update-locale`, which keeps every
  variable the module does not own (for example `LANGUAGE`). Backup
  `/etc/default/locale.bak.<timestamp>` when a value changes.
- A `LC_ALL` line in `/etc/default/locale` overrides everything this module
  sets; the module warns about it and does not remove it.
- Optional `LOCALE_TZ=<Area/City>` (must be a file under
  `/usr/share/zoneinfo`, a directory is rejected): sets the time zone with `timedatectl`;
  without it the time zone is left alone.
- No services. No keyboard files. No `/etc/locale.conf` (that is the Arch
  location; Debian reads `/etc/default/locale`, and `localectl` shows it).

## Hardware detection

None.

## Decisions

- `update-locale` instead of copying a file: it preserves foreign variables
  and is the Debian-supported writer. Idempotency does not depend on byte
  comparison: the module reads each wanted variable (one pair of quotes
  removed) and calls `update-locale` only when one differs.
- `locale-gen` runs when `locale.gen` changed or when a wanted locale is
  missing from `locale -a` (a file that is right but never generated).
  Only the two needed locales are enabled, not the whole list.
- `update-locale` runs after `locale-gen` so it never points at a missing
  locale.
- The keyboard and the console font are deliberately untouched.

## Idempotency check

`locale.gen` is rendered into a temp file and compared with `install_file`;
`locale -a` is checked for both locales; each variable of
`/etc/default/locale` is compared with the wanted value. A second run prints
`total changes: 0`.

## Revert

Restore `/etc/default/locale` and `/etc/locale.gen` from their
`*.bak.<timestamp>` files (or run `sudo update-locale LANG=<old>` and remove
the `LC_*` lines), then `sudo locale-gen`. The `locales` package is left
installed.

## Verification

```bash
./install.sh --only locale          # then again: "total changes: 0"
localectl status                    # System Locale: LANG=en_US.UTF-8 and the LC_* es_CO values
locale -a | grep -E 'en_US|es_CO'   # en_US.utf8 and es_CO.utf8
bash -lc 'locale'                   # LC_TIME="es_CO.UTF-8" in a new login shell
./install.sh --only locale --dry-run  # "Nothing to change"
```
