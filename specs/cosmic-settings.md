# cosmic-settings

## Purpose

Apply the COSMIC desktop settings of the reference machine (tiling, theme and
icons, screenshot shortcut, idle, screenshots, Files, Terminal, clock and audio
applets) by installing individual cosmic-config key files into the invoking
user's `~/.config/cosmic`, without touching any key that is not shipped.

## Source of truth

The EndeavourOS module (`eos-cosmic-setup`, `modules/20-cosmic-settings.sh`,
`specs/cosmic-settings.md`, `files/cosmic/`). cosmic-config stores one file per
key, `~/.config/cosmic/<component>/v<N>/<key>`, each holding one RON value.
`files/cosmic/<component>/v<N>/<key>` is a byte-exact copy of the eos files,
except for the shortcuts file (see below). Each key was checked against COSMIC
1.11.0-1.build198 on the Kali test VM (`odd/verified-facts.md` section 1).

| Component (version) | Keys shipped and value |
|---------------------|------------------------|
| `com.system76.CosmicComp` (v1) | `autotile` true; `autotile_behavior` PerWorkspace; `active_hint` true; `appearance_settings` (clip floating and tiled windows, shadow on tiled); `input_default` (pointer acceleration speed ~0.6, kept as a preference). `xkb_config` is NOT shipped |
| `com.system76.CosmicSettings.Shortcuts` (v1) | `custom`: Super+Shift+S runs `cosmic-screenshot` (merged, see below) |
| `com.system76.CosmicTk` (v1) | `header_size` Compact; `interface_density` Compact; `icon_theme` "Papirus-Dark" |
| `com.system76.CosmicTheme.Mode` (v1) | `is_dark` true (seed-only) |
| `com.system76.CosmicTheme.Dark.Builder` and `.Light.Builder` (v2) | builder keys: accent `#6E22A8` (seed-only), frosted ExtremelyLow, gaps (0, 8), corner radii, spacing, palette, alpha map, tints |
| `com.system76.CosmicTheme.Dark` and `.Light` (v2) | derived theme keys; `accent` and `accent_button` are seed-only |
| `com.system76.CosmicIdle` (v1) | `screen_off_time` None; `suspend_on_ac_time` None (idle actions disabled) |
| `com.system76.CosmicPortal` (v1) | `screenshot`: save to Clipboard, choice Rectangle (seed-only) |
| `com.system76.CosmicAppletTime` (v1) | `first_day_of_week` 6; `military_time` false |
| `com.system76.CosmicAppletAudio` (v1) | `show_media_controls_in_top_panel` false |
| `com.system76.CosmicTerm` (v1) | `show_headerbar` false |
| `com.system76.CosmicFiles` (v1) | `context_actions` (PeaZip entries), `desktop`, `dialog`, `show_details`, `tab` |
| `com.system76.CosmicAppList` (v1) | `enable_drag_source` true; `favorites` []; `filter_top_levels` None |

## Verification against COSMIC 1.11 (decision record)

- Versions: `/usr/share/cosmic` ships v2 for the themes (v1 is the legacy float
  format) and v1 for everything else; a live session on the VM created only v1
  directories for the non-theme components and v1+v2 for Theme.Dark and
  Theme.Dark.Builder. So the shipped versions match; no key needed a version bump.
- Every key name and every struct field in the shipped values (for example
  `clip_floating_windows`, `show_mounted_drives`, `steps`, `last_rectangle`)
  exists as a string in the 1.11 binaries (`cosmic-*`, `xdg-desktop-portal-cosmic`);
  checked by script, none missing. `frosted_maximized_apps` and `list_button`
  are absent from the shipped v2 defaults but present in the binaries, so they
  are kept.
- Live: in a running COSMIC session on the VM the keys read back, windows tile
  automatically, the accent and dark theme apply, folder icons are Papirus, the
  clock is 12 hour, and a second run reports `total changes: 0` (COSMIC does not
  rewrite the shipped keys). Screenshot: `odd/evidence/cosmic-settings.png`.

## Ambiguity decisions

1. **Alt+S (aura) is not shipped.** The eos `custom` file also bound Alt+S to
   `aura switcher`; on Kali aura is an opt-in module, so that entry moves there.
2. **Shortcut ownership.** `custom` is one RON map shared by every module and
   by the user. This module owns exactly one entry: Super+Shift+S bound to
   `Spawn("cosmic-screenshot")`. If the file is missing or an empty map it is
   created from the seed (`files/cosmic/.../custom`); if it holds other entries
   (aura's Alt+S, the user's own) the entry is added inside the existing map
   after a `.bak.<timestamp>` backup; if Super+Shift+S is already bound (to
   anything, in either modifier order) the file is left alone, because a
   duplicate key would make the map invalid; an unrecognisable file is left
   alone with a warning. The map is read by a small awk reader: `//` comments
   and strings are skipped (a commented-out binding is not a binding), fields
   may come in any order and the modifiers in either order, a last entry
   without a trailing comma gets one (before its trailing comment) prior to
   appending, and any shape the reader does not understand (block comment,
   unbalanced brackets, an entry without `key`, a missing comma between
   entries) leaves the file untouched with a warning. The module never removes or edits entries it does not
   own. The reader and merger are one function, `cosmic_shortcut_ensure` in
   `lib/common.sh`, shared with the aura module (specs/aura.md decision 3), which
   adds its Alt+S entry the same way: either order of the two modules works and
   neither clobbers the other. A key combination already bound to something else
   is left alone with a warning.
3. **No keyboard.** The `xkb_config` generation (and the login-screen copy) is
   not part of this module; the keyboard module owns it. This module never
   writes `xkb_config`.
4. **Dark mode and accent without aura.** eos let Aura own both (`auto_theme`,
   `auto_dark`). On Kali aura is opt-in and usually absent, so something must
   set them or the machine would look like stock COSMIC. The module seeds them
   once (dark mode on, purple `#6E22A8` accent) only when the files are missing,
   i.e. the reference look on a new machine; they are never rewritten after that.
   So the user changing them in Settings, and aura, when enabled later, both
   win, and the dry-run still reaches "Nothing to change". Same mechanism as eos
   (seed-only); only the reason differs.
5. **`system_actions` is not written.** COSMIC 1.11 ships the full map
   (`/usr/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions`)
   and it is not verifiable that cosmic-settings merges a partial user map (the
   key is a whole RON map). A partial map could drop the screenshot, volume and
   brightness actions; a full copy would freeze them at 1.11. So the terminal
   action (`Terminal: "kitty"`) is left to the kitty module, which can write the
   full map with only that change, and only when kitty exists.
6. **Stale keys.** eos files under `CosmicTheme.*/v1` (legacy format) are not
   shipped. No font keys, no `CosmicFiles/v1/favorites` (personal path), no
   `input_devices` (hardware specific).
7. **User scope.** The installer refuses to run as root, so `$HOME` is the
   invoking user's home; nothing is written to root's home or outside
   `~/.config/cosmic`. The shared guard `user_path_writable` (lib/common.sh,
   used by every helper that writes a file) skips a key whose file, or any
   existing directory between it and `$HOME`, is not owned by the invoking user
   (for example left by an earlier `sudo` run): one warning per path, never a
   write through sudo into the user's config. A symlinked key file is written
   through the link when its target is inside `$HOME`, otherwise skipped (the
   link is never replaced by a regular file).

## Files and packages touched

- Every file under `files/cosmic/` (except the shortcuts seed) is installed to
  `$HOME/.config/cosmic/<same relative path>` with mode 0644 via `install_file`
  (backup `<key>.bak.<timestamp>` when it replaces a different file). Seed-only
  keys are skipped when the file exists.
- `$HOME/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`: merged.
- Package: `papirus-icon-theme` (Kali, needed for `Papirus-Dark`).
- No services. cosmic-config watches the files, so changes apply live; no
  process is restarted.

## Hardware detection

none

## Idempotency check

Each key file is compared byte by byte; seed-only keys are skipped when
present; the shortcuts file is left alone once it holds the Super+Shift+S
binding. A second run reports `total changes: 0` (also after a live session).

## Revert

- Restore a key from its `<key>.bak.<timestamp>` file, or delete the key file
  under `~/.config/cosmic/` to fall back to the COSMIC default for that key.
  The `.bak` files sit next to the keys inside the watched v1 directories
  (cosmic-config ignores them); delete them after restoring.
- Remove the Super+Shift+S entry from the `custom` shortcuts file (or restore its backup).
- `sudo apt-get purge papirus-icon-theme` to remove the icon theme.

## Verification

- `./install.sh --only cosmic-settings --dry-run` reports nothing to change
  after a real run; a second real run reports `total changes: 0`.
- `bat ~/.config/cosmic/com.system76.CosmicTk/v1/icon_theme` prints `"Papirus-Dark"`.
- `rg '/home/' files/cosmic` prints nothing; no `xkb_config` or `system_actions`
  file exists under `files/cosmic`.
- `tests/test-cosmic-settings.sh` (temporary HOME, fake apt): install, backups,
  seed-only, shortcut merge in both orders, user binding respected, empty and
  malformed files, no keyboard code.
