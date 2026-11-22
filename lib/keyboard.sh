#!/usr/bin/env bash
# lib/keyboard.sh: choosing the keyboard layout (validation against the system
# XKB rules list, the numbered menu, the pre-flight checks install.sh runs).
# Sourced after lib/common.sh by install.sh and by modules/90-keyboard.sh. See
# specs/keyboard.md. It does not set shell options.

# shellcheck disable=SC2034  # KBD_* results are read by the keyboard module
_KBD_LST="/usr/share/X11/xkb/rules/evdev.lst"
_KBD_CHOICE_RE='^(keep|[A-Za-z0-9_]+(:[A-Za-z0-9_-]+)?)$'

# Set by kbd_parse_choice.
KBD_KEEP=0
KBD_LAYOUT=""
KBD_VARIANT=""

# _kbd_lst_section <layout|variant>: the entries of one section of evdev.lst.
_kbd_lst_section() {
  awk -v s="$1" '/^! /{ cur = ($2 == s); next } cur && NF { print }' "$(rootpath "$_KBD_LST")"
}

# kbd_layout_valid <layout>: true when the XKB rules list has that layout.
kbd_layout_valid() {
  _kbd_lst_section layout | awk -v l="$1" '$1 == l { f = 1 } END { exit !f }'
}

# kbd_variant_valid <layout> <variant>: true when the layout has that variant.
kbd_variant_valid() {
  _kbd_lst_section variant | awk -v l="$1:" -v v="$2" '$1 == v && $2 == l { f = 1 } END { exit !f }'
}

# kbd_layout_desc <layout>: the description of the layout ("English (US)").
kbd_layout_desc() {
  _kbd_lst_section layout | awk -v l="$1" '$1 == l { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }'
}

# kbd_variant_desc <layout> <variant>: the description of the variant without
# the "<layout>: " prefix.
kbd_variant_desc() {
  _kbd_lst_section variant | awk -v l="$1:" -v v="$2" '
    $1 == v && $2 == l { sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }'
}

# kbd_parse_choice <value>: validate "keep" or "<layout>[:<variant>]" against
# the XKB rules list and set KBD_KEEP, KBD_LAYOUT and KBD_VARIANT. Prints the
# reason and returns 1 when the value is not usable.
kbd_parse_choice() {
  local v="$1" layout variant=""
  KBD_KEEP=0 KBD_LAYOUT="" KBD_VARIANT=""
  if [[ ! "$v" =~ $_KBD_CHOICE_RE ]]; then
    log_error "invalid keyboard choice '$v': use <layout>[:<variant>] or keep"
    return 1
  fi
  if [[ "$v" == keep ]]; then
    KBD_KEEP=1
    return 0
  fi
  layout="${v%%:*}"
  [[ "$v" == *:* ]] && variant="${v#*:}"
  if [[ ! -r "$(rootpath "$_KBD_LST")" ]]; then
    log_error "the XKB rules list $_KBD_LST is missing (install the xkb-data package), so the layout cannot be validated"
    return 1
  fi
  if ! kbd_layout_valid "$layout"; then
    log_error "unknown keyboard layout '$layout': it is not in $_KBD_LST"
    return 1
  fi
  if [[ -n "$variant" ]] && ! kbd_variant_valid "$layout" "$variant"; then
    log_error "unknown variant '$variant' for the keyboard layout '$layout': it is not in $_KBD_LST"
    return 1
  fi
  KBD_LAYOUT="$layout"
  KBD_VARIANT="$variant"
}

# kbd_current: print "<layout> <variant>" from /etc/default/keyboard (either
# may be empty, the layout may hold several comma separated layouts).
kbd_current() {
  local f l v
  f="$(rootpath /etc/default/keyboard)"
  [[ -r "$f" ]] || return 0
  l="$(sed -n 's/^[[:space:]]*XKBLAYOUT="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f" | head -n 1)"
  v="$(sed -n 's/^[[:space:]]*XKBVARIANT="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f" | head -n 1)"
  printf '%s %s\n' "$l" "$v"
}

# kbd_menu: the numbered menu. No default: an empty or invalid answer asks
# again. Reads standard input; sets KEYBOARD_CHOICE. Returns 1 when the input
# ends before a valid answer (never loops on end of file).
kbd_menu() {
  local ans layout variant cur cur_l cur_v
  cur="$(kbd_current)"
  cur_l="${cur%% *}"
  cur_v="${cur#* }"
  [[ "$cur" == *" "* ]] || cur_v=""
  printf '\nKeyboard layout. Pick one to replace the layout chosen in the Kali installer, or keep the current one.\n'
  printf '  1) English (US)                                  us\n'
  printf '  2) English (US), intl. with AltGr dead keys       us altgr-intl\n'
  printf '  3) English (US), intl. with dead keys             us intl\n'
  printf '  4) Spanish (Latin American)                       latam\n'
  printf '  5) Spanish (Spain)                                es\n'
  printf '  6) Keep current (layout: %s, variant: %s)\n' "${cur_l:-none}" "${cur_v:-none}"
  printf '  7) Other (any XKB layout and optional variant)\n'
  while :; do
    printf 'Choose 1-7: '
    if ! IFS= read -r ans; then
      printf '\n'
      log_error "no keyboard choice: the input ended before a valid answer (use --keyboard <layout>[:<variant>] or --keyboard keep)"
      return 1
    fi
    ans="${ans//[[:space:]]/}"
    case "$ans" in
      1) KEYBOARD_CHOICE="us" ;;
      2) KEYBOARD_CHOICE="us:altgr-intl" ;;
      3) KEYBOARD_CHOICE="us:intl" ;;
      4) KEYBOARD_CHOICE="latam" ;;
      5) KEYBOARD_CHOICE="es" ;;
      6) KEYBOARD_CHOICE="keep" ;;
      7)
        while :; do
          printf 'XKB layout (for example fr, de, gb): '
          IFS= read -r layout || {
            printf '\n'
            log_error "no keyboard choice: the input ended before a valid layout"
            return 1
          }
          layout="${layout//[[:space:]]/}"
          if [[ -z "$layout" ]]; then
            log_warn "type a layout name"
          elif [[ "$layout" =~ ^[A-Za-z0-9_]+$ ]] && kbd_layout_valid "$layout"; then
            break
          else
            log_warn "unknown layout '$layout': see $_KBD_LST"
          fi
        done
        while :; do
          printf 'Variant (empty for none): '
          IFS= read -r variant || {
            printf '\n'
            log_error "no keyboard choice: the input ended before a valid variant"
            return 1
          }
          variant="${variant//[[:space:]]/}"
          if [[ -z "$variant" ]]; then
            break
          elif [[ "$variant" =~ ^[A-Za-z0-9_-]+$ ]] && kbd_variant_valid "$layout" "$variant"; then
            break
          else
            log_warn "unknown variant '$variant' for '$layout': see $_KBD_LST"
          fi
        done
        KEYBOARD_CHOICE="$layout${variant:+:$variant}"
        ;;
      *)
        log_warn "invalid choice '$ans': type a number from 1 to 7"
        continue
        ;;
    esac
    export KEYBOARD_CHOICE
    return 0
  done
}

# kbd_preflight: before sudo and before any module. Validates --keyboard and
# refuses to run a real install that would need the menu without a terminal.
# Returns 2 for a bad value, 1 for a missing choice.
kbd_preflight() {
  if [[ -n "${KEYBOARD_CHOICE:-}" ]]; then
    # xkb-data (the rules list) missing: a real run installs it after the sudo
    # password is asked (once, see kbd_ask_if_needed) and validates then. A
    # dry-run cannot install, so it still fails here.
    if [[ "$KEYBOARD_CHOICE" != keep && "$DRY_RUN" != "1" && ! -r "$(rootpath "$_KBD_LST")" &&
      "$KEYBOARD_CHOICE" =~ $_KBD_CHOICE_RE ]]; then
      log_info "the XKB rules list is missing; xkb-data is installed first and the layout is validated then"
      return 0
    fi
    kbd_parse_choice "$KEYBOARD_CHOICE" || return 2
    return 0
  fi
  if [[ ! -t 0 && "$DRY_RUN" != "1" ]]; then
    log_error "the keyboard module needs a layout and there is no terminal to ask on: pass --keyboard <layout>[:<variant>] (for example --keyboard us:altgr-intl) or --keyboard keep. Nothing was changed"
    return 1
  fi
  return 0
}

# kbd_ask_if_needed: after sudo, before stdin is closed: show the menu once
# when no --keyboard was given and there is a terminal.
kbd_ask_if_needed() {
  # The rules list comes from xkb-data: install it (and keyboard-configuration)
  # now that the sudo session exists, before validating or showing "Other".
  if [[ "$DRY_RUN" != "1" && "${KEYBOARD_CHOICE:-}" != keep && ! -r "$(rootpath "$_KBD_LST")" ]]; then
    ensure_packages keyboard-configuration xkb-data || return 1
  fi
  if [[ -n "${KEYBOARD_CHOICE:-}" ]]; then
    kbd_parse_choice "$KEYBOARD_CHOICE" || return 2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_info "dry-run: no --keyboard given and no terminal; the real run asks for the layout in a menu"
    return 0
  fi
  kbd_menu || return 1
  kbd_parse_choice "$KEYBOARD_CHOICE"
}
