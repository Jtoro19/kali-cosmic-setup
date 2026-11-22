#!/usr/bin/env bash
# tests/test-packages-ai.sh: modules/22-packages-ai.sh (Ollama release archives,
# the ollama user and unit, localhost binding) against fake apt-get, curl,
# systemctl, useradd and usermod, with tiny .tar.zst fixtures. Never touches the
# real system and never downloads.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2030/SC2031: sections that run in a ( ) subshell do so on purpose.
# shellcheck disable=SC2251,SC2319,SC2030,SC2031
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
export TMPDIR="$WORK/tmp"
make_fakes "$WORK/bin"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

VER=0.40.17
BASE_TGZ=ollama-linux-amd64.tar.zst
ROCM_TGZ=ollama-linux-amd64-rocm.tar.zst
BASE_URL="https://github.com/ollama/ollama/releases/download/v$VER/$BASE_TGZ"
ROCM_URL="https://github.com/ollama/ollama/releases/download/v$VER/$ROCM_TGZ"
PREFIX="$KCS_ROOT/usr/local"
UNIT="$KCS_ROOT/etc/systemd/system/ollama.service"
ALL="$FAKE_STATE/all.log"

# mk_archives: tiny fixtures with the layout of the official archives (bin/ and
# lib/ollama/); the fixture binary reports the version like the real client.
mk_archives() {
  local d="$WORK/pkg"
  rm -rf -- "$d"
  mkdir -p "$d/base/bin" "$d/base/lib/ollama" "$d/rocm/lib/ollama/rocm"
  cat >"$d/base/bin/ollama" <<EOS
#!/bin/sh
echo "ollama \$*" >>"\$FAKE_STATE/ollama-calls.log"
echo "Warning: could not connect to a running Ollama instance" >&2
echo "Warning: client version is $VER" >&2
EOS
  chmod +x "$d/base/bin/ollama"
  echo cpu >"$d/base/lib/ollama/libggml-cpu.so"
  echo rocm >"$d/rocm/lib/ollama/rocm/librocblas.so"
  tar --zstd -cf "$FAKE_STATE/curl-files/$BASE_TGZ" -C "$d/base" bin lib
  tar --zstd -cf "$FAKE_STATE/curl-files/$ROCM_TGZ" -C "$d/rocm" lib
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${TMPDIR:?}"
  mkdir -p "$FAKE_STATE/curl-files" "$KCS_ROOT" "$TMPDIR"
  : >"$FAKE_STATE/installed"
  : >"$FAKE_STATE/units"
  printf '%s\n' render video >"$FAKE_STATE/groups"
  mk_archives
  export PACKAGES_AI_SHA256 PACKAGES_AI_ROCM_SHA256
  PACKAGES_AI_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$BASE_TGZ" | awk '{ print $1 }')"
  PACKAGES_AI_ROCM_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$ROCM_TGZ" | awk '{ print $1 }')"
  # The dependency module (packages) runs once up front with its own fixtures.
  local f
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' >"$WORK/brave.key"
  for f in DBF1A116C220B8C7164F98230686B78420038257 47D32A74E9A9E013A4B4926C68D513D36A73CD96 \
    B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0; do printf 'FPR=%s\n' "$f" >>"$WORK/brave.key"; done
  printf '%s\n' '-----END PGP PUBLIC KEY BLOCK-----' >>"$WORK/brave.key"
  cp -- "$WORK/brave.key" "$FAKE_STATE/curl-files/brave-browser-archive-keyring.gpg"
  printf 'not a real deb, a fixture\n' >"$FAKE_STATE/curl-files/peazip_11.4.0.LINUX.GTK2-1_amd64.deb"
  local pz
  pz="$(sha256sum "$FAKE_STATE/curl-files/peazip_11.4.0.LINUX.GTK2-1_amd64.deb" | awk '{ print $1 }')"
  PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    PACKAGES_PEAZIP_SHA256="$pz" "$REPO_ROOT/install.sh" --only packages >"$WORK/out-packages" 2>&1 </dev/null || cat -- "$WORK/out-packages"
  : >"$FAKE_STATE/curl.log"
}

# pai <install.sh args...>: run the module with no GPU unless PACKAGES_AI_GPU_VENDORS is set.
pai() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" USER=tester KCS_TEST="${PAI_KCS_TEST-1}" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    PACKAGES_AI_GPU_VENDORS="${PACKAGES_AI_GPU_VENDORS-}" XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only packages-ai "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata and routing -----------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^packages-ai +yes ' <<<"$out" >/dev/null
check "metadata: packages-ai is listed as opt-in" $?
PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" "$REPO_ROOT/install.sh" --all --dry-run >"$WORK/out" 2>&1 </dev/null
! grep -q 'module: packages-ai' "$WORK/out"
check "--all skips the opt-in packages-ai module" $?
pai --dry-run
p1="$(grep -n 'module: packages$' "$WORK/out" | head -n 1 | cut -d: -f1)"
p2="$(grep -n 'module: packages-ai$' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$p1" && -n "$p2" && "$p1" -lt "$p2" ]]
check "--only packages-ai pulls in its dependency packages first" $?

# --- dry-run ------------------------------------------------------------------
reset_state
pai --dry-run
[[ "$rc" == 0 && ! -s "$FAKE_STATE/curl.log" && ! -e "$PREFIX/bin/ollama" && ! -e "$UNIT" ]] &&
  [[ ! -s "$FAKE_STATE/useradd.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "dry-run: exit 0, no download, no archive, user, unit or apt-get" $?
[[ -z "$(ls -A "$TMPDIR")" && ! -e "$KCS_ROOT/var/tmp" ]]
check "dry-run: no temporary directory is created" $?
grep -q "dry-run.*$BASE_URL" "$WORK/out" && grep -q "ollama $VER" "$WORK/out"
check "dry-run: reports the pinned version and the archive that would be downloaded" $?

# --- generic run (no GPU) -----------------------------------------------------
reset_state
pai
[[ "$rc" == 0 ]]
check "generic: exit 0" $?
grep -qx 'zstd' "$FAKE_STATE/installed"
check "generic: zstd (needed to unpack the archive) is installed" $?
[[ -x "$PREFIX/bin/ollama" && "$(stat -c %a "$PREFIX/bin/ollama")" == 755 && -f "$PREFIX/lib/ollama/libggml-cpu.so" ]]
check "generic: bin/ollama (0755) and lib/ollama are installed under /usr/local" $?
[[ ! -e "$PREFIX/lib/ollama/rocm" ]] && ! grep -qx "$ROCM_URL" "$FAKE_STATE/curl.log"
check "generic: the ROCm archive is neither downloaded nor extracted" $?
grep -qx "$BASE_URL" "$FAKE_STATE/curl.log"
check "generic: the archive comes from the pinned GitHub release URL" $?
[[ "$(wc -l <"$FAKE_STATE/curl-args.log")" -ge 1 ]] && ! grep -qv -e "--proto =https" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--tlsv1.2" "$FAKE_STATE/curl-args.log"
check "generic: the download is https-only with TLS 1.2" $?
grep -q 'useradd' "$ALL" && grep -q -- '-r' "$FAKE_STATE/useradd.log" && grep -q -- '/usr/sbin/nologin' "$FAKE_STATE/useradd.log" &&
  grep -q -- '-d /usr/share/ollama' "$FAKE_STATE/useradd.log" && grep -qx 'ollama' "$FAKE_STATE/users"
check "user: a system user ollama with no login shell and home /usr/share/ollama is created" $?
grep -qx 'User=ollama' "$UNIT" && grep -qx 'Group=ollama' "$UNIT" && grep -qx 'ExecStart=/usr/local/bin/ollama serve' "$UNIT" &&
  grep -qx 'Environment="OLLAMA_HOST=127.0.0.1:11434"' "$UNIT" && grep -qx 'WantedBy=multi-user.target' "$UNIT"
check "unit: ollama.service runs as ollama with OLLAMA_HOST=127.0.0.1:11434" $?
! grep -Eq '0\.0\.0\.0|OLLAMA_ORIGINS|\[::\]' "$UNIT"
check "unit: no wildcard bind address and no extra origins" $?
r="$(grep -n '^daemon-reload' "$FAKE_STATE/systemctl.log" | head -n 1 | cut -d: -f1)"
e="$(grep -n '^enable --now -- ollama.service$' "$FAKE_STATE/systemctl.log" | head -n 1 | cut -d: -f1)"
[[ -n "$r" && -n "$e" && "$r" -lt "$e" ]]
check "unit: daemon-reload runs before ollama.service is enabled and started" $?
[[ -z "$(ls -A "$TMPDIR")" && -z "$(ls -A "$KCS_ROOT/var/tmp")" ]] && ! compgen -G "$PREFIX/.ollama-stage*" >/dev/null
check "generic: no temporary or staging files are left behind" $?
! grep -q '^restart' "$FAKE_STATE/systemctl.log"
check "generic: a first install starts the service once (enable --now), without a restart" $?
! grep -Eq '^(pull|run|create|serve)' "$FAKE_STATE/ollama-calls.log" 2>/dev/null
check "generic: no model is pulled and the binary is only asked for its version" $?
! grep -q 'NVIDIA' "$WORK/out"
check "generic: no NVIDIA warning without an NVIDIA GPU" $?

# --- second run changes nothing -----------------------------------------------
printf 'ollama.service\n' >"$FAKE_STATE/enabled"
printf 'ollama.service\n' >"$FAKE_STATE/active"
pai
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/curl.log" && ! -s "$FAKE_STATE/apt.log" ]] &&
  [[ ! -s "$FAKE_STATE/useradd.log" && ! -s "$FAKE_STATE/usermod.log" ]] && ! grep -q '^enable\|^restart' "$FAKE_STATE/systemctl.log"
check "second run: total changes: 0, no download, no user, no enable, no restart" $?
! compgen -G "$KCS_ROOT/etc/systemd/system/*.bak.*" >/dev/null
check "second run: no backup files are created" $?

# --- AMD GPU: ROCm overlay ----------------------------------------------------
reset_state
PACKAGES_AI_GPU_VENDORS=amd pai
[[ "$rc" == 0 && -f "$PREFIX/lib/ollama/rocm/librocblas.so" && -f "$PREFIX/lib/ollama/libggml-cpu.so" ]]
check "amd: the ROCm archive is extracted over the base archive (both libs present)" $?
b="$(grep -nx "$BASE_URL" "$FAKE_STATE/curl.log" | cut -d: -f1)"
a="$(grep -nx "$ROCM_URL" "$FAKE_STATE/curl.log" | cut -d: -f1)"
[[ -n "$a" && -n "$b" && "$b" -lt "$a" ]]
check "amd: the base archive is downloaded first, then the ROCm one" $?
grep -qx 'usermod -aG render ollama' "$ALL" && grep -qx 'usermod -aG video ollama' "$ALL"
check "amd: the ollama user joins render and video (GPU device access)" $?
printf 'ollama.service\n' >"$FAKE_STATE/enabled"
printf 'ollama.service\n' >"$FAKE_STATE/active"
PACKAGES_AI_GPU_VENDORS=amd pai
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/curl.log" && ! -s "$FAKE_STATE/usermod.log" ]]
check "amd: a second run reports total changes: 0 and downloads nothing" $?

# A generic install that later runs on an AMD host gains the ROCm build.
reset_state
pai
PACKAGES_AI_GPU_VENDORS=amd pai
[[ "$rc" == 0 && -f "$PREFIX/lib/ollama/rocm/librocblas.so" ]] && grep -qx "$ROCM_URL" "$FAKE_STATE/curl.log"
check "amd: a generic install is completed with the ROCm build when an AMD GPU shows up" $?

# Detection through lspci (no override): an AMD display device selects ROCm.
reset_state
mkdir -p "$WORK/bin-lspci"
printf '#!/bin/sh\necho "03:00.0 VGA compatible controller [0300]: AMD/ATI Navi 31 [Radeon RX 7900 XTX] [1002:744c] (rev c8)"\n' >"$WORK/bin-lspci/lspci"
chmod +x "$WORK/bin-lspci/lspci"
rm -f -- "${FAKE_STATE:?}"/*.log
rc=0
PATH="$WORK/bin-lspci:$WORK/bin:$PATH" USER=tester KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --only packages-ai >"$WORK/out" 2>&1 </dev/null || rc=$?
[[ "$rc" == 0 ]] && grep -qx "$ROCM_URL" "$FAKE_STATE/curl.log"
check "amd: detect_gpu_vendors (lspci 1002) selects the ROCm build" $?
# A virtio GPU (a VM) gets the generic build.
reset_state
printf '#!/bin/sh\necho "00:01.0 VGA compatible controller [0300]: Red Hat, Inc. Virtio 1.0 GPU [1af4:1050] (rev 01)"\n' >"$WORK/bin-lspci/lspci"
rm -f -- "${FAKE_STATE:?}"/*.log
rc=0
PATH="$WORK/bin-lspci:$WORK/bin:$PATH" USER=tester KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --only packages-ai >"$WORK/out" 2>&1 </dev/null || rc=$?
[[ "$rc" == 0 ]] && ! grep -qx "$ROCM_URL" "$FAKE_STATE/curl.log" && [[ ! -e "$PREFIX/lib/ollama/rocm" ]]
check "generic: a virtio GPU gets the generic build" $?

# --- NVIDIA: generic build plus a driver warning ---------------------------------
reset_state
PACKAGES_AI_GPU_VENDORS=nvidia pai
[[ "$rc" == 0 && ! -e "$PREFIX/lib/ollama/rocm" ]] && grep -q 'NVIDIA' "$WORK/out"
check "nvidia: the generic build is installed and the run warns that the driver is not installed here" $?

# --- versions: upgrade older, never downgrade newer ------------------------------
reset_state
mkdir -p "$PREFIX/bin" "$PREFIX/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 0.30.0"\n' >"$PREFIX/bin/ollama"
chmod +x "$PREFIX/bin/ollama"
echo stale >"$PREFIX/lib/ollama/libstale.so"
printf 'ollama.service\n' >"$FAKE_STATE/enabled"
printf 'ollama.service\n' >"$FAKE_STATE/active"
pai
[[ "$rc" == 0 && ! -e "$PREFIX/lib/ollama/libstale.so" && -f "$PREFIX/lib/ollama/libggml-cpu.so" ]] && grep -qx "$BASE_URL" "$FAKE_STATE/curl.log"
check "upgrade: an older Ollama is replaced and its stale libraries are removed" $?
grep -q '^restart -- ollama.service$' "$FAKE_STATE/systemctl.log"
check "upgrade: the running service is restarted once" $?
! compgen -G "$PREFIX/bin/*.bak.*" >/dev/null
check "upgrade: the replaced binary is not backed up" $?
reset_state
mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\necho "ollama version is 0.99.1"\n' >"$PREFIX/bin/ollama"
chmod +x "$PREFIX/bin/ollama"
mkdir -p "$PREFIX/lib/ollama"
echo "0.99.1 generic" >"$PREFIX/lib/ollama/.kali-cosmic-setup"
pai
! grep -qx "$BASE_URL" "$FAKE_STATE/curl.log" && [[ "$("$PREFIX/bin/ollama" --version)" == *0.99.1* ]]
check "newer: an installed 0.99.1 is not downgraded to $VER" $?

# --- failures ------------------------------------------------------------------------
reset_state
export PACKAGES_AI_SHA256=1111111111111111111111111111111111111111111111111111111111111111
pai
[[ "$rc" != 0 ]] && grep -qi 'checksum mismatch' "$WORK/out" && [[ ! -e "$PREFIX/bin/ollama" && ! -e "$UNIT" ]] &&
  ! grep -q '^enable' "$FAKE_STATE/systemctl.log"
check "checksum: a mismatch fails the module and installs nothing (no unit, no service)" $?
[[ -z "$(ls -A "$TMPDIR")" && -z "$(ls -A "$KCS_ROOT/var/tmp" 2>/dev/null)" ]]
check "checksum: the temporary download is removed after a mismatch" $?
reset_state
PAI_KCS_TEST='' pai
[[ "$rc" != 0 && ! -e "$PREFIX/bin/ollama" ]]
check "checksum: the pinned sha256 rejects the fixture when the test marker is absent" $?
reset_state
FAKE_CURL_FAIL=1 pai
[[ "$rc" != 0 && ! -e "$PREFIX/bin/ollama" && ! -e "$UNIT" ]]
check "download: a failed download fails the module and installs nothing" $?
unset FAKE_CURL_FAIL
reset_state
mkdir -p "$KCS_ROOT/usr"
printf 'not a directory\n' >"$KCS_ROOT/usr/local"
pai
[[ "$rc" != 0 && -z "$(ls -A "$TMPDIR")" && -z "$(ls -A "$KCS_ROOT/var/tmp" 2>/dev/null)" ]]
check "cleanup: the download directory is removed when an install step exits" $?

# --- static checks -------------------------------------------------------------------
reset_state
pinfail=0
for pin in \
  "_PACKAGES_AI_SHA256=.?1df9d6228bac5a22e420b242708c0d10e5b886db97bab99d446a41760f4e79af" \
  "_PACKAGES_AI_ROCM_SHA256=.?830e7068a16a3946edb1ee23f3ba455c9f966f9155be9934ca87f62004e20fe7" \
  "_PACKAGES_AI_VERSION=.?0.40.17"; do
  grep -Eq "^$pin" "$REPO_ROOT/modules/22-packages-ai.sh" || pinfail=1
done
((pinfail == 0))
check "the module pins ollama 0.40.17 and the sha256 of both archives from the release checksum file" $?
[[ -f "$REPO_ROOT/modules/22-packages-ai.sh" ]] && ! grep -Eq 'curl .*\| *(ba)?sh|ollama\.com/install|ollama (pull|run)|0\.0\.0\.0|wget' "$REPO_ROOT/modules/22-packages-ai.sh"
check "the module has no curl-pipe-shell installer, no wget, no model pull and no wildcard bind" $?
grep '^| packages-ai ' "$REPO_ROOT/README.md" | grep -q 'systemctl disable --now ollama'
check "README: the packages-ai row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
