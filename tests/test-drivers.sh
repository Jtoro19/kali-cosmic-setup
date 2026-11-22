#!/usr/bin/env bash
# tests/test-drivers.sh: modules/10-drivers.sh against fake apt-get, dpkg-query
# and apt-cache. The hardware is chosen with the test-only DRIVERS_CPU_VENDOR
# and DRIVERS_GPU_VENDORS overrides. Never touches the real system.
# shellcheck disable=SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
make_fakes "$WORK/bin"
# apt-cache policy <pkg>: "Candidate: (none)" for the packages listed in
# FAKE_NO_CANDIDATE (space separated), a version for the others.
cat >"$WORK/bin/apt-cache" <<'EOS'
#!/bin/sh
for a in "$@"; do pkg="$a"; done
echo "$pkg:"
case " ${FAKE_NO_CANDIDATE:-} " in
  *" $pkg "*) echo "  Installed: (none)"; echo "  Candidate: (none)" ;;
  *) echo "  Installed: (none)"; echo "  Candidate: 1.0-1" ;;
esac
# A long version table: a reader that stops early (grep -q) makes this
# writer die of SIGPIPE, which `set -o pipefail` turns into a failure.
i=0
while [ "$i" -lt 20000 ]; do echo " *** 1.0-1 500 http://example.invalid/kali kali-rolling/main amd64 Packages"; i=$((i + 1)); done
EOS
chmod +x "$WORK/bin/apt-cache"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

APT="$FAKE_STATE/apt.log"
reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT"
  : >"$FAKE_STATE/installed"
}

# drv <install.sh args...>: run the module; DRIVERS_* come from the caller.
drv() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only drivers "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# installed_has <pkg...>: every package was requested through apt-get install.
installed_has() {
  local p
  for p in "$@"; do grep -q -- "^$p\$" "$FAKE_STATE/installed" || return 1; done
}
installed_lacks() {
  local p
  for p in "$@"; do ! grep -q -- "^$p\$" "$FAKE_STATE/installed" || return 1; done
}

BASE=(mesa-vulkan-drivers mesa-va-drivers libgl1-mesa-dri)

# --- dry-run ----------------------------------------------------------------
reset_state
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS=amd drv --dry-run
[[ "$rc" == 0 ]] && [[ ! -s "$APT" ]] && grep -q 'install packages: .*amd64-microcode' "$WORK/out"
check "dry-run lists the packages and runs no apt-get" $?

# --- AMD CPU and AMD GPU (the owner's host) ---------------------------------
reset_state
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS=amd drv
[[ "$rc" == 0 ]]
check "amd/amd: run succeeds" $?
installed_has amd64-microcode firmware-amd-graphics "${BASE[@]}"
check "amd/amd: amd64-microcode, firmware-amd-graphics and the mesa base" $?
installed_lacks intel-microcode intel-media-va-driver
check "amd/amd: no intel packages" $?
[[ "$(grep -c ' install ' "$APT")" == 1 ]]
check "amd/amd: one apt-get install call" $?
! grep -Eq 'i386|lib32|:i386|nvidia' "$APT"
check "amd/amd: no i386, lib32 or nvidia package" $?
drv
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$APT" ]]
check "amd/amd: second run reports total changes: 0 and runs no apt-get" $?

# --- Intel CPU and Intel GPU -------------------------------------------------
reset_state
DRIVERS_CPU_VENDOR=intel DRIVERS_GPU_VENDORS=intel drv
[[ "$rc" == 0 ]] && installed_has intel-microcode intel-media-va-driver "${BASE[@]}" &&
  installed_lacks amd64-microcode firmware-amd-graphics
check "intel/intel: intel-microcode, intel-media-va-driver and the mesa base only" $?

# --- Intel CPU with an AMD GPU, and both GPUs --------------------------------
reset_state
DRIVERS_CPU_VENDOR=intel DRIVERS_GPU_VENDORS=amd drv
installed_has intel-microcode firmware-amd-graphics "${BASE[@]}" && installed_lacks amd64-microcode intel-media-va-driver
check "intel cpu with amd gpu: the vendors are chosen independently" $?
reset_state
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS="amd intel" drv
installed_has amd64-microcode firmware-amd-graphics intel-media-va-driver "${BASE[@]}"
check "amd and intel GPUs together: both sets of packages" $?

# --- VM: virtio GPU, no vendor -----------------------------------------------
reset_state
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS="" drv
[[ "$rc" == 0 ]] && installed_has amd64-microcode "${BASE[@]}" && installed_lacks firmware-amd-graphics intel-media-va-driver
check "no GPU vendor (VM): microcode and the mesa base, no vendor-specific package" $?
grep -q 'no AMD, Intel or NVIDIA GPU' "$WORK/out"
check "no GPU vendor: logs that the vendor-specific part is skipped" $?
! grep -q '\[warn\]' "$WORK/out"
check "no GPU vendor: no warning (a VM is a normal case)" $?

# --- NVIDIA: warn only --------------------------------------------------------
reset_state
DRIVERS_CPU_VENDOR=intel DRIVERS_GPU_VENDORS=nvidia drv
[[ "$rc" == 0 ]] && installed_has intel-microcode "${BASE[@]}" && ! grep -qi 'nvidia' "$APT"
check "nvidia: nothing nvidia is installed" $?
grep -q '\[warn\].*nvidia-driver' "$WORK/out"
check "nvidia: warns and points to Kali's nvidia-driver" $?
reset_state
DRIVERS_CPU_VENDOR=intel DRIVERS_GPU_VENDORS="intel nvidia" drv
installed_has intel-media-va-driver && ! grep -qi 'nvidia' "$APT" && grep -q 'nvidia-driver' "$WORK/out"
check "intel plus nvidia (hybrid laptop): intel packages, nvidia only warned" $?

# --- unknown CPU -----------------------------------------------------------
reset_state
DRIVERS_CPU_VENDOR=unknown DRIVERS_GPU_VENDORS="" drv
[[ "$rc" == 0 ]] && installed_lacks amd64-microcode intel-microcode && grep -q '\[warn\].*unknown CPU' "$WORK/out"
check "unknown cpu: no microcode, a warning, the run still succeeds" $?
reset_state
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS="matrox" drv
[[ "$rc" == 0 ]] && grep -q 'unknown GPU vendor' "$WORK/out"
check "unknown gpu vendor string: ignored with a message" $?

# --- non-free-firmware not available ------------------------------------------
reset_state
FAKE_NO_CANDIDATE="amd64-microcode firmware-amd-graphics" DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS=amd drv
[[ "$rc" == 0 ]] && installed_has "${BASE[@]}" && installed_lacks amd64-microcode firmware-amd-graphics &&
  grep -q '\[warn\].*non-free-firmware' "$WORK/out"
check "packages with no candidate (non-free-firmware off): skipped with a warning, the rest installs" $?

# --- already installed: nothing to do -----------------------------------------
reset_state
printf '%s\n' amd64-microcode firmware-amd-graphics "${BASE[@]}" >"$FAKE_STATE/installed"
DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS=amd drv
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$APT" ]]
check "everything already installed: total changes: 0, no apt-get" $?

# --- failure -----------------------------------------------------------------
reset_state
FAKE_APT_RC=100 DRIVERS_CPU_VENDOR=amd DRIVERS_GPU_VENDORS=amd drv
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?

# --- the module itself ---------------------------------------------------------
! grep -Eq 'i386|lib32|nvidia-inst|multilib' "$REPO_ROOT/modules/10-drivers.sh" 2>/dev/null
check "the module source has no i386, lib32, multilib or nvidia-inst" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
