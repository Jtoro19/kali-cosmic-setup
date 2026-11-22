#!/usr/bin/env bash
# lib/common.sh: shared helpers for install.sh and modules (Kali / apt).
#
# This file is sourced, never executed. It deliberately does not set shell
# options: the caller (install.sh) owns `set -euo pipefail`.

# --- Globals ----------------------------------------------------------------

# Repository root, resolved from this file's location (lib/..).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# 1 = print what would happen, change nothing.
DRY_RUN="${DRY_RUN:-0}"
export DRY_RUN

# Number of changes made (or that would be made in dry-run).
CHANGES=0

# Set by install_file and the helpers built on it: 1 when the last call changed
# (or, in dry-run, would change) a file. Read by modules.
FILE_CHANGED=0
export FILE_CHANGED

# Files already backed up during this process (one backup per file per run).
declare -A _BACKED_UP=()

# --- Logging ----------------------------------------------------------------

_C_RESET="" _C_BLUE="" _C_GREEN="" _C_YELLOW="" _C_RED="" _C_CYAN=""
if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'
  _C_BLUE=$'\033[34m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m'
  _C_CYAN=$'\033[36m'
fi

log_info() { printf '%s[info]%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
log_ok() { printf '%s[ok]%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_error() { printf '%s[error]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }

# Records one change and prints it. When install.sh set _KCS_CHANGES_FILE the
# running count is mirrored there, so a module that fails (and so exits early)
# still reports the changes it made. A module's own EXIT trap cannot lose it.
log_change() {
  CHANGES=$((CHANGES + 1))
  printf '%s[change]%s %s\n' "$_C_CYAN" "$_C_RESET" "$*"
  if [[ -n "${_KCS_CHANGES_FILE:-}" ]]; then
    printf '%s\n' "$CHANGES" >"$_KCS_CHANGES_FILE" 2>/dev/null || true
  fi
}

# --- Command execution ------------------------------------------------------

# Contract: run and run_sudo are FAIL-FAST. A module runs in its own subshell,
# so on a failed command they log it and `exit` with its status, which ends
# only that module. This holds even when the caller is inside `helper || ...`
# (where bash turns errexit off). Use run_may_fail / run_sudo_may_fail at a
# call site that really tolerates failure and handle the status there.

# run_may_fail <cmd...>: execute, or only print in dry-run mode. Returns the
# command's status instead of exiting.
run_may_fail() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

# run <cmd...>: like run_may_fail, but a non-zero status ends the module.
run() {
  local rc=0
  run_may_fail "$@" || rc=$?
  if ((rc != 0)); then
    log_error "command failed (exit $rc): $*"
    exit "$rc"
  fi
}

# run_sudo_may_fail <cmd...>: like run_may_fail, prefixed with sudo. Real runs
# use `sudo -n` so an expired timestamp fails at once instead of prompting
# (install.sh keeps the timestamp fresh after asking for the password once).
run_sudo_may_fail() {
  if [[ "$DRY_RUN" == "1" ]]; then
    run_may_fail sudo "$@"
  else
    run_may_fail sudo -n "$@"
  fi
}

# run_sudo <cmd...>: like run, prefixed with sudo (fail-fast).
run_sudo() {
  local rc=0
  run_sudo_may_fail "$@" || rc=$?
  if ((rc != 0)); then
    log_error "command failed (exit $rc): sudo $*"
    exit "$rc"
  fi
}

# sudo_read <cmd...>: run a read-only command that needs root to see its data
# and print its output; failures print nothing. Real runs try `sudo -n` first
# (never prompts) and then the plain command. With KCS_SKIP_SUDO=1 (test-only,
# same switch as install.sh) sudo is not involved at all, so tests do not
# depend on the host's sudo timestamp or secure_path.
sudo_read() {
  if [[ "${KCS_SKIP_SUDO:-0}" == "1" ]]; then
    "$@" 2>/dev/null
  else
    sudo -n "$@" 2>/dev/null || "$@" 2>/dev/null
  fi
}

# _needs_sudo <path>: true when the path (or its nearest existing parent)
# is not writable by the current user.
_needs_sudo() {
  local p="$1"
  if [[ -e "$p" && ! -w "$p" ]]; then
    return 0
  fi
  while [[ ! -e "$p" ]]; do
    p="$(dirname "$p")"
  done
  [[ -w "$p" ]] && return 1
  return 0
}

# _priv_run <target-path> <cmd...>: run, with sudo only when the target
# location is not writable by the current user.
_priv_run() {
  local target="$1"
  shift
  if _needs_sudo "$target"; then
    run_sudo "$@"
  else
    run "$@"
  fi
}

# _priv_run_tmp <tmp> <target-path> <cmd...>: like _priv_run, for a command that
# installs the temp file <tmp>: the temp file is removed whether the command
# succeeds or fails, and a failure still ends the module (fail-fast, as run).
_priv_run_tmp() {
  local tmp="$1" rc=0
  shift
  (_priv_run "$@") || rc=$?
  rm -f -- "$tmp"
  if ((rc != 0)); then
    exit "$rc"
  fi
}

# --- Files in the invoking user's home ----------------------------------------

# Paths already warned about (one warning per path and run). Kept in the
# caller's shell, so the checks below set _UPATH instead of printing in a
# command substitution.
declare -A _USER_PATH_WARNED=()
_UPATH_HOME="" _UPATH_UID="" _UPATH_USER=""

_user_path_warn_once() { # <path> <message>
  if [[ -z "${_USER_PATH_WARNED[$1]:-}" ]]; then
    _USER_PATH_WARNED["$1"]=1
    log_warn "$2"
  fi
}

# _user_path_check <path>: sets _UPATH to the path to write and returns 0, or
# warns and returns 1 (the caller skips the file). Only paths below $HOME are
# checked; any other path is returned unchanged.
# - A symlink (the file itself or a directory above it) is followed with
#   readlink only when its target is inside $HOME; a target outside is
#   skipped, never replaced by a regular file.
# - Every existing path from the target up to (not including) $HOME must be
#   owned by the invoking user. Files that someone else owns are never written
#   through sudo: install_file and friends would pick sudo for a location the
#   user cannot write, and a file in $HOME that root owns is not ours to rewrite.
_user_path_check() {
  local path="$1" canon plain p i
  local -a chain=() owners=()
  _UPATH="$path"
  if [[ -z "$_UPATH_HOME" ]]; then
    _UPATH_HOME="$(readlink -m -- "$HOME")"
    _UPATH_UID="$(id -u)"
    _UPATH_USER="$(id -un)"
  fi
  canon="$(readlink -m -- "$path")"
  plain="$path"
  case "$path" in
    /*/./* | */../* | *//* | */. | */.. | */) plain="$(realpath -m -s -- "$path")" ;;
    /*) ;;
    *) plain="$(realpath -m -s -- "$path")" ;;
  esac
  if [[ "$plain" != "$_UPATH_HOME"/* && "$plain" != "$_UPATH_HOME" && "$canon" != "$_UPATH_HOME"/* ]]; then
    return 0
  fi
  # The path is $HOME itself: only its owner matters (it is not "below" $HOME).
  if [[ "$canon" == "$_UPATH_HOME" ]]; then
    if [[ "$(stat -c %u -- "$canon" 2>/dev/null)" != "$_UPATH_UID" ]]; then
      _user_path_warn_once "$canon" "$canon is not owned by $_UPATH_USER: not writing anything there (fix it with: sudo chown $_UPATH_USER $canon)"
      return 1
    fi
    return 0
  fi
  if [[ "$canon" != "$_UPATH_HOME"/* ]]; then
    _user_path_warn_once "$plain" "$path is a symlink to $canon, outside $HOME: not writing through it"
    return 1
  fi
  p="$canon"
  while [[ "$p" != "$_UPATH_HOME" && -n "$p" ]]; do
    # readlink -m returns a looping link unresolved: a symlink left in the
    # canonical path means a loop.
    if [[ -L "$p" ]]; then
      _user_path_warn_once "$plain" "$path is, or lies below, a symlink loop: skipping it"
      return 1
    fi
    if [[ -e "$p" ]]; then
      chain+=("$p")
    fi
    p="${p%/*}"
  done
  if ((${#chain[@]} > 0)); then
    mapfile -t owners < <(stat -c %u -- "${chain[@]}" 2>/dev/null)
    for i in "${!chain[@]}"; do
      if [[ "${owners[i]:-}" != "$_UPATH_UID" ]]; then
        _user_path_warn_once "${chain[i]}" "${chain[i]} is not owned by $_UPATH_USER: not writing anything there (fix it with: sudo chown -R $_UPATH_USER ${chain[i]})"
        return 1
      fi
    done
  fi
  if [[ "$canon" != "$plain" ]]; then
    _UPATH="$canon"
  fi
  return 0
}

# user_path_writable <path>: true when this module may write the path: below
# $HOME it is owned by the invoking user (or does not exist yet under a
# directory that is) and any symlink on the way stays inside $HOME. Otherwise
# it warns (once per path) and returns 1. Every helper that writes a file
# calls it, so no module ever writes a file in $HOME through sudo.
user_path_writable() {
  _user_path_check "$1"
}

# user_path_resolve <path>: like user_path_writable, and prints the path to
# write (a symlink resolved to its target inside $HOME, else the path itself).
user_path_resolve() {
  _user_path_check "$1" || return 1
  printf '%s\n' "$_UPATH"
}

# --- File helpers -----------------------------------------------------------

# backup_file <path>: copy to <path>.bak.<YYYYmmdd-HHMMSS>, once per run.
backup_file() {
  local path="$1" ts
  [[ -e "$path" ]] || return 0
  if [[ -n "${_BACKED_UP[$path]:-}" ]]; then
    return 0
  fi
  _BACKED_UP["$path"]=1
  ts="$(date +%Y%m%d-%H%M%S)"
  _priv_run "$path" cp -p -- "$path" "$path.bak.$ts"
}

# install_file <src> <dest> [mode] [nobackup]: idempotent file install with
# backup (the 4th argument "nobackup" skips it, for reproducible artifacts such
# as verified release binaries whose .bak copy would only be a stale executable).
# Sets FILE_CHANGED to 1 when it changed (or would change) the file, else 0.
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}" nobackup="${4:-}"
  FILE_CHANGED=0
  if [[ ! -f "$src" ]]; then
    log_error "install_file: source not found: $src"
    return 1
  fi
  _user_path_check "$dest" || return 0
  dest="$_UPATH"
  if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
    return 0
  fi
  FILE_CHANGED=1
  log_change "install $dest"
  if [[ "$nobackup" != "nobackup" ]]; then
    backup_file "$dest"
  fi
  _priv_run "$dest" mkdir -p -- "$(dirname "$dest")"
  _priv_run "$dest" install -m "$mode" -- "$src" "$dest"
}

# install_template <src.in> <dest> [mode]: render @HOME@ and @USER@ in the
# template into a temp file, then install it with install_file (so backup,
# idempotency and dry-run behave the same). Uses bash parameter expansion, so
# paths with special characters (including "&") are substituted literally.
install_template() {
  local src="$1" dest="$2" mode="${3:-0644}" tmp content rc=0
  if [[ ! -f "$src" ]]; then
    log_error "install_template: source not found: $src"
    return 1
  fi
  tmp="$(mktemp)"
  # The sentinel keeps trailing newlines intact through command substitution.
  content="$(
    cat -- "$src"
    printf x
  )"
  content="${content%x}"
  content="${content//@HOME@/"$HOME"}"
  content="${content//@USER@/"${USER:-$(id -un)}"}"
  printf '%s' "$content" >"$tmp"
  install_file "$tmp" "$dest" "$mode" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# ensure_line <file> <line>: append the line only if not already present.
ensure_line() {
  local file="$1" line="$2" prefix=""
  _user_path_check "$file" || return 0
  file="$_UPATH"
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    return 0
  fi
  # KEY=value with an existing KEY= line of another value: keep it, no duplicate.
  # Only a strict KEY= (shell variable name) counts as a key, and it is matched as
  # a fixed string at the start of a line (no regex).
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= && -f "$file" ]]; then
    local key="${BASH_REMATCH[1]}"
    if awk -v k="$key=" 'index($0, k) == 1 { found = 1 } END { exit !found }' "$file"; then
      log_warn "$file already sets $key to another value: leaving it (wanted: $line)"
      return 0
    fi
  fi
  log_change "add line to $file: $line"
  backup_file "$file"
  _priv_run "$file" mkdir -p -- "$(dirname "$file")"
  if [[ -s "$file" && -n "$(tail -c1 -- "$file")" ]]; then
    prefix=$'\n'
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if _needs_sudo "$file"; then
    printf '%s%s\n' "$prefix" "$line" | sudo -n tee -a -- "$file" >/dev/null
  else
    printf '%s%s\n' "$prefix" "$line" >>"$file"
  fi
}

# ensure_block <file> <marker-name> <content>: manage a delimited block.
ensure_block() {
  local file="$1" name="$2" content="$3"
  local begin="# >>> kali-cosmic-setup:${name} >>>"
  local end="# <<< kali-cosmic-setup:${name} <<<"
  local tmp current mode="0644" action

  _user_path_check "$file" || return 0
  file="$_UPATH"
  tmp="$(mktemp)"

  if [[ -f "$file" ]] && grep -qxF -- "$begin" "$file"; then
    if ! grep -qxF -- "$end" "$file"; then
      rm -f -- "$tmp"
      log_warn "$file has the begin marker of block '$name' but no end marker: malformed, leaving the file untouched (fix or remove the marker line by hand)"
      return 0
    fi
    current="$(awk -v b="$begin" -v e="$end" \
      '$0 == e { f = 0 } f { print } $0 == b { f = 1 }' "$file")"
    if [[ "$current" == "$content" ]]; then
      rm -f -- "$tmp"
      return 0
    fi
    action="update"
    BLOCK="$content" awk -v b="$begin" -v e="$end" '
      $0 == b {
        if (!done) { print b; print ENVIRON["BLOCK"]; print e; done = 1 }
        inblock = 1
        next
      }
      inblock { if ($0 == e) { inblock = 0 } next }
      { print }
    ' "$file" >"$tmp"
  else
    action="add"
    if [[ -f "$file" ]]; then
      cp -- "$file" "$tmp"
      if [[ -s "$tmp" && -n "$(tail -c1 -- "$tmp")" ]]; then
        printf '\n' >>"$tmp"
      fi
    fi
    printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >>"$tmp"
  fi

  if [[ -f "$file" ]]; then
    mode="$(stat -c %a -- "$file")"
  fi
  log_change "$action block '$name' in $file"
  backup_file "$file"
  _priv_run "$file" mkdir -p -- "$(dirname "$file")"
  _priv_run_tmp "$tmp" "$file" install -m "$mode" -- "$tmp" "$file"
}

# --- Paths and system checks ------------------------------------------------

# rootpath <abs-path>: print the path under $KCS_ROOT. KCS_ROOT is a test-only
# prefix (tests/ point it at a temp dir so no real /etc is touched); it is
# empty in a real run, so rootpath returns the path unchanged.
rootpath() {
  printf '%s%s\n' "${KCS_ROOT:-}" "$1"
}

# os_is_debian_like: true when /etc/os-release says ID or ID_LIKE contains
# kali or debian. Reads the file without sourcing it into this shell.
os_is_debian_like() {
  local file ids
  file="$(rootpath /etc/os-release)"
  [[ -r "$file" ]] || return 1
  ids="$(
    # shellcheck source=/dev/null
    . "$file" 2>/dev/null
    printf '%s %s' "${ID:-}" "${ID_LIKE:-}"
  )"
  [[ " $ids " == *" kali "* || " $ids " == *" debian "* ]]
}

# --- Packages (apt) ---------------------------------------------------------

# _apt_get <apt-get args...>: apt-get through sudo, fully non-interactive and
# keeping the admin's configuration files on conffile prompts. `env` carries
# DEBIAN_FRONTEND through sudo's environment reset.
_apt_get() {
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# _apt_get_may_fail <apt-get args...>: like _apt_get but returns the status
# instead of ending the module, for a caller that must clean up first.
_apt_get_may_fail() {
  run_sudo_may_fail env DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# pkg_installed <pkg>: true when dpkg says the package is fully installed.
# A package removed but with config files left is not installed.
pkg_installed() {
  local status
  # shellcheck disable=SC2016  # ${Status} is dpkg-query syntax, not shell
  status="$(LC_ALL=C dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null)" || return 1
  [[ "$status" == "install ok installed" ]]
}

_APT_UPDATED=0

# apt_update_once [--force]: refresh the package lists once per run. --force
# updates again (after a repository, key or pin changed).
apt_update_once() {
  if [[ "${1:-}" != "--force" && "$_APT_UPDATED" == "1" ]]; then
    return 0
  fi
  log_info "refreshing the package lists"
  _apt_get update
  _APT_UPDATED=1
}

# apt_update_may_fail: like apt_update_once but returns the status instead of
# ending the module, for a caller that can carry on with stale lists. A failed
# refresh is not remembered, so a later apt_update_once tries again.
apt_update_may_fail() {
  if [[ "$_APT_UPDATED" == "1" ]]; then
    return 0
  fi
  log_info "refreshing the package lists"
  _apt_get_may_fail update || return $?
  _APT_UPDATED=1
}

# apt_full_upgrade: bring the system up to date (never a partial upgrade).
apt_full_upgrade() {
  log_change "full system upgrade"
  _apt_get full-upgrade
}

# ensure_packages [--no-install-recommends] <pkg...>: install only the missing
# packages. The switch is for packages whose Recommends would pull in things
# this repo deliberately drops.
ensure_packages() {
  local pkg
  local -a missing=() opts=()
  if [[ "${1:-}" == "--no-install-recommends" ]]; then
    opts+=(--no-install-recommends)
    shift
  fi
  for pkg in "$@"; do
    if ! pkg_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  log_change "install packages: ${missing[*]}"
  _apt_get install "${opts[@]}" "${missing[@]}"
}

# apt_has_candidate <pkg>: true when apt knows a version to install. The output
# is captured first: a `grep -q` in a pipe would end apt-cache early and
# pipefail would report that as a failure. LC_ALL=C because apt-cache prints
# "Candidate:" translated otherwise.
apt_has_candidate() {
  local out
  out="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ "$out" =~ Candidate:\ [^\(] ]]
}

# pkg_version <pkg>: print the installed version of a package, nothing when it
# is not installed.
pkg_version() {
  # shellcheck disable=SC2016  # ${Version} is dpkg-query syntax, not shell
  LC_ALL=C dpkg-query -W -f='${Version}' -- "$1" 2>/dev/null || true
}

# _read_package_file <file>: print one package per line, dropping comments
# (whole-line or trailing) and blank lines. Prints nothing when missing.
_read_package_file() {
  [[ -f "$1" ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' -- "$1" | grep -v '^$' || true
}

# install_package_list <group>: install the packages of files/packages/<group>.apt
# (one per line, # comments). Only the missing ones are looked at; one without
# an apt candidate (for example a component that is not enabled) is skipped with
# a warning so the rest still installs. The lists are refreshed once, and only
# when something has to be installed.
install_package_list() {
  local group="$1" file="$REPO_ROOT/files/packages/$1.apt" pkg
  local -a all=() missing=() install=()
  if [[ ! -f "$file" ]]; then
    log_error "install_package_list: no package list for group '$group' ($file)"
    return 1
  fi
  mapfile -t all < <(_read_package_file "$file")
  for pkg in "${all[@]}"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  apt_update_once || return 1
  for pkg in "${missing[@]}"; do
    if apt_has_candidate "$pkg"; then
      install+=("$pkg")
    else
      log_warn "$pkg is not available from apt (is the component enabled in your sources?); skipping it"
    fi
  done
  if ((${#install[@]} == 0)); then
    return 0
  fi
  ensure_packages "${install[@]}"
}

# download_verified <url> <dest> <sha256>: download <url> and install it at
# <dest> only when its SHA-256 equals <sha256> (64 hex digits, any case). An
# empty or malformed checksum is refused before anything is downloaded: there
# is no unverified mode. The download happens in a private temporary directory
# that is always removed. Returns non-zero, leaving <dest> untouched, on a
# download or checksum failure. Dry-run downloads nothing.
download_verified() {
  local url="$1" dest="$2" sum="${3,,}" tmp rc=0
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    log_error "download_verified: refusing $url without a valid SHA-256 checksum"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download $url and verify SHA-256 $sum"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_error "download_verified: curl is required (the desktop module installs it)"
    return 1
  fi
  tmp="$(mktemp -d)"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 \
    --max-time 600 --retry 2 -o "$tmp/download" -- "$url" || rc=$?
  if ((rc != 0)); then
    log_error "cannot download $url (exit $rc)"
    rm -rf -- "$tmp"
    return 1
  fi
  if ! printf '%s  download\n' "$sum" | (cd "$tmp" && sha256sum -c --status); then
    log_error "checksum mismatch for $url: expected SHA-256 $sum, got $(sha256sum "$tmp/download" | awk '{ print $1 }'); nothing was installed"
    rm -rf -- "$tmp"
    return 1
  fi
  mkdir -p -- "$(dirname "$dest")"
  mv -f -- "$tmp/download" "$dest" || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

# _gpg_primary_fingerprints <file>: print the fingerprint of every primary key
# in a key file (armored or binary), one per line. Uses a throw-away keyring
# directory so nothing is written to ~/.gnupg.
_gpg_primary_fingerprints() {
  local home
  home="$(mktemp -d)"
  # LC_ALL=C: the --with-colons record names must not depend on the locale.
  GNUPGHOME="$home" LC_ALL=C gpg --batch --show-keys --with-colons -- "$1" 2>/dev/null |
    awk -F: '/^pub:/ { p = 1; next } p && /^fpr:/ { print $10; p = 0 }' || true
  rm -rf -- "$home"
}

# _key_has_fingerprint <file> <fingerprints>: true when the primary keys in the
# file are exactly the expected ones. <fingerprints> is one full fingerprint or
# several separated by spaces or commas (a vendor keyring that holds more than
# one key); the order does not matter, an extra or a missing key fails.
_key_has_fingerprint() {
  local got want
  got="$(_gpg_primary_fingerprints "$1" | sort | tr '\n' ' ')"
  want="$(printf '%s' "${2^^}" | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
  [[ -n "$got" && "$got" == "$want" ]]
}

# apt_install_key <url> <dest> <fingerprint...>: install an apt signing key at
# <dest> (for example /etc/apt/keyrings/x.gpg) only after checking that it has
# exactly the expected full fingerprint (or, for a keyring holding several
# keys, exactly the expected set, space or comma separated in one argument). An ASCII-armored key is dearmored.
# Needs gpg and curl (https only); the caller installs gnupg and curl first.
# Returns non-zero, installing nothing, on a download or fingerprint failure.
# Idempotent: when <dest> already holds that fingerprint nothing is downloaded.
apt_install_key() {
  local url="$1" dest="$2" fpr="${3^^}" real tmp keyfile rc=0
  real="$(rootpath "$dest")"
  if [[ -f "$real" ]] && _key_has_fingerprint "$real" "$fpr"; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "install key $dest (fingerprint $fpr) from $url"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_error "apt_install_key: curl is required (the desktop module installs it)"
    return 1
  fi
  tmp="$(mktemp)"
  keyfile="$(mktemp)"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 \
    --max-time 600 --retry 2 -o "$tmp" -- "$url" || rc=$?
  if ((rc != 0)); then
    log_error "cannot download the key $url (exit $rc)"
    rm -f -- "$tmp" "$keyfile"
    return 1
  fi
  if ! _key_has_fingerprint "$tmp" "$fpr"; then
    log_error "key fingerprint mismatch for $url: expected $fpr, got '$(_gpg_primary_fingerprints "$tmp" | tr '\n' ' ')'; nothing was installed"
    rm -f -- "$tmp" "$keyfile"
    return 1
  fi
  if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp"; then
    LC_ALL=C gpg --batch --yes --dearmor -o "$keyfile" -- "$tmp" || rc=$?
  else
    cp -- "$tmp" "$keyfile"
  fi
  if ((rc != 0)) || ! _key_has_fingerprint "$keyfile" "$fpr"; then
    log_error "the key from $url did not survive dearmoring intact; nothing was installed"
    rm -f -- "$tmp" "$keyfile"
    return 1
  fi
  log_change "install key $dest (fingerprint $fpr)"
  backup_file "$real"
  _priv_run "$real" mkdir -p -- "$(dirname "$real")"
  _priv_run "$real" install -m 0644 -- "$keyfile" "$real"
  rm -f -- "$tmp" "$keyfile"
}

# ensure_file_content <dest> <content> [mode]: write <content> (plus a final
# newline) to <dest> unless it is already identical. A different existing file
# is backed up first. Dry-run aware.
ensure_file_content() {
  local dest="$1" content="$2" mode="${3:-0644}" tmp rc=0
  tmp="$(mktemp)"
  printf '%s\n' "$content" >"$tmp"
  install_file "$tmp" "$dest" "$mode" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# apt_ensure_sources <name> <uri> <suite> <components> <signed-by>: write the
# deb822 file /etc/apt/sources.list.d/<name>.sources. FILE_CHANGED tells the
# caller whether it changed (so it can run apt_update_once --force).
apt_ensure_sources() {
  local name="$1" uri="$2" suite="$3" comps="$4" key="$5" content
  content="# Managed by kali-cosmic-setup
Types: deb
URIs: $uri
Suites: $suite
Components: $comps
Signed-By: $key"
  ensure_file_content "$(rootpath "/etc/apt/sources.list.d/$name.sources")" "$content"
}

# apt_ensure_pin <name> <content>: write /etc/apt/preferences.d/<name> exactly
# as given (the caller writes the full preferences records). FILE_CHANGED as
# above.
apt_ensure_pin() {
  ensure_file_content "$(rootpath "/etc/apt/preferences.d/$1")" "$2"
}

# --- systemd user units -----------------------------------------------------

user_unit_enabled() {
  systemctl --user is-enabled --quiet "$1" >/dev/null 2>&1
}

ensure_user_unit_enabled() {
  local unit="$1"
  if user_unit_enabled "$unit"; then
    return 0
  fi
  log_change "enable user unit: $unit"
  run systemctl --user daemon-reload
  run systemctl --user enable --now "$unit"
}

# system_unit_exists <unit>: true when systemd knows the unit file.
system_unit_exists() {
  [[ -n "$(systemctl list-unit-files --no-legend -- "$1" 2>/dev/null)" ]]
}

# system_unit_masked <unit>: true when the unit is masked (an admin decision:
# `systemctl enable` fails on it).
system_unit_masked() {
  local state
  state="$(LC_ALL=C systemctl is-enabled -- "$1" 2>/dev/null || true)"
  [[ "$state" == masked* ]]
}

# ensure_system_unit_enabled <unit>: enable and start a system unit only when
# its unit file exists, it is not enabled yet and the admin has not masked it
# (a masked unit is skipped, never unmasked). Read-only check.
ensure_system_unit_enabled() {
  local unit="$1"
  system_unit_exists "$unit" || return 0
  if systemctl is-enabled --quiet -- "$unit" >/dev/null 2>&1; then
    return 0
  fi
  if system_unit_masked "$unit"; then
    log_info "$unit is masked: leaving it alone"
    return 0
  fi
  log_change "enable system unit: $unit"
  run_sudo systemctl enable --now -- "$unit"
}

# ensure_user_in_group <group>: add $USER to an existing group. Takes effect
# after the next login. Read-only check.
ensure_user_in_group() {
  local group="$1"
  getent group "$group" >/dev/null 2>&1 || return 0
  if id -nG "$USER" | tr ' ' '\n' | grep -qx -- "$group"; then
    return 0
  fi
  log_change "add $USER to group $group (re-login needed)"
  run_sudo usermod -aG "$group" "$USER"
}

# --- Hardware detection -----------------------------------------------------

# detect_cpu_vendor: print amd, intel or unknown (from /proc/cpuinfo, which
# KCS_ROOT can redirect in tests).
detect_cpu_vendor() {
  local vendor="" info
  info="$(rootpath /proc/cpuinfo)"
  if [[ -r "$info" ]]; then
    vendor="$(grep -m1 '^vendor_id' "$info" || true)"
  fi
  case "$vendor" in
    *AuthenticAMD*) printf 'amd\n' ;;
    *GenuineIntel*) printf 'intel\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# detect_gpu_vendors: print the space-separated vendors of the display devices
# (amd, intel, nvidia, always in that order), by PCI vendor id: 1002, 8086,
# 10de. Uses lspci; without it, falls back to the vendor files of
# /sys/class/drm/card*/device (0x1002 ...), and warns when neither source
# exists. Empty when there is no such GPU (a VM's virtio GPU is 1af4).
detect_gpu_vendors() {
  local id amd=0 intel=0 nvidia=0 f seen=0
  local -a out=() ids=()
  if command -v lspci >/dev/null 2>&1; then
    mapfile -t ids < <(LC_ALL=C lspci -nn 2>/dev/null | grep -E 'VGA|3D|Display' |
      grep -Eo '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' | tr 'A-F' 'a-f' | cut -c2-5 || true)
    seen=1
  else
    for f in "$(rootpath /sys/class/drm)"/card*/device/vendor; do
      [[ -r "$f" ]] || continue
      seen=1
      id="$(<"$f")"
      id="${id,,}"
      ids+=("${id#0x}")
    done
    if ((!seen)); then
      log_warn "cannot detect the GPU: lspci is missing and /sys/class/drm has no card (install pciutils to enable vendor-specific drivers)"
    fi
  fi
  for id in "${ids[@]}"; do
    case "$id" in
      1002) amd=1 ;;
      8086) intel=1 ;;
      10de) nvidia=1 ;;
      *) ;;
    esac
  done
  if ((amd)); then out+=(amd); fi
  if ((intel)); then out+=(intel); fi
  if ((nvidia)); then out+=(nvidia); fi
  printf '%s\n' "${out[*]:-}"
}

# awk helpers shared by the ensure_ini_line programs: a trailing CR (a CRLF
# file) is ignored when comparing, and a key matches with optional blanks around
# the "=" ("key = value" is the same key as "key=value").
# shellcheck disable=SC2016  # awk program, not shell
_INI_AWK_LIB='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function chomp(s) { if (substr(s, length(s)) == "\r") s = substr(s, 1, length(s) - 1); return s }
function cr(s) { return (substr(s, length(s)) == "\r") ? "\r" : "" }
function keyof(l,   p) { p = index(l, "="); if (!p) return ""; return trim(substr(l, 1, p - 1)) }
function valof(l,   p) { p = index(l, "="); return trim(substr(l, p + 1)) }
BEGIN { sec = ENVIRON["SEC"]; e = ENVIRON["ENTRY"]; k = keyof(e); ev = valof(e) }
'

# ensure_ini_line <file> <section> <key=value>: make sure the key has this value
# under [section]. Creates the file or section when missing. If the key already
# exists with a different value, warn and leave it alone, unless the optional 4th
# argument is "replace", which rewrites that key in place. CRLF files keep their
# line endings; "key = value" counts as key=value. The file is resolved and
# guarded like every user file (see user_path_writable).
# shellcheck disable=SC2016  # awk programs, not shell
ensure_ini_line() {
  local file="$1" section="$2" entry="$3" policy="${4:-keep}" key tmp mode="0644" state
  key="${entry%%=*}"
  _user_path_check "$file" || return 0
  file="$_UPATH"
  if [[ -f "$file" ]]; then
    if ! state="$(SEC="[$section]" ENTRY="$entry" awk "$_INI_AWK_LIB"'
      { line = trim(chomp($0)) }
      line ~ /^\[/ { cur = (line == sec); next }
      cur && keyof(line) == k { print (valof(line) == ev) ? "present" : "conflict"; exit }
    ' "$file")"; then
      log_error "cannot read $file"
      return 1
    fi
    if [[ "$state" == "present" ]]; then
      return 0
    fi
    if [[ "$state" == "conflict" && "$policy" != "replace" ]]; then
      log_warn "$file: key '$key' under [$section] has another value; leaving it"
      return 0
    fi
    tmp="$(mktemp)"
    if [[ "$state" == "conflict" ]]; then
      # policy=replace: rewrite the first matching key in the section.
      SEC="[$section]" ENTRY="$entry" awk "$_INI_AWK_LIB"'
        { line = trim(chomp($0)) }
        line ~ /^\[/ { cur = (line == sec); print; next }
        cur && !done && keyof(line) == k { print e cr($0); done = 1; next }
        { print }
      ' "$file" >"$tmp" || {
        rm -f -- "$tmp"
        return 1
      }
      mode="$(stat -c %a -- "$file")"
      log_change "set '$entry' under [$section] in $file"
      backup_file "$file"
      _priv_run_tmp "$tmp" "$file" install -m "$mode" -- "$tmp" "$file"
      return 0
    fi
    SEC="[$section]" ENTRY="$entry" awk "$_INI_AWK_LIB"'
      { print }
      trim(chomp($0)) == sec && !done { print e cr($0); done = 1; found = 1 }
      END { if (!found) { print ""; print sec; print e } }
    ' "$file" >"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
    mode="$(stat -c %a -- "$file")"
  else
    tmp="$(mktemp)"
    printf '[%s]\n%s\n' "$section" "$entry" >"$tmp"
  fi
  log_change "add '$entry' under [$section] in $file"
  backup_file "$file"
  _priv_run "$file" mkdir -p -- "$(dirname "$file")"
  _priv_run_tmp "$tmp" "$file" install -m "$mode" -- "$tmp" "$file"
}

# --- Login shell and legacy text ---------------------------------------------

# login_shell_name: the name (basename) of the invoking user's login shell, from
# the passwd database (`getent passwd`), not from $SHELL. KCS_LOGIN_SHELL
# replaces it only when KCS_TEST is set (tests simulate zsh and bash).
login_shell_name() {
  local user="${USER:-$(id -un)}" shell=""
  if [[ -n "${KCS_TEST:-}" && -n "${KCS_LOGIN_SHELL:-}" ]]; then
    shell="$KCS_LOGIN_SHELL"
  else
    shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7)" || true
  fi
  printf '%s\n' "${shell##*/}"
}

# login_rc_file: print the interactive rc file of the invoking user's login
# shell: ~/.zshrc for zsh, ~/.bashrc for bash. Any other shell (or none found)
# warns and returns 1, so the caller skips its shell block. The shell itself is
# never changed.
login_rc_file() {
  local name
  name="$(login_shell_name)"
  case "$name" in
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    *)
      log_warn "login shell '${name:-unknown}' is not zsh or bash: not writing a shell block (this repo never changes your shell)"
      return 1
      ;;
  esac
}

# remove_line <file> <exact-line> [preceding-line]: remove every occurrence of
# the exact line found OUTSIDE kali-cosmic-setup managed blocks. When
# preceding-line is given, the line immediately above is removed too if it
# matches exactly. Backs up first; counts as one change; dry-run aware.
remove_line() {
  local file="$1" line="$2" prev="${3:-}" tmp mode
  [[ -f "$file" ]] || return 0
  _user_path_check "$file" || return 0
  file="$_UPATH"
  tmp="$(mktemp)"
  LINE="$line" PREV="$prev" awk '
    BEGIN { line = ENVIRON["LINE"]; prev = ENVIRON["PREV"] }
    /^# >>> kali-cosmic-setup:/ { inb = 1 }
    { n++; txt[n] = $0; blk[n] = inb }
    /^# <<< kali-cosmic-setup:/ { inb = 0 }
    END {
      for (i = 1; i <= n; i++) del[i] = 0
      for (i = 1; i <= n; i++) {
        if (!blk[i] && txt[i] == line) {
          del[i] = 1
          if (prev != "" && i > 1 && !blk[i-1] && txt[i-1] == prev) del[i-1] = 1
        }
      }
      for (i = 1; i <= n; i++) if (!del[i]) print txt[i]
    }
  ' "$file" >"$tmp"
  if cmp -s -- "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  mode="$(stat -c %a -- "$file")"
  log_change "remove legacy line from $file: $line"
  backup_file "$file"
  _priv_run_tmp "$tmp" "$file" install -m "$mode" -- "$tmp" "$file"
}

# remove_exact_block <file> <multiline-text>: remove the first exact contiguous
# occurrence of the given lines found OUTSIDE kali-cosmic-setup managed blocks.
# Other occurrences are kept. Backs up first; counts as one change; dry-run
# aware. Does nothing when the file or the text is missing.
remove_exact_block() {
  local file="$1" text="$2" tmp mode
  [[ -f "$file" && -n "$text" ]] || return 0
  _user_path_check "$file" || return 0
  file="$_UPATH"
  tmp="$(mktemp)"
  TEXT="$text" awk '
    BEGIN { m = split(ENVIRON["TEXT"], pat, "\n") }
    /^# >>> kali-cosmic-setup:/ { inb = 1 }
    { n++; txt[n] = $0; blk[n] = inb }
    /^# <<< kali-cosmic-setup:/ { inb = 0 }
    END {
      start = 0
      for (i = 1; i + m - 1 <= n && !start; i++) {
        ok = 1
        for (j = 1; j <= m; j++) {
          if (blk[i+j-1] || txt[i+j-1] != pat[j]) { ok = 0; break }
        }
        if (ok) start = i
      }
      for (i = 1; i <= n; i++) {
        if (start && i >= start && i < start + m) continue
        print txt[i]
      }
    }
  ' "$file" >"$tmp"
  if cmp -s -- "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  mode="$(stat -c %a -- "$file")"
  log_change "remove legacy block from $file: ${text%%$'\n'*} ..."
  backup_file "$file"
  _priv_run_tmp "$tmp" "$file" install -m "$mode" -- "$tmp" "$file"
}

# user_systemd_ready: true when `systemctl --user` can reach the invoking user's
# manager (a graphical or lingering session). Points XDG_RUNTIME_DIR at
# /run/user/<uid> when it is unset (SSH without pam_systemd). Callers skip the
# enable/start of a user unit when this is false (the unit files are still
# written) and say so.
user_systemd_ready() {
  if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$(id -u)" ]]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi
  systemctl --user show-environment >/dev/null 2>&1
}

# --- GSettings --------------------------------------------------------------

# _GSETTINGS_PREFIX: command words that put gsettings on a session bus, set by
# _gsettings_prepare (empty when the environment already has one).
_GSETTINGS_PREFIX=()

# _gsettings_prepare: find a way to reach a session bus for gsettings/dconf.
# 1. DBUS_SESSION_BUS_ADDRESS is set (a desktop session): use it as it is.
# 2. $XDG_RUNTIME_DIR/bus exists (SSH to a user whose systemd user manager runs,
#    for example a logged-in COSMIC user): point DBUS_SESSION_BUS_ADDRESS at it,
#    so the values land where the live session reads them.
# 3. Otherwise (a TTY or SSH login without a user bus): run gsettings under
#    `dbus-run-session`, a private bus that starts dconf-service, which writes
#    ~/.config/dconf/user; sessions that start later (or are running: dconf
#    watches the file) read it. gsettings syncs before it exits, so the daemon
#    going away with the private bus loses nothing. GIO_USE_VFS=local keeps the
#    GVfs modules out: on a private bus they would activate gvfsd-fuse and other
#    daemons that outlive the command and keep its output pipe open.
# Returns 1 when none of these exists.
_gsettings_prepare() {
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  _GSETTINGS_PREFIX=()
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    return 0
  fi
  if [[ -S "$rt/bus" ]]; then
    _GSETTINGS_PREFIX=(env "DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus")
    return 0
  fi
  if command -v dbus-run-session >/dev/null 2>&1; then
    _GSETTINGS_PREFIX=(env GIO_USE_VFS=local dbus-run-session --)
    return 0
  fi
  return 1
}

# _gsettings_get <schema> <key>: sets _GS_VALUE to the printed value; returns
# gsettings' status. The value goes through a file, not a command substitution:
# a daemon that outlives gsettings and holds a pipe open would block the
# substitution. Every gsettings call is cut off after 20 seconds (a missing or
# hung dconf service must not hang the install) and reads no terminal input.
_gsettings_get() {
  local tmp rc=0
  tmp="$(mktemp)"
  timeout -k 5 "${KCS_GSETTINGS_TIMEOUT:-20}" "${_GSETTINGS_PREFIX[@]}" gsettings get "$1" "$2" >"$tmp" 2>/dev/null </dev/null || rc=$?
  _GS_VALUE="$(<"$tmp")"
  rm -f -- "$tmp"
  return "$rc"
}

# _gsettings_run <args...>: gsettings with the timeout, no input and no output
# (the status is what counts).
_gsettings_run() {
  timeout -k 5 "${KCS_GSETTINGS_TIMEOUT:-20}" "${_GSETTINGS_PREFIX[@]}" gsettings "$@" </dev/null >/dev/null 2>&1
}

# ensure_gsetting <schema> <key> <value>: set a GSettings key only when the
# current value differs. <value> uses gsettings' printed form (strings keep
# their single quotes, for example "'prefer-dark'"). Without gsettings, a way to
# reach a session bus (see _gsettings_prepare) or the schema, warn and skip
# without failing. A failing set is a warning, not a module failure, and the
# value is read back after the set: a backend that accepts the write and drops
# it (no dconf service behind the bus) is reported. The read is side-effect
# free, so dry-run is accurate.
ensure_gsetting() {
  local schema="$1" key="$2" value="$3" current
  if ! command -v gsettings >/dev/null 2>&1; then
    log_warn "gsettings not found; skipping $schema $key"
    return 0
  fi
  if ! _gsettings_prepare; then
    log_warn "no session bus and no dbus-run-session; skipping gsettings $schema $key (run it from a desktop session, or install dbus-bin)"
    return 0
  fi
  if ! _gsettings_get "$schema" "$key"; then
    log_warn "cannot read gsettings $schema $key; skipping"
    return 0
  fi
  current="$_GS_VALUE"
  if [[ "$current" == "$value" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "gsettings set $schema $key $value (was $current)"
    printf '[dry-run] would run: gsettings set %s %s %s\n' "$schema" "$key" "$value"
    return 0
  fi
  if ! run_may_fail _gsettings_run set "$schema" "$key" "$value"; then
    log_warn "gsettings set $schema $key $value failed or timed out; leaving it"
    return 0
  fi
  log_change "gsettings set $schema $key $value (was $current)"
  if ! _gsettings_get "$schema" "$key" || [[ "$_GS_VALUE" != "$value" ]]; then
    log_warn "gsettings $schema $key reads ${_GS_VALUE:-nothing} after the set: the value did not persist (is a dconf service running for this session?)"
  fi
}
