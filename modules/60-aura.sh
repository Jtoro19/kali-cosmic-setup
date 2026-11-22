#!/usr/bin/env bash
# modules/60-aura.sh: Aura live wallpaper manager (pinned, checksum-verified
# release), the restore-last-wallpaper user unit and the Alt+S shortcut.
# Opt-in. See specs/aura.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="aura"
# shellcheck disable=SC2034
MODULE_DESC="Aura live wallpaper: pinned release (sha256), restore-last-wallpaper user unit, Alt+S shortcut"
# shellcheck disable=SC2034
MODULE_OPTIN=1
# shellcheck disable=SC2034
MODULE_DEPS=""

# The release pin: the tag of github.com/antwny/aura that the reference machine
# runs, and the sha256 of its x86_64 tarball. The same value is published in the
# release's own aura-<tag>-x86_64-linux.tar.gz.sha256 and equals the digest
# GitHub computes for the asset (checked 2026-11-22). To move the pin, change
# both lines and re-check the checksum against the release.
_AURA_VERSION="v1.5.0"
_AURA_SHA256="0c6d7ea68e93e5e87a5d1e6f6bc31372646b65873d15175fdb10cecf26a4d1e8"
_AURA_URL_BASE="https://github.com/antwny/aura/releases/download"

_aura_marker() {
  printf '%s/kali-cosmic-setup/aura/version\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# _aura_current: the pinned version is installed (marker) and its binary exists.
_aura_current() {
  local m
  m="$(_aura_marker)"
  [[ -x "$HOME/.local/bin/aura" && -f "$m" && "$(<"$m")" == "$_AURA_VERSION" ]]
}

# _aura_install_files <package dir>: the same files and paths as the upstream
# user install (--user), without running the upstream install.sh.
_aura_install_files() {
  local pkg="$1"
  local bin_dir="$HOME/.local/bin"
  local share="${XDG_DATA_HOME:-$HOME/.local/share}"
  local desktop line before="$CHANGES"

  # Reproducible from the pinned release, so no .bak executables on PATH.
  install_file "$pkg/aura" "$bin_dir/aura" 0755 nobackup || return 1
  if [[ -f "$pkg/mpvpaper" ]]; then
    install_file "$pkg/mpvpaper" "$bin_dir/mpvpaper" 0755 nobackup || return 1
  fi
  install_file "$pkg/io.github.antwny.aura.svg" \
    "$share/icons/hicolor/scalable/apps/io.github.antwny.aura.svg" 0644 || return 1
  install_file "$pkg/io.github.antwny.aura.metainfo.xml" \
    "$share/metainfo/io.github.antwny.aura.metainfo.xml" 0644 || return 1

  # Desktop entry: absolute Exec and a TryExec just above it, like upstream.
  desktop="$pkg/../aura.desktop.out"
  : >"$desktop"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == Exec=* ]]; then
      printf 'TryExec=%s/aura\nExec=%s/aura\n' "$bin_dir" "$bin_dir" >>"$desktop"
    elif [[ "$line" != TryExec=* ]]; then
      printf '%s\n' "$line" >>"$desktop"
    fi
  done <"$pkg/io.github.antwny.aura.desktop"
  install_file "$desktop" "$share/applications/io.github.antwny.aura.desktop" 0644 || return 1

  # Refresh the caches only when something was installed.
  if ((CHANGES != before)); then
    if command -v update-desktop-database >/dev/null 2>&1; then
      run_may_fail update-desktop-database "$share/applications" || true
    fi
    if [[ -f "$share/icons/hicolor/icon-theme.cache" ]] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
      run_may_fail gtk-update-icon-cache -f -t "$share/icons/hicolor" || true
    fi
  fi
}

# _aura_fetch_install <tmp>: download, verify (twice: right before unpacking the
# user-owned copy is checked again), unpack and install the release.
_aura_fetch_install() {
  local tmp="$1" name="aura-${_AURA_VERSION}-x86_64-linux" sum="$_AURA_SHA256" tarball pkg marker f
  tarball="$tmp/$name.tar.gz"
  # The tests serve a fixture; a real run always uses the pinned checksum.
  if [[ -n "${KCS_TEST:-}" && -n "${AURA_SHA256:-}" ]]; then
    sum="$AURA_SHA256"
  fi

  log_info "aura: downloading $_AURA_URL_BASE/$_AURA_VERSION/$name.tar.gz"
  download_verified "$_AURA_URL_BASE/$_AURA_VERSION/$name.tar.gz" "$tarball" "$sum" || return 1
  if ! printf '%s  %s\n' "$sum" "$tarball" | sha256sum -c --status; then
    log_error "aura: checksum mismatch: the downloaded archive changed before it was unpacked; nothing was installed"
    return 1
  fi
  log_ok "aura: sha256 verified"
  if ! tar -xzf "$tarball" -C "$tmp" --no-same-owner --no-same-permissions; then
    log_error "aura: cannot extract $name.tar.gz"
    return 1
  fi
  pkg="$tmp/$name"
  for f in aura io.github.antwny.aura.svg io.github.antwny.aura.metainfo.xml io.github.antwny.aura.desktop; do
    if [[ ! -f "$pkg/$f" || -L "$pkg/$f" ]]; then
      log_error "aura: unexpected tarball layout, $name/$f not found (not installing)"
      return 1
    fi
  done
  mkdir -p -- "$pkg"
  _aura_install_files "$pkg" || return 1

  marker="$(_aura_marker)"
  if user_path_writable "$marker"; then
    mkdir -p -- "$(dirname "$marker")"
    printf '%s\n' "$_AURA_VERSION" >"$marker"
  fi
}

# _aura_install: the pinned release, skipped when it is already installed.
_aura_install() {
  local tmp rc=0

  if _aura_current; then
    return 0
  fi
  if [[ "$(uname -m)" != "x86_64" ]]; then
    log_error "aura: the release is x86_64 only (this machine is $(uname -m))"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] would download Aura %s and verify its SHA-256\n' "$_AURA_VERSION"
    log_change "download and install Aura $_AURA_VERSION"
    return 0
  fi
  log_change "download and install Aura $_AURA_VERSION"
  mkdir -p -- "${TMPDIR:-/tmp}"
  tmp="$(mktemp -d)" || return 1
  _aura_fetch_install "$tmp" || rc=$?
  rm -rf -- "$tmp"
  if ((rc != 0)); then
    log_error "aura $_AURA_VERSION was not installed (exit $rc)"
  fi
  return "$rc"
}

# _aura_remove_autostart <path>: back up and remove an autostart entry.
_aura_remove_autostart() {
  user_path_writable "$1" || return 0
  log_change "remove autostart entry $1"
  backup_file "$1"
  run rm -f -- "$1"
}

# _aura_legacy_cleanup: one start mechanism only (the systemd unit).
_aura_legacy_cleanup() {
  local autostart="$HOME/.config/autostart"
  local old_script="$HOME/.local/bin/aura-autostart.sh"
  local f

  if [[ -e "$autostart/aura.desktop" ]]; then
    _aura_remove_autostart "$autostart/aura.desktop"
  fi
  if [[ -e "$old_script" ]] && user_path_writable "$old_script"; then
    log_change "remove legacy script $old_script"
    backup_file "$old_script"
    run rm -f -- "$old_script"
  fi
  # Any other autostart entry that starts Aura (for example Aura's own).
  if [[ -d "$autostart" ]]; then
    while IFS= read -r -d '' f; do
      [[ "$f" == "$autostart/aura.desktop" ]] && continue
      if grep -qE '^Exec=.*aura' "$f"; then
        _aura_remove_autostart "$f"
      fi
    done < <(find "$autostart" -maxdepth 1 -name '*.desktop' -print0 | sort -z)
  fi
}

# _aura_guard_autostart: keep Aura's own autostart off (the unit restores).
# Every other key is left to Aura, including its theme keys (auto_theme,
# auto_dark): Aura owns the accent color and dark mode while it runs.
_aura_guard_autostart() {
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/aura/config.json"
  local tmp mode

  if [[ ! -f "$config" ]]; then
    log_info "aura: no $config yet; apply a wallpaper once with Aura to create it"
    return 0
  fi
  if ! jq -e . "$config" >/dev/null 2>&1; then
    log_warn "aura: $config is not valid JSON; leaving it alone"
    return 0
  fi
  if jq -e '.autostart == false' "$config" >/dev/null 2>&1; then
    return 0
  fi
  tmp="$(mktemp)"
  if ! jq '.autostart = false' "$config" >"$tmp"; then
    rm -f -- "$tmp"
    log_error "aura: cannot update $config"
    return 1
  fi
  mode="$(stat -c %a -- "$config")"
  log_info "aura: setting autostart to false (the aura-restore unit restores the wallpaper)"
  install_file "$tmp" "$config" "$mode"
  rm -f -- "$tmp"
}

# _aura_restore_unit: the restore script and its user unit, enabled when a user
# manager is reachable.
_aura_restore_unit() {
  local src="$REPO_ROOT/files/aura"
  local unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/aura-restore.service"
  local changed=0

  install_file "$src/aura-restore" "$HOME/.local/bin/aura-restore" 0755 || return 1
  install_file "$src/aura-restore.service" "$unit" 0644 || return 1
  ((FILE_CHANGED)) && changed=1
  if ! user_systemd_ready; then
    log_warn "no systemd user manager is reachable (no login session for $USER here): aura-restore.service is installed but not enabled; after you log in to COSMIC run: systemctl --user enable --now aura-restore.service"
    return 0
  fi
  if ((changed)); then
    run systemctl --user daemon-reload
  fi
  # Enabling starts the unit; it exits at once when a wallpaper is already running.
  ensure_user_unit_enabled aura-restore.service
}

module_apply() {
  ensure_packages mpv libmpv2 ffmpeg jq curl || return 1

  # A failed install stops the module: no unit and no shortcut for a missing aura.
  _aura_install || return 1

  _aura_restore_unit || return 1
  _aura_legacy_cleanup
  _aura_guard_autostart || return 1

  # Alt+S: Aura's quick switcher. Only this entry is added to the shared
  # shortcut map (cosmic_shortcut_ensure); a user binding on Alt+S wins.
  cosmic_shortcut_ensure "Alt" s aurahud "Spawn(\"$HOME/.local/bin/aura switcher\")"
}
