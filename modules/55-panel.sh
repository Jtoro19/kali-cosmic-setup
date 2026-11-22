#!/usr/bin/env bash
# modules/55-panel.sh: the COSMIC top panel layout (applet order) of the
# reference setup, as three cosmic-config keys. See specs/panel.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="panel"
# shellcheck disable=SC2034
MODULE_DESC="COSMIC panel: single top panel with the reference applet order (Workspace Icons, Lock Keys, system applets)"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS="applets cosmic-settings"

# The built applets the layout references (ids of modules/50-applets.sh).
_PANEL_COMMUNITY_APPLETS=(
  "io.github.crocodile.cosmic-ext-applet-workspace-icons"
  "com.lucianosb.cosmic-ext-lock-keys"
)

# _panel_warn_missing_applets: the layout names two applets this setup builds; if
# their desktop entry is missing (the applets module skipped or failed) the panel
# would show a gap, so say so. Only a warning: the layout is still written.
_panel_warn_missing_applets() {
  local id dir found
  local -a dirs=(
    "${XDG_DATA_HOME:-$HOME/.local/share}"
    "$(rootpath /usr/local/share)"
    "$(rootpath /usr/share)"
  )
  for id in "${_PANEL_COMMUNITY_APPLETS[@]}"; do
    found=0
    for dir in "${dirs[@]}"; do
      [[ -f "$dir/applications/$id.desktop" ]] && found=1
    done
    if ((found == 0)); then
      log_warn "applet $id is in the panel layout but its desktop entry is not installed (did the applets module skip it?): the panel will show a gap until it is"
    fi
  done
}

# module_apply: only the layout keys are managed (entries, plugins_wings,
# plugins_center). Every other key of the panel (size, opacity, autohide, ...)
# is the user's and is never written. cosmic-panel watches the key files and
# reloads live, so nothing is restarted.
module_apply() {
  local src="$REPO_ROOT/files/panel"
  local dest="$HOME/.config/cosmic"
  local rel

  while IFS= read -r rel; do
    install_file "$src/$rel" "$dest/$rel" 0644 || return 1
  done < <(cd "$src" && find . -type f -printf '%P\n' | sort)
  _panel_warn_missing_applets
}
