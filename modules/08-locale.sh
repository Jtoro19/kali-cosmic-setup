#!/usr/bin/env bash
# modules/08-locale.sh: system language and regional formats (see specs/locale.md).

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="locale"
# shellcheck disable=SC2034
MODULE_DESC="locale: English UI with Colombian formats (keyboard and time zone are kept; time zone only if LOCALE_TZ is set)"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Locales to generate: the language one and the formats one.
_LOCALE_GEN=("en_US.UTF-8 UTF-8" "es_CO.UTF-8 UTF-8")

# _locale_gen_render <src>: print locale.gen with the wanted locales
# uncommented (appended when absent). A missing source renders from nothing.
_locale_gen_render() {
  local wanted src="$1"
  [[ -f "$src" ]] || src=/dev/null
  wanted="$(printf '%s\n' "${_LOCALE_GEN[@]}")"
  WANTED="$wanted" awk '
    BEGIN { n = split(ENVIRON["WANTED"], w, "\n"); for (i = 1; i <= n; i++) if (w[i] != "") want[w[i]] = 1 }
    { line = $0; sub(/^#[ \t]*/, "", line) }
    (line in want) && !(line in done) { print line; done[line] = 1; next }
    { print }
    END { for (i = 1; i <= n; i++) if ((w[i] != "") && !(w[i] in done)) print w[i] }
  ' "$src"
}

# _locale_not_generated: true when a wanted locale is absent from `locale -a`
# (the names there use the lowercase "utf8" spelling).
_locale_not_generated() {
  local have entry name
  have="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  for entry in "${_LOCALE_GEN[@]}"; do
    name="${entry%% *}"
    name="${name%.UTF-8}.utf8"
    grep -qxF -- "${name,,}" <<<"$have" || return 0
  done
  return 1
}

# _locale_value <file> <var>: the value of VAR in a KEY=VALUE file, one pair of
# surrounding quotes removed; empty when unset.
_locale_value() {
  local line
  [[ -f "$1" ]] || return 0
  line="$(grep -m1 "^$2=" "$1" || true)"
  line="${line#*=}"
  line="${line#[\"\']}"
  line="${line%[\"\']}"
  printf '%s' "$line"
}

module_apply() {
  local conf="$REPO_ROOT/files/locale/locale.conf" gen tmp line var default_file
  local -a want=() stale=()

  ensure_packages locales || return 1

  # Locales: edit locale.gen, then generate when it changed or a wanted locale
  # is still missing from `locale -a`.
  gen="$(rootpath /etc/locale.gen)"
  tmp="$(mktemp)"
  _locale_gen_render "$gen" >"$tmp"
  install_file "$tmp" "$gen" 0644 || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
  if ((FILE_CHANGED)) || _locale_not_generated; then
    log_change "generate locales: ${_LOCALE_GEN[*]%% *}"
    run_sudo locale-gen || return 1
  fi

  # Defaults: LANG in English, formats in es_CO. update-locale keeps every
  # variable this module does not own (for example LANGUAGE).
  default_file="$(rootpath /etc/default/locale)"
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Z_]+=.+$ ]] || continue
    want+=("$line")
  done <"$conf"
  for line in "${want[@]}"; do
    var="${line%%=*}"
    [[ "$(_locale_value "$default_file" "$var")" == "${line#*=}" ]] || stale+=("$line")
  done
  if ((${#stale[@]} > 0)); then
    log_change "set ${default_file#"${KCS_ROOT:-}"}: ${stale[*]}"
    backup_file "$default_file"
    run_sudo update-locale "${want[@]}" || return 1
  fi

  # The keyboard layout is not touched (the keyboard module owns it). The time
  # zone only changes on request.
  if [[ -n "${LOCALE_TZ:-}" ]]; then
    if [[ ! -e "/usr/share/zoneinfo/$LOCALE_TZ" ]]; then
      log_error "unknown time zone: $LOCALE_TZ"
      return 1
    fi
    if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$LOCALE_TZ" ]]; then
      log_change "set time zone: $LOCALE_TZ"
      run_sudo timedatectl set-timezone "$LOCALE_TZ" || return 1
    fi
  fi
}
