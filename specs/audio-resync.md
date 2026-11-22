# audio-resync

## Purpose

Work around a COSMIC bug where the panel sound applet and Settings > Sound show
"No device selected" with an empty device list, so their volume sliders do
nothing, while PipeWire, `wpctl` and `pavucontrol` keep working. Upstream:
pop-os/cosmic-settings-daemon#193 (the daemon does not pick up the PipeWire
devices until it is restarted). `MODULE_OPTIN=0`, no dependencies.

## Source of truth

eos `57-audio-resync.sh`, `specs/audio-resync.md` and `files/audio-resync/*`,
ported as is (plan decision). The Comment of the autostart entry names this
repository. Facts: PipeWire 1.6.9 on the Kali VM, COSMIC 1.11.0
(`odd/verified-facts.md`).

## Files and packages touched

- `~/.local/bin/cosmic-audio-resync` (0755): waits `RESYNC_DELAY` seconds
  (default 5), kills `cosmic-settings-daemon`, starts it again with `setsid`
  only when the session did not respawn it, then kills `cosmic-panel` (the
  session respawns the panel together with its applets; killing only the
  sound applet does not bring it back).
- `~/.config/autostart/cosmic-audio-resync.desktop`, rendered from
  `files/audio-resync/cosmic-audio-resync.desktop.in` (`@HOME@`).
- Migration: `~/.local/bin/fix-cosmic-audio.sh` and
  `~/.config/autostart/fix-cosmic-audio.desktop` (hand-made versions of the
  same workaround) are backed up (`.bak.<timestamp>`) and removed.
- No packages (`pkill`, `pgrep` and `setsid` come from procps and util-linux,
  always present on Kali).

## Decisions on ambiguities

1. **XDG autostart, not a systemd user unit.** The plan suggested handling this
   like the clipboard module (a user unit). The reference deliberately uses an
   autostart entry: the script restarts a session daemon and the panel, which
   need the full session environment, and a oneshot unit would take its
   children down with its cgroup. On Kali the entry is turned into the
   transient service `app-cosmic-audio-resync@autostart.service` by
   `systemd-xdg-autostart-generator` when `xdg-desktop-autostart.target` is
   reached (cosmic-session starts it, see the VM evidence in
   `odd/tasks/remaining-modules.md`). The module therefore enables and starts
   nothing, and never restarts the running daemon or the panel itself during an
   install: the resync happens at the next login (or by hand).
2. **Ownership guard.** Every write and every legacy removal goes through the
   shared `user_path_writable` guard: a file owned by someone else, or a path
   that is (or lies below) a symlink pointing outside `$HOME`, is skipped with a
   warning, never written through sudo, never removed.
3. **Legacy cleanup kept** (harmless) even though a fresh Kali install never had
   the hand-made files.
4. **Possible upstream fix.** The bug may be fixed in a later COSMIC; remove the
   module then (see Revert).

## Hardware detection

None. The script exits without doing anything when `cosmic-settings-daemon` is
not installed.

## Idempotency check

`install_file` and `install_template` compare bytes; the migration acts only
when the legacy files exist. A second run reports `total changes: 0`.

## Revert

```bash
rm ~/.local/bin/cosmic-audio-resync ~/.config/autostart/cosmic-audio-resync.desktop
```

(restore `.bak.<timestamp>` files if a legacy file was migrated).

## Verification

```bash
./install.sh --only audio-resync --dry-run
./install.sh --only audio-resync          # then again: "total changes: 0"
RESYNC_DELAY=0 ~/.local/bin/cosmic-audio-resync   # in a COSMIC session
pgrep -x cosmic-panel                     # the panel is back a few seconds later
tests/test-audio-resync.sh
```
