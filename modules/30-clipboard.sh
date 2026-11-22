#!/usr/bin/env bash
# modules/30-clipboard.sh: persistent Wayland clipboard on COSMIC. wl-clipboard
# from Kali, wl-clip-persist built from a pinned upstream tag (it is not packaged
# in Kali or Debian), the COSMIC data-control environment line and a user unit.
# See specs/clipboard.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="clipboard"
# shellcheck disable=SC2034
MODULE_DESC="persistent clipboard: wl-clipboard, wl-clip-persist (built from the pinned upstream tag), COSMIC data-control env var, user service"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Pin: tag v0.5.0 of Linus789/wl-clip-persist is a lightweight tag on this
# commit (GitHub API git/ref/tags/v0.5.0). Upstream publishes no binary and no
# checksum, so the build is of the exact commit below, with the repository's own
# Cargo.lock (--locked).
_CLIP_REPO="https://github.com/Linus789/wl-clip-persist.git"
_CLIP_TAG="v0.5.0"
_CLIP_VERSION="0.5.0"
_CLIP_COMMIT="e26fde01c13922e3a65049dafb7d5adfbc52626e"
_CLIP_BIN="/usr/local/bin/wl-clip-persist"
# Build dependencies from Kali (verified: the crate graph is pure Rust, no -dev
# library is needed; gcc is the linker).
_CLIP_BUILD_DEPS=(cargo rustc git gcc ca-certificates)

_CLIP_BIN_CHANGED=0
_CLIP_SRC=""

# EXIT trap: the checkout and its target directory are build artifacts. The trap
# swallows failures so it never changes the module's exit status.
_clip_cleanup() {
  if [[ -n "${_CLIP_SRC:-}" ]]; then
    rm -rf -- "$_CLIP_SRC" 2>/dev/null || true
  fi
  return 0
}

# _clip_version <path>: the first dotted number of `<path> --version`.
_clip_version() {
  local out
  [[ -x "$1" ]] || return 0
  out="$(LC_ALL=C "$1" --version 2>&1 || true)"
  grep -Eom1 '[0-9]+(\.[0-9]+)+' <<<"$out" || true
}

# _clip_build: clone the pinned tag, check that the commit is the pinned one,
# build with the locked dependency set and install the binary. Skipped when the
# installed binary already reports the pinned version.
_clip_binary() {
  local bin head
  bin="$(rootpath "$_CLIP_BIN")"
  if [[ "$(_clip_version "$bin")" == "$_CLIP_VERSION" ]]; then
    return 0
  fi
  ensure_packages "${_CLIP_BUILD_DEPS[@]}" || return 1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "build wl-clip-persist $_CLIP_VERSION (tag $_CLIP_TAG, commit $_CLIP_COMMIT) and install it to $_CLIP_BIN"
    _CLIP_BIN_CHANGED=1
    return 0
  fi
  log_change "build wl-clip-persist $_CLIP_VERSION (tag $_CLIP_TAG, commit $_CLIP_COMMIT) and install it to $_CLIP_BIN"
  _CLIP_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/kali-cosmic-setup/src/wl-clip-persist"
  rm -rf -- "$_CLIP_SRC"
  mkdir -p -- "$(dirname "$_CLIP_SRC")"
  run git clone --depth 1 --quiet --branch "$_CLIP_TAG" "$_CLIP_REPO" "$_CLIP_SRC"
  head="$(git -C "$_CLIP_SRC" rev-parse HEAD)"
  if [[ "$head" != "$_CLIP_COMMIT" ]]; then
    log_error "wl-clip-persist $_CLIP_TAG is commit ${head:-unknown}, not the pinned $_CLIP_COMMIT: refusing to build it"
    return 1
  fi
  run cargo build --release --locked --manifest-path "$_CLIP_SRC/Cargo.toml" --target-dir "$_CLIP_SRC/target"
  _priv_run "$bin" mkdir -p -- "$(dirname "$bin")"
  _priv_run "$bin" install -m 0755 -- "$_CLIP_SRC/target/release/wl-clip-persist" "$bin"
  _CLIP_BIN_CHANGED=1
  rm -rf -- "$_CLIP_SRC"
  _CLIP_SRC=""
}

# _clip_unit: the user unit, enabled and started in a graphical session.
_clip_unit() {
  local unit="$HOME/.config/systemd/user/wl-clip-persist.service" changed=0 name=wl-clip-persist.service
  install_file "$REPO_ROOT/files/clipboard/wl-clip-persist.service" "$unit" 0644 || return 1
  if ((FILE_CHANGED || _CLIP_BIN_CHANGED)); then
    changed=1
  fi
  if ! user_systemd_ready; then
    log_warn "no systemd user manager is reachable (no login session for $USER here): $name is installed but not enabled; after you log in to COSMIC run: systemctl --user enable --now $name"
    return 0
  fi
  if ((FILE_CHANGED)); then
    run systemctl --user daemon-reload
  fi
  if ! user_unit_enabled "$name"; then
    log_change "enable user unit: $name"
    run systemctl --user enable "$name"
  fi
  if systemctl --user is-active --quiet graphical-session.target >/dev/null 2>&1; then
    if ! systemctl --user is-active --quiet "$name" >/dev/null 2>&1; then
      log_change "start user unit: $name"
      run systemctl --user start "$name"
    elif ((changed)); then
      log_change "restart user unit: $name (new binary or unit)"
      run systemctl --user try-restart "$name"
    fi
  fi
}

module_apply() {
  local legacy="$HOME/.config/autostart/wl-clip-persist.desktop"
  trap _clip_cleanup EXIT
  ensure_packages wl-clipboard || return 1
  _clip_binary || return 1

  # COSMIC keeps the data-control protocol off unless this is set; wl-clip-persist
  # needs it. /etc/environment survives session file updates and is read by the
  # greeter's PAM stack when the session opens, so it applies after the next login.
  ensure_line "$(rootpath /etc/environment)" "COSMIC_DATA_CONTROL_ENABLED=1"

  _clip_unit || return 1

  # COSMIC autostart was unreliable for this; the systemd unit replaces it.
  if [[ -e "$legacy" ]] && user_path_writable "$legacy"; then
    log_change "remove legacy autostart entry $legacy"
    backup_file "$legacy"
    run rm -f -- "$legacy"
  fi
}
