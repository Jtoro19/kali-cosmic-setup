# keyboard

## Purpose

Replace the keyboard layout chosen in the Kali installer with the one the user
picks (menu or `--keyboard`), in every place that holds it, and prove that the
installer layout is nowhere afterwards. `MODULE_OPTIN=0`, no dependencies, file
`modules/90-keyboard.sh` (after every other default module). The menu and the
validation live in `lib/keyboard.sh`, called from `install.sh`.

## Source of truth

`BRIEF.md` section "Keyboard" and `specs/000-plan.md` "Keyboard design". This
differs from eos-cosmic-setup, which keeps the installer layout: only the COSMIC
`xkb_config` render and the greeter-user copy are ported from eos
`modules/20-cosmic-settings.sh` (`_cosmic_xkb_render`, `_cosmic_greeter_xkb_apply`
and the commit "give the login screen the system keyboard layout"), with the
changes in decisions 6 and 7. Facts: `odd/verified-facts.md` section 5 and the VM
checks below (Kali rolling, keyboard-configuration 1.249, COSMIC 1.11.0).

## Interface

- Menu, shown once by `install.sh` right after `sudo -v` and before stdin is
  closed, only when the keyboard module is selected and no `--keyboard` was
  given: 1 `us`, 2 `us:altgr-intl`, 3 `us:intl`, 4 `latam`, 5 `es`, 6 Keep
  current (shows the layout and variant of `/etc/default/keyboard`), 7 Other
  (layout, then an optional variant, each validated against
  `/usr/share/X11/xkb/rules/evdev.lst`). No default: empty or invalid input asks
  again; end of input fails (never loops).
- `--keyboard <layout>[:<variant>]` and `--keyboard keep` skip the menu. The
  value is validated against the same list before `sudo` is asked (exit 2).
- No terminal and no `--keyboard` on a real run: the installer stops before any
  module with a clear message (exit 1). On `--dry-run` it only says that the real
  run asks, and the module plans nothing.
- `--dry-run` with a choice prints the layout and the files it would change.

## Files and packages touched

Chosen layout L, variant V (possibly empty):

1. `/etc/default/keyboard` (backup): `XKBMODEL="pc105"`, `XKBLAYOUT="L"`,
   `XKBVARIANT="V"`, `XKBOPTIONS=""`; the other lines (comments, `BACKSPACE`)
   stay, a missing file is created complete. Written **first**, see decision 3.
2. debconf `keyboard-configuration/{modelcode,layoutcode,variantcode,optionscode,xkb-keymap}`
   plus the display answers `layout` and `variant`, through `debconf-set-selections`
   and `dpkg-reconfigure -f noninteractive` with `DEBIAN_FRONTEND=noninteractive`,
   only when a code answer differs.
3. `setupcon --save-only` (the console keymap cache in `/etc/console-setup`) and
   `update-initramfs -u` only when something changed above, or when
   `/etc/default/keyboard` is newer than the running kernel's initramfs (an
   interrupted earlier run). That is what the TTY console and a disk-unlock prompt
   read.
4. `localectl set-x11-keymap L pc105 V ""`, only when `localectl status` differs
   (this is what cosmic-greeter and the console conversion read).
5. COSMIC `~/.config/cosmic/com.system76.CosmicComp/v1/xkb_config` of the invoking
   user (backup) and of the greeter user (`cosmic-greeter`, home from `getent`,
   `/var/lib/cosmic-greeter`), written as root with the greeter's ownership; only
   that file, missing directories are created owned by the greeter. RON format as
   COSMIC writes it (verified on the VM): `rules: "", model: "pc105", layout: "L",
   variant: "V", options: None`, with the `repeat_delay` and `repeat_rate` already in
   the file kept (defaults 600 and 25).
6. Package `keyboard-configuration` and `xkb-data` (already present on Kali).

"Keep current" changes nothing and runs no command.

## Decisions on ambiguities

1. **The layout becomes the only one configured.** A chosen layout replaces the
   whole `layout` and `variant` lists of the COSMIC config, so layouts added in
   COSMIC Settings are replaced by an explicit choice (also on a repeat run with
   the same `--keyboard`). "Keep current" never touches them. This matches the
   BRIEF ("picking a layout in the menu makes it the only configured one again").
2. **"The installer layout appears nowhere" is checked by equality, not by
   searching for the old name.** After the apply, `_kbd_verify` reads every place
   and requires exactly the chosen layout: `/etc/default/keyboard` (layout, variant,
   empty options), debconf (the five code answers), the display answers (they must
   no longer be the pre-run ones), `localectl status` (X11 layout and variant),
   `/etc/vconsole.conf` (`XKBLAYOUT`, and a `KEYMAP` that did not survive from before
   the run), the user's and the greeter's `xkb_config`. Anything else is listed with
   `log_error` and the module fails (exit non-zero). This is stronger than a
   substring search (a variant, a second layout or a stale `KEYMAP` all fail) and
   is idempotent: on a repeat run there is no "old" layout to name.
3. **File first, then debconf (found on the VM).** `dpkg-reconfigure` reads
   `/etc/default/keyboard` before the debconf answers and the file wins: with the
   file still on `latam`, our preseeded `layoutcode`, `variantcode` and `xkb-keymap`
   were reset to `latam` (the verification caught it on the first real run). The
   module therefore writes the file first; the reconfigure then keeps the answers
   and words the display answers itself ("English (US) - English (intl., with
   AltGr dead keys)"), which is why they are compared with the old ones, not with
   a wanted text. The file is written once more after `localectl`, which may
   rewrite it.
4. **`/etc/vconsole.conf`.** On this Kali it is first a regular file (written by
   `localectl`, with `KEYMAP=la-latin1`) and after the first reboot a symlink to
   `default/keyboard`; both work (checked with a `latam` and back round trip).
   systemd converts the X11 layout to the console `KEYMAP` itself.
5. **Console keymap.** `setupcon --save-only` refreshes the cached keymap without
   touching the running console; the running TTY and the greeter pick the layout
   up after a reboot (the run says so). Checked after the reboot with `dumpkeys`:
   on the console, keycode 49 gives `n`/`ntilde` and keycode 30 gives
   `a`/`aacute` on the AltGr level (`us` `altgr-intl`).
6. **Model `pc105` in the COSMIC config.** eos renders an empty model; the file
   COSMIC itself seeded on the Kali VM has `model: "pc105"`, which is what the
   module writes, to avoid a spurious difference. Key repeat values already in the
   file are kept instead of eos's fixed 600/25.
7. **COSMIC may write `xkb_config` itself.** When the system layout changes
   COSMIC rewrote the user's `xkb_config` before the module reached it, so the
   compare found it identical (no change counted for it). Harmless: the content
   is the same.
8. **No Input Sources applet in the panel (orchestrator decision).** The panel
   keeps the reference layout, which has no Input Sources applet; the layout
   switcher itself still works. Verified on the VM in a live COSMIC session with
   `ydotool`: with the config `layout: "us,latam", variant: "altgr-intl,"`
   (what COSMIC Settings writes when a second layout is added), typing the key
   at keycode 39 in a focused kitty gave `;`, after Super+Space `ñ`, after
   Super+Space again `;` (`odd/evidence/keyboard-layout-switch-two-layouts.png`
   shows the layout OSD); Super+Space is COSMIC's default `InputSourceSwitch`
   shortcut. The applet can be added in COSMIC Settings > Desktop > Panel. The
   module then restored the single layout (one change, then 0).
9. **No second sudo prompt.** Every privileged step uses `run_sudo` (`sudo -n`)
   or `sudo_read`; the greeter's config is read with `sudo -n cat`.
10. **Dry-run.** Runs the same comparisons as a real run, so it reports the
    changes (the second write of `/etc/default/keyboard`, which only exists to
    undo a `localectl` rewrite, and the verification are skipped). If the
    greeter's file cannot be read without sudo it counts as different.
11. **Display answers are compared only when what they describe changed (M12b).**
    The `layout` display answer ("English (US)") is compared with the pre-run one
    only when the layout code changed; the `variant` display answer (it names the
    layout too) only when the layout or the variant code changed. A variant-only
    change within the same layout (`us` to `us:altgr-intl`, the usual case since the
    Kali installer default is `us`) therefore no longer flags the unchanged layout
    text as an installer trace.
12. **xkb-data is installed before validating (M12b).** The rules list
    (`evdev.lst`) is validated before the sudo password is asked, which would
    reject `--keyboard` on a system without `xkb-data`. A real run now defers the
    validation when the list is missing: after the one sudo prompt,
    `kbd_ask_if_needed` installs `keyboard-configuration` and `xkb-data`, then
    validates (exit 2 on a bad value, nothing applied). A dry-run cannot install,
    so it still exits 2 with the message. This keeps "ask the sudo password once".
13. **Model and console cache are verified (M12b).** The verification also needs
    `XKBMODEL="pc105"` in `/etc/default/keyboard`. A failing `setupcon --save-only`
    fails the module (error, before the initramfs), and the next run retries it
    because `/etc/default/keyboard` is then newer than the initramfs.
14. **Greeter files behind symlinks are skipped (M12b).** The greeter user owns its
    home, so root never follows a link there: when the home, `.config`, `cosmic`,
    `com.system76.CosmicComp`, `v1`, the `xkb_config` file or the backup target is a
    symlink (or the backup name exists), the login screen step is skipped with a
    warning and its verification is skipped too. Backups use
    `cp --no-dereference -p`.
15. **Messages use `id -un`, not `$USER` (M12b)**, and the menu header says the
    picked layout replaces the installer one "or keep the current one", so it does
    not contradict "Keep current".

## Hardware detection

None.

## Idempotency check

Every step compares first: the file render against the file, the five debconf
code answers, `localectl status`, the two `xkb_config` files, and the initramfs
step runs only after a change (or a stale initramfs). A second run with the same
choice, and `--keyboard keep`, report `total changes: 0` (VM evidence below).

## Revert

Restore `/etc/default/keyboard.bak.<timestamp>`, then
`sudo dpkg-reconfigure keyboard-configuration`, `sudo update-initramfs -u` and
`sudo localectl set-x11-keymap <layout> pc105 <variant>`; restore the
`xkb_config.bak.<timestamp>` of the user and of the greeter. Simpler: run
`./install.sh --only keyboard --keyboard <other layout>`.

## Verification

```bash
./install.sh --only keyboard --dry-run --keyboard us:altgr-intl
./install.sh --only keyboard --keyboard us:altgr-intl     # then again: "total changes: 0"
./install.sh --only keyboard --keyboard keep              # 0 changes
cat /etc/default/keyboard; sudo debconf-show keyboard-configuration; localectl status
cat ~/.config/cosmic/com.system76.CosmicComp/v1/xkb_config
sudo cat /var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicComp/v1/xkb_config
tests/test-keyboard.sh
```

## VM evidence (Kali VM, installer layout `latam`)

- Dry-run lists 7 changes. First real run (before decision 3): rc=1, the
  verification named `debconf keyboard-configuration/layoutcode is "latam"` and
  three more traces; after the fix: rc=0, 5 changes, `/etc/default/keyboard` and
  debconf (`layoutcode us`, `variantcode altgr-intl`, `xkb-keymap us(altgr-intl)`),
  `localectl` (`X11 Layout: us`, `X11 Variant: altgr-intl`), user and greeter
  `xkb_config` all `us` / `altgr-intl`; `latam` appears nowhere outside the
  `.bak` files (grep over /etc/default, /etc/vconsole.conf, /etc/console-setup and the debconf database).
- Second run and `--keyboard keep`: `total changes: 0`. A scripted menu run through a
  pseudo terminal (empty and `9` re-ask, `2`) changed nothing on top of the same
  choice.
- After the reboot: `keyboard-setup` and `console-setup` active, console keymap as
  above, the greeter shows `us (alt...` (`odd/evidence/keyboard-greeter.png`), no
  failed units.
- Live COSMIC session (before the reboot): AltGr+n typed `ñ`, AltGr+a typed `á`,
  the `;` key typed `;` in kitty (`odd/evidence/keyboard-live-altgr-us.png`).
  Not repeated after the reboot: starting a session needs a temporary greetd
  `initial_session`, which the automation guard refused to allow.

### M12b VM evidence

- VM on `us:altgr-intl`; `--keyboard us` rc=0 (6 changes, verification passed), then
  `--keyboard us:altgr-intl` (the variant-only change that failed before): rc=0, 6
  changes, `is the only one configured`; repeat `total changes: 0`; `--keyboard keep`
  `total changes: 0`; `systemctl --failed` empty; `localectl` us / pc105 / altgr-intl.
