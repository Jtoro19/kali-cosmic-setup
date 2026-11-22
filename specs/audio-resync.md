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

- `~/.local/bin/cosmic-audio-resync` (0755): exits at once unless
  `XDG_CURRENT_DESKTOP` contains `COSMIC`; waits `RESYNC_DELAY` seconds (default
  5); polls (bounded, `RESYNC_WAIT` ticks of `RESYNC_TICK` seconds, default 30 x 1 s)
  until `cosmic-settings-daemon` and `cosmic-panel` run; kills the daemon and
  waits `RESYNC_RESPAWN` ticks (default 5) for the session to respawn it, and
  starts it with `setsid` only when none came (see decision 5); then kills
  `cosmic-panel` and checks it respawned within the same bound, logging when it
  did not (the session respawns the panel together with its applets; killing
  only the sound applet does not bring it back). Never fails the login: it
  always exits 0.
- `~/.config/autostart/cosmic-audio-resync.desktop`, rendered from
  `files/audio-resync/cosmic-audio-resync.desktop.in` (`@HOME@`), with
  `OnlyShowIn=COSMIC;` so no other desktop runs it.
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
4. **COSMIC only.** The entry has `OnlyShowIn=COSMIC;` and the script exits
   unless `XDG_CURRENT_DESKTOP` contains `COSMIC`. Checked on the VM:
   `systemd-xdg-autostart-generator` turns `OnlyShowIn` into
   `ExecCondition=systemd-xdg-autostart-condition "COSMIC" ""`, which succeeds
   with `XDG_CURRENT_DESKTOP=COSMIC` and fails with `GNOME`.
5. **Wait, do not assume (M10b review W2).** The script polls (bounded) for the
   daemon and the panel before killing anything, and checks the respawns.
   Evidence on the Kali VM (COSMIC 1.11.0): `cosmic-session` journals
   "restarted process ... cosmic-panel" after the panel is killed, but it does
   **not** respawn `cosmic-settings-daemon` (after `pkill` nothing came back in
   20 s; `cosmic-osd` then logged "failed to connect to cosmic-settings's
   varlink service"). So the daemon is started by hand only when no respawn
   came within `RESYNC_RESPAWN` ticks, which leaves a session that does
   supervise it alone, and the script never leaves the desktop without a
   daemon. A daemon that never started (login failure) is not started either:
   the script logs and exits.
6. **Possible upstream fix.** The bug may be fixed in a later COSMIC; remove the
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

If a legacy hand-made version was migrated, also restore the backed-up
`~/.local/bin/fix-cosmic-audio.sh.bak.<timestamp>` and
`~/.config/autostart/fix-cosmic-audio.desktop.bak.<timestamp>` (rename them back
without the `.bak.<timestamp>` suffix).

## Verification

```bash
./install.sh --only audio-resync --dry-run
./install.sh --only audio-resync          # then again: "total changes: 0"
RESYNC_DELAY=0 ~/.local/bin/cosmic-audio-resync   # in a COSMIC session
pgrep -x cosmic-panel                     # the panel is back a few seconds later
tests/test-audio-resync.sh   # includes an execution test with fake pgrep/pkill/setsid
```
