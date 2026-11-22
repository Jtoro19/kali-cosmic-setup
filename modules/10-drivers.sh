#!/usr/bin/env bash
# modules/10-drivers.sh: CPU microcode and GPU userspace drivers, by detected
# vendor (see specs/drivers.md).

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="drivers"
# shellcheck disable=SC2034
MODULE_DESC="CPU microcode and GPU drivers (mesa, Vulkan, VA-API, AMD firmware) chosen by detected vendor"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS=""

# Userspace drivers every machine gets: Vulkan (radv, anv, lavapipe), VA-API
# and the DRI/GL drivers (llvmpipe, virgl in a VM).
_DRIVERS_BASE=(mesa-vulkan-drivers mesa-va-drivers libgl1-mesa-dri)

# _drivers_cpu_vendor: amd, intel or unknown. DRIVERS_CPU_VENDOR is a test-only
# override so other hardware can be simulated.
_drivers_cpu_vendor() {
  if [[ -n "${DRIVERS_CPU_VENDOR:-}" ]]; then
    printf '%s\n' "$DRIVERS_CPU_VENDOR"
  else
    detect_cpu_vendor
  fi
}

# _drivers_gpu_vendors: space-separated amd/intel/nvidia, possibly empty.
# DRIVERS_GPU_VENDORS is a test-only override; when set (even to the empty
# string) it replaces detection, so an empty value simulates a VM.
_drivers_gpu_vendors() {
  if [[ -n "${DRIVERS_GPU_VENDORS+x}" ]]; then
    printf '%s\n' "$DRIVERS_GPU_VENDORS"
  else
    detect_gpu_vendors
  fi
}

# _drivers_has_candidate <pkg>: true when apt knows a version to install. The
# output is captured first: a `grep -q` in a pipe would end apt-cache early and
# pipefail would report that as a failure.
_drivers_has_candidate() {
  local out
  out="$(apt-cache policy "$1" 2>/dev/null)" || return 1
  [[ "$out" =~ Candidate:\ [^\(] ]]
}

module_apply() {
  local cpu vendors v pkg nvidia=0 known=0
  local -a want=("${_DRIVERS_BASE[@]}") firmware=() install=()

  cpu="$(_drivers_cpu_vendor)"
  case "$cpu" in
    amd) firmware+=(amd64-microcode) ;;
    intel) firmware+=(intel-microcode) ;;
    *) log_warn "unknown CPU vendor; skipping microcode" ;;
  esac

  vendors="$(_drivers_gpu_vendors)"
  for v in $vendors; do
    case "$v" in
      amd)
        known=1
        firmware+=(firmware-amd-graphics)
        ;;
      intel)
        known=1
        want+=(intel-media-va-driver)
        ;;
      nvidia)
        known=1
        nvidia=1
        ;;
      *) log_info "ignoring unknown GPU vendor: $v" ;;
    esac
  done
  if ((!known)); then
    log_info "no AMD, Intel or NVIDIA GPU detected (virtual GPU?): installing the mesa base only, skipping vendor-specific drivers"
  fi

  # Microcode and AMD GPU firmware live in Kali's non-free-firmware component.
  # Without it they cannot be installed: warn and carry on with the rest.
  for pkg in "${firmware[@]}"; do
    if pkg_installed "$pkg" || _drivers_has_candidate "$pkg"; then
      want+=("$pkg")
    else
      log_warn "$pkg is not available from apt; enable the non-free-firmware component in your Kali sources and run the installer again"
    fi
  done

  for pkg in "${want[@]}"; do
    pkg_installed "$pkg" || install+=("$pkg")
  done
  if ((${#install[@]} > 0)); then
    apt_update_once || return 1
    ensure_packages "${want[@]}" || return 1
  fi

  # The proprietary driver is a per-machine decision (DKMS, kernel headers):
  # never installed automatically.
  if ((nvidia)); then
    if pkg_installed nvidia-driver; then
      log_info "NVIDIA driver already installed; leaving it alone"
    else
      log_warn "NVIDIA GPU found but no NVIDIA driver installed: this module never installs it. Install Kali's nvidia-driver yourself (see https://www.kali.org/docs/general-use/install-nvidia-drivers-on-kali-linux/)"
    fi
  fi
}
