#!/usr/bin/env bash
# modules/25-dark-mode.sh: dark mode for GTK3/GTK4 and Qt5/Qt6 apps (see
# specs/dark-mode.md). COSMIC's own dark mode belongs to the cosmic-settings module.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="dark-mode"
# shellcheck disable=SC2034
MODULE_DESC="Dark mode for GTK3/4 (adw-gtk3-dark, prefer-dark) and Qt5/6 (qt5ct, qt6ct) apps"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS="cosmic-settings"

_DARK_GTK_PACKAGE="adw-gtk3-kali"
_DARK_GTK_THEME="adw-gtk3-dark"

# _dark_mode_gtk: GTK3, GTK4 and libadwaita through GSettings plus the settings
# files that GTK reads when GSettings is not available to an app.
_dark_mode_gtk() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" ini theme="$_DARK_GTK_THEME"

  ensure_packages "$_DARK_GTK_PACKAGE" || return 1
  # The package ships the theme (verified). In a dry run it may not be installed
  # yet, so the directory is checked only for a real run.
  if [[ "$DRY_RUN" != "1" && ! -d "$(rootpath "/usr/share/themes/$theme")" ]]; then
    log_warn "theme $theme not found after installing $_DARK_GTK_PACKAGE: setting only the dark preference"
    theme=""
  fi

  [[ -z "$theme" ]] || ensure_gsetting org.gnome.desktop.interface gtk-theme "'$theme'"
  ensure_gsetting org.gnome.desktop.interface color-scheme "'prefer-dark'"

  # GTK3 apps that do not read GSettings (X11 apps with no XSETTINGS daemon, as
  # on COSMIC, or apps that bundle their own GTK) fall back to settings.ini.
  ini="$cfg/gtk-3.0/settings.ini"
  [[ -z "$theme" ]] || ensure_ini_line "$ini" Settings "gtk-theme-name=$theme" replace
  ensure_ini_line "$ini" Settings "gtk-application-prefer-dark-theme=1" replace
  # GTK4 without libadwaita honours the preference; libadwaita follows
  # color-scheme. The theme name is not set here: adw-gtk3 is a GTK3 theme.
  ensure_ini_line "$cfg/gtk-4.0/settings.ini" Settings "gtk-application-prefer-dark-theme=1" replace
}

# _dark_mode_qt: Qt5 and Qt6 through qt5ct/qt6ct.
_dark_mode_qt() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" src="$REPO_ROOT/files/dark-mode"
  local env_file tool line
  env_file="$(rootpath /etc/environment)"

  ensure_packages qt5ct qt6ct || return 1

  # The qt6ct plugin registers both the qt6ct and qt5ct keys, so one value
  # makes Qt6 apps load qt6ct and Qt5 apps load qt5ct. /etc/environment is read
  # by greetd's PAM stack (cosmic-greeter has pam_env readenv=1) when the
  # session opens, so it takes effect after the next login. Never add a second
  # QT_QPA_PLATFORMTHEME line.
  if [[ -f "$env_file" ]] && grep -q '^QT_QPA_PLATFORMTHEME=' "$env_file" &&
    ! grep -qxF 'QT_QPA_PLATFORMTHEME=qt5ct' "$env_file"; then
    log_warn "$env_file sets QT_QPA_PLATFORMTHEME to another value: not adding a second line (Qt apps follow that value, not qt5ct/qt6ct)"
  else
    ensure_line "$env_file" "QT_QPA_PLATFORMTHEME=qt5ct"
  fi

  # Only the [Appearance] keys are managed: qt5ct/qt6ct keep their own state
  # (fonts, window geometry) in the same file when their GUI is opened.
  for tool in qt5ct qt6ct; do
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \[* ]] && continue
      ensure_ini_line "$cfg/$tool/$tool.conf" Appearance "$line" replace
    done <"$src/$tool.conf"
  done
}

module_apply() {
  _dark_mode_gtk || return 1
  _dark_mode_qt || return 1
}
