#!/usr/bin/env bash
# modules/15-packages.sh: core everyday desktop and CLI packages from Kali, plus
# Brave (vendor apt repo) and PeaZip (upstream .deb). See specs/packages.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="packages"
# shellcheck disable=SC2034
MODULE_DESC="Core everyday packages (Firefox ESR, CLI tools, fonts, codecs) plus Brave from its vendor repo and PeaZip from its upstream .deb"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# --- Brave: vendor apt repo (Brave's published Debian instructions) ---------
_PACKAGES_BRAVE_REPO_NAME="brave-browser"
_PACKAGES_BRAVE_REPO_URI="https://brave-browser-apt-release.s3.brave.com/"
_PACKAGES_BRAVE_KEY_URL="https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"
_PACKAGES_BRAVE_KEY_DEST="/etc/apt/keyrings/brave-browser-archive-keyring.gpg"
# Full fingerprints of the three "Brave Linux Release" primary keys that Brave's
# keyring file holds (checked on 2026-11-22: the file contains exactly these, and
# keys.openpgp.org publishes the same three). The key is installed only when the
# file matches this set exactly. Brave documents no fingerprint; see the spec.
_PACKAGES_BRAVE_KEY_FPRS="DBF1A116C220B8C7164F98230686B78420038257 47D32A74E9A9E013A4B4926C68D513D36A73CD96 B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0"
# Needed to fetch and verify the key.
_PACKAGES_PREREQS=(gnupg curl ca-certificates)

# --- PeaZip: upstream .deb from the GitHub release --------------------------
# GTK2 build (the Qt6 build would drag Qt into a GTK/COSMIC desktop). The sha256
# is the value in the release's own SHA256.txt (also the GitHub asset digest).
_PACKAGES_PEAZIP_VERSION="11.4.0"
_PACKAGES_PEAZIP_DEB="peazip_${_PACKAGES_PEAZIP_VERSION}.LINUX.GTK2-1_amd64.deb"
_PACKAGES_PEAZIP_URL="https://github.com/peazip/PeaZip/releases/download/${_PACKAGES_PEAZIP_VERSION}/${_PACKAGES_PEAZIP_DEB}"
_PACKAGES_PEAZIP_SHA256="b4ec801e857f232518cfc91d74690d27d35dbf911308b671d5156fc5c631956c"
# The upstream .deb declares no dependencies; its GTK2 binary needs these.
_PACKAGES_PEAZIP_RUNTIME=(libgtk2.0-0t64)

# apt preferences: the first matching record wins, so the allow record for the
# two Brave packages comes first and every other package of the repo is blocked.
_packages_brave_pin() {
  cat <<'PIN'
Explanation: kali-cosmic-setup: only brave-browser and its keyring package may come from the Brave repo
Package: brave-browser brave-keyring
Pin: origin "brave-browser-apt-release.s3.brave.com"
Pin-Priority: 500

Explanation: kali-cosmic-setup: everything else from the Brave repo is blocked, it never replaces a Kali package
Package: *
Pin: origin "brave-browser-apt-release.s3.brave.com"
Pin-Priority: -1
PIN
}

# _packages_brave: key, sources, pin, then the package. The lists are refreshed
# when the repo, its key or its pin changed, or brave-browser has no candidate.
_packages_brave() {
  local before="$CHANGES"
  ensure_packages "${_PACKAGES_PREREQS[@]}" || return 1
  apt_install_key "$_PACKAGES_BRAVE_KEY_URL" "$_PACKAGES_BRAVE_KEY_DEST" \
    "$_PACKAGES_BRAVE_KEY_FPRS" || return 1
  apt_ensure_sources "$_PACKAGES_BRAVE_REPO_NAME" "$_PACKAGES_BRAVE_REPO_URI" stable main \
    "$_PACKAGES_BRAVE_KEY_DEST" || return 1
  apt_ensure_pin "$_PACKAGES_BRAVE_REPO_NAME" "$(_packages_brave_pin)" || return 1
  # Refresh when the repo files changed, or when the lists do not know the
  # package (a failed earlier update, or wiped lists).
  if ((CHANGES > before)) || ! apt_has_candidate brave-browser; then
    apt_update_once --force || return 1
  fi
  ensure_packages brave-browser || return 1
  _packages_brave_untrust
}

# _packages_brave_untrust: brave-keyring's postinst links its key into
# /etc/apt/trusted.gpg.d, which makes it trusted for EVERY repository, wider
# than our Signed-By plus pin. Remove that symlink (it is not in the package's
# file list; every upgrade of brave-keyring recreates it, so this runs on every
# pass). Only a symlink is removed; a regular file there is the admin's and is
# left alone with a warning. A symlink needs no backup.
_packages_brave_untrust() {
  local link
  link="$(rootpath /etc/apt/trusted.gpg.d/brave-browser-release.gpg)"
  if [[ -L "$link" ]]; then
    log_change "remove $link (global apt trust that brave-keyring adds; Signed-By and the pin stay)"
    run_sudo rm -f -- "$link"
  elif [[ -e "$link" ]]; then
    log_warn "$link is a regular file, not the brave-keyring symlink: leaving it alone (it trusts Brave's key for every repository)"
  fi
}

# _packages_sha256_ok <file> <sha256>: true when the file has that SHA-256.
_packages_sha256_ok() {
  printf '%s  %s\n' "$2" "$1" | sha256sum -c --status
}

# _packages_peazip: install the pinned upstream .deb unless this version or a
# newer one is installed. PACKAGES_PEAZIP_SHA256 overrides the pinned checksum
# only when KCS_TEST is set (the tests serve a fixture, not the real .deb); a
# real run always uses the pinned value.
_packages_peazip() {
  local want="$_PACKAGES_PEAZIP_SHA256" cur dir deb rc=0
  if [[ -n "${KCS_TEST:-}" && -n "${PACKAGES_PEAZIP_SHA256:-}" ]]; then
    want="$PACKAGES_PEAZIP_SHA256"
  fi
  cur="$(pkg_version peazip)"
  if pkg_installed peazip && [[ -n "$cur" ]] &&
    dpkg --compare-versions "$cur" ge "$_PACKAGES_PEAZIP_VERSION"; then
    return 0
  fi
  ensure_packages curl ca-certificates || return 1
  if ! pkg_installed "${_PACKAGES_PEAZIP_RUNTIME[0]}"; then
    # The lists may be stale or wiped: the runtime package needs a candidate.
    apt_update_once || return 1
  fi
  ensure_packages "${_PACKAGES_PEAZIP_RUNTIME[@]}" || return 1
  log_change "install peazip $_PACKAGES_PEAZIP_VERSION from the upstream .deb"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download $_PACKAGES_PEAZIP_URL and verify SHA-256 $want"
    return 0
  fi
  dir="$(mktemp -d)"
  deb="$dir/$_PACKAGES_PEAZIP_DEB"
  # apt reads the file as its unprivileged _apt user: the directory must be
  # traversable and the file readable.
  chmod 0755 "$dir"
  download_verified "$_PACKAGES_PEAZIP_URL" "$deb" "$want" || rc=$?
  if ((rc == 0)); then
    chmod 0644 "$deb" 2>/dev/null || true
    # Verify again right before apt reads the file (it sits in a user-owned
    # directory between the download and the install).
    if _packages_sha256_ok "$deb" "$want"; then
      _apt_get_may_fail install "$deb" || rc=$?
    else
      log_error "checksum mismatch: the downloaded .deb changed before it was installed; nothing was installed"
      rc=1
    fi
  fi
  rm -rf -- "$dir"
  if ((rc != 0)); then
    log_error "peazip $_PACKAGES_PEAZIP_VERSION was not installed (exit $rc)"
  fi
  return "$rc"
}

module_apply() {
  install_package_list core || return 1
  _packages_brave || return 1
  _packages_peazip || return 1
}
