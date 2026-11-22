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

# install_file <src> <dest> [mode]: idempotent file install with backup. Sets
# FILE_CHANGED to 1 when it changed (or would change) the file, else 0.
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  FILE_CHANGED=0
  if [[ ! -f "$src" ]]; then
    log_error "install_file: source not found: $src"
    return 1
  fi
  if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
    return 0
  fi
  FILE_CHANGED=1
  log_change "install $dest"
  backup_file "$dest"
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
  if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
    return 0
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

  tmp="$(mktemp)"

  if [[ -f "$file" ]] && grep -qxF -- "$begin" "$file"; then
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
  _priv_run "$file" install -m "$mode" -- "$tmp" "$file"
  rm -f -- "$tmp"
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

# pkg_installed <pkg>: true when dpkg says the package is fully installed.
# A package removed but with config files left is not installed.
pkg_installed() {
  local status
  # shellcheck disable=SC2016  # ${Status} is dpkg-query syntax, not shell
  status="$(dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null)" || return 1
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

# _gpg_primary_fingerprints <file>: print the fingerprint of every primary key
# in a key file (armored or binary), one per line. Uses a throw-away keyring
# directory so nothing is written to ~/.gnupg.
_gpg_primary_fingerprints() {
  local home
  home="$(mktemp -d)"
  GNUPGHOME="$home" gpg --batch --show-keys --with-colons -- "$1" 2>/dev/null |
    awk -F: '/^pub:/ { p = 1; next } p && /^fpr:/ { print $10; p = 0 }' || true
  rm -rf -- "$home"
}

# _key_has_fingerprint <file> <fingerprint>: true when the file holds exactly
# one primary key and its fingerprint equals the expected one.
_key_has_fingerprint() {
  local fprs
  fprs="$(_gpg_primary_fingerprints "$1")"
  [[ -n "$fprs" && "$fprs" == "${2^^}" ]]
}

# apt_install_key <url> <dest> <fingerprint>: install an apt signing key at
# <dest> (for example /etc/apt/keyrings/x.gpg) only after checking that it has
# exactly the expected full fingerprint. An ASCII-armored key is dearmored.
# Needs gpg and curl (or wget); the caller installs gnupg and curl first.
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
  tmp="$(mktemp)"
  keyfile="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" -- "$url" || rc=$?
  else
    wget -q -O "$tmp" -- "$url" || rc=$?
  fi
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
    gpg --batch --yes --dearmor -o "$keyfile" -- "$tmp" || rc=$?
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

# ensure_system_unit_enabled <unit>: enable and start a system unit only when
# its unit file exists and it is not enabled yet. Read-only check.
ensure_system_unit_enabled() {
  local unit="$1"
  system_unit_exists "$unit" || return 0
  if systemctl is-enabled --quiet -- "$unit" >/dev/null 2>&1; then
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
