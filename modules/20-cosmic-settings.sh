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

# _COSMIC_RON_AWK: a small reader for the `custom` shortcut map, a RON map of
# `(modifiers: [...], key: "x", description: ...): Action,` entries. It skips
# // comments and strings, accepts any field order, and understands only that
# shape: anything else (a block comment, unbalanced brackets, an entry without a
# key, a missing comma) ends with status 2, "not understood". With mode=scan it
# prints whether Super+Shift+S is bound: `free`, `screenshot` (to
# cosmic-screenshot) or `other`. With mode=open it prints the file up to its
# final brace, with a comma inserted after the last entry when it lacks one.
# shellcheck disable=SC2016  # awk program, not shell
_COSMIC_RON_AWK='
function bad() { exit 2 }
function finish_action() {
  if (inact && pm) status = (act == ":Spawn(\"cosmic-screenshot\")") ? "screenshot" : "other"
  inact = 0; pm = 0; act = ""
}
function tuple(   piece, m, k, parts, np, j, sorted) {
  if (!match(tup, /(^|,)key:"#[0-9]+"/)) bad()
  piece = substr(tup, RSTART, RLENGTH); sub(/^,/, "", piece)
  k = strs[substr(piece, 7, length(piece) - 7)]
  m = ""
  if (match(tup, /(^|,)modifiers:\[[^]]*\]/)) {
    piece = substr(tup, RSTART, RLENGTH); sub(/^,/, "", piece)
    np = split(substr(piece, 12, length(piece) - 12), parts, ",")
    for (j = 1; j <= np; j++) if (parts[j] != "") list[++cnt] = parts[j]
    # sort the modifier names so that their order does not matter
    for (j = 1; j <= cnt; j++) for (x = j + 1; x <= cnt; x++) if (list[x] < list[j]) { t = list[j]; list[j] = list[x]; list[x] = t }
    for (j = 1; j <= cnt; j++) m = m (j > 1 ? "," : "") list[j]
    cnt = 0
  }
  pm = (m == "Shift,Super" && tolower(k) == "s")
}
{ buf = buf $0 "\n" }
END {
  n = length(buf); status = "free"
  for (i = 1; i <= n; i++) {
    c = substr(buf, i, 1)
    if (c ~ /[ \t\r\n]/) continue
    if (c == "/" && substr(buf, i + 1, 1) == "/") { while (i <= n && substr(buf, i, 1) != "\n") i++; continue }
    if (c == "/" && substr(buf, i + 1, 1) == "*") bad()
    if (done) bad()
    pcode = lastcode; pch = lastch
    if (c == "\"") {
      j = i + 1; s = ""
      while (j <= n) {
        d = substr(buf, j, 1)
        if (d == "\\") { s = s d substr(buf, j + 1, 1); j += 2; continue }
        if (d == "\"") break
        s = s d; j++
      }
      if (j > n || depth < 1) bad()
      i = j; strs[++ns] = s
      if (intup) tup = tup "\"#" ns "\""
      else if (inact) act = act "\"" s "\""
      else bad()
      lastcode = i; lastch = "\""
      continue
    }
    lastcode = i; lastch = c
    if (c == "{" || c == "(" || c == "[") {
      if (depth == 0) { if (c != "{" || seen) bad(); seen = 1; depth = 1; stack[1] = c; continue }
      if (depth == 1 && !inact) { if (c != "(") bad(); depth = 2; stack[2] = c; intup = 1; tup = ""; continue }
      if (depth == 1 && inact && c == "(" && substr(act, length(act), 1) == ")") bad()
      depth++; stack[depth] = c
      if (intup) tup = tup c; else act = act c
      continue
    }
    if (c == "}" || c == ")" || c == "]") {
      if (depth == 0) bad()
      o = stack[depth]
      if (!((o == "{" && c == "}") || (o == "(" && c == ")") || (o == "[" && c == "]"))) bad()
      depth--
      if (depth == 0) { finish_action(); closepos = i; fcode = pcode; fch = pch; done = 1; continue }
      if (depth == 1 && intup) { intup = 0; tuple(); inact = 1; act = ""; continue }
      if (intup) tup = tup c; else act = act c
      continue
    }
    if (depth == 0) bad()
    if (c == "," && depth == 1) { if (!inact) bad(); finish_action(); continue }
    if (intup) tup = tup c
    else if (inact) act = act c
    else bad()
  }
  if (!done || depth != 0) bad()
  if (mode == "scan") { print status; exit 0 }
  if (fch != "{" && fch != "," && fch !~ /[A-Za-z0-9_)"\]]/) bad()
  printf "%s", substr(buf, 1, fcode)
  if (fch != "{" && fch != ",") printf ","
  printf "%s", substr(buf, fcode + 1, closepos - fcode - 1)
}'

# _cosmic_settings_shortcuts: the `custom` key is one RON map shared by every
# module and by the user. This module owns only its own entry (Super+Shift+S,
# cosmic-screenshot): it creates the file when missing or empty, adds its entry
# to an existing map, and leaves the file alone when that key combination is
# already bound (to cosmic-screenshot or to anything else: a duplicate key
# would make the map invalid). Entries of other modules (aura's Alt+S) and of
# the user are never removed or changed. A map whose shape is not understood is
# left untouched with a warning.
_cosmic_settings_shortcuts() {
  local base="$REPO_ROOT/files/cosmic/$_COSMIC_SHORTCUTS" dest="$HOME/.config/cosmic/$_COSMIC_SHORTCUTS"
  local content trimmed body tmp state rc=0

  user_path_writable "$dest" || return 0
  content=""
  [[ -f "$dest" ]] && content="$(cat -- "$dest")"
  trimmed="${content//[[:space:]]/}"
  if [[ -z "$trimmed" || "$trimmed" == "{}" ]]; then
    install_file "$base" "$dest" 0644
    return
  fi
  if ! state="$(printf '%s\n' "$content" | awk -v mode=scan "$_COSMIC_RON_AWK")"; then
    log_warn "$dest is not a shortcut map this module understands: not adding the Super+Shift+S screenshot shortcut"
    return 0
  fi
  case "$state" in
    screenshot) return 0 ;;
    other)
      log_info "Super+Shift+S is already bound to something else in $dest: leaving it alone"
      return 0
      ;;
  esac

  # The entries of the seed are the lines between its braces.
  body="$(sed '1d;$d' "$base")"
  tmp="$(mktemp)"
  if ! printf '%s\n' "$content" | awk -v mode=open "$_COSMIC_RON_AWK" >"$tmp"; then
    rm -f -- "$tmp"
    log_warn "$dest is not a shortcut map this module understands: not adding the Super+Shift+S screenshot shortcut"
    return 0
  fi
  printf '%s\n}\n' "$body" >>"$tmp"
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
    user_path_writable "$dest" || continue
    if [[ " ${_COSMIC_SEED_ONLY[*]} " == *" $rel "* && -e "$dest" ]]; then
      continue
    fi
    install_file "$src/$rel" "$dest" 0644 || return 1
  done

  _cosmic_settings_shortcuts || return 1
}
