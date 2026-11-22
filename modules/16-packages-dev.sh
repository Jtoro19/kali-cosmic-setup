#!/usr/bin/env bash
# modules/16-packages-dev.sh: development tools. Kali packages, VS Code and
# Claude Code from their vendors' signed apt repos, uv, engram and gentle-ai from
# checksum-verified GitHub releases; enables Docker and MariaDB (localhost
# only). See specs/packages-dev.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="packages-dev"
# shellcheck disable=SC2034
MODULE_DESC="Development tools (Kali toolchains, VS Code, Claude Code, uv, engram, gentle-ai, Docker and MariaDB on localhost)"
# shellcheck disable=SC2034
MODULE_OPTIN=1
# shellcheck disable=SC2034
MODULE_DEPS="packages"

# Needed to fetch and verify the keys and the release archives.
_PD_PREREQS=(gnupg curl ca-certificates)

# --- Vendor apt repos -------------------------------------------------------
# One record each: name, uri, suite, key url, key dest, key fingerprint, the one
# package the repo may provide, the host the pin matches.
# VS Code: https://code.visualstudio.com/docs/setup/linux (the docs give no
# fingerprint; read with gpg --show-keys on 2026-11-22).
_PD_VSCODE_NAME="vscode"
_PD_VSCODE_URI="https://packages.microsoft.com/repos/code"
_PD_VSCODE_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
_PD_VSCODE_KEY_DEST="/etc/apt/keyrings/packages.microsoft.gpg"
_PD_VSCODE_KEY_FPR="BC528686B50D79E339D3721CEB3E94ADBE1229CF"
_PD_VSCODE_HOST="packages.microsoft.com"
# Claude Code: Anthropic's signed apt repo, documented at
# https://code.claude.com/docs/en/setup (the official key fingerprint is printed
# there and matches the downloaded key).
_PD_CLAUDE_NAME="claude-code"
_PD_CLAUDE_URI="https://downloads.claude.ai/claude-code/apt/stable"
_PD_CLAUDE_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
_PD_CLAUDE_KEY_DEST="/etc/apt/keyrings/claude-code.gpg"
_PD_CLAUDE_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
_PD_CLAUDE_HOST="downloads.claude.ai"

# --- Release binaries (system scope, /usr/local/bin) ------------------------
# The sha256 of each archive is the value in the release's own checksum file;
# it also equals the digest GitHub computes for the asset.
_PACKAGES_DEV_UV_VERSION="0.13.9"
_PACKAGES_DEV_UV_ARCHIVE="uv-x86_64-unknown-linux-gnu.tar.gz"
_PACKAGES_DEV_UV_URL="https://github.com/astral-sh/uv/releases/download/${_PACKAGES_DEV_UV_VERSION}/${_PACKAGES_DEV_UV_ARCHIVE}"
_PACKAGES_DEV_UV_SHA256="a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5"
_PACKAGES_DEV_ENGRAM_VERSION="3.7.2"
_PACKAGES_DEV_ENGRAM_ARCHIVE="engram_${_PACKAGES_DEV_ENGRAM_VERSION}_linux_amd64.tar.gz"
_PACKAGES_DEV_ENGRAM_URL="https://github.com/Gentleman-Programming/engram/releases/download/v${_PACKAGES_DEV_ENGRAM_VERSION}/${_PACKAGES_DEV_ENGRAM_ARCHIVE}"
_PACKAGES_DEV_ENGRAM_SHA256="8db9d5db1c1574b8b830aac4ffbe86c024014aed6b9a3f0406ac3361a152cdf0"
_PACKAGES_DEV_GENTLE_AI_VERSION="4.6.0"
_PACKAGES_DEV_GENTLE_AI_ARCHIVE="gentle-ai_${_PACKAGES_DEV_GENTLE_AI_VERSION}_linux_amd64.tar.gz"
_PACKAGES_DEV_GENTLE_AI_URL="https://github.com/Gentleman-Programming/gentle-ai/releases/download/v${_PACKAGES_DEV_GENTLE_AI_VERSION}/${_PACKAGES_DEV_GENTLE_AI_ARCHIVE}"
_PACKAGES_DEV_GENTLE_AI_SHA256="c645e8551f6e3f79831b142a6b087795dc3217e02e9dafb5b701dc4373b33e7d"

_PD_BIN_DIR="/usr/local/bin"
_PD_MARIADB_DROPIN="/etc/mysql/mariadb.conf.d/99-kali-cosmic-localhost.cnf"

# _pd_pin <package> <host>: apt preferences. The first matching record wins, so
# the allow record for the one package comes first and every other package of
# the repo is blocked: the repo can never replace a Kali package.
_pd_pin() {
  cat <<PIN
Explanation: kali-cosmic-setup: only $1 may come from $2
Package: $1
Pin: origin "$2"
Pin-Priority: 500

Explanation: kali-cosmic-setup: everything else from $2 is blocked, it never replaces a Kali package
Package: *
Pin: origin "$2"
Pin-Priority: -1
PIN
}

# _pd_repo <name> <uri> <key-url> <key-dest> <fingerprint> <package> <host>: key
# (fingerprint-checked), deb822 sources file and pin. Sets _PD_REPO_CHANGED=1
# when any of them changed.
_pd_repo() {
  local name="$1" uri="$2" key_url="$3" key_dest="$4" fpr="$5" pkg="$6" host="$7" before="$CHANGES"
  apt_install_key "$key_url" "$key_dest" "$fpr" || return 1
  apt_ensure_sources "$name" "$uri" stable main "$key_dest" || return 1
  apt_ensure_pin "$name" "$(_pd_pin "$pkg" "$host")" || return 1
  if ((CHANGES > before)); then
    _PD_REPO_CHANGED=1
  fi
}

# _pd_vendor_packages: both vendor repos, one refresh of the lists, then the
# packages. The lists are refreshed when a repo, key or pin changed, or when a
# package has no candidate (a failed earlier update, or wiped lists).
_pd_vendor_packages() {
  _PD_REPO_CHANGED=0
  ensure_packages "${_PD_PREREQS[@]}" || return 1
  _pd_repo "$_PD_VSCODE_NAME" "$_PD_VSCODE_URI" "$_PD_VSCODE_KEY_URL" "$_PD_VSCODE_KEY_DEST" \
    "$_PD_VSCODE_KEY_FPR" code "$_PD_VSCODE_HOST" || return 1
  _pd_repo "$_PD_CLAUDE_NAME" "$_PD_CLAUDE_URI" "$_PD_CLAUDE_KEY_URL" "$_PD_CLAUDE_KEY_DEST" \
    "$_PD_CLAUDE_KEY_FPR" claude-code "$_PD_CLAUDE_HOST" || return 1
  if ((_PD_REPO_CHANGED)) || ! apt_has_candidate code || ! apt_has_candidate claude-code; then
    apt_update_once --force || return 1
  fi
  _pd_preseed_code || return 1
  ensure_packages code claude-code || return 1
  _pd_code_untrust
}

# _pd_preseed_code: the code deb's postinst adds Microsoft's repo and key unless
# debconf says false. We manage the repo ourselves (Signed-By, pin), so answer
# false BEFORE every install or upgrade of the package.
_pd_preseed_code() {
  if LC_ALL=C debconf-show code 2>/dev/null | grep -q 'code/add-microsoft-repo: false'; then
    return 0
  fi
  log_change "debconf: code/add-microsoft-repo = false (the deb must not add its own repo or key)"
  run_sudo debconf-set-selections <<<"code code/add-microsoft-repo boolean false"
}

# _pd_code_untrust: with the answer preseeded the deb adds nothing (checked on
# the VM). Should a future deb still drop Microsoft's key into trusted.gpg.d
# (trusted for every repository, wider than our Signed-By and pin), remove it,
# like the Brave case in the packages module. The keyring a deb may leave in
# /usr/share/keyrings is inert without a sources file that names it, and other
# Microsoft repos may use it, so it is left alone.
_pd_code_untrust() {
  local f
  f="$(rootpath /etc/apt/trusted.gpg.d/microsoft.gpg)"
  if [[ -e "$f" || -L "$f" ]]; then
    log_change "remove $f (global apt trust that the code deb adds; Signed-By and the pin stay)"
    run_sudo rm -f -- "$f"
  fi
}

# --- uv, engram, gentle-ai --------------------------------------------------
_pd_sha256_ok() {
  printf '%s  %s\n' "$2" "$1" | sha256sum -c --status
}

# _pd_bin_version <path>: the version a binary reports ("<name> <version> ...").
_pd_bin_version() {
  [[ -x "$1" ]] || return 0
  LC_ALL=C "$1" --version 2>/dev/null | awk 'NR == 1 { print $2 }' || true
}

# _pd_release <name> <version> <url> <sha256> <archive> <member=bin>...: install
# the binaries of a pinned GitHub release into /usr/local/bin. The first binary
# is the version probe. Skipped when it reports the pinned version or newer, and
# every binary exists, so a newer one is never downgraded. A PACKAGES_DEV_<NAME>_SHA256
# in the environment replaces the pinned checksum only when KCS_TEST is set (the
# tests serve fixtures); a real run always uses the pinned value.
_pd_release() {
  local name="$1" version="$2" url="$3" sum="$4" archive="$5" pair member bin cur dir rc=0
  local ovar="PACKAGES_DEV_${name^^}_SHA256"
  local -a pairs=("${@:6}") members=() dests=()
  ovar="${ovar//-/_}"
  if [[ -n "${KCS_TEST:-}" && -n "${!ovar:-}" ]]; then
    sum="${!ovar}"
  fi
  for pair in "${pairs[@]}"; do
    members+=("${pair%%=*}")
    dests+=("$(rootpath "$_PD_BIN_DIR/${pair#*=}")")
  done
  cur="$(_pd_bin_version "${dests[0]}")"
  if [[ -n "$cur" ]] && dpkg --compare-versions "$cur" ge "$version"; then
    local all=1
    for bin in "${dests[@]}"; do [[ -x "$bin" ]] || all=0; done
    ((all)) && return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "install $name $version into $_PD_BIN_DIR"
    log_info "[dry-run] would download $url and verify SHA-256 $sum"
    return 0
  fi
  ensure_packages curl ca-certificates || return 1
  dir="$(mktemp -d)"
  download_verified "$url" "$dir/$archive" "$sum" || rc=$?
  if ((rc == 0)); then
    # Verify again right before extracting (the directory is user-owned).
    if _pd_sha256_ok "$dir/$archive" "$sum"; then
      tar -xzf "$dir/$archive" -C "$dir" --no-same-owner -- "${members[@]}" || rc=$?
    else
      log_error "checksum mismatch: the downloaded $name archive changed before it was unpacked; nothing was installed"
      rc=1
    fi
  fi
  if ((rc == 0)); then
    local i
    for i in "${!members[@]}"; do
      install_file "$dir/${members[$i]}" "${dests[$i]}" 0755 || rc=$?
    done
  fi
  rm -rf -- "$dir"
  if ((rc != 0)); then
    log_error "$name $version was not installed (exit $rc)"
  fi
  return "$rc"
}

_pd_release_tools() {
  _pd_release uv "$_PACKAGES_DEV_UV_VERSION" "$_PACKAGES_DEV_UV_URL" "$_PACKAGES_DEV_UV_SHA256" \
    "$_PACKAGES_DEV_UV_ARCHIVE" uv-x86_64-unknown-linux-gnu/uv=uv uv-x86_64-unknown-linux-gnu/uvx=uvx || return 1
  _pd_release engram "$_PACKAGES_DEV_ENGRAM_VERSION" "$_PACKAGES_DEV_ENGRAM_URL" "$_PACKAGES_DEV_ENGRAM_SHA256" \
    "$_PACKAGES_DEV_ENGRAM_ARCHIVE" engram=engram || return 1
  _pd_release gentle-ai "$_PACKAGES_DEV_GENTLE_AI_VERSION" "$_PACKAGES_DEV_GENTLE_AI_URL" \
    "$_PACKAGES_DEV_GENTLE_AI_SHA256" "$_PACKAGES_DEV_GENTLE_AI_ARCHIVE" gentle-ai=gentle-ai
}

# --- Services: localhost only -----------------------------------------------
# _pd_mariadb: bind to 127.0.0.1 in a drop-in (read after 50-server.cnf, so it
# wins) BEFORE the server is started; an already running server is restarted
# once so the binding applies.
_pd_mariadb() {
  local unit=mariadb.service
  ensure_file_content "$(rootpath "$_PD_MARIADB_DROPIN")" "# Managed by kali-cosmic-setup: MariaDB listens on localhost only.
[mysqld]
bind-address = 127.0.0.1" || return 1
  if ((FILE_CHANGED)) && system_unit_exists "$unit" && systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
    log_change "restart $unit (the localhost binding applies)"
    run_sudo systemctl restart -- "$unit"
  fi
  ensure_system_unit_enabled "$unit"
}

_pd_services() {
  _pd_mariadb || return 1
  # Docker listens on its unix socket only (the module writes no daemon.json
  # and no tcp host).
  ensure_system_unit_enabled docker.service || return 1
  # Both groups take effect after the next login. docker is root-equivalent
  # (see the spec). plugdev is the group of Kali's android-udev-rules.
  ensure_user_in_group docker || return 1
  ensure_user_in_group plugdev
}

module_apply() {
  install_package_list dev || return 1
  _pd_vendor_packages || return 1
  _pd_release_tools || return 1
  _pd_services || return 1
}
