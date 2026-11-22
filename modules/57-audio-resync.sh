#!/usr/bin/env bash
# modules/57-audio-resync.sh: resync the COSMIC sound applet with PipeWire at login.
# See specs/audio-resync.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="audio-resync"
# shellcheck disable=SC2034
MODULE_DESC="COSMIC sound applet: restart cosmic-settings-daemon at login so it sees the audio devices"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Hand-made versions of the same workaround.
_RESYNC_LEGACY_SCRIPT=".local/bin/fix-cosmic-audio.sh"
_RESYNC_LEGACY_DESKTOP=".config/autostart/fix-cosmic-audio.desktop"

module_apply() {
  local src="$REPO_ROOT/files/audio-resync"
  local script="$HOME/.local/bin/cosmic-audio-resync"
  local desktop="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/cosmic-audio-resync.desktop"
  local f

  # Migration: one start mechanism only. A file someone else owns is never
  # touched (user_path_writable warns and says no).
  for f in "$HOME/$_RESYNC_LEGACY_DESKTOP" "$HOME/$_RESYNC_LEGACY_SCRIPT"; do
    if [[ -e "$f" ]] && user_path_writable "$f"; then
      log_change "remove legacy file $f (replaced by cosmic-audio-resync)"
      backup_file "$f"
      run rm -f -- "$f"
    fi
  done

  # install_file and install_template run the same ownership and symlink guard.
  install_file "$src/cosmic-audio-resync" "$script" 0755 || return 1
  install_template "$src/cosmic-audio-resync.desktop.in" "$desktop" 0644 || return 1
  return 0
}
