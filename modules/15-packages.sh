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

# --- Browsers in a virtual machine: run as X11 clients ------------------------
# In a VM with a virtual display (display_is_virtual: a hypervisor and no
# physical GPU) Chromium and Brave can crash as native Wayland clients on COSMIC
# (see specs/packages.md). Only there (never on bare metal) Chromium gets a
# /etc/chromium.d drop-in and Brave a generated desktop entry in
# /usr/local/share/applications that wins over the packaged one. Both carry the
# marker, which is how the module recognises them. The virtio-only version of
# this workaround used another marker and drop-in name: both are still
# recognised as ours and the old drop-in is removed.
_PACKAGES_VGPU_MARKER="kali-cosmic-setup: virtual-gpu browser workaround"
_PACKAGES_VGPU_OLD_MARKER="kali-cosmic-setup: virtio-gpu browser workaround"
_PACKAGES_VGPU_FLAG="--ozone-platform=x11"
_PACKAGES_VGPU_CHROMIUM="/etc/chromium.d/kali-cosmic-setup-virtual-gpu"
_PACKAGES_VGPU_OLD_CHROMIUM="/etc/chromium.d/kali-cosmic-setup-virtio-gpu"
_PACKAGES_VGPU_BRAVE_SRC="/usr/share/applications/brave-browser.desktop"
_PACKAGES_VGPU_BRAVE_DEST="/usr/local/share/applications/brave-browser.desktop"

# _packages_vgpu_drop <path> <content>: on a virtual display, make <path> hold
# <content>; otherwise remove it. An empty <content> also means "remove". A
# file without either marker is not ours: it is left alone (never replaced)
# with a warning. Sets FILE_CHANGED like ensure_file_content.
_packages_vgpu_drop() {
  local path="$1" content="$2" real
  real="$(rootpath "$path")"
  FILE_CHANGED=0
  if [[ -e "$real" ]] && ! grep -qF -e "$_PACKAGES_VGPU_MARKER" -e "$_PACKAGES_VGPU_OLD_MARKER" "$real"; then
    if [[ -n "$content" ]]; then
      log_warn "$path exists without the kali-cosmic-setup marker: leaving it alone (the virtual-gpu browser workaround is not applied through it)"
    else
      log_warn "$path exists without the kali-cosmic-setup marker: not ours, leaving it alone"
    fi
    return 0
  fi
  if [[ -n "$content" ]]; then
    ensure_file_content "$real" "$content"
  elif [[ -e "$real" ]]; then
    FILE_CHANGED=1
    log_change "remove $path (browser workaround, not needed here)"
    _priv_run "$real" rm -f -- "$real"
  fi
}

# _packages_brave_x11_entry: print the packaged Brave desktop entry with the
# flag after the executable of every Exec= line, behind the marker comment.
_packages_brave_x11_entry() {
  local src line group="" exe main_exe has_tryexec=0 skipped=0
  src="$(rootpath "$_PACKAGES_VGPU_BRAVE_SRC")"
  # The main group's executable, for a TryExec: if Brave is removed, launchers
  # and the MIME lookup hide this copy instead of offering a dead entry.
  main_exe="$(awk '/^\[/ { g = $0 } g == "[Desktop Entry]" && /^Exec=/ { sub(/^Exec=/, ""); split($0, a, " "); print a[1]; exit }' "$src")"
  awk '/^\[/ { g = $0 } g == "[Desktop Entry]" && /^TryExec=/ { f = 1 } END { exit !f }' "$src" && has_tryexec=1
  printf '# %s: generated from %s\n' "$_PACKAGES_VGPU_MARKER" "$_PACKAGES_VGPU_BRAVE_SRC"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == \[*\] ]]; then
      group="$line"
      printf '%s\n' "$line"
      if [[ "$group" == "[Desktop Entry]" ]] && ((!has_tryexec)) && _packages_plain_exe "$main_exe"; then
        printf 'TryExec=%s\n' "$main_exe"
      fi
      continue
    fi
    if [[ "$line" == Exec=* ]]; then
      exe="${line#Exec=}"
      exe="${exe%% *}"
      if _packages_plain_exe "$exe"; then
        line="Exec=$exe $_PACKAGES_VGPU_FLAG${line#"Exec=$exe"}"
      else
        skipped=1
      fi
    fi
    printf '%s\n' "$line"
  done <"$src"
  if ((skipped)); then
    log_warn "$_PACKAGES_VGPU_BRAVE_SRC has an Exec line that does not start with a plain program path (quoted or env): left without $_PACKAGES_VGPU_FLAG"
  fi
}

# _packages_plain_exe <word>: a program path the flag can safely follow (not
# empty, not quoted, not `env` or a VAR=value assignment).
_packages_plain_exe() {
  [[ -n "$1" && "$1" != \"* && "$1" != env && "$1" != *=* ]]
}

_packages_browsers_vgpu() {
  local chromium="" brave="" changed=0 dir
  if display_is_virtual; then
    chromium="# $_PACKAGES_VGPU_MARKER: Chromium can crash as a native Wayland client in a virtual machine
export CHROMIUM_FLAGS=\"\$CHROMIUM_FLAGS $_PACKAGES_VGPU_FLAG\""
    if [[ -f "$(rootpath "$_PACKAGES_VGPU_BRAVE_SRC")" ]]; then
      brave="$(_packages_brave_x11_entry)"
    fi
  fi
  _packages_vgpu_drop "$_PACKAGES_VGPU_OLD_CHROMIUM" ""
  ((FILE_CHANGED)) && changed=1
  _packages_vgpu_drop "$_PACKAGES_VGPU_CHROMIUM" "$chromium"
  ((FILE_CHANGED)) && changed=1
  _packages_vgpu_drop "$_PACKAGES_VGPU_BRAVE_DEST" "$brave"
  ((FILE_CHANGED)) && changed=1
  if ((changed)) && command -v update-desktop-database >/dev/null 2>&1; then
    dir="$(dirname "$(rootpath "$_PACKAGES_VGPU_BRAVE_DEST")")"
    if [[ -d "$dir" ]]; then
      if _needs_sudo "$dir"; then
        run_sudo_may_fail update-desktop-database "$dir" || true
      else
        run_may_fail update-desktop-database "$dir" || true
      fi
    fi
  fi
  return 0
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
  local want="$_PACKAGES_PEAZIP_SHA256" cur dir deb rdeb rt rc=0
  if [[ -n "${KCS_TEST:-}" && -n "${PACKAGES_PEAZIP_SHA256:-}" ]]; then
    want="$PACKAGES_PEAZIP_SHA256"
  fi
  cur="$(pkg_version peazip)"
  if pkg_installed peazip && [[ -n "$cur" ]] &&
    dpkg --compare-versions "$cur" ge "$_PACKAGES_PEAZIP_VERSION"; then
    return 0
  fi
  ensure_packages curl ca-certificates || return 1
  for rt in "${_PACKAGES_PEAZIP_RUNTIME[@]}"; do
    if ! pkg_installed "$rt"; then
      # The lists may be stale or wiped: a runtime package needs a candidate.
      apt_update_once || return 1
      break
    fi
  done
  ensure_packages "${_PACKAGES_PEAZIP_RUNTIME[@]}" || return 1
  log_change "install peazip $_PACKAGES_PEAZIP_VERSION from the upstream .deb"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download $_PACKAGES_PEAZIP_URL and verify SHA-256 $want"
    return 0
  fi
  # The download lands in a private (0700) directory of the invoking user. Root
  # never installs from there: the verified file is copied into a root-owned
  # directory, verified again there, and apt installs that copy. The root-owned
  # directory is 0755 and the copy 0644 so apt's unprivileged _apt user can
  # read it.
  dir="$(mktemp -d)"
  _PACKAGES_TMP_USER="$dir"
  chmod 0700 "$dir"
  deb="$dir/$_PACKAGES_PEAZIP_DEB"
  download_verified "$_PACKAGES_PEAZIP_URL" "$deb" "$want" || rc=$?
  if ((rc == 0)); then
    _PACKAGES_TMP_ROOT="$(run_sudo_may_fail mktemp -d)" || rc=$?
  fi
  if ((rc == 0)); then
    run_sudo_may_fail chmod 0755 "$_PACKAGES_TMP_ROOT" || rc=$?
    rdeb="$_PACKAGES_TMP_ROOT/$_PACKAGES_PEAZIP_DEB"
  fi
  if ((rc == 0)); then
    run_sudo_may_fail install -m0644 "$deb" "$rdeb" || rc=$?
  fi
  if ((rc == 0)); then
    if _packages_sha256_ok "$rdeb" "$want"; then
      _apt_get_may_fail install "$rdeb" || rc=$?
    else
      log_error "checksum mismatch: the copy of the .deb changed before it was installed; nothing was installed"
      rc=1
    fi
  fi
  _packages_cleanup
  if ((rc != 0)); then
    log_error "peazip $_PACKAGES_PEAZIP_VERSION was not installed (exit $rc)"
  fi
  return "$rc"
}

# _packages_cleanup: remove the user temp dir and the root-owned staging dir of
# the PeaZip install. It runs at the end of the install and as the EXIT trap of
# this module, because a fail-fast helper or a signal ends the module with exit
# and the staging dir would stay behind in /tmp. Safe to call twice.
_packages_cleanup() {
  if [[ -n "${_PACKAGES_TMP_ROOT:-}" ]]; then
    run_sudo_may_fail rm -rf -- "$_PACKAGES_TMP_ROOT" || true
    _PACKAGES_TMP_ROOT=""
  fi
  if [[ -n "${_PACKAGES_TMP_USER:-}" ]]; then
    rm -rf -- "$_PACKAGES_TMP_USER"
    _PACKAGES_TMP_USER=""
  fi
}

module_apply() {
  _PACKAGES_TMP_USER=""
  _PACKAGES_TMP_ROOT=""
  trap _packages_cleanup EXIT
  install_package_list core || return 1
  _packages_brave || return 1
  _packages_browsers_vgpu || return 1
  _packages_peazip || return 1
}
