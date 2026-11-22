#!/usr/bin/env bash
# tests/test-hardware.sh: detect_cpu_vendor, detect_gpu_vendors and display_is_virtual from
# lib/common.sh, against a fake /proc/cpuinfo (KCS_ROOT) and a fake lspci.
# shellcheck disable=SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
mkdir -p "$WORK/bin" "$WORK/root/proc"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# lspci: prints $LSPCI_OUT (the real command with -nn prints lines like these).
cat >"$WORK/bin/lspci" <<'EOS'
#!/bin/sh
printf '%s\n' "$LSPCI_OUT"
EOS
chmod +x "$WORK/bin/lspci"

# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

cpu() { # cpu <vendor_id line>: detect_cpu_vendor on a fake cpuinfo
  printf 'processor\t: 0\n%s\nmodel name\t: x\n' "$1" >"$WORK/root/proc/cpuinfo"
  KCS_ROOT="$WORK/root" detect_cpu_vendor
}
gpu() { # gpu <lspci output>
  LSPCI_OUT="$1" PATH="$WORK/bin:$PATH" detect_gpu_vendors
}

[[ "$(cpu 'vendor_id	: AuthenticAMD')" == amd ]]
check "cpu: AuthenticAMD is amd" $?
[[ "$(cpu 'vendor_id	: GenuineIntel')" == intel ]]
check "cpu: GenuineIntel is intel" $?
[[ "$(cpu 'vendor_id	: SomethingElse')" == unknown ]]
check "cpu: another vendor is unknown" $?
rm -f -- "$WORK/root/proc/cpuinfo"
[[ "$(KCS_ROOT="$WORK/root" detect_cpu_vendor)" == unknown ]]
check "cpu: no cpuinfo is unknown" $?

[[ "$(gpu '00:01.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XTX] [1002:744c]')" == amd ]]
check "gpu: RX 7900 XTX (1002) is amd" $?
[[ "$(gpu '00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics [8086:9bc5]')" == intel ]]
check "gpu: Intel (8086) is intel" $?
[[ "$(gpu '01:00.0 3D controller [0302]: NVIDIA Corporation GA107 [10DE:25a2]')" == nvidia ]]
check "gpu: NVIDIA (10de, upper case id, 3D controller) is nvidia" $?
[[ "$(gpu '00:02.0 VGA compatible controller [0300]: Intel Corporation [8086:9bc5]
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation [10de:2684]
06:00.0 Display controller [0380]: AMD [1002:1681]')" == "amd intel nvidia" ]]
check "gpu: several vendors come out sorted amd intel nvidia, once each" $?
[[ "$(gpu '00:01.0 VGA compatible controller [0300]: Red Hat, Inc. Virtio 1.0 GPU [1af4:1050] (rev 01)')" == "" ]]
check "gpu: the virtio GPU of a VM gives an empty list" $?
[[ "$(gpu '00:1f.3 Audio device [0403]: Intel Corporation [8086:a0c8]
00:14.0 Ethernet controller [0200]: AMD [1002:1234]')" == "" ]]
check "gpu: non-display devices are ignored" $?
mkdir -p "$WORK/empty"
[[ "$(KCS_ROOT="$WORK/root" PATH="$WORK/empty" detect_gpu_vendors 2>/dev/null)" == "" ]]
check "gpu: without lspci and without sysfs the list is empty" $?
KCS_ROOT="$WORK/root" PATH="$WORK/empty" detect_gpu_vendors 2>&1 >/dev/null | grep -q 'lspci'
check "gpu: without lspci and without sysfs it warns" $?
drm() { # drm <vendor id...>: fake /sys/class/drm cards without lspci
  local i=0 v
  rm -rf -- "$WORK/root/sys"
  for v in "$@"; do
    mkdir -p "$WORK/root/sys/class/drm/card$i/device" "$WORK/root/sys/class/drm/card$i-DP-1"
    echo "$v" >"$WORK/root/sys/class/drm/card$i/device/vendor"
    i=$((i + 1))
  done
  KCS_ROOT="$WORK/root" PATH="$WORK/empty" detect_gpu_vendors
}
[[ "$(drm 0x1002)" == amd ]]
check "gpu: without lspci, sysfs vendor 0x1002 is amd" $?
[[ "$(drm 0x10de 0x8086 0x1002)" == "amd intel nvidia" ]]
check "gpu: without lspci, sysfs vendors come out sorted amd intel nvidia" $?
[[ "$(drm 0x1af4 2>&1)" == "" ]]
check "gpu: without lspci, a virtio card in sysfs gives an empty list and no warning" $?

# display_is_virtual: a VM (systemd-detect-virt --vm succeeds) where no cardN
# has a physical GPU vendor (AMD 1002, Intel 8086, NVIDIA 10de).
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"
make_fakes "$WORK/bin"
virt() { # virt <hypervisor|none> <vendor id|novendor...>: fake cards and connectors, then display_is_virtual
  local hv="$1" i=0 v
  shift
  rm -rf -- "$WORK/root/sys"
  mkdir -p "$WORK/root/sys/class/drm"
  for v in "$@"; do
    mkdir -p "$WORK/root/sys/class/drm/card$i/device" "$WORK/root/sys/class/drm/card$i-Virtual-1"
    [[ "$v" == novendor ]] || echo "$v" >"$WORK/root/sys/class/drm/card$i/device/vendor"
    i=$((i + 1))
  done
  FAKE_VIRT="$hv" PATH="$WORK/bin:$PATH" KCS_ROOT="$WORK/root" display_is_virtual
}
virt kvm 0x1af4
check "virtual: KVM with a virtio card" $?
virt vmware 0x15ad
check "virtual: VMware with its 0x15ad card" $?
virt oracle 0x80ee
check "virtual: VirtualBox with its 0x80ee card" $?
virt microsoft novendor
check "virtual: Hyper-V with a card that has no vendor file" $?
virt kvm 0x1b36 0x1234
check "virtual: KVM with QXL and bochs cards" $?
virt kvm
check "virtual: a VM without any card" $?
! virt kvm 0x1af4 0x10de
check "virtual: a VM with a passed-through NVIDIA card is not virtual" $?
! virt kvm 0x1002
check "virtual: a VM with only an AMD card is not virtual" $?
! virt kvm 0x1af4 0x8086
check "virtual: a VM with a passed-through Intel card is not virtual" $?
! virt vmware 0x15ad 0x10DE
check "virtual: the vendor is compared case-insensitively" $?
! virt none 0x1af4
check "virtual: bare metal with a virtio card is not virtual" $?
! virt none 0x15ad
check "virtual: bare metal with any card is not virtual" $?
rm -rf -- "$WORK/root/sys"
mkdir -p "$WORK/root/sys/class/drm/card0-Virtual-1/device"
echo 0x10de >"$WORK/root/sys/class/drm/card0-Virtual-1/device/vendor"
FAKE_VIRT=kvm PATH="$WORK/bin:$PATH" KCS_ROOT="$WORK/root" display_is_virtual
check "virtual: a connector entry (card0-Virtual-1) is not a card" $?
rm -rf -- "$WORK/root/sys"
FAKE_VIRT=kvm PATH="$WORK/bin:$PATH" KCS_ROOT="$WORK/root" display_is_virtual
check "virtual: a VM without /sys/class/drm is virtual" $?
virt kvm 0x1af4
! KCS_ROOT="$WORK/root" PATH="$WORK/empty" display_is_virtual
check "virtual: without systemd-detect-virt it is not virtual (never on doubt)" $?

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
