#!/usr/bin/env bash
# modules/83-mic-agc.sh: stop browsers and Electron apps from moving the microphone volume.
# See specs/mic-agc.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="mic-agc"
# shellcheck disable=SC2034
MODULE_DESC="Microphone: block automatic gain control from browsers and Electron apps (PipeWire rule)"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

_MIC_AGC_RULE="20-block-mic-agc.conf"
# File name of the first hand-made version of this rule.
_MIC_AGC_LEGACY_RULE="99-block-mic-agc.conf"

module_apply() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  local dir="$cfg/pipewire/pipewire-pulse.conf.d"
  local before=$CHANGES

  # Migration: keep a single rule file. The backup does not end in .conf, so
  # PipeWire ignores it. A file someone else owns is left alone.
  if [[ -f "$dir/$_MIC_AGC_LEGACY_RULE" ]] && user_path_writable "$dir/$_MIC_AGC_LEGACY_RULE"; then
    log_change "remove legacy rule $dir/$_MIC_AGC_LEGACY_RULE (replaced by $_MIC_AGC_RULE)"
    backup_file "$dir/$_MIC_AGC_LEGACY_RULE"
    run rm -f -- "$dir/$_MIC_AGC_LEGACY_RULE"
  fi
  install_file "$REPO_ROOT/files/mic-agc/$_MIC_AGC_RULE" "$dir/$_MIC_AGC_RULE" 0644 || return 1

  # pipewire-pulse reads pulse.rules when it starts, so it is the only service
  # to restart, and only when the rule changed and a user instance is running
  # (not on a fresh install before the first login, nor over SSH with no user
  # manager). Restarting just pipewire-pulse leaves PipeWire and WirePlumber, and
  # the COSMIC sound applet's view of the devices, untouched.
  if ((CHANGES > before)); then
    if user_systemd_ready && systemctl --user is-active --quiet pipewire-pulse.service >/dev/null 2>&1; then
      run systemctl --user restart pipewire-pulse
      log_warn "restarting pipewire-pulse: restart apps that were using audio so they reconnect"
    else
      log_info "pipewire-pulse is not running; the rule applies at next login"
    fi
  fi
  return 0
}
