# panel

## Purpose

Give the COSMIC top panel the applet layout of the reference setup
(`eos-cosmic-setup/reference/screenshots/panel-bar.png` and `panel-applets.png`):
one top panel, Workspace Icons at the start, the system applets and Lock Keys at
the end. `MODULE_OPTIN=0`, `MODULE_DEPS="applets cosmic-settings"` (the two built
applets must exist before the panel names them; cosmic-settings owns the rest of
`~/.config/cosmic`).

## Source of truth

eos `55-panel.sh`, `specs/panel.md` and `files/panel/*`, ported with the facts in
`odd/verified-facts.md` section 2 (COSMIC 1.11 default panel and applet ids).
eos copied 25 panel keys plus `entries`. Of the 23 that do not carry the layout, 19
equal the shipped COSMIC defaults (compared on the VM) and 4 (`name`,
`border_width`, `keep_style_on_maximize`, `padding_overlap`) are keys the shipped
directory does not list, with the values `"Panel"`, `0.0`, `false`, `0.5`. Only
the three keys that carry the layout are shipped here:

| Key (user file under `~/.config/cosmic`) | Value |
|------------------------------------------|-------|
| `com.system76.CosmicPanel/v1/entries` | `["Panel"]` (the Dock is not listed, so it stays off, as in eos) |
| `com.system76.CosmicPanel.Panel/v1/plugins_wings` | start: Workspace Icons (`io.github.crocodile.cosmic-ext-applet-workspace-icons`); end, in order: `CosmicAppletTime`, Lock Keys (`com.lucianosb.cosmic-ext-lock-keys`), `CosmicAppletStatusArea`, `CosmicAppletTiling`, `CosmicAppletAudio`, `CosmicAppletBluetooth`, `CosmicAppletNetwork`, `CosmicAppletBattery`, `CosmicAppletNotifications`, `CosmicAppletPower` |
| `com.system76.CosmicPanel.Panel/v1/plugins_center` | `None` |

Every system applet id exists on COSMIC 1.11 (checked on the VM:
`X-CosmicApplet` desktop entries under `/usr/share/applications`).

## Files and packages touched

- The three key files above, under `~/.config/cosmic` of the invoking user.
- No packages, no service, no restart: cosmic-panel watches the key files and
  reloads live (verified on the VM in a COSMIC session).

## Decisions on ambiguities

1. **Now Playing is dropped, the center segment is empty.** The reference center
   shows Now Playing (a third-party applet from the AUR that the plan drops, see
   specs/applets.md decision 6), so `plugins_center` is `None`. Without it the
   panel center is empty and the date stays at the end, next to the other
   status applets, as in the reference. Not `Some([])`: both mean "no center
   applets"; `None` is what the system Dock default also uses for an unused segment.
2. **Only the layout keys are managed.** The 23 other keys eos copied are the
   defaults (19 verified against `/usr/share/cosmic/com.system76.CosmicPanel.Panel/v1`
   on the VM, 4 not listed there and unverified as defaults). Writing them would
   only pin today's defaults and overwrite what the user changed in COSMIC Settings (size, opacity, autohide, position, ...), so
   they are never written. The layout keys are the module's purpose: a different
   existing value is replaced after a `.bak.<timestamp>` backup, and the next run
   changes nothing.
3. **The eos applet set, not the Kali default.** Kali's default panel also has
   Input Sources and Accessibility, and Workspaces / App Library buttons; the
   reference layout has none of them (the workspace switch is Workspace Icons).
   The reference look wins. Add Input Sources in Settings, Desktop, Panel if a
   second keyboard layout is used.
4. **No Dock.** `entries` lists only `Panel`, like eos, so `CosmicAppList` (the
   dock favourites kept by the cosmic-settings module) does not show. Delete the
   `entries` file to get the default panel and dock back.
5. **Missing built applets only warn.** If the desktop entry of Workspace Icons or
   Lock Keys is not in the user, `/usr/local` or `/usr` data directories (the
   applets module skipped or failed), the layout is still written and the run
   warns; the panel shows a gap until the applet is installed.
6. **Ownership guard.** The keys go through `install_file`, so a file or
   directory owned by someone else is skipped with a warning (never written
   through sudo) and a symlink is followed only into `$HOME`.

7. **The layout replaces an existing one (final decision).** BRIEF targets a
   fresh system and the definition of done requires the reference layout, so an
   existing `entries` and `plugins_wings` / `plugins_center` are replaced after a
   `<key>.bak.<timestamp>` backup, and the Dock is dropped. A user who customised
   the panel and does not want this must not run the module (`--skip panel`) or
   restore the `.bak` files; the opt-out is "restore the .bak" (see Revert). Review
   finding W4 of the M7b+M8b+M9 review was settled this way, not by merging.

## Hardware detection

None. `output: All` is the shipped default, so no output name is needed.

## Idempotency check

Each key is installed only when its bytes differ. A second run reports
`total changes: 0`. Dry-run lists the keys that would change and writes nothing.

## Revert

Restore the `<key>.bak.<timestamp>` files next to the three keys, or delete the
three key files to fall back to the COSMIC default panel and dock. Changes apply
live.

## Verification

```bash
./install.sh --only panel --dry-run      # nothing written
./install.sh --only panel                # then again: "total changes: 0"
# in the COSMIC session: Settings, Desktop, Panel, Applets lists the applets of
# panel-applets.png (without Now Playing); grim shows the bar of panel-bar.png
tests/test-panel.sh
```
