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
# GitHub computes for the asset (v1.11.2, checked 2026-11-22). To move the pin, change
# both lines and re-check the checksum against the release.
_AURA_VERSION="v1.11.2"
_AURA_SHA256="880ced8548a40bf5a260c1f1c7198d7fde3f474388ca6383b013b0c77f8bc954"
_AURA_URL_BASE="https://github.com/antwny/aura/releases/download"

_aura_marker() {
  printf '%s/kali-cosmic-setup/aura/version\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

_aura_share() { printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}"; }

# The marker: line 1 is the installed tag, line 2 says whether the release
# shipped its own mpvpaper ("mpvpaper=bundled", also assumed for a marker with
# one line) or not ("mpvpaper=none"), line 3 lists the optional members the
# release shipped ("optional=aura-effects aura-depth fire-symbolic.svg"; none
# for a marker without that line, so an old marker never demands them).

# The optional members: two executables (~/.local/bin) and one action icon.
_AURA_OPT_BINS="aura-effects aura-depth"
_AURA_OPT_ICONS="fire-symbolic.svg"
_AURA_REQ_ICONS="navbar-open-symbolic.svg navbar-closed-symbolic.svg"

# _aura_current: the pinned version is installed (marker) and every artifact of
# it exists: aura, mpvpaper (when the release ships one), the optional members
# the marker lists, the required action icons, desktop entry, icon and metainfo.
_aura_current() {
  local m share ver mp opt f
  m="$(_aura_marker)"
  share="$(_aura_share)"
  [[ -f "$m" ]] || return 1
  ver="$(sed -n 1p "$m")"
  mp="$(sed -n 2p "$m")"
  [[ "$ver" == "$_AURA_VERSION" && -x "$HOME/.local/bin/aura" ]] || return 1
  [[ "$mp" == "mpvpaper=none" || -x "$HOME/.local/bin/mpvpaper" ]] || return 1
  for f in $_AURA_REQ_ICONS; do
    [[ -f "$share/icons/hicolor/scalable/actions/$f" ]] || return 1
  done
  opt="$(sed -n 3p "$m")"
  opt="${opt#optional=}"
  for f in $opt; do
    case " $_AURA_OPT_BINS " in
      *" $f "*) [[ -x "$HOME/.local/bin/$f" ]] || return 1 ;;
      *)
        case " $_AURA_OPT_ICONS " in
          *" $f "*) [[ -f "$share/icons/hicolor/scalable/actions/$f" ]] || return 1 ;;
        esac
        ;;
    esac
  done
  [[ -f "$share/applications/io.github.antwny.aura.desktop" &&
    -f "$share/icons/hicolor/scalable/apps/io.github.antwny.aura.svg" &&
    -f "$share/metainfo/io.github.antwny.aura.metainfo.xml" ]]
}

# _aura_semver_newer <a> <b>: version a is strictly newer than version b.
_aura_semver_newer() {
  [[ -n "$1" && "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# _aura_installed_newer: an Aura newer than the pin is already there (recorded in
# the marker, or reported by the binary itself), so the pin must not downgrade it.
# `aura --version` prints "Aura Live Wallpaper v1.5.0" and exits; it runs with a
# time limit and no input.
_aura_installed_newer() {
  local m bin="$HOME/.local/bin/aura" have
  m="$(_aura_marker)"
  # Only a marker line shaped like a version counts: a corrupted line must not
  # sort above the pin and block the install for good.
  if [[ -f "$m" ]]; then
    have="$(sed -n 1p "$m")"
    [[ "$have" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] && _aura_semver_newer "$have" "$_AURA_VERSION" && return 0
  fi
  if [[ -f "$bin" && -x "$bin" && ! -L "$bin" ]]; then
    have="$(timeout 5 "$bin" --version </dev/null 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
    [[ -z "$have" || "$have" == v* ]] || have="v$have"
    _aura_semver_newer "$have" "$_AURA_VERSION" && return 0
  fi
  return 1
}

# _aura_install_bin <src> <dest>: an executable of the release. It is
# reproducible, so once the marker exists no .bak is made; a file that is there
# without the marker (not installed by this module before) is backed up first.
_aura_install_bin() {
  local src="$1" dest="$2"
  if [[ -e "$dest" || -L "$dest" ]] && ! cmp -s -- "$src" "$dest" && [[ ! -f "$(_aura_marker)" ]]; then
    if user_path_writable "$dest"; then
      log_info "aura: $dest was not installed by this setup; backing it up before replacing it"
      backup_file "$dest"
    fi
  fi
  install_file "$src" "$dest" 0755 nobackup
}

# _aura_install_files <package dir>: the same files and paths as the upstream
# user install (--user), without running the upstream install.sh.
_aura_install_files() {
  local pkg="$1"
  local bin_dir="$HOME/.local/bin"
  local share desktop line f png before="$CHANGES"
  share="$(_aura_share)"

  # Reproducible from the pinned release, so no .bak executables on PATH (an
  # existing one this setup did not install is backed up once, see above).
  _aura_install_bin "$pkg/aura" "$bin_dir/aura" || return 1
  if [[ -f "$pkg/mpvpaper" ]]; then
    _aura_install_bin "$pkg/mpvpaper" "$bin_dir/mpvpaper" || return 1
  fi
  for f in $_AURA_OPT_BINS; do
    if [[ -f "$pkg/$f" ]]; then
      _aura_install_bin "$pkg/$f" "$bin_dir/$f" || return 1
    fi
  done
  install_file "$pkg/io.github.antwny.aura.svg" \
    "$share/icons/hicolor/scalable/apps/io.github.antwny.aura.svg" 0644 || return 1
  for f in $_AURA_REQ_ICONS $_AURA_OPT_ICONS; do
    if [[ -f "$pkg/$f" ]]; then
      install_file "$pkg/$f" "$share/icons/hicolor/scalable/actions/$f" 0644 || return 1
    fi
  done
  # Like upstream: drop stale PNGs of the Aura icon (exactly this name, in an
  # apps/ directory one level below hicolor), through the user path guards.
  for png in "$share"/icons/hicolor/*/apps/io.github.antwny.aura.png; do
    [[ -e "$png" || -L "$png" ]] || continue
    user_path_writable "$png" || continue
    log_change "remove stale icon $png"
    run rm -f -- "$png"
  done
  install_file "$pkg/io.github.antwny.aura.metainfo.xml" \
    "$share/metainfo/io.github.antwny.aura.metainfo.xml" 0644 || return 1

  # Desktop entry, like upstream: `Exec=aura [args]` becomes the absolute path
  # with its arguments kept (the Switcher action runs `aura switcher`), and the
  # main [Desktop Entry] group gets one absolute TryExec just above its Exec.
  # TryExec is not valid in an action group, so none is written there.
  desktop="$pkg/../aura.desktop.out"
  : >"$desktop"
  local group="" tryexec_done=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == \[*\] ]]; then
      group="$line"
    elif [[ "$line" == TryExec=* ]]; then
      continue
    elif [[ "$line" == Exec=aura || "$line" == "Exec=aura "* ]]; then
      if [[ "$group" == "[Desktop Entry]" ]] && ((!tryexec_done)); then
        printf 'TryExec=%s/aura\n' "$bin_dir" >>"$desktop"
        tryexec_done=1
      fi
      line="Exec=$bin_dir/aura${line#Exec=aura}"
    fi
    printf '%s\n' "$line" >>"$desktop"
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
  local tmp="$1" name="aura-${_AURA_VERSION}-x86_64-linux" sum="$_AURA_SHA256" tarball pkg marker f opt
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
  _aura_tar_safe "$tarball" "$name" || return 1
  if ! tar -xzf "$tarball" -C "$tmp" --no-same-owner --no-same-permissions; then
    log_error "aura: cannot extract $name.tar.gz"
    return 1
  fi
  pkg="$tmp/$name"
  if [[ ! -d "$pkg" || -L "$pkg" ]]; then
    log_error "aura: unexpected tarball layout, $name is not a plain directory (not installing)"
    return 1
  fi
  for f in aura io.github.antwny.aura.svg io.github.antwny.aura.metainfo.xml io.github.antwny.aura.desktop $_AURA_REQ_ICONS; do
    if [[ ! -f "$pkg/$f" || -L "$pkg/$f" ]]; then
      log_error "aura: unexpected tarball layout, $name/$f not found (not installing)"
      return 1
    fi
  done
  opt=""
  for f in mpvpaper $_AURA_OPT_BINS $_AURA_OPT_ICONS; do
    if [[ -L "$pkg/$f" ]]; then
      log_error "aura: unexpected tarball layout, $name/$f is a symlink (not installing)"
      return 1
    fi
    [[ "$f" != mpvpaper && -f "$pkg/$f" ]] && opt+="${opt:+ }$f"
  done
  _aura_install_files "$pkg" || return 1

  marker="$(_aura_marker)"
  if user_path_writable "$marker"; then
    mkdir -p -- "$(dirname "$marker")"
    printf '%s\nmpvpaper=%s\noptional=%s\n' "$_AURA_VERSION" "$([[ -f "$pkg/mpvpaper" ]] && echo bundled || echo none)" "$opt" >"$marker"
  fi
}

# _aura_tar_safe <tarball> <top dir>: list the members before extracting and
# refuse anything outside the package directory: absolute names, `..`
# components, another top-level name, and every member that is not a plain file
# or directory (a symlink or hard link could point anywhere).
_aura_tar_safe() {
  local tarball="$1" top="$2" line name bad=""
  while IFS= read -r name; do
    if [[ "$name" == /* || "$name" == ".." || "$name" == ../* || "$name" == */../* || "$name" == */.. ]]; then
      bad="$name"
      break
    fi
    if [[ "$name" != "$top" && "$name" != "$top"/* ]]; then
      bad="$name"
      break
    fi
  done < <(tar -tzf "$tarball" 2>/dev/null)
  if [[ -z "$bad" ]]; then
    while IFS= read -r line; do
      case "${line:0:1}" in
        - | d) ;;
        *)
          bad="${line#* }"
          break
          ;;
      esac
    done < <(tar -tvzf "$tarball" 2>/dev/null)
  fi
  if [[ -n "$bad" ]]; then
    log_error "aura: unsafe member in the archive ($bad): absolute, parent, outside $top/, or a link (not installing)"
    return 1
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
  if _aura_installed_newer; then
    log_warn "aura: a newer Aura than the pinned $_AURA_VERSION is installed; keeping it (this setup never downgrades). Move the pin to update"
    return 0
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
      if [[ "${f##*/}" == io.github.antwny.aura.desktop ]] || grep -qE '^Exec=([^ ]*/)?(aura|aura-autostart\.sh)([ ]|$)' "$f"; then
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
  # A HOME with whitespace, a quote or a backslash cannot be written into the
  # shortcut map (the Spawn string is split on whitespace by COSMIC and RON
  # strings are not escaped here): skip the shortcut, the rest works.
  if [[ "$HOME" == *[[:space:]\"\\]* ]]; then
    log_warn "aura: HOME contains whitespace, a double quote or a backslash, so the Alt+S shortcut is not added (run aura switcher yourself)"
    return 0
  fi
  cosmic_shortcut_ensure "Alt" s aurahud "Spawn(\"$HOME/.local/bin/aura switcher\")"
}
