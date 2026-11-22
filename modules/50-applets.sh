#!/usr/bin/env bash
# modules/50-applets.sh: COSMIC panel applets Workspace Icons and Lock Keys, built
# with cargo from pinned upstream commits (neither is packaged for Kali). Now
# Playing is dropped. See specs/applets.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="applets"
# shellcheck disable=SC2034
MODULE_DESC="COSMIC applets: Workspace Icons and Lock Keys (built with cargo from pinned upstream commits)"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Pins. Workspace Icons: tag v1.4.0 (Cargo version 1.3.0, config version 3, the
# version of the shipped key files). Lock Keys: upstream has no release with its
# current panel id, so the commit that names it `com.lucianosb.cosmic-ext-lock-keys`
# is pinned. Both are fetched by commit and the checked-out commit is verified.
_APPLETS_WI_NAME="cosmic-ext-applet-workspace-icons"
_APPLETS_WI_ID="io.github.crocodile.cosmic-ext-applet-workspace-icons"
_APPLETS_WI_URL="https://github.com/crocodile/cosmic-ext-applet-workspace-icons.git"
_APPLETS_WI_COMMIT="3cf946a85c4fd3eb3b5cf6cfb4ba43f14206ab77"
_APPLETS_LK_NAME="cosmic-ext-lock-keys"
_APPLETS_LK_ID="com.lucianosb.cosmic-ext-lock-keys"
_APPLETS_LK_URL="https://github.com/lucianosb/cosmic-applet-lock-keys.git"
_APPLETS_LK_COMMIT="1be12f5668dc449af6992944342a1f684764ce02"

# Build dependencies from Kali: the minimal set that a real build of both applets
# needed on the test VM (gcc is the linker; the only -dev library is xkbcommon).
_APPLETS_BUILD_DEPS=(build-essential cargo rustc git pkg-config libxkbcommon-dev ca-certificates)

_APPLETS_SRC=""

# EXIT trap: the checkout and its target directory are build artifacts. The trap
# swallows failures so it never changes the module's exit status.
_applets_cleanup() {
  if [[ -n "${_APPLETS_SRC:-}" ]]; then
    rm -rf -- "$_APPLETS_SRC" 2>/dev/null || true
  fi
  return 0
}

_applets_marker() { # <name>
  printf '%s/kali-cosmic-setup/applets/%s.commit\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$1"
}

# _applets_current <name> <commit> <binary>: true when the binary exists and the
# recorded build commit is the pin.
_applets_current() {
  local marker
  marker="$(_applets_marker "$1")"
  [[ -x "$3" && -f "$marker" && "$(<"$marker")" == "$2" ]]
}

# _applets_record <name> <commit>: remember what was built (user state file).
_applets_record() {
  local marker
  marker="$(_applets_marker "$1")"
  user_path_writable "$marker" || return 0
  mkdir -p -- "$(dirname "$marker")"
  printf '%s\n' "$2" >"$marker"
}

# _applets_build <name> <url> <commit>: fetch the pinned commit into the cache
# directory, check that it is the pinned one, and build it with the repository's
# own Cargo.lock. As the invoking user, never in the repository. Leaves the
# checkout in _APPLETS_SRC for the install step (the trap removes it).
_applets_build() {
  local name="$1" url="$2" commit="$3" head
  _APPLETS_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/kali-cosmic-setup/src/$name"
  rm -rf -- "$_APPLETS_SRC"
  mkdir -p -- "$(dirname "$_APPLETS_SRC")"
  export GIT_TERMINAL_PROMPT=0
  run git init -q "$_APPLETS_SRC"
  run git -C "$_APPLETS_SRC" remote add origin "$url"
  run git -C "$_APPLETS_SRC" fetch -q --depth 1 origin "$commit"
  run git -C "$_APPLETS_SRC" checkout -q FETCH_HEAD
  head="$(git -C "$_APPLETS_SRC" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    log_error "$name: the checkout is commit ${head:-unknown}, not the pinned $commit: refusing to build it"
    return 1
  fi
  run cargo build --release --locked --manifest-path "$_APPLETS_SRC/Cargo.toml" --target-dir "$_APPLETS_SRC/target" </dev/null
}

# _applets_refresh_icons <hicolor-dir> [sudo]: refresh an icon cache that already
# exists there (none is created: the lookup works from the directories).
_applets_refresh_icons() {
  local dir="$1"
  [[ -f "$dir/icon-theme.cache" ]] && command -v gtk-update-icon-cache >/dev/null 2>&1 || return 0
  if [[ "${2:-}" == sudo ]]; then
    run_sudo_may_fail gtk-update-icon-cache -f -t -i "$dir" || log_warn "could not refresh the icon cache in $dir"
  else
    run_may_fail gtk-update-icon-cache -f -t -i "$dir" || log_warn "could not refresh the icon cache in $dir"
  fi
}

# _applets_workspace_icons: user-local install, the layout of the upstream
# install recipe with prefix ~/.local. The desktop entry comes from this repository
# (its Exec holds the user's home) and the config keys are always compared.
_applets_workspace_icons() {
  local src="$REPO_ROOT/files/applets" bin="$HOME/.local/bin/$_APPLETS_WI_NAME"
  local share="${XDG_DATA_HOME:-$HOME/.local/share}" f rel

  install_template "$src/$_APPLETS_WI_ID.desktop.in" "$share/applications/$_APPLETS_WI_ID.desktop" 0644 || return 1
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/cosmic/}"
    install_file "$f" "$HOME/.config/cosmic/$rel" 0644 || return 1
  done < <(find "$src/cosmic" -type f -print0 | sort -z)

  _applets_current "$_APPLETS_WI_NAME" "$_APPLETS_WI_COMMIT" "$bin" && return 0
  # Never build for a location the user cannot write (and never use sudo there).
  user_path_writable "$bin" || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "build and install $_APPLETS_WI_NAME (commit $_APPLETS_WI_COMMIT) to $bin"
    return 0
  fi
  log_change "build and install $_APPLETS_WI_NAME (commit $_APPLETS_WI_COMMIT) to $bin"
  _applets_build "$_APPLETS_WI_NAME" "$_APPLETS_WI_URL" "$_APPLETS_WI_COMMIT" || return 1
  install_file "$_APPLETS_SRC/target/release/$_APPLETS_WI_NAME" "$bin" 0755 nobackup || return 1
  install_file "$_APPLETS_SRC/resources/$_APPLETS_WI_ID.svg" \
    "$share/icons/hicolor/scalable/apps/$_APPLETS_WI_ID.svg" 0644 nobackup || return 1
  install_file "$_APPLETS_SRC/resources/$_APPLETS_WI_ID.metainfo.xml" \
    "$share/metainfo/$_APPLETS_WI_ID.metainfo.xml" 0644 nobackup || return 1
  _applets_refresh_icons "$share/icons/hicolor"
  _applets_record "$_APPLETS_WI_NAME" "$_APPLETS_WI_COMMIT"
  rm -rf -- "$_APPLETS_SRC"
  _APPLETS_SRC=""
}

# _applets_lock_keys: system-wide under /usr/local (outside dpkg's files, and on
# the default XDG data path), by hand: the upstream justfile names files that do
# not exist.
_applets_lock_keys() {
  local bin icons desktop
  bin="$(rootpath "/usr/local/bin/$_APPLETS_LK_NAME")"
  icons="$(rootpath /usr/local/share/icons/hicolor/scalable/apps)"
  desktop="$(rootpath "/usr/local/share/applications/$_APPLETS_LK_ID.desktop")"

  if ! _applets_current "$_APPLETS_LK_NAME" "$_APPLETS_LK_COMMIT" "$bin"; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log_change "build and install $_APPLETS_LK_NAME (commit $_APPLETS_LK_COMMIT) to /usr/local/bin"
    else
      log_change "build and install $_APPLETS_LK_NAME (commit $_APPLETS_LK_COMMIT) to /usr/local/bin"
      _applets_build "$_APPLETS_LK_NAME" "$_APPLETS_LK_URL" "$_APPLETS_LK_COMMIT" || return 1
      install_file "$_APPLETS_SRC/target/release/$_APPLETS_LK_NAME" "$bin" 0755 nobackup || return 1
      install_file "$_APPLETS_SRC/data/icons/caps-lock-symbolic.svg" "$icons/caps-lock-symbolic.svg" 0644 nobackup || return 1
      install_file "$_APPLETS_SRC/data/icons/num-lock-symbolic.svg" "$icons/num-lock-symbolic.svg" 0644 nobackup || return 1
      _applets_refresh_icons "$(dirname "$(dirname "$icons")")" sudo
      _applets_record "$_APPLETS_LK_NAME" "$_APPLETS_LK_COMMIT"
      rm -rf -- "$_APPLETS_SRC"
      _APPLETS_SRC=""
    fi
  fi
  # The desktop entry is this repository's (absolute Exec), always compared.
  install_file "$REPO_ROOT/files/applets/$_APPLETS_LK_ID.desktop" "$desktop" 0644
}

module_apply() {
  trap _applets_cleanup EXIT
  # Packages are needed only when something is going to be built.
  if ! _applets_current "$_APPLETS_WI_NAME" "$_APPLETS_WI_COMMIT" "$HOME/.local/bin/$_APPLETS_WI_NAME" ||
    ! _applets_current "$_APPLETS_LK_NAME" "$_APPLETS_LK_COMMIT" "$(rootpath "/usr/local/bin/$_APPLETS_LK_NAME")"; then
    ensure_packages "${_APPLETS_BUILD_DEPS[@]}" || return 1
  fi
  _applets_workspace_icons || return 1
  _applets_lock_keys || return 1
}
