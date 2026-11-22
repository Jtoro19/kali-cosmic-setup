# drivers

## Purpose

Install the CPU microcode and the GPU userspace drivers that match the
hardware, detected at run time. Nothing is hardcoded to one vendor. It must
work on real hardware (the owner's host: AMD Ryzen with a Radeon RX 7900 XTX)
and on a VM (any hypervisor: virtio, VMware, VirtualBox, Hyper-V, ...).

## Source of truth

The reference host (AMD CPU, RX 7900 XTX) used `amd-ucode`, `mesa` and
`vulkan-radeon`. Kali equivalents, checked with `apt-cache policy` on the test
VM (kali-rolling):

| Need | Kali package | Component |
|------|--------------|-----------|
| AMD microcode | `amd64-microcode` | non-free-firmware |
| Intel microcode | `intel-microcode` | non-free-firmware |
| AMD GPU firmware (amdgpu; the 7900 XTX does not run without it) | `firmware-amd-graphics` | non-free-firmware |
| Vulkan (radv, anv, lavapipe software renderer) | `mesa-vulkan-drivers` | main |
| VA-API (AMD) | `mesa-va-drivers` | main |
| VA-API (Intel) | `intel-media-va-driver` | main |
| DRI/GL drivers (llvmpipe, virgl) | `libgl1-mesa-dri` | main |

There is no data file; the package choice is encoded in
`modules/10-drivers.sh`.

## Files and packages touched

- No files, no services, no kernel parameters, no bootloader change.
- Packages, only the missing ones, in one `apt-get install`:
  - Always: `mesa-vulkan-drivers`, `mesa-va-drivers`, `libgl1-mesa-dri`.
  - AMD CPU: `amd64-microcode`. Intel CPU: `intel-microcode`.
  - AMD GPU: `firmware-amd-graphics`.
  - Intel GPU: `intel-media-va-driver`.
  - NVIDIA GPU: nothing (see below).
- Debian's initramfs-tools hooks embed the microcode on the package's
  postinst; the new microcode loads after the next reboot.

## Hardware detection

`detect_cpu_vendor` (`/proc/cpuinfo` vendor_id) and `detect_gpu_vendors` (PCI
vendor ids 1002 AMD, 8086 Intel, 10de NVIDIA of VGA, 3D and Display devices)
live in `lib/common.sh` and are tested in `tests/test-hardware.sh`.
CPU and GPU are chosen independently (Intel CPU with an AMD GPU is fine).
Test-only overrides: `DRIVERS_CPU_VENDOR` (amd, intel, other) and
`DRIVERS_GPU_VENDORS` (space-separated; set even to empty it replaces
detection, so an empty value simulates a VM).

- A VM's virtual GPU (virtio, VMware, VirtualBox, Hyper-V, ...) or any unknown vendor: the vendor-specific parts are skipped
  with an info line, no warning; the mesa base still gives llvmpipe/virgl and
  lavapipe Vulkan, so no separate swrast package is needed.
- Without `lspci`, detection falls back to the vendor files of
  `/sys/class/drm/card*/device/vendor` (0x1002 AMD, 0x8086 Intel, 0x10de
  NVIDIA); when neither source exists the module warns and treats the GPU as
  unknown.
- Unknown CPU vendor: warning, no microcode.
- NVIDIA: warn only and point to Kali's `nvidia-driver`. It is never
  installed automatically: it needs DKMS and kernel headers and is a
  per-machine decision. When `nvidia-driver` is already installed it is left
  alone.

## Decisions

- No i386 or lib32 packages (plan: no multiarch).
- `firmware-amd-graphics` is installed for an AMD GPU because the amdgpu
  driver needs its firmware blobs; without them a 7900 XTX boots to a
  framebuffer at best.
- The microcode and firmware packages are in `non-free-firmware`. When a
  package has no apt candidate (component not enabled) the module warns, skips
  that package and installs the rest, so a stripped sources file never fails
  the run. `mesa-*` packages are in main and are required.
- `apt-get update` runs once, only when something has to be installed or when
  a wanted firmware package shows no candidate (stale lists on a fresh image):
  the check is repeated once after the refresh, and only then warned about.
  The refresh here is soft (`apt_update_may_fail`): if it fails (no network yet)
  the module warns that availability cannot be confirmed and carries on, because
  a missing firmware candidate never fails the run. In dry-run the lists are
  not refreshed, so a missing candidate is reported as "cannot be checked"
  instead of the non-free-firmware advice.
- Candidate checks use `apt_has_candidate` from `lib/common.sh`, which forces
  `LC_ALL=C` (apt prints `Candidate:` translated otherwise). The same applies to
  the other apt and dpkg output parsers.
- Intel GPUs get `intel-media-va-driver` (Broadwell and newer). Pre-Broadwell
  hardware needs `i965-va-driver`, which is not covered; the mesa base still
  gives GL and Vulkan where supported.
- Microcode is installed in a VM too (the CPU vendor is passed through): it is
  harmless and keeps one rule for every machine.

## Idempotency check

Packages are installed only when `dpkg-query` says they are missing; with all
present there is no apt call and the run reports `total changes: 0`.

## Revert

`sudo apt-get purge <package>` for any of the packages above (microcode and
firmware packages are safe to keep). Nothing else was changed.

## Verification

```bash
./install.sh --only drivers            # then again: "total changes: 0"
dpkg -l amd64-microcode mesa-vulkan-drivers mesa-va-drivers   # or intel-microcode
glxinfo -B                             # renderer: virgl or llvmpipe in a VM, radeonsi on the 7900 XTX
vulkaninfo --summary                   # needs vulkan-tools; lists radv or llvmpipe
./install.sh --only drivers --dry-run  # "Nothing to change"
```
