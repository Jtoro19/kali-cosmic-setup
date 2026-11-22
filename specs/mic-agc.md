# mic-agc

## Purpose

Stop browsers and Electron apps from moving the system microphone volume with
their WebRTC automatic gain control, so the microphone stays at the level set
in the COSMIC sound applet. `MODULE_OPTIN=0`, no dependencies.

## Source of truth

eos `83-mic-agc.sh`, `specs/mic-agc.md` and `files/mic-agc/20-block-mic-agc.conf`,
ported as is (plan decision: PipeWire 1.6.9 on Kali supports `pulse.rules`
quirks). The regex differs from eos for the apps of this setup (decision 1).

## Files and packages touched

- `~/.config/pipewire/pipewire-pulse.conf.d/20-block-mic-agc.conf` (0644): a
  `pulse.rules` entry that applies the quirk `block-source-volume` to clients
  whose `application.process.binary` matches
  `~^(chromium|brave|firefox|firefox-esr|code|electron)$`.
- Migration: an earlier hand-made `99-block-mic-agc.conf` in the same directory
  is backed up (`.bak.<timestamp>`, ignored by PipeWire because it does not end
  in `.conf`) and removed, so one rule file remains.
- When the rule changed and a user `pipewire-pulse.service` is running:
  `systemctl --user restart pipewire-pulse`. Otherwise (fresh install before
  the first login, SSH without a user manager) the rule applies at next login.
- No packages.

## Decisions on ambiguities

1. **The app list.** The Kali setup installs Firefox ESR (`firefox-esr`, the
   binary name of Kali's Firefox), Chromium, Brave and VS Code (`code`). The
   rule matches those plus the generic `firefox` (Firefox from other sources)
   and `electron`. Dropped from the eos list, because none of them is part of
   this setup: `chrome`, `vivaldi`, `librewolf`, `Discord`, `discord` (Vesktop
   and Discord are not installed, plan), `zoom`, `teams-for-linux`, `slack`.
   The regex is anchored, so `firefox-esr-x` or `pactl` do not match. Add an app
   by its binary name (see the comment in the file).
2. **User level.** Like eos: a user `pipewire-pulse.conf.d` fragment, no root,
   no system file. The ownership guard (`user_path_writable`) covers the rule
   and the legacy file: a file owned by someone else, or a symlinked directory
   pointing outside `$HOME`, is skipped with a warning and nothing restarts.
3. **Restart only `pipewire-pulse`.** eos restarts `pipewire`, `pipewire-pulse`
   and `wireplumber`. `pulse.rules` is read only by pipewire-pulse, so the port
   restarts just that service: it reconnects the PulseAudio-protocol apps and
   leaves the graph and the COSMIC sound applet's device list alone (the
   audio-resync workaround is not needed after it). Verified on the Kali VM
   (COSMIC 1.11.0, M10b review W3), in a live session: `cosmic-settings-daemon`
   is a native PipeWire client (listed by `wpctl status`), not a PulseAudio one;
   after `systemctl --user restart pipewire-pulse` it stayed connected, and the
   volume-up key (handled by the daemon) still moved the default sink from 50%
   to 55% with the COSMIC volume OSD showing 55%
   (`odd/evidence/audio-resync-w3-volume-key-after-pulse-restart.png`).
   Not observed: the sound applet popup itself (pointer clicks through ydotool
   did not reach the panel on this VM); the daemon, the keys and the OSD were. The check uses
   `user_systemd_ready`, so it also works over SSH (`XDG_RUNTIME_DIR` is set to
   `/run/user/<uid>`); a missing user manager means "applies at next login".
4. **Property to match.** `application.process.binary`, as in eos. It is what
   libpulse and pipewire-pulse record for the client executable, which is
   stable across Firefox and Chromium versions, unlike `application.name`.

## Hardware detection

None. The COSMIC sound applet, `pavucontrol`, `wpctl` and any app outside the
regex still set the volume.

## Idempotency check

`install_file` compares bytes; the migration only acts when the legacy file
exists; the restart only follows a changed file. A second run reports
`total changes: 0` and restarts nothing.

## Revert

```bash
rm ~/.config/pipewire/pipewire-pulse.conf.d/20-block-mic-agc.conf
systemctl --user restart pipewire-pulse
```

## Verification

```bash
./install.sh --only mic-agc --dry-run
./install.sh --only mic-agc               # then again: "total changes: 0"
# the rule is active: a client that looks like Firefox ESR cannot set the source volume
env 'PULSE_PROP_application.process.binary=firefox-esr' pactl set-source-volume @DEFAULT_SOURCE@ 25%   # Failure: Access denied
env 'PULSE_PROP_application.process.binary=other-app'   pactl set-source-volume @DEFAULT_SOURCE@ 25%   # works
wpctl get-volume @DEFAULT_AUDIO_SOURCE@
tests/test-mic-agc.sh
```
