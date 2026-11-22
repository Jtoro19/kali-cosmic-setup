#!/usr/bin/env bash
# modules/40-kitty.sh: kitty terminal config, COSMIC accent sync (theme version
# 2), the clear alias in the rc file of the login shell, and kitty as the COSMIC
# default terminal. See specs/kitty.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="kitty"
# shellcheck disable=SC2034
MODULE_DESC="kitty terminal: frosted config, COSMIC accent colors, clear alias, default terminal"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

_KITTY_ACTIONS_DEFAULT="/usr/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions"

# _kitty_files: the config, the color script and the two user units. Sets
# _KITTY_CHANGED when the script or a unit changed (they need a reload and a run).
_kitty_files() {
  local src="$REPO_ROOT/files/kitty" unit_dir="$HOME/.config/systemd/user" f
  _KITTY_CHANGED=0
  install_file "$src/kitty.conf" "$HOME/.config/kitty/kitty.conf" 0644 || return 1
  install_file "$src/kitty-cosmic-colors.sh" "$HOME/.local/bin/kitty-cosmic-colors.sh" 0755 || return 1
  ((FILE_CHANGED)) && _KITTY_CHANGED=1
  for f in kitty-cosmic-colors.service kitty-cosmic-colors.path; do
    install_file "$src/$f" "$unit_dir/$f" 0644 || return 1
    ((FILE_CHANGED)) && _KITTY_CHANGED=1
  done
  return 0
}

# _kitty_colors_units: reload, enable the path unit and generate the colors file
# when something changed (or the generated file is missing).
_kitty_colors_units() {
  local bin="$HOME/.local/bin/kitty-cosmic-colors.sh" out="$HOME/.config/kitty/cosmic-colors.conf" name=kitty-cosmic-colors.path
  if user_systemd_ready; then
    if ((_KITTY_CHANGED)); then
      run systemctl --user daemon-reload
    fi
    if ! user_unit_enabled "$name"; then
      log_change "enable user unit: $name"
      run systemctl --user enable --now "$name"
    fi
  else
    log_warn "no systemd user manager is reachable (no login session for $USER here): the colour-sync units are installed but not enabled; after you log in to COSMIC run: systemctl --user enable --now $name"
  fi
  if ((_KITTY_CHANGED)) || [[ ! -e "$out" ]]; then
    user_path_writable "$out" || return 0
    # Generates cosmic-colors.conf from the accent; exits 0 when there is no theme.
    run "$bin"
  fi
}

# _kitty_default_terminal: COSMIC runs the `Terminal` action of the system_actions
# map (Super+T). In COSMIC 1.11 that key is the WHOLE map (a user value replaces
# the shipped one), so the shipped map is copied with only the Terminal command
# changed, never a one-entry map. An existing user map keeps all its entries; its
# Terminal command is switched only when it is still the shipped cosmic-term.
_kitty_default_terminal() {
  local dest="$HOME/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions"
  local default tmp re='^([[:space:]]*Terminal:[[:space:]]*)"[^"]*"'
  default="$(rootpath "$_KITTY_ACTIONS_DEFAULT")"
  user_path_writable "$dest" || return 0
  if [[ ! -e "$dest" ]]; then
    if [[ ! -f "$default" ]] || ! grep -Eq "$re" "$default"; then
      log_warn "$default has no Terminal entry: not writing system_actions (set the default terminal in COSMIC Settings, Super+T runs the Terminal action)"
      return 0
    fi
    tmp="$(mktemp)"
    sed -E "s/$re/\\1\"kitty\"/" "$default" >"$tmp"
    install_file "$tmp" "$dest" 0644
    rm -f -- "$tmp"
    return 0
  fi
  if grep -Eq '^[[:space:]]*Terminal:[[:space:]]*"kitty"' "$dest"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*Terminal:[[:space:]]*"cosmic-term"' "$dest"; then
    tmp="$(mktemp)"
    sed -E "s/$re/\\1\"kitty\"/" "$dest" >"$tmp"
    install_file "$tmp" "$dest" 0644
    rm -f -- "$tmp"
    return 0
  fi
  log_warn "$dest sets another Terminal command (or none): leaving it; edit it by hand to use kitty with Super+T"
}

# _kitty_shell_block: the clear alias, in the rc file of the login shell.
_kitty_shell_block() {
  local rc alias_line legacy_comment
  rc="$(login_rc_file)" || return 0
  alias_line='alias clear='\''printf "\e[H\e[2J\e[3J"'\'''
  # Legacy Spanish comment that older setups left above the alias (match only).
  legacy_comment='# clear que también borra el historial de scroll'
  remove_line "$rc" "$alias_line" "$legacy_comment"
  ensure_block "$rc" kitty-clear "$alias_line"
}

# _kitty_mimeapps: kitty.desktop as the default terminal handler (cosmic-settings
# and cosmic-files read ~/.config/cosmic-mimeapps.list). A new file is written
# in one step (no backup of a file this run just created); an existing one is
# edited key by key and another handler the user chose is kept.
_kitty_mimeapps() {
  local f="$HOME/.config/cosmic-mimeapps.list"
  if [[ ! -e "$f" ]]; then
    ensure_file_content "$f" "[Default Applications]
x-scheme-handler/terminal=kitty.desktop
application/x-terminal-emulator=kitty.desktop"
    return
  fi
  ensure_ini_line "$f" "Default Applications" "x-scheme-handler/terminal=kitty.desktop"
  ensure_ini_line "$f" "Default Applications" "application/x-terminal-emulator=kitty.desktop"
}

module_apply() {
  ensure_packages kitty || return 1
  _kitty_files || return 1
  _kitty_colors_units || return 1
  _kitty_shell_block || return 1
  _kitty_default_terminal || return 1
  _kitty_mimeapps
}
