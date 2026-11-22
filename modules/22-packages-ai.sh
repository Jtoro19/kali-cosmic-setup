#!/usr/bin/env bash
# modules/22-packages-ai.sh: Ollama from its official release archives
# (SHA-256 verified), the generic build by default and the ROCm build on AMD
# GPUs, a dedicated ollama user and a systemd unit bound to 127.0.0.1. No model
# is pulled. See specs/packages-ai.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="packages-ai"
# shellcheck disable=SC2034
MODULE_DESC="Ollama (official release, generic or ROCm build) as a service on 127.0.0.1:11434"
# shellcheck disable=SC2034
MODULE_OPTIN=1
# shellcheck disable=SC2034
MODULE_DEPS="packages"

# zstd unpacks the archives; curl and ca-certificates download them.
_PAI_PREREQS=(zstd curl ca-certificates)

# Pinned release. The sha256 values are the lines of the release's own
# sha256sum.txt (they equal the digests GitHub computes for the assets).
_PACKAGES_AI_VERSION="0.40.17"
_PACKAGES_AI_BASE_URL="https://github.com/ollama/ollama/releases/download/v${_PACKAGES_AI_VERSION}"
_PACKAGES_AI_ARCHIVE="ollama-linux-amd64.tar.zst"
_PACKAGES_AI_SHA256="1df9d6228bac5a22e420b242708c0d10e5b886db97bab99d446a41760f4e79af"
_PACKAGES_AI_ROCM_ARCHIVE="ollama-linux-amd64-rocm.tar.zst"
_PACKAGES_AI_ROCM_SHA256="830e7068a16a3946edb1ee23f3ba455c9f966f9155be9934ca87f62004e20fe7"

_PAI_PREFIX="/usr/local"
_PAI_USER="ollama"
_PAI_HOME="/usr/share/ollama"
_PAI_HOST="127.0.0.1:11434"
_PAI_UNIT="ollama.service"
_PAI_MARKER_NAME=".kali-cosmic-setup"

_PAI_CHANGED=0
_PAI_WORK=""
_PAI_STAGE=""

# _pai_cleanup: EXIT trap. A fail-fast helper (run_sudo) ends the module with
# exit, so the download directory and the staging directory are removed here.
_pai_cleanup() {
  if [[ -n "${_PAI_WORK:-}" ]]; then
    rm -rf -- "$_PAI_WORK"
  fi
  if [[ -n "${_PAI_STAGE:-}" && -e "$_PAI_STAGE" ]]; then
    _priv_run "$_PAI_STAGE" rm -rf -- "$_PAI_STAGE"
  fi
}

_pai_sha256_ok() {
  printf '%s  %s\n' "$2" "$1" | sha256sum -c --status
}

# _pai_version <path>: the first dotted number of `<path> --version` (stdout and
# stderr: the client prints a warning line when no server runs).
_pai_version() {
  local out
  [[ -x "$1" ]] || return 0
  out="$(LC_ALL=C "$1" --version 2>&1 || true)"
  grep -Eom1 '[0-9]+(\.[0-9]+)+' <<<"$out" || true
}

# _pai_variant: rocm on an AMD GPU, else generic. PACKAGES_AI_GPU_VENDORS (set,
# even empty) replaces the detection. Warns about NVIDIA.
_pai_variant() {
  local gpus
  if [[ -v PACKAGES_AI_GPU_VENDORS ]]; then
    gpus="$PACKAGES_AI_GPU_VENDORS"
  else
    gpus="$(detect_gpu_vendors)"
  fi
  if [[ " $gpus " == *" nvidia "* ]]; then
    log_warn "NVIDIA GPU: this repo does not install the NVIDIA driver; Ollama uses the GPU only when the driver is installed (the generic build is installed)"
  fi
  if [[ " $gpus " == *" amd "* ]]; then
    printf 'rocm\n'
  else
    printf 'generic\n'
  fi
}

# _pai_fetch <archive> <sha256> <dir>: download an archive into <dir> and verify
# it again right before it is unpacked (the directory is user-owned).
_pai_fetch() {
  local archive="$1" sum="$2" dir="$3"
  TMPDIR="$dir" download_verified "$_PACKAGES_AI_BASE_URL/$archive" "$dir/$archive" "$sum" || return 1
  if ! _pai_sha256_ok "$dir/$archive" "$sum"; then
    log_error "checksum mismatch: the downloaded $archive changed before it was unpacked; nothing was installed"
    return 1
  fi
}

# _pai_install <variant>: download, verify and unpack into a staging directory
# inside the prefix, then swap lib/ollama and bin/ollama in. The ROCm archive is
# an overlay of the base archive (upstream manual install: both are extracted
# into the same prefix). A failed download or unpack leaves the old install as it was.
_pai_install() {
  local variant="$1" prefix bin marker cur mv="" sum rsum
  prefix="$(rootpath "$_PAI_PREFIX")"
  bin="$prefix/bin/ollama"
  marker="$prefix/lib/ollama/$_PAI_MARKER_NAME"
  sum="$_PACKAGES_AI_SHA256"
  rsum="$_PACKAGES_AI_ROCM_SHA256"
  # Test-only: fixtures replace the pinned checksums only when KCS_TEST is set.
  if [[ -n "${KCS_TEST:-}" ]]; then
    sum="${PACKAGES_AI_SHA256:-$sum}"
    rsum="${PACKAGES_AI_ROCM_SHA256:-$rsum}"
  fi
  if [[ -r "$marker" ]]; then
    read -r _ mv <"$marker" || true
  fi
  cur="$(_pai_version "$bin")"
  if [[ -n "$cur" ]] && dpkg --compare-versions "$cur" ge "$_PACKAGES_AI_VERSION" &&
    { [[ "$variant" != rocm ]] || [[ "$mv" == rocm ]]; }; then
    return 0
  fi
  if [[ "$(uname -m)" != x86_64 ]]; then
    log_error "Ollama's pinned release archives here are for x86_64 only (this machine is $(uname -m))"
    return 1
  fi
  _PAI_CHANGED=1
  if [[ "$DRY_RUN" == "1" ]]; then
    log_change "install ollama $_PACKAGES_AI_VERSION ($variant build) into $_PAI_PREFIX"
    log_info "[dry-run] would download $_PACKAGES_AI_BASE_URL/$_PACKAGES_AI_ARCHIVE and verify SHA-256 $sum"
    if [[ "$variant" == rocm ]]; then
      log_info "[dry-run] would download $_PACKAGES_AI_BASE_URL/$_PACKAGES_AI_ROCM_ARCHIVE and verify SHA-256 $rsum"
    fi
    return 0
  fi
  log_change "install ollama $_PACKAGES_AI_VERSION ($variant build) into $_PAI_PREFIX"
  # /var/tmp is on disk: /tmp may be a RAM-backed tmpfs and the archives are gigabytes.
  mkdir -p -- "$(rootpath /var/tmp)"
  _PAI_WORK="$(mktemp -d -p "$(rootpath /var/tmp)")"
  _PAI_STAGE="$prefix/.ollama-stage"
  _priv_run "$_PAI_STAGE" rm -rf -- "$_PAI_STAGE"
  _priv_run "$_PAI_STAGE" mkdir -p -- "$_PAI_STAGE"
  _pai_fetch "$_PACKAGES_AI_ARCHIVE" "$sum" "$_PAI_WORK" || return 1
  run_sudo tar --zstd -xf "$_PAI_WORK/$_PACKAGES_AI_ARCHIVE" -C "$_PAI_STAGE" --no-same-owner
  rm -f -- "${_PAI_WORK:?}/$_PACKAGES_AI_ARCHIVE"
  if [[ "$variant" == rocm ]]; then
    _pai_fetch "$_PACKAGES_AI_ROCM_ARCHIVE" "$rsum" "$_PAI_WORK" || return 1
    run_sudo tar --zstd -xf "$_PAI_WORK/$_PACKAGES_AI_ROCM_ARCHIVE" -C "$_PAI_STAGE" --no-same-owner
    rm -f -- "${_PAI_WORK:?}/$_PACKAGES_AI_ROCM_ARCHIVE"
  fi
  if [[ ! -f "$_PAI_STAGE/bin/ollama" || ! -d "$_PAI_STAGE/lib/ollama" ]]; then
    log_error "the Ollama archive has no bin/ollama and lib/ollama: nothing was installed"
    return 1
  fi
  # The libraries of an older release must not mix with the new ones.
  run_sudo rm -rf -- "$prefix/lib/ollama"
  run_sudo mkdir -p -- "$prefix/lib" "$prefix/bin"
  run_sudo mv -- "$_PAI_STAGE/lib/ollama" "$prefix/lib/ollama"
  run_sudo install -m 0755 -- "$_PAI_STAGE/bin/ollama" "$bin"
  run_sudo tee -- "$marker" <<<"$_PACKAGES_AI_VERSION $variant" >/dev/null
  _priv_run "$_PAI_STAGE" rm -rf -- "$_PAI_STAGE"
  _PAI_STAGE=""
  rm -rf -- "$_PAI_WORK"
  _PAI_WORK=""
}

# _pai_user: the dedicated system user (layout of Ollama's manual install).
_pai_user() {
  if getent passwd "$_PAI_USER" >/dev/null 2>&1; then
    return 0
  fi
  log_change "create system user $_PAI_USER (home $_PAI_HOME, no login)"
  run_sudo useradd -r -s /usr/sbin/nologin -U -m -d "$_PAI_HOME" "$_PAI_USER"
}

# _pai_gpu_groups: on the ROCm build the service user needs the GPU devices.
_pai_gpu_groups() {
  local g
  getent passwd "$_PAI_USER" >/dev/null 2>&1 || return 0
  for g in render video; do
    getent group "$g" >/dev/null 2>&1 || continue
    if id -nG "$_PAI_USER" | tr ' ' '\n' | grep -qx -- "$g"; then
      continue
    fi
    log_change "add $_PAI_USER to group $g (GPU device access)"
    run_sudo usermod -aG "$g" "$_PAI_USER"
    _PAI_CHANGED=1
  done
}

# _pai_unit: ollama.service, bound to loopback only.
_pai_unit() {
  ensure_file_content "$(rootpath "/etc/systemd/system/$_PAI_UNIT")" "# Managed by kali-cosmic-setup: Ollama listens on localhost only.
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$_PAI_PREFIX/bin/ollama serve
User=$_PAI_USER
Group=$_PAI_USER
Restart=always
RestartSec=3
Environment=\"OLLAMA_HOST=$_PAI_HOST\"
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target" || return 1
  if ((FILE_CHANGED)); then
    _PAI_CHANGED=1
    run_sudo systemctl daemon-reload
  fi
}

# _pai_service: enable and start; an already running service is restarted once
# when the binary, the unit or the groups changed (a first start needs none).
_pai_service() {
  local was_active=0
  if systemctl is-active --quiet "$_PAI_UNIT" >/dev/null 2>&1; then
    was_active=1
  fi
  ensure_system_unit_enabled "$_PAI_UNIT" || return 1
  if ((_PAI_CHANGED && was_active)); then
    log_change "restart $_PAI_UNIT (the new binary, unit or groups apply)"
    run_sudo systemctl restart -- "$_PAI_UNIT"
  fi
}

module_apply() {
  local variant
  trap _pai_cleanup EXIT
  ensure_packages "${_PAI_PREREQS[@]}" || return 1
  variant="$(_pai_variant)"
  _pai_install "$variant" || return 1
  _pai_user || return 1
  if [[ "$variant" == rocm ]]; then
    _pai_gpu_groups || return 1
  fi
  _pai_unit || return 1
  _pai_service
}
