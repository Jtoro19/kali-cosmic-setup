#!/usr/bin/env bash
# modules/75-mime.sh: default applications in ~/.config/mimeapps.list.
# See specs/mime.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="mime"
# shellcheck disable=SC2034
MODULE_DESC="default applications (Brave for web and PDF, PeaZip for zip) for installed apps only"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS="packages"

# mime-type=desktop-id pairs. A pair is applied only when the desktop entry is
# installed, so an app that was not installed is simply skipped.
_MIME_DEFAULTS=(
  "text/html=brave-browser.desktop"
  "x-scheme-handler/http=brave-browser.desktop"
  "x-scheme-handler/https=brave-browser.desktop"
  "x-scheme-handler/about=brave-browser.desktop"
  "x-scheme-handler/unknown=brave-browser.desktop"
  "application/pdf=brave-browser.desktop"
  "application/zip=peazip.desktop"
)

# _mime_desktop_installed <desktop-id>: true when the entry exists in the user,
# /usr/local or /usr applications directory.
_mime_desktop_installed() {
  local id="$1" d
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" \
    "$(rootpath /usr/local/share/applications)" "$(rootpath /usr/share/applications)"; do
    [[ -f "$d/$id" ]] && return 0
  done
  return 1
}

# _mime_list_value <file> <key>: the value of the key under [Default Applications].
_mime_list_value() {
  awk -v k="$2" '
    { l = $0; sub(/\r$/, "", l) }
    l ~ /^[ \t]*\[/ { cur = (l ~ /^[ \t]*\[Default Applications\][ \t]*$/); next }
    cur { p = index(l, "="); if (p) { key = substr(l, 1, p - 1); gsub(/[ \t]/, "", key);
      if (key == k) { v = substr(l, p + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } } }
  ' "$1"
}

module_apply() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  local list="$cfg/mimeapps.list" cosmic="$cfg/cosmic-mimeapps.list" pair type app other
  local -a todo=()
  for pair in "${_MIME_DEFAULTS[@]}"; do
    type="${pair%%=*}"
    app="${pair#*=}"
    if ! _mime_desktop_installed "$app"; then
      log_info "skip $type: $app is not installed"
      continue
    fi
    todo+=("$pair")
    # The desktop-specific list of the user is read before mimeapps.list, so a
    # different handler there would win. It is the user's (and COSMIC Settings')
    # file: say so, never edit it.
    if [[ -f "$cosmic" ]]; then
      other="$(_mime_list_value "$cosmic" "$type")"
      if [[ -n "$other" && "$other" != "$app" ]]; then
        log_warn "$cosmic sets $type=$other and outranks $list: change it in COSMIC Settings > Default Applications, or remove that line, to get $app"
      fi
    fi
  done
  ((${#todo[@]} > 0)) || return 0

  # A new file is written in one step (no backup of a file this run just
  # created); an existing one is merged key by key and every other entry,
  # section and comment stays.
  if [[ ! -e "$list" ]]; then
    ensure_file_content "$list" "$(printf '[Default Applications]\n'; printf '%s\n' "${todo[@]}")"
    return 0
  fi
  for pair in "${todo[@]}"; do
    ensure_ini_line "$list" "Default Applications" "$pair" replace
  done
  return 0
}
