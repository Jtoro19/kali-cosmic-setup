#!/usr/bin/env bash
# modules/90-keyboard.sh: the keyboard layout, everywhere (see specs/keyboard.md).
# The layout comes from KEYBOARD_CHOICE (install.sh menu or --keyboard).

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="keyboard"
# shellcheck disable=SC2034
MODULE_DESC="keyboard layout from a menu or --keyboard, replacing the installer layout in /etc/default/keyboard, debconf, console, localectl and COSMIC"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# shellcheck source=lib/keyboard.sh
[[ "$(type -t kbd_parse_choice || true)" == function ]] || source "$REPO_ROOT/lib/keyboard.sh"

_KBD_MODEL="pc105"
_KBD_DEFAULT_REPEAT_DELAY=600
_KBD_DEFAULT_REPEAT_RATE=25
_KBD_DEBCONF_PKG="keyboard-configuration"

# --- reading the current state ---------------------------------------------------------

# _kbd_default_file_render <src> <layout> <variant>: print /etc/default/keyboard
# with the model, layout, variant and options set (other lines stay; missing
# ones are added; a missing source renders a complete new file).
_kbd_default_file_render() {
  local src="$1"
  [[ -f "$src" ]] || src=/dev/null
  awk -v l="$2" -v var="$3" -v m="$_KBD_MODEL" '
    BEGIN { v["XKBMODEL"] = m; v["XKBLAYOUT"] = l; v["XKBVARIANT"] = var; v["XKBOPTIONS"] = ""
            n = split("XKBMODEL XKBLAYOUT XKBVARIANT XKBOPTIONS", order, " ") }
    {
      seen_any = 1
      if ($0 ~ /^[ \t]*BACKSPACE=/) bs = 1
      if (match($0, /^[ \t]*XKB(MODEL|LAYOUT|VARIANT|OPTIONS)=/)) {
        key = substr($0, RSTART, RLENGTH - 1); gsub(/[ \t]/, "", key)
        if (!(key in done)) { printf "%s=\"%s\"\n", key, v[key]; done[key] = 1 }
        next
      }
      print
    }
    END {
      if (!seen_any) print "# KEYBOARD CONFIGURATION FILE\n"
      for (i = 1; i <= n; i++) if (!(order[i] in done)) printf "%s=\"%s\"\n", order[i], v[order[i]]
      if (!bs) print "BACKSPACE=\"guess\""
    }' "$src"
}

# _kbd_debconf_dump: the keyboard-configuration answers as "question<TAB>value".
_kbd_debconf_dump() {
  { sudo_read debconf-show "$_KBD_DEBCONF_PKG" || true; } | awk '
    { sub(/^[* ] /, ""); p = index($0, ": "); q = $0; v = ""
      if (p) { q = substr($0, 1, p - 1); v = substr($0, p + 2) } else { sub(/:$/, "", q) }
      sub(/^keyboard-configuration\//, "", q); sub(/[ \t]+$/, "", v); print q "\t" v }'
}

# _kbd_dc <dump> <question>: the value of one answer in a dump.
_kbd_dc() {
  awk -F'\t' -v q="$2" '$1 == q { print $2; exit }' <<<"$1"
}

# _kbd_localectl_field <field>: value of a `localectl status` line ("X11 Layout"),
# empty when absent, unset or "n/a".
_kbd_localectl_field() {
  localectl status 2>/dev/null | awk -v f="$1:" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, f) == 1 {
      v = substr(line, length(f) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v != "n/a" && v != "(unset)") print v
      exit
    }' || true
}

# _kbd_ron_field <text> <field>: the value of a RON field of the xkb_config:
# a quoted string, or a number.
_kbd_ron_field() {
  sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\\{0,1\\}\\([^\",]*\\)\"\\{0,1\\},\\{0,1\\}[[:space:]]*\$/\\1/p" <<<"$1" | head -n 1
}

# _kbd_ron_escape <text>: escape a value for a RON string literal.
_kbd_ron_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# _kbd_xkb_render <layout> <variant> <delay> <rate>: the CosmicComp xkb_config
# RON, byte-exact with what COSMIC writes (no trailing newline).
_kbd_xkb_render() {
  printf '(\n    rules: "",\n    model: "%s",\n    layout: "%s",\n    variant: "%s",\n    options: None,\n    repeat_delay: %s,\n    repeat_rate: %s,\n)' \
    "$_KBD_MODEL" "$(_kbd_ron_escape "$1")" "$(_kbd_ron_escape "$2")" "$3" "$4"
}

# _kbd_num <text> <default>: the text when it is a number, else the default.
_kbd_num() {
  [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '%s' "$2"
}

# --- applying -----------------------------------------------------------------------------

# _kbd_apply_debconf <layout> <variant>: make the keyboard-configuration answers
# the chosen layout, set non-interactively, and let the package rewrite its
# configuration without asking.
_kbd_apply_debconf() {
  local layout="$1" variant="$2" dump keymap ldesc vdesc q want have stale=0
  dump="$(_kbd_debconf_dump)"
  keymap="$layout${variant:+($variant)}"
  ldesc="$(kbd_layout_desc "$layout")"
  vdesc="$ldesc"
  [[ -n "$variant" ]] && vdesc="$ldesc - $(kbd_variant_desc "$layout" "$variant")"
  # The display answers (layout, variant) are set too, but they are not compared:
  # dpkg-reconfigure rewrites them in its own wording.
  local -a answers=(
    "modelcode=$_KBD_MODEL" "layoutcode=$layout" "variantcode=$variant" "optionscode="
    "xkb-keymap=$keymap"
  )
  for q in "${answers[@]}"; do
    want="${q#*=}"
    have="$(_kbd_dc "$dump" "${q%%=*}")"
    [[ "$have" == "$want" ]] || stale=1
  done
  ((stale)) || return 0
  log_change "set the keyboard-configuration answers to $keymap (debconf)"
  {
    printf '%s %s/%s string %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" modelcode "$_KBD_MODEL"
    printf '%s %s/%s string %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" layoutcode "$layout"
    printf '%s %s/%s string %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" variantcode "$variant"
    printf '%s %s/%s string\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" optionscode
    printf '%s %s/%s select %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" xkb-keymap "$keymap"
    printf '%s %s/%s select %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" layout "$ldesc"
    printf '%s %s/%s select %s\n' "$_KBD_DEBCONF_PKG" "$_KBD_DEBCONF_PKG" variant "$vdesc"
  } | run_sudo env DEBIAN_FRONTEND=noninteractive debconf-set-selections
  # The package reads /etc/default/keyboard first and lets it win over the
  # answers, so the file must already hold the chosen layout (module_apply
  # writes it before this); noninteractive, it then asks nothing.
  run_sudo env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive "$_KBD_DEBCONF_PKG"
}

# _kbd_apply_xkb_user <layout> <variant>: the COSMIC keyboard config of the
# invoking user. The key repeat settings already in the file stay.
_kbd_apply_xkb_user() {
  local dest="$HOME/.config/cosmic/com.system76.CosmicComp/v1/xkb_config" cur="" delay rate tmp rc=0
  user_path_writable "$dest" || return 0
  [[ -r "$dest" ]] && cur="$(<"$dest")"
  delay="$(_kbd_num "$(_kbd_ron_field "$cur" repeat_delay)" "$_KBD_DEFAULT_REPEAT_DELAY")"
  rate="$(_kbd_num "$(_kbd_ron_field "$cur" repeat_rate)" "$_KBD_DEFAULT_REPEAT_RATE")"
  tmp="$(mktemp)"
  _kbd_xkb_render "$1" "$2" "$delay" "$rate" >"$tmp"
  install_file "$tmp" "$dest" 0644 || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# _kbd_greeter_home: the home of the cosmic-greeter user, empty when there is
# none. KCS_GREETER_USER and KCS_GREETER_HOME are test-only overrides.
_kbd_greeter_user() { printf '%s' "${KCS_GREETER_USER:-cosmic-greeter}"; }
_kbd_greeter_home() {
  if [[ -n "${KCS_GREETER_HOME:-}" ]]; then
    printf '%s' "$KCS_GREETER_HOME"
  else
    getent passwd "$(_kbd_greeter_user)" 2>/dev/null | cut -d: -f6 || true
  fi
}

# _kbd_apply_xkb_greeter <layout> <variant>: the same config for the login
# screen. cosmic-greeter runs its own cosmic-comp as the cosmic-greeter system
# user, which reads xkb_config from that user's home. Written as root with the
# greeter's ownership; the other files of that home are never touched.
_kbd_apply_xkb_greeter() {
  local layout="$1" variant="$2" user home group base dest tmp cur="" delay rate d
  user="$(_kbd_greeter_user)"
  home="$(_kbd_greeter_home)"
  if [[ -z "$home" ]]; then
    log_info "no $user user; the login screen keyboard is not configured"
    return 0
  fi
  group="$(id -gn "$user" 2>/dev/null || printf '%s' "$user")"
  base="$home/.config/cosmic/com.system76.CosmicComp/v1"
  dest="$base/xkb_config"
  cur="$(sudo_read cat -- "$dest" || true)"
  delay="$(_kbd_num "$(_kbd_ron_field "$cur" repeat_delay)" "$_KBD_DEFAULT_REPEAT_DELAY")"
  rate="$(_kbd_num "$(_kbd_ron_field "$cur" repeat_rate)" "$_KBD_DEFAULT_REPEAT_RATE")"
  tmp="$(mktemp)"
  _kbd_xkb_render "$layout" "$variant" "$delay" "$rate" >"$tmp"
  if [[ -n "$cur" ]] && cmp -s -- "$tmp" <(printf '%s' "$cur"); then
    rm -f -- "$tmp"
    return 0
  fi
  log_change "install login screen keyboard ($layout${variant:+:$variant}): $dest"
  # Missing directories are created owned by the greeter user so it can still
  # write the rest of its own COSMIC config.
  for d in "$home/.config" "$home/.config/cosmic" "${base%/v1}" "$base"; do
    if [[ ! -d "$d" ]] && ! sudo_read test -d "$d"; then
      run_sudo install -d -o "$user" -g "$group" -m 0700 -- "$d"
    fi
  done
  if [[ -n "$cur" ]]; then
    run_sudo cp -p -- "$dest" "$dest.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  run_sudo install -m 0644 -o "$user" -g "$group" -- "$tmp" "$dest"
  rm -f -- "$tmp"
}

# _kbd_apply_localectl <layout> <variant>: the X11 keymap of the system, which
# cosmic-greeter and the console conversion read.
_kbd_apply_localectl() {
  local layout="$1" variant="$2"
  if [[ "$(_kbd_localectl_field "X11 Layout")" == "$layout" &&
    "$(_kbd_localectl_field "X11 Variant")" == "$variant" &&
    "$(_kbd_localectl_field "X11 Model")" == "$_KBD_MODEL" &&
    -z "$(_kbd_localectl_field "X11 Options")" ]]; then
    return 0
  fi
  log_change "set the X11 keymap (localectl): $layout${variant:+:$variant}"
  run_sudo localectl set-x11-keymap "$layout" "$_KBD_MODEL" "$variant" ""
}

# --- verifying ------------------------------------------------------------------------------

# _kbd_verify <layout> <variant> <old-keymap> <old-debconf-dump>: every place holds exactly the
# chosen layout, so the installer layout is nowhere. Prints every trace and
# returns 1 otherwise.
_kbd_verify() {
  local layout="$1" variant="$2" old_keymap="$3" f dump x text gh
  local -a bad=()
  f="$(rootpath /etc/default/keyboard)"
  [[ "$(sed -n 's/^XKBLAYOUT="\(.*\)"$/\1/p' "$f" 2>/dev/null)" == "$layout" ]] ||
    bad+=("/etc/default/keyboard has XKBLAYOUT=\"$(sed -n 's/^XKBLAYOUT=//p' "$f" 2>/dev/null)\" (wanted $layout)")
  [[ "$(sed -n 's/^XKBVARIANT="\(.*\)"$/\1/p' "$f" 2>/dev/null)" == "$variant" ]] ||
    bad+=("/etc/default/keyboard has XKBVARIANT=$(sed -n 's/^XKBVARIANT=//p' "$f" 2>/dev/null) (wanted \"$variant\")")
  [[ "$(sed -n 's/^XKBOPTIONS="\(.*\)"$/\1/p' "$f" 2>/dev/null)" == "" ]] ||
    bad+=("/etc/default/keyboard has XKBOPTIONS set (wanted empty)")

  dump="$(_kbd_debconf_dump)"
  local keymap="$layout${variant:+($variant)}"
  local -a pairs=("layoutcode=$layout" "variantcode=$variant" "modelcode=$_KBD_MODEL" "optionscode=" \
    "xkb-keymap=$keymap")
  local p q
  for p in "${pairs[@]}"; do
    [[ "$(_kbd_dc "$dump" "${p%%=*}")" == "${p#*=}" ]] ||
      bad+=("debconf $_KBD_DEBCONF_PKG/${p%%=*} is \"$(_kbd_dc "$dump" "${p%%=*}")\" (wanted \"${p#*=}\")")
  done
  # The display answers must not be the installer's any more (they are worded by
  # the package, so they are compared with the old ones, not with a wanted text).
  if [[ "$(_kbd_dc "$old_dump" layoutcode)" != "$layout" || "$(_kbd_dc "$old_dump" variantcode)" != "$variant" ]]; then
    for q in layout variant; do
      x="$(_kbd_dc "$old_dump" "$q")"
      [[ -z "$x" || "$(_kbd_dc "$dump" "$q")" != "$x" ]] ||
        bad+=("debconf $_KBD_DEBCONF_PKG/$q is still the installer's \"$x\"")
    done
  fi
  [[ -n "$(_kbd_dc "$dump" variant)" ]] || bad+=("debconf $_KBD_DEBCONF_PKG/variant is empty")

  [[ "$(_kbd_localectl_field "X11 Layout")" == "$layout" ]] ||
    bad+=("localectl X11 Layout is \"$(_kbd_localectl_field "X11 Layout")\" (wanted $layout)")
  [[ "$(_kbd_localectl_field "X11 Variant")" == "$variant" ]] ||
    bad+=("localectl X11 Variant is \"$(_kbd_localectl_field "X11 Variant")\" (wanted \"$variant\")")
  # The console map systemd keeps in /etc/vconsole.conf must not be the old one.
  local vc
  vc="$(rootpath /etc/vconsole.conf)"
  if [[ -r "$vc" ]]; then
    x="$(sed -n 's/^XKBLAYOUT=//p' "$vc" | tr -d '"')"
    [[ -z "$x" || "$x" == "$layout" ]] || bad+=("/etc/vconsole.conf has XKBLAYOUT=$x (wanted $layout)")
    x="$(sed -n 's/^KEYMAP=//p' "$vc" | tr -d '"')"
    if [[ -n "$old_keymap" && "$x" == "$old_keymap" ]]; then
      bad+=("/etc/vconsole.conf still has the installer console keymap KEYMAP=$x")
    fi
  fi

  local cur
  cur="$HOME/.config/cosmic/com.system76.CosmicComp/v1/xkb_config"
  if [[ -r "$cur" ]]; then
    text="$(<"$cur")"
    [[ "$(_kbd_ron_field "$text" layout)" == "$layout" && "$(_kbd_ron_field "$text" variant)" == "$variant" ]] ||
      bad+=("COSMIC xkb_config of $USER has layout \"$(_kbd_ron_field "$text" layout)\" variant \"$(_kbd_ron_field "$text" variant)\"")
  else
    bad+=("COSMIC xkb_config of $USER is missing: $cur")
  fi
  gh="$(_kbd_greeter_home)"
  if [[ -n "$gh" ]]; then
    text="$(sudo_read cat -- "$gh/.config/cosmic/com.system76.CosmicComp/v1/xkb_config" || true)"
    if [[ -z "$text" ]]; then
      bad+=("COSMIC xkb_config of the login screen user is missing or unreadable")
    elif [[ "$(_kbd_ron_field "$text" layout)" != "$layout" || "$(_kbd_ron_field "$text" variant)" != "$variant" ]]; then
      bad+=("COSMIC xkb_config of the login screen user has layout \"$(_kbd_ron_field "$text" layout)\" variant \"$(_kbd_ron_field "$text" variant)\"")
    fi
  fi
  if ((${#bad[@]} > 0)); then
    log_error "the keyboard layout did not replace the installer layout everywhere:"
    for p in "${bad[@]}"; do
      log_error "  - $p"
    done
    return 1
  fi
  log_ok "keyboard layout ${layout}${variant:+:$variant} is the only one configured (/etc/default/keyboard, debconf, localectl, console, COSMIC for $USER and the login screen)"
}

# _kbd_write_default_file <file> <layout> <variant>: /etc/default/keyboard with the
# chosen layout (backup, sudo for the write, dry-run aware).
_kbd_write_default_file() {
  local tmp rc=0
  tmp="$(mktemp)"
  _kbd_default_file_render "$1" "$2" "$3" >"$tmp"
  install_file "$tmp" "$1" 0644 || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# --- module ---------------------------------------------------------------------------------

module_apply() {
  local choice="${KEYBOARD_CHOICE:-}" layout variant cur cur_l cur_v before kf old_keymap="" vc
  local initrd old_dump

  if [[ -z "$choice" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_info "keyboard: no layout chosen yet (the real run asks in a menu or takes --keyboard); nothing to plan"
      return 0
    fi
    log_error "keyboard: no layout was chosen; run ./install.sh from a terminal (it asks) or pass --keyboard <layout>[:<variant>] or --keyboard keep"
    return 1
  fi
  kbd_parse_choice "$choice" || return 1
  if ((KBD_KEEP)); then
    cur="$(kbd_current)"
    cur_l="${cur%% *}"
    cur_v="${cur#* }"
    log_info "keyboard: keeping the current layout (${cur_l:-none}${cur_v:+:$cur_v}); nothing is changed"
    return 0
  fi
  layout="$KBD_LAYOUT"
  variant="$KBD_VARIANT"
  kf="$(rootpath /etc/default/keyboard)"
  vc="$(rootpath /etc/vconsole.conf)"
  # The console keymap of the installer layout, to recognise it if it survives.
  # Only meaningful when this run changes the X11 layout (localectl converts it).
  if [[ -r "$vc" ]] && [[ "$(_kbd_localectl_field "X11 Layout")" != "$layout" ||
    "$(_kbd_localectl_field "X11 Variant")" != "$variant" ]]; then
    old_keymap="$(sed -n 's/^KEYMAP=//p' "$vc" | tr -d '"')"
  fi

  log_info "keyboard: layout $layout${variant:+, variant $variant} (model $_KBD_MODEL, no options)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "keyboard: would set /etc/default/keyboard, the debconf answers of $_KBD_DEBCONF_PKG, the initramfs and console cache (only when something changed), the X11 keymap (localectl), and the COSMIC xkb_config of $USER and of the login screen user"
  fi

  ensure_packages "$_KBD_DEBCONF_PKG" xkb-data || return 1

  old_dump="$(_kbd_debconf_dump)"
  before=$CHANGES
  # The file first: dpkg-reconfigure lets it win over the debconf answers.
  _kbd_write_default_file "$kf" "$layout" "$variant" || return 1
  _kbd_apply_debconf "$layout" "$variant" || return 1
  _kbd_apply_localectl "$layout" "$variant" || return 1
  # localectl may rewrite /etc/default/keyboard; make sure it ends as wanted.
  if [[ "$DRY_RUN" != "1" ]]; then
    _kbd_write_default_file "$kf" "$layout" "$variant" || return 1
  fi
  # The stored console files and the initramfs hold the keymap: refresh them
  # when the system layout changed, or when /etc/default/keyboard is newer than
  # the initramfs (an earlier run was interrupted before it was rebuilt).
  initrd="$(rootpath "/boot/initrd.img-$(uname -r)")"
  if ((CHANGES > before)) || { [[ "$DRY_RUN" != "1" && -e "$initrd" && "$kf" -nt "$initrd" ]]; }; then
    if command -v setupcon >/dev/null 2>&1; then
      log_change "refresh the console keymap cache (setupcon)"
      run_sudo_may_fail setupcon --save-only || log_warn "setupcon --save-only failed; the console keymap cache may be stale"
    fi
    log_change "update the initramfs so the console and any disk unlock prompt use the layout"
    run_sudo update-initramfs -u
  fi

  _kbd_apply_xkb_user "$layout" "$variant" || return 1
  _kbd_apply_xkb_greeter "$layout" "$variant" || return 1

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  _kbd_verify "$layout" "$variant" "$old_keymap" "$old_dump" || return 1
  if ((CHANGES > before)); then
    log_warn "keyboard: the console and the login screen use the new layout in full after a reboot"
  fi
}
