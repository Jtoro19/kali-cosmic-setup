#!/usr/bin/env bash
# modules/20-cosmic-settings.sh: COSMIC desktop settings written as
# cosmic-config key files into the invoking user's ~/.config/cosmic (see
# specs/cosmic-settings.md).

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="cosmic-settings"
# shellcheck disable=SC2034
MODULE_DESC="COSMIC settings: tiling, theme and icons (Papirus-Dark), screenshot shortcut, idle, Files, Terminal, panel applets"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# The shortcuts file is merged, not copied (see _cosmic_settings_shortcuts).
_COSMIC_SHORTCUTS="com.system76.CosmicSettings.Shortcuts/v1/custom"

# Keys that are seeded only when missing. The portal rewrites the screenshot
# state after every screenshot. Dark mode and the accent color belong to the
# user (Settings) and, when the opt-in aura module is used, to aura: the
# module gives a new machine the reference look once and never fights later.
_COSMIC_SEED_ONLY=(
  "com.system76.CosmicPortal/v1/screenshot"
  "com.system76.CosmicTheme.Dark.Builder/v2/accent"
  "com.system76.CosmicTheme.Dark/v2/accent"
  "com.system76.CosmicTheme.Dark/v2/accent_button"
  "com.system76.CosmicTheme.Light.Builder/v2/accent"
  "com.system76.CosmicTheme.Light/v2/accent"
  "com.system76.CosmicTheme.Light/v2/accent_button"
  "com.system76.CosmicTheme.Mode/v1/is_dark"
)

# _cosmic_settings_shortcuts: this module owns one entry of the shared `custom`
# map, Super+Shift+S for cosmic-screenshot; the merge rule (own entry only, other
# entries and user bindings never touched) is cosmic_shortcut_ensure in
# lib/common.sh, shared with the aura module's Alt+S entry.
_cosmic_settings_shortcuts() {
  cosmic_shortcut_ensure "Super,Shift" s cosmic-screenshot 'Spawn("cosmic-screenshot")'
}

module_apply() {
  local src="$REPO_ROOT/files/cosmic" dst="$HOME/.config/cosmic" rel dest
  local -a files=()

  # Papirus-Dark (CosmicTk icon_theme) needs this package.
  ensure_packages papirus-icon-theme || return 1

  # cosmic-config stores one file per key and watches the files, so every
  # shipped key is installed on its own and applies live (no restart). Keys
  # that are not shipped are never touched.
  while IFS= read -r -d '' rel; do
    files+=("${rel#"$src"/}")
  done < <(find "$src" -type f -print0 | sort -z)

  for rel in "${files[@]}"; do
    [[ "$rel" == "$_COSMIC_SHORTCUTS" ]] && continue
    dest="$dst/$rel"
    user_path_writable "$dest" || continue
    if [[ " ${_COSMIC_SEED_ONLY[*]} " == *" $rel "* && -e "$dest" ]]; then
      continue
    fi
    install_file "$src/$rel" "$dest" 0644 || return 1
  done

  _cosmic_settings_shortcuts || return 1
}
