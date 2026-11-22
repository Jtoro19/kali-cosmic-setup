#!/usr/bin/env bash
# tests/test-packages-dev.sh: modules/16-packages-dev.sh (dev list, VS Code and
# Claude Code vendor repos, uv/engram/gentle-ai release binaries, Docker and
# MariaDB services) against fake apt-get, dpkg-query, apt-cache, curl, gpg,
# systemctl, debconf and usermod. Never touches the real system.
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

MS_FPR=BC528686B50D79E339D3721CEB3E94ADBE1229CF
CC_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
MS_KEY=/etc/apt/keyrings/packages.microsoft.gpg
CC_KEY=/etc/apt/keyrings/claude-code.gpg
MS_URL=https://packages.microsoft.com/keys/microsoft.asc
CC_URL=https://downloads.claude.ai/keys/claude-code.asc
UV_TGZ=uv-x86_64-unknown-linux-gnu.tar.gz
EN_TGZ=engram_3.7.2_linux_amd64.tar.gz
GA_TGZ=gentle-ai_4.6.0_linux_amd64.tar.gz
UV_URL=https://github.com/astral-sh/uv/releases/download/0.13.9/$UV_TGZ
EN_URL=https://github.com/Gentleman-Programming/engram/releases/download/v3.7.2/$EN_TGZ
GA_URL=https://github.com/Gentleman-Programming/gentle-ai/releases/download/v4.6.0/$GA_TGZ
BIN="$KCS_ROOT/usr/local/bin"
APT="$FAKE_STATE/apt.log"
ALL="$FAKE_STATE/all.log"
DROPIN="$KCS_ROOT/etc/mysql/mariadb.conf.d/99-kali-cosmic-localhost.cnf"

# mk_tool <dir> <name> <version> <tarball> <member...>: a tarball whose members
# are scripts that print "<name> <version>".
mk_tool() {
  local dir="$1" name="$2" ver="$3" tgz="$4" m
  shift 4
  rm -rf -- "$WORK/pkg" && mkdir -p "$WORK/pkg"
  for m in "$@"; do
    mkdir -p "$WORK/pkg/$(dirname "$m")"
    printf '#!/bin/sh\necho "%s %s (fixture)"\n' "$name" "$ver" >"$WORK/pkg/$m"
    chmod +x "$WORK/pkg/$m"
  done
  tar -czf "$dir/$tgz" -C "$WORK/pkg" "$@"
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${TMPDIR:?}"
  mkdir -p "$FAKE_STATE/curl-files" "$KCS_ROOT" "$TMPDIR"
  : >"$FAKE_STATE/installed"
  printf '%s\n' docker.service mariadb.service >"$FAKE_STATE/units"
  printf '%s\n' docker plugdev >"$FAKE_STATE/groups"
  fake_key_file "$FAKE_STATE/curl-files/microsoft.asc" "$MS_FPR"
  fake_key_file "$FAKE_STATE/curl-files/claude-code.asc" "$CC_FPR"
  mk_tool "$FAKE_STATE/curl-files" uv 0.13.9 "$UV_TGZ" uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx
  mk_tool "$FAKE_STATE/curl-files" engram 3.7.2 "$EN_TGZ" engram
  mk_tool "$FAKE_STATE/curl-files" gentle-ai 4.6.0 "$GA_TGZ" gentle-ai
  # The dependency module (packages) runs once up front with its own fixtures,
  # so the dev runs below start from a machine that already has it.
  local f
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' >"$WORK/brave.key"
  for f in DBF1A116C220B8C7164F98230686B78420038257 47D32A74E9A9E013A4B4926C68D513D36A73CD96 \
    B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0; do printf 'FPR=%s\n' "$f" >>"$WORK/brave.key"; done
  printf '%s\n' '-----END PGP PUBLIC KEY BLOCK-----' >>"$WORK/brave.key"
  cp -- "$WORK/brave.key" "$FAKE_STATE/curl-files/brave-browser-archive-keyring.gpg"
  printf 'not a real deb, a fixture\n' >"$FAKE_STATE/curl-files/peazip_11.4.0.LINUX.GTK2-1_amd64.deb"
  export PACKAGES_PEAZIP_SHA256
  PACKAGES_PEAZIP_SHA256="$(sha256sum "$FAKE_STATE/curl-files/peazip_11.4.0.LINUX.GTK2-1_amd64.deb" | awk '{ print $1 }')"
  PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only packages >"$WORK/out-packages" 2>&1 </dev/null || cat -- "$WORK/out-packages"
  export PACKAGES_DEV_UV_SHA256 PACKAGES_DEV_ENGRAM_SHA256 PACKAGES_DEV_GENTLE_AI_SHA256
  PACKAGES_DEV_UV_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$UV_TGZ" | awk '{ print $1 }')"
  PACKAGES_DEV_ENGRAM_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$EN_TGZ" | awk '{ print $1 }')"
  PACKAGES_DEV_GENTLE_AI_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$GA_TGZ" | awk '{ print $1 }')"
}

# pd <install.sh args...>: run the module. The PACKAGES_DEV_*_SHA256 overrides
# are honoured only with KCS_TEST=1 (PD_KCS_TEST= empty simulates a real run).
pd() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" USER=tester KCS_TEST="${PD_KCS_TEST-1}" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only packages-dev "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

installed_has() {
  local p
  for p in "$@"; do grep -qx -- "$p" "$FAKE_STATE/installed" || return 1; done
}
installed_lacks() {
  local p
  for p in "$@"; do ! grep -qx -- "$p" "$FAKE_STATE/installed" || return 1; done
}

# --- module metadata and routing ---------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^packages-dev +yes ' <<<"$out" >/dev/null
check "metadata: packages-dev is listed as opt-in" $?
PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" "$REPO_ROOT/install.sh" --all --dry-run >"$WORK/out" 2>&1 </dev/null
! grep -q 'module: packages-dev' "$WORK/out"
check "--all skips the opt-in packages-dev module" $?
pd --dry-run
p1="$(grep -n 'module: packages$' "$WORK/out" | head -n 1 | cut -d: -f1)"
p2="$(grep -n 'module: packages-dev$' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$p1" && -n "$p2" && "$p1" -lt "$p2" ]]
check "--only packages-dev pulls in its dependency packages first" $?

# --- dry-run ----------------------------------------------------------------
reset_state
pd --dry-run
[[ "$rc" == 0 && ! -s "$APT" && ! -s "$FAKE_STATE/curl.log" && ! -e "$KCS_ROOT$MS_KEY" && ! -e "$DROPIN" && ! -e "$BIN/uv" ]]
check "dry-run: exit 0, no apt-get, no download, no key, drop-in or binary written" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "dry-run: no temporary directory or file is created" $?
[[ ! -s "$FAKE_STATE/usermod.log" ]] && ! grep -q '^enable' "$FAKE_STATE/systemctl.log" 2>/dev/null
check "dry-run: no group change and no unit is enabled" $?
grep -q 'dry-run.*uv' "$WORK/out" && grep -q 'dry-run.*engram' "$WORK/out" && grep -q 'dry-run.*gentle-ai' "$WORK/out"
check "dry-run: reports that uv, engram and gentle-ai would be installed" $?

# --- full run ---------------------------------------------------------------
reset_state
pd
[[ "$rc" == 0 ]]
check "run: exit 0" $?
installed_has build-essential git golang-go rustc cargo python3-venv python3-pip python3-pil \
  python3-pyqt5 python3-reportlab docker.io docker-buildx docker-compose mariadb-server meld just \
  adb fastboot android-udev-rules shellcheck
check "run: the dev list is installed with the Kali names" $?
installed_lacks base-devel go rust python-pillow docker-compose-v2 android-tools android-udev
check "run: Arch names are not requested" $?
installed_has code claude-code
check "run: code and claude-code are installed" $?
[[ -f "$KCS_ROOT$MS_KEY" && -f "$KCS_ROOT$CC_KEY" ]] &&
  grep -qx "$MS_URL" "$FAKE_STATE/curl.log" && grep -qx "$CC_URL" "$FAKE_STATE/curl.log"
check "run: both vendor keys are installed under /etc/apt/keyrings from the official URLs" $?
SRC="$KCS_ROOT/etc/apt/sources.list.d/vscode.sources"
grep -qx 'Types: deb' "$SRC" && grep -qx 'URIs: https://packages.microsoft.com/repos/code' "$SRC" &&
  grep -qx 'Suites: stable' "$SRC" && grep -qx 'Components: main' "$SRC" &&
  grep -qx "Signed-By: $MS_KEY" "$SRC"
check "vscode: deb822 sources file with Signed-By pointing at the Microsoft keyring" $?
SRC2="$KCS_ROOT/etc/apt/sources.list.d/claude-code.sources"
grep -qx 'URIs: https://downloads.claude.ai/claude-code/apt/stable' "$SRC2" &&
  grep -qx 'Suites: stable' "$SRC2" && grep -qx 'Components: main' "$SRC2" &&
  grep -qx "Signed-By: $CC_KEY" "$SRC2"
check "claude-code: deb822 sources file for the official stable apt repo with Signed-By" $?
for pair in "vscode:code:packages.microsoft.com" "claude-code:claude-code:downloads.claude.ai"; do
  IFS=: read -r name pkg host <<<"$pair"
  PIN="$KCS_ROOT/etc/apt/preferences.d/$name"
  allow="$(grep -n "^Package: $pkg\$" "$PIN" | head -n 1 | cut -d: -f1)"
  block="$(grep -n '^Package: \*$' "$PIN" | head -n 1 | cut -d: -f1)"
  [[ -n "$allow" && -n "$block" && "$allow" -lt "$block" ]] &&
    [[ "$(grep -c "^Pin: origin \"$host\"\$" "$PIN")" == 2 ]] && grep -qx 'Pin-Priority: -1' "$PIN"
  check "$name: the pin allows only $pkg from $host (first), then blocks the rest" $?
done
# The VS Code deb must not add its own repo: the answer is preseeded before install.
grep -qx 'code code/add-microsoft-repo boolean false' "$FAKE_STATE/debconf.log"
check "vscode: code/add-microsoft-repo is preseeded to false" $?
pre="$(grep -n '^debconf-set-selections' "$ALL" | head -n 1 | cut -d: -f1)"
inst="$(grep -n 'apt-get .*install.* code' "$ALL" | head -n 1 | cut -d: -f1)"
upd="$(grep -n 'apt-get .* update' "$ALL" | tail -n 1 | cut -d: -f1)"
[[ -n "$pre" && -n "$inst" && -n "$upd" && "$pre" -lt "$inst" && "$upd" -lt "$inst" ]]
check "vscode: the answer is preseeded and the lists refreshed before code is installed" $?
# Release binaries: system scope, pinned versions, 0755.
for b in uv uvx engram gentle-ai; do
  [[ -x "$BIN/$b" && "$(stat -c %a "$BIN/$b")" == 755 ]] || break
done
check "tools: uv, uvx, engram and gentle-ai are installed to /usr/local/bin with mode 0755" $?
[[ "$("$BIN/uv" --version)" == 'uv 0.13.9'* && "$("$BIN/engram" --version)" == 'engram 3.7.2'* &&
  "$("$BIN/gentle-ai" --version)" == 'gentle-ai 4.6.0'* ]]
check "tools: the installed binaries report the pinned versions" $?
grep -qx "$UV_URL" "$FAKE_STATE/curl.log" && grep -qx "$EN_URL" "$FAKE_STATE/curl.log" &&
  grep -qx "$GA_URL" "$FAKE_STATE/curl.log"
check "tools: the archives come from the pinned GitHub release URLs" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "run: no temporary files are left behind" $?
[[ "$(wc -l <"$FAKE_STATE/curl-args.log")" -ge 5 ]] &&
  ! grep -qv -e "--proto =https" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--tlsv1.2" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--retry 2" "$FAKE_STATE/curl-args.log"
check "downloads: curl is https-only with TLS 1.2 and a bounded retry" $?

# Services: MariaDB drop-in first, then the units; docker group for the user.
grep -qx '\[mysqld\]' "$DROPIN" && grep -qx 'bind-address = 127.0.0.1' "$DROPIN"
check "mariadb: a drop-in binds the server to 127.0.0.1" $?
grep -qx 'docker.service' "$FAKE_STATE/enabled" && grep -qx 'mariadb.service' "$FAKE_STATE/enabled"
check "services: docker.service and mariadb.service are enabled" $?
grep -q '^enable --now -- docker.service$' "$FAKE_STATE/systemctl.log" &&
  grep -q '^enable --now -- mariadb.service$' "$FAKE_STATE/systemctl.log"
check "services: both units are enabled and started with enable --now" $?
! grep -qi 'tcp://\|2375\|2376' "$ALL" "$FAKE_STATE/systemctl.log" && ! rg -q 'tcp://' "$REPO_ROOT/modules/16-packages-dev.sh" "$REPO_ROOT/files/packages" 2>/dev/null
check "services: Docker is not configured for a TCP listener" $?
grep -qx 'usermod -aG docker tester' "$ALL" && grep -q 're-login' "$WORK/out"
check "docker: the invoking user is added to the docker group, with a re-login note" $?
grep -qx 'usermod -aG plugdev tester' "$ALL"
check "adb: the invoking user is added to plugdev, the group of android-udev-rules" $?
! rg -q 'adbusers' "$REPO_ROOT/modules/16-packages-dev.sh"
check "adb: no adbusers group (Kali's rules use plugdev)" $?
dr="$(grep -n "99-kali-cosmic-localhost.cnf" "$WORK/out" | head -n 1 | cut -d: -f1)"
en="$(grep -n 'enable system unit: mariadb.service' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$dr" && -n "$en" && "$dr" -lt "$en" ]]
check "mariadb: the drop-in is written before the unit is enabled and started" $?

# --- second run changes nothing ---------------------------------------------
pd
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$APT" && ! -s "$FAKE_STATE/curl.log" ]] &&
  [[ ! -s "$FAKE_STATE/usermod.log" ]] && ! grep -q '^enable' "$FAKE_STATE/systemctl.log" &&
  ! grep -q 'restart' "$FAKE_STATE/systemctl.log"
check "second run: total changes: 0, no apt-get, no download, no enable, no restart, no usermod" $?
! compgen -G "$KCS_ROOT/etc/*/*.bak.*" >/dev/null && ! compgen -G "$KCS_ROOT/etc/*/*/*.bak.*" >/dev/null
check "second run: no backup files are created" $?

# --- MariaDB already running: the drop-in change restarts it -----------------
reset_state
printf 'mariadb.service\n' >"$FAKE_STATE/active"
printf 'mariadb.service\n' >"$FAKE_STATE/enabled"
pd
grep -q '^restart -- mariadb.service$' "$FAKE_STATE/systemctl.log"
check "mariadb: an active server is restarted when the drop-in is first written" $?
reset_state
pd
! grep -q 'restart' "$FAKE_STATE/systemctl.log"
check "mariadb: a server that was not running is started, not restarted" $?

# --- vendor key fingerprint mismatch -----------------------------------------
reset_state
fake_key_file "$FAKE_STATE/curl-files/microsoft.asc" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
pd
[[ "$rc" != 0 ]] && grep -qi 'fingerprint' "$WORK/out" && [[ ! -e "$KCS_ROOT$MS_KEY" && ! -e "$SRC" ]]
check "vscode: a key with another fingerprint fails the module and installs nothing" $?
installed_lacks code && [[ ! -e "$BIN/uv" ]]
check "vscode: code is not installed after the failure" $?
reset_state
fake_key_file "$FAKE_STATE/curl-files/claude-code.asc" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
pd
[[ "$rc" != 0 ]] && grep -qi 'fingerprint' "$WORK/out" && [[ ! -e "$KCS_ROOT$CC_KEY" && ! -e "$SRC2" ]] && installed_lacks claude-code
check "claude-code: a key with another fingerprint fails the module and installs nothing" $?

# --- release checksum mismatch ------------------------------------------------
reset_state
export PACKAGES_DEV_UV_SHA256=1111111111111111111111111111111111111111111111111111111111111111
pd
[[ "$rc" != 0 ]] && grep -qi 'checksum mismatch' "$WORK/out" && [[ ! -e "$BIN/uv" && ! -e "$BIN/uvx" ]]
check "uv: a checksum mismatch fails the module and installs nothing" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "uv: the temporary download is removed after a mismatch" $?
reset_state
PD_KCS_TEST='' pd
export PACKAGES_DEV_UV_SHA256=1111111111111111111111111111111111111111111111111111111111111111
[[ "$rc" != 0 && ! -e "$BIN/uv" ]]
check "tools: the pinned sha256 rejects the fixture when the test marker is absent" $?
for pin in \
  '_PACKAGES_DEV_UV_SHA256=.?a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5' \
  '_PACKAGES_DEV_ENGRAM_SHA256=.?8db9d5db1c1574b8b830aac4ffbe86c024014aed6b9a3f0406ac3361a152cdf0' \
  '_PACKAGES_DEV_GENTLE_AI_SHA256=.?c645e8551f6e3f79831b142a6b087795dc3217e02e9dafb5b701dc4373b33e7d'; do
  grep -Eq "^$pin" "$REPO_ROOT/modules/16-packages-dev.sh" || break
done
check "tools: the module pins the verified sha256 of uv 0.13.9, engram 3.7.2 and gentle-ai 4.6.0" $?

# --- version checks: upgrade older, never downgrade newer ----------------------
reset_state
mkdir -p "$BIN"
printf '#!/bin/sh\necho "uv 0.9.0 (old)"\n' >"$BIN/uv"
printf '#!/bin/sh\necho "uvx 0.9.0 (old)"\n' >"$BIN/uvx"
chmod +x "$BIN/uv" "$BIN/uvx"
pd
[[ "$("$BIN/uv" --version)" == 'uv 0.13.9'* ]] && grep -qx "$UV_URL" "$FAKE_STATE/curl.log"
check "uv: an older installed version is upgraded" $?
files=("$BIN"/*)
! compgen -G "$BIN/*.bak.*" >/dev/null && ((${#files[@]} == 4))
check "uv: the replaced release binary is not backed up (no stale .bak executable on PATH)" $?
reset_state
mkdir -p "$BIN"
printf '#!/bin/sh\necho "uv 0.20.1 (new)"\n' >"$BIN/uv"
printf '#!/bin/sh\necho "uvx 0.20.1 (new)"\n' >"$BIN/uvx"
chmod +x "$BIN/uv" "$BIN/uvx"
pd
! grep -qx "$UV_URL" "$FAKE_STATE/curl.log" && [[ "$("$BIN/uv" --version)" == 'uv 0.20.1'* ]]
check "uv: a newer installed version (0.20.1 > 0.13.9) is not downgraded" $?

# --- version probe: the first dotted number of the output ----------------------
reset_state
mkdir -p "$BIN"
printf '#!/bin/sh\necho "uv 0.13.9 (fixture)"\n' >"$BIN/uv"
printf '#!/bin/sh\necho "uvx 0.13.9 (fixture)"\n' >"$BIN/uvx"
printf '#!/bin/sh\necho "v3.7.2"\n' >"$BIN/engram"
printf '#!/bin/sh\necho "gentle-ai version 4.6.0"\n' >"$BIN/gentle-ai"
chmod +x "$BIN"/*
pd
[[ "$rc" == 0 ]] && ! grep -q 'github.com' "$FAKE_STATE/curl.log"
check "version probe: 'v3.7.2' and 'gentle-ai version 4.6.0' count as the pinned versions (no download)" $?
reset_state
mkdir -p "$BIN"
printf '#!/bin/sh\necho "gentle-ai version 4.1.0"\n' >"$BIN/gentle-ai"
chmod +x "$BIN/gentle-ai"
pd
[[ "$("$BIN/gentle-ai" --version)" == 'gentle-ai 4.6.0'* ]] && grep -qx "$GA_URL" "$FAKE_STATE/curl.log"
check "version probe: 'gentle-ai version 4.1.0' is recognised as older and upgraded" $?

# --- the debconf check survives a long output under pipefail --------------------
reset_state
export FAKE_DEBCONF_BIG=1
pd
pd
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && ! grep -q 'debconf: code/add-microsoft-repo' "$WORK/out"
check "debconf: the answer check does not break under pipefail (second run reports 0 changes)" $?
unset FAKE_DEBCONF_BIG

# --- temp dir cleanup on a fail-fast exit ---------------------------------------
reset_state
mkdir -p "$KCS_ROOT/usr/local"
printf 'not a directory\n' >"$KCS_ROOT/usr/local/bin"
pd
[[ "$rc" != 0 && -z "$(ls -A "$TMPDIR")" ]]
check "cleanup: the temporary download directory is removed when the install step exits" $?

# --- the docker group warning -----------------------------------------------------
reset_state
pd
grep -q 'root-equivalent' "$WORK/out"
check "docker: the run warns that docker group membership is root-equivalent" $?

# --- README revert row ------------------------------------------------------------
grep '^| packages-dev ' "$REPO_ROOT/README.md" | grep -q 'docker.socket'
check "README: the packages-dev revert row stops docker.socket too" $?

# --- code postinst adds its own repo despite the answer: it is cleaned up -------
reset_state
export FAKE_CODE_ADDS_REPO=1
pd
[[ "$rc" == 0 && ! -e "$KCS_ROOT/etc/apt/trusted.gpg.d/microsoft.gpg" && -e "$KCS_ROOT/usr/share/keyrings/microsoft.gpg" ]] &&
  [[ -f "$SRC" ]] && grep -qx "Signed-By: $MS_KEY" "$SRC"
check "vscode: a global trust key the deb adds is removed; the inert keyring and our sources file stay" $?
pd
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "vscode: after the cleanup a further run reports total changes: 0" $?
unset FAKE_CODE_ADDS_REPO
TG="$KCS_ROOT/etc/apt/trusted.gpg.d/microsoft.gpg"
reset_state
mkdir -p "$KCS_ROOT/etc/apt/trusted.gpg.d" "$KCS_ROOT/usr/share/keyrings"
echo "the admin's own key" >"$TG"
echo "deb keyring" >"$KCS_ROOT/usr/share/keyrings/microsoft.gpg"
pd
[[ "$rc" == 0 && -f "$TG" && "$(<"$TG")" == "the admin's own key" ]] && grep -qi 'leaving it alone' "$WORK/out"
check "vscode: a different microsoft.gpg in trusted.gpg.d (the admin's file) is kept with a warning" $?
pd
grep -q 'total changes: 0' "$WORK/out"
check "vscode: keeping the admin's file leaves a further run at total changes: 0" $?
reset_state
mkdir -p "$KCS_ROOT/etc/apt/trusted.gpg.d"
ln -s /usr/share/keyrings/microsoft.gpg "$TG"
pd
[[ "$rc" == 0 && ! -e "$TG" && ! -L "$TG" ]]
check "vscode: a symlink microsoft.gpg in trusted.gpg.d is removed" $?
reset_state
mkdir -p "$KCS_ROOT/etc/apt/trusted.gpg.d"
echo "orphan key" >"$TG"
pd
[[ "$rc" == 0 && -f "$TG" ]]
check "vscode: a regular microsoft.gpg without the deb keyring to compare with is kept" $?

# --- a failed update then a re-run: the vendor packages still get their lists ---
reset_state
export FAKE_NEEDS_UPDATE="code claude-code"
FAKE_APT_FAIL_UPDATE_NTH=2 pd
[[ "$rc" != 0 ]] && installed_lacks code
check "update: a failed apt-get update fails the module before code is installed" $?
pd
[[ "$rc" == 0 ]] && installed_has code claude-code
check "update: the re-run refreshes the lists again and installs both vendor packages" $?
unset FAKE_NEEDS_UPDATE

# --- masked docker unit is left alone; docker group missing is skipped -----------
reset_state
printf 'docker.service\n' >"$FAKE_STATE/masked"
pd
[[ "$rc" == 0 ]] && ! grep -qx 'docker.service' "$FAKE_STATE/enabled" && grep -q 'masked' "$WORK/out"
check "docker: a masked unit is skipped with a note, the module still succeeds" $?
reset_state
: >"$FAKE_STATE/groups"
pd
[[ "$rc" == 0 && ! -s "$FAKE_STATE/usermod.log" ]]
check "groups: a group that does not exist is skipped" $?

# --- apt failure -------------------------------------------------------------------
reset_state
FAKE_APT_RC=100 pd
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?

# --- static checks on the data and the module --------------------------------------
LIST="$REPO_ROOT/files/packages/dev.apt"
pkgs="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$')"
! grep -Eqx 'base-devel|go|rust|python|python-pillow|python-pyqt5|python-reportlab|android-tools|android-udev|docker-compose-v2|uv|code|claude-code|visual-studio-code-bin|engram-bin|gentle-ai' <<<"$pkgs"
check "dev.apt: no Arch names and no vendor or release-binary tools in the list" $?
[[ -z "$(sort <<<"$pkgs" | uniq -d)" ]]
check "dev.apt: no duplicate entries" $?
! grep -Eq 'i386|lib32|multilib|yay|pacman|flatpak|npm install|wget|curl .*\| *(ba)?sh|claude\.ai/install' "$REPO_ROOT/modules/16-packages-dev.sh"
check "the module has no pacman, flatpak, npm, wget or curl-pipe-shell installer" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
