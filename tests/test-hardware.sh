#!/usr/bin/env bash
# tests/test-hardware.sh: detect_cpu_vendor and detect_gpu_vendors from
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
[[ "$(PATH="$WORK/empty" detect_gpu_vendors)" == "" ]]
check "gpu: without lspci the list is empty" $?

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
