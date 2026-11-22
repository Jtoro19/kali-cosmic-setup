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

# _cosmic_settings_shortcuts: the `custom` key is one RON map shared by every
# module and by the user. This module owns only its own entry (Super+Shift+S,
# cosmic-screenshot): it creates the file when missing or empty, adds its entry
# to an existing map, and leaves the file alone when that key combination is
# already bound (to cosmic-screenshot or to anything else: a duplicate key
# would make the map invalid). Entries of other modules (aura's Alt+S) and of
# the user are never removed or changed.
_cosmic_settings_shortcuts() {
  local base="$REPO_ROOT/files/cosmic/$_COSMIC_SHORTCUTS" dest="$HOME/.config/cosmic/$_COSMIC_SHORTCUTS"
  local content trimmed body tmp rc=0
  local ws='[[:space:]]*'
  local re="modifiers:$ws\\[$ws(Super,${ws}Shift|Shift,${ws}Super),?$ws\\],${ws}key:${ws}\"[sS]\""

  content=""
  [[ -f "$dest" ]] && content="$(cat -- "$dest")"
  trimmed="${content//[[:space:]]/}"
  if [[ -z "$trimmed" || "$trimmed" == "{}" ]]; then
    install_file "$base" "$dest" 0644
    return
  fi
  if [[ "$content" =~ $re ]]; then
    if [[ "$content" != *'Spawn("cosmic-screenshot")'* ]]; then
      log_info "Super+Shift+S is already bound to something else in $dest: leaving it alone"
    fi
    return 0
  fi
  if [[ "${trimmed:0:1}" != "{" || "${trimmed: -1}" != "}" ]]; then
    log_warn "$dest is not a recognisable shortcut map: not adding the Super+Shift+S screenshot shortcut"
    return 0
  fi

  # The entries of the seed are the lines between its braces.
  body="$(sed '1d;$d' "$base")"
  content="${content%"${content##*[![:space:]]}"}"
  content="${content%\}}"
  content="${content%"${content##*[![:space:]]}"}"
  tmp="$(mktemp)"
  printf '%s\n%s\n}\n' "$content" "$body" >"$tmp"
  install_file "$tmp" "$dest" 0644 || rc=$?
  rm -f -- "$tmp"
  return "$rc"
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
    if [[ " ${_COSMIC_SEED_ONLY[*]} " == *" $rel "* && -e "$dest" ]]; then
      continue
    fi
    install_file "$src/$rel" "$dest" 0644 || return 1
  done

  _cosmic_settings_shortcuts || return 1
}
