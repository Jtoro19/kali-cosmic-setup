#!/usr/bin/env bash
# tests/test-apt.sh: the apt layer of lib/common.sh (pkg_installed,
# ensure_packages, key, sources and pin helpers). Uses fake commands on PATH
# and a temporary root prefix (KCS_ROOT), so nothing real is touched.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2251,SC2319
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
mkdir -p "$FAKE_STATE" "$KCS_ROOT"
make_fakes "$WORK/bin"
export PATH="$WORK/bin:$PATH"
: >"$FAKE_STATE/installed"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# h <code...>: run code with common.sh loaded, in a subshell with errexit on.
h() {
  (
    set -euo pipefail
    # shellcheck source=lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
    eval "$*"
  )
}

FPR=18575C957A7754E1C93B0EBA3DAEA102469D37CF
KEYURL=https://example.invalid/key.gpg
KEYDEST=/etc/apt/keyrings/test.gpg
export FAKE_KEY_FILE="$WORK/key.asc"

# --- pkg_installed ----------------------------------------------------------
printf 'alpha\nbeta:rc\n' >"$FAKE_STATE/installed"
h 'pkg_installed alpha'
check "pkg_installed: installed package" $?
! h 'pkg_installed beta'
check "pkg_installed: removed with config files is not installed" $?
! h 'pkg_installed gamma' 2>/dev/null
check "pkg_installed: unknown package is not installed" $?

# --- ensure_packages --------------------------------------------------------
: >"$FAKE_STATE/apt.log"
h 'ensure_packages alpha gamma delta' >/dev/null
check "ensure_packages: succeeds" $?
grep -q 'install .*gamma delta' "$FAKE_STATE/apt.log" && ! grep -q 'alpha' "$FAKE_STATE/apt.log"
check "ensure_packages: installs only the missing packages" $?
grep -q -- '-y' "$FAKE_STATE/apt.log" &&
  grep -q 'DEBIAN_FRONTEND=noninteractive' "$FAKE_STATE/apt.log" &&
  grep -q -- '-o Dpkg::Options::=--force-confdef' "$FAKE_STATE/apt.log" &&
  grep -q -- '-o Dpkg::Options::=--force-confold' "$FAKE_STATE/apt.log"
check "ensure_packages: noninteractive with confdef and confold" $?
! grep -q 'no-install-recommends' "$FAKE_STATE/apt.log"
check "ensure_packages: recommends are installed by default" $?
: >"$FAKE_STATE/apt.log"
h 'ensure_packages alpha gamma delta' >/dev/null
[[ ! -s "$FAKE_STATE/apt.log" ]]
check "ensure_packages: second run calls apt-get not at all" $?
h 'ensure_packages --no-install-recommends epsilon' >/dev/null
grep -q -- '--no-install-recommends.* epsilon' "$FAKE_STATE/apt.log"
check "ensure_packages --no-install-recommends adds the flag" $?
: >"$FAKE_STATE/apt.log"
h 'DRY_RUN=1; ensure_packages zeta' >"$WORK/out"
[[ ! -s "$FAKE_STATE/apt.log" ]] && grep -q 'would run: sudo env DEBIAN_FRONTEND=noninteractive apt-get' "$WORK/out"
check "ensure_packages: dry-run prints the command and runs nothing" $?

# --- apt_update_once, apt_full_upgrade --------------------------------------
: >"$FAKE_STATE/apt.log"
h 'apt_update_once; apt_update_once' >/dev/null
[[ "$(grep -c ' update \[' "$FAKE_STATE/apt.log")" == 1 ]]
check "apt_update_once: updates only once per run" $?
: >"$FAKE_STATE/apt.log"
h 'apt_update_once; apt_update_once --force' >/dev/null
[[ "$(grep -c ' update \[' "$FAKE_STATE/apt.log")" == 2 ]]
check "apt_update_once --force updates again" $?
: >"$FAKE_STATE/apt.log"
h 'apt_full_upgrade' >/dev/null
grep -q 'full-upgrade' "$FAKE_STATE/apt.log" && grep -q 'force-confold' "$FAKE_STATE/apt.log"
check "apt_full_upgrade: full-upgrade, noninteractive, confold" $?

# --- apt_install_key --------------------------------------------------------
fake_key_file "$FAKE_KEY_FILE" "$FPR"
: >"$FAKE_STATE/curl.log"
h "apt_install_key '$KEYURL' '$KEYDEST' '$FPR'" >/dev/null
check "apt_install_key: installs a key with the expected fingerprint" $?
[[ -f "$KCS_ROOT$KEYDEST" ]]
check "apt_install_key: key file exists under the root prefix" $?
: >"$FAKE_STATE/curl.log"
h "apt_install_key '$KEYURL' '$KEYDEST' '$FPR'" >"$WORK/out"
[[ ! -s "$FAKE_STATE/curl.log" ]] && ! grep -q '\[change\]' "$WORK/out"
check "apt_install_key: second run downloads nothing and changes nothing" $?
rm -f -- "$KCS_ROOT$KEYDEST"
! h "apt_install_key '$KEYURL' '$KEYDEST' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'" >"$WORK/out" 2>&1
check "apt_install_key: fingerprint mismatch fails" $?
grep -q 'fingerprint' "$WORK/out"
check "apt_install_key: the mismatch is reported" $?
[[ ! -e "$KCS_ROOT$KEYDEST" ]]
check "apt_install_key: nothing is installed on mismatch" $?
: >"$FAKE_STATE/curl.log"
h "DRY_RUN=1; apt_install_key '$KEYURL' '$KEYDEST' '$FPR'" >"$WORK/out"
[[ ! -e "$KCS_ROOT$KEYDEST" && ! -s "$FAKE_STATE/curl.log" ]] && grep -q 'install key' "$WORK/out"
check "apt_install_key: dry-run reports and downloads nothing" $?
# A stale key with another fingerprint is replaced, keeping a backup.
mkdir -p "$KCS_ROOT/etc/apt/keyrings"
fake_key_file "$KCS_ROOT$KEYDEST" "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
h "apt_install_key '$KEYURL' '$KEYDEST' '$FPR'" >/dev/null
bak=("$KCS_ROOT$KEYDEST".bak.*)
[[ -f "${bak[0]}" ]] && grep -q "FPR=$FPR" "$KCS_ROOT$KEYDEST"
check "apt_install_key: a different existing key is backed up and replaced" $?

# --- apt_ensure_sources -----------------------------------------------------
SRC="$KCS_ROOT/etc/apt/sources.list.d/test.sources"
h "apt_ensure_sources test https://example.invalid/repo/ unstable main $KEYDEST" >/dev/null
check "apt_ensure_sources: writes the file" $?
grep -qx 'Types: deb' "$SRC" &&
  grep -qx 'URIs: https://example.invalid/repo/' "$SRC" &&
  grep -qx 'Suites: unstable' "$SRC" &&
  grep -qx 'Components: main' "$SRC" &&
  grep -qx "Signed-By: $KEYDEST" "$SRC"
check "apt_ensure_sources: deb822 fields" $?
h "apt_ensure_sources test https://example.invalid/repo/ unstable main $KEYDEST" >"$WORK/out"
! grep -q '\[change\]' "$WORK/out" && ! compgen -G "$SRC.bak.*" >/dev/null
check "apt_ensure_sources: identical content changes nothing, no backup" $?
h "apt_ensure_sources test https://example.invalid/repo/ stable main $KEYDEST" >/dev/null
compgen -G "$SRC.bak.*" >/dev/null && grep -qx 'Suites: stable' "$SRC"
check "apt_ensure_sources: changed content is backed up and replaced" $?

# --- apt_ensure_pin ---------------------------------------------------------
PIN="$KCS_ROOT/etc/apt/preferences.d/test"
PINTXT=$'Package: *\nPin: origin "example.invalid"\nPin-Priority: -1'
h "apt_ensure_pin test '$PINTXT'" >/dev/null
[[ "$(<"$PIN")" == "$PINTXT" ]]
check "apt_ensure_pin: writes the content as given" $?
h "apt_ensure_pin test '$PINTXT'" >"$WORK/out"
! grep -q '\[change\]' "$WORK/out" && ! compgen -G "$PIN.bak.*" >/dev/null
check "apt_ensure_pin: identical content changes nothing" $?
h "apt_ensure_pin test 'Package: x'" >/dev/null
compgen -G "$PIN.bak.*" >/dev/null
check "apt_ensure_pin: changed content is backed up" $?

# --- apt_install_key: a keyring with several primary keys -------------------
# Vendors such as Brave ship one keyring file holding more than one key. The
# expected value is then the full set of fingerprints (space or comma separated)
# and the file must hold exactly that set.
F1=DBF1A116C220B8C7164F98230686B78420038257
F2=47D32A74E9A9E013A4B4926C68D513D36A73CD96
F3=B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0
MULTI=/etc/apt/keyrings/multi.gpg
printf '%s\nFPR=%s\nFPR=%s\nFPR=%s\n%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$F1" "$F2" "$F3" \
  '-----END PGP PUBLIC KEY BLOCK-----' >"$FAKE_KEY_FILE"
h "apt_install_key '$KEYURL' '$MULTI' '$F1 $F2 $F3'" >/dev/null
check "apt_install_key: a three-key keyring matching the full set is installed" $?
h "apt_install_key '$KEYURL' '$MULTI' '$F3,$F1,$F2'" >"$WORK/out"
! grep -q '\[change\]' "$WORK/out"
check "apt_install_key: the set is order-insensitive and a second run changes nothing" $?
rm -f -- "$KCS_ROOT$MULTI"
! h "apt_install_key '$KEYURL' '$MULTI' '$F1 $F2'" >/dev/null 2>&1
check "apt_install_key: a keyring with an extra key is refused" $?
[[ ! -e "$KCS_ROOT$MULTI" ]]
check "apt_install_key: nothing is installed when the set differs" $?
! h "apt_install_key '$KEYURL' '$MULTI' '$F1 $F2 $F3 $FPR'" >/dev/null 2>&1
check "apt_install_key: a keyring missing an expected key is refused" $?
fake_key_file "$FAKE_KEY_FILE" "$FPR"

# --- install_package_list ---------------------------------------------------
# files/packages/<group>.apt: one package per line, # comments (whole line or
# trailing) and blank lines ignored. Only missing packages with an apt
# candidate are installed; one without a candidate is skipped with a warning.
LISTREPO="$WORK/listrepo"
mkdir -p "$LISTREPO/files/packages"
cat >"$LISTREPO/files/packages/t.apt" <<'EOL'
# a comment line

alpha
  gamma   # trailing comment, indented entry
delta

# another
epsilon
EOL
: >"$FAKE_STATE/apt.log"
printf 'alpha\n' >"$FAKE_STATE/installed"
h "REPO_ROOT='$LISTREPO'; install_package_list t" >"$WORK/out" 2>&1
check "install_package_list: succeeds" $?
grep -q 'install .*gamma delta epsilon' "$FAKE_STATE/apt.log" && ! grep -Eq 'alpha|comment|another' "$FAKE_STATE/apt.log"
check "install_package_list: comments, blanks and installed packages are not passed to apt" $?
[[ "$(grep -c ' update \[' "$FAKE_STATE/apt.log")" == 1 ]]
check "install_package_list: refreshes the lists once before installing" $?
: >"$FAKE_STATE/apt.log"
h "REPO_ROOT='$LISTREPO'; install_package_list t" >"$WORK/out" 2>&1
[[ ! -s "$FAKE_STATE/apt.log" ]] && ! grep -q '\[change\]' "$WORK/out"
check "install_package_list: everything installed means no apt call, no change" $?
printf 'alpha\n' >"$FAKE_STATE/installed"
: >"$FAKE_STATE/apt.log"
FAKE_NO_CANDIDATE="gamma" h "REPO_ROOT='$LISTREPO'; install_package_list t" >"$WORK/out" 2>&1
check "install_package_list: a package without a candidate does not fail the run" $?
grep -q '\[warn\].*gamma' "$WORK/out" && grep -q 'install .*delta epsilon' "$FAKE_STATE/apt.log" && ! grep -q 'gamma' "$FAKE_STATE/apt.log"
check "install_package_list: the unavailable package is warned about and skipped" $?
! h "REPO_ROOT='$LISTREPO'; install_package_list nosuchgroup" >"$WORK/out" 2>&1
check "install_package_list: a missing list file is an error" $?
printf 'alpha\n' >"$FAKE_STATE/installed"
: >"$FAKE_STATE/apt.log"
h "REPO_ROOT='$LISTREPO'; DRY_RUN=1; install_package_list t" >"$WORK/out" 2>&1
[[ ! -s "$FAKE_STATE/apt.log" ]] && grep -q 'would run' "$WORK/out"
check "install_package_list: dry-run runs no apt-get" $?

# --- download_verified ------------------------------------------------------
PAYLOAD="$WORK/payload.bin"
printf 'the payload\n' >"$PAYLOAD"
PSUM="$(sha256sum "$PAYLOAD" | awk '{ print $1 }')"
BADSUM=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$FAKE_STATE/curl-files" "$WORK/dl" "$WORK/tmp"
cp -- "$PAYLOAD" "$FAKE_STATE/curl-files/payload.bin"
DLURL=https://example.invalid/dir/payload.bin
export TMPDIR="$WORK/tmp"
: >"$FAKE_STATE/curl.log"
h "download_verified '$DLURL' '$WORK/dl/ok.bin' '$PSUM'" >/dev/null
check "download_verified: a matching checksum succeeds" $?
cmp -s "$PAYLOAD" "$WORK/dl/ok.bin"
check "download_verified: the verified file is at the destination" $?
grep -qx "$DLURL" "$FAKE_STATE/curl.log"
check "download_verified: it fetched the URL" $?
! h "download_verified '$DLURL' '$WORK/dl/bad.bin' '$BADSUM'" >"$WORK/out" 2>&1
check "download_verified: a checksum mismatch fails" $?
[[ ! -e "$WORK/dl/bad.bin" ]] && grep -qi 'checksum' "$WORK/out"
check "download_verified: nothing is left at the destination and the mismatch is reported" $?
! h "download_verified '$DLURL' '$WORK/dl/empty.bin' ''" >"$WORK/out" 2>&1
check "download_verified: an empty checksum is refused" $?
! h "download_verified '$DLURL' '$WORK/dl/short.bin' 'abc123'" >"$WORK/out" 2>&1
check "download_verified: a malformed checksum is refused" $?
[[ ! -e "$WORK/dl/empty.bin" && ! -e "$WORK/dl/short.bin" ]]
check "download_verified: refused checksums download nothing to the destination" $?
FAKE_CURL_FAIL=1 h "download_verified '$DLURL' '$WORK/dl/fail.bin' '$PSUM'" >"$WORK/out" 2>&1
[[ $? -ne 0 && ! -e "$WORK/dl/fail.bin" ]]
check "download_verified: a failed download fails and leaves nothing" $?
UPPER="$(printf '%s' "$PSUM" | tr 'a-f' 'A-F')"
h "download_verified '$DLURL' '$WORK/dl/upper.bin' '$UPPER'" >/dev/null
check "download_verified: an uppercase checksum is accepted" $?
: >"$FAKE_STATE/curl.log"
h "DRY_RUN=1; download_verified '$DLURL' '$WORK/dl/dry.bin' '$PSUM'" >"$WORK/out"
[[ ! -s "$FAKE_STATE/curl.log" && ! -e "$WORK/dl/dry.bin" ]]
check "download_verified: dry-run downloads nothing" $?
[[ -z "$(ls -A "$WORK/tmp")" ]]
check "download_verified: no temporary files are left behind" $?
unset TMPDIR

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
