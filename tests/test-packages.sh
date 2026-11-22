#!/usr/bin/env bash
# tests/test-packages.sh: modules/15-packages.sh (core list, Brave vendor repo,
# PeaZip upstream .deb) against fake apt-get, dpkg-query, apt-cache, curl and
# gpg. Never touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2251,SC2319
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

# Brave's three published signing keys (the keyring file holds all of them).
BRAVE_FPRS="DBF1A116C220B8C7164F98230686B78420038257 47D32A74E9A9E013A4B4926C68D513D36A73CD96 B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0"
KEYRING=/etc/apt/keyrings/brave-browser-archive-keyring.gpg
BRAVE_KEY_URL=https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
DEB=peazip_11.4.0.LINUX.GTK2-1_amd64.deb
DEB_URL=https://github.com/peazip/PeaZip/releases/download/11.4.0/$DEB

APT="$FAKE_STATE/apt.log"
reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${TMPDIR:?}"
  mkdir -p "$FAKE_STATE/curl-files" "$KCS_ROOT" "$TMPDIR"
  : >"$FAKE_STATE/installed"
  # The Brave keyring and a stand-in .deb, served by the fake curl by file name.
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' >"$WORK/brave.key"
  local f
  for f in $BRAVE_FPRS; do printf 'FPR=%s\n' "$f" >>"$WORK/brave.key"; done
  printf '%s\n' '-----END PGP PUBLIC KEY BLOCK-----' >>"$WORK/brave.key"
  cp -- "$WORK/brave.key" "$FAKE_STATE/curl-files/brave-browser-archive-keyring.gpg"
  printf 'not a real deb, a fixture\n' >"$FAKE_STATE/curl-files/$DEB"
  PZ_SUM="$(sha256sum "$FAKE_STATE/curl-files/$DEB" | awk '{ print $1 }')"
  export PACKAGES_PEAZIP_SHA256="$PZ_SUM"
}

# pk <install.sh args...>: run the module. PACKAGES_PEAZIP_SHA256 is the
# test-only override of the pinned checksum (the fixture is not the real deb).
pk() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only packages "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

installed_has() {
  local p
  for p in "$@"; do grep -qx -- "$p" "$FAKE_STATE/installed" || return 1; done
}
installed_lacks() {
  local p
  for p in "$@"; do ! grep -qx -- "$p" "$FAKE_STATE/installed" || return 1; done
}

# --- dry-run ----------------------------------------------------------------
reset_state
pk --dry-run
[[ "$rc" == 0 && ! -s "$APT" && ! -s "$FAKE_STATE/curl.log" && ! -e "$KCS_ROOT$KEYRING" ]]
check "dry-run: exit 0, no apt-get, no download, no key written" $?
grep -q 'install packages: .*firefox-esr' "$WORK/out"
check "dry-run: lists the core packages it would install" $?

# --- full run ---------------------------------------------------------------
reset_state
pk
[[ "$rc" == 0 ]]
check "run: exit 0" $?
installed_has firefox-esr bat fd-find eza ripgrep tealdeer manpages fonts-noto-core \
  gstreamer1.0-plugins-bad apt-file unrar
check "run: the core list is installed with the Kali names" $?
installed_lacks yay downgrade pacman-contrib rebuild-detector pkgfile librewolf which flatpak \
  nano-syntax-highlighting
check "run: dropped Arch-only packages are not requested" $?
installed_has brave-browser
check "run: brave-browser is installed" $?
installed_has peazip
check "run: peazip is installed" $?
grep -q "^deb-file-present .*/$DEB\$" "$FAKE_STATE/all.log" ||
  grep -q "deb-file-present" "$FAKE_STATE/all.log"
check "run: the .deb existed on disk when apt-get installed it" $?
grep -qx "$BRAVE_KEY_URL" "$FAKE_STATE/curl.log" && grep -qx "$DEB_URL" "$FAKE_STATE/curl.log"
check "run: the Brave key and the PeaZip .deb come from the official URLs" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "run: no temporary files are left behind" $?

# Brave repository files.
[[ -f "$KCS_ROOT$KEYRING" ]]
check "brave: the keyring is installed under /etc/apt/keyrings" $?
SRC="$KCS_ROOT/etc/apt/sources.list.d/brave-browser.sources"
grep -qx 'Types: deb' "$SRC" &&
  grep -qx 'URIs: https://brave-browser-apt-release.s3.brave.com/' "$SRC" &&
  grep -qx 'Suites: stable' "$SRC" && grep -qx 'Components: main' "$SRC" &&
  grep -qx "Signed-By: $KEYRING" "$SRC"
check "brave: deb822 sources file with Signed-By pointing at the keyring" $?
PIN="$KCS_ROOT/etc/apt/preferences.d/brave-browser"
# The first record that matches wins: the allow record for the two Brave
# packages must come before the block-everything record.
allow="$(grep -n '^Package: brave-browser brave-keyring$' "$PIN" | head -n 1 | cut -d: -f1)"
block="$(grep -n '^Package: \*$' "$PIN" | head -n 1 | cut -d: -f1)"
[[ -n "$allow" && -n "$block" && "$allow" -lt "$block" ]]
check "brave: the pin allows brave-browser and brave-keyring first, then blocks the rest" $?
[[ "$(grep -c '^Pin: origin "brave-browser-apt-release.s3.brave.com"$' "$PIN")" == 2 ]] &&
  grep -qx 'Pin-Priority: -1' "$PIN"
check "brave: both records are bound to the Brave origin; the catch-all is -1" $?
# The repository must be configured, and the lists refreshed, before the package.
upd="$(grep -n 'apt-get .* update' "$FAKE_STATE/all.log" | tail -n 1 | cut -d: -f1)"
inst="$(grep -n 'apt-get .*install.* brave-browser' "$FAKE_STATE/all.log" | head -n 1 | cut -d: -f1)"
[[ -n "$upd" && -n "$inst" && "$upd" -lt "$inst" ]]
check "brave: apt-get update runs after the repo is added and before brave-browser is installed" $?

# --- second run changes nothing ---------------------------------------------
pk
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$APT" ]] && [[ ! -s "$FAKE_STATE/curl.log" ]]
check "second run: total changes: 0, no apt-get, no download" $?
! compgen -G "$KCS_ROOT/etc/apt/*/*.bak.*" >/dev/null
check "second run: no backup files are created" $?

# --- Brave key fingerprint mismatch ----------------------------------------
reset_state
printf '%s\nFPR=%s\n%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA '-----END PGP PUBLIC KEY BLOCK-----' \
  >"$FAKE_STATE/curl-files/brave-browser-archive-keyring.gpg"
pk
[[ "$rc" != 0 ]] && grep -qi 'fingerprint' "$WORK/out"
check "brave: a key with another fingerprint fails the module" $?
[[ ! -e "$KCS_ROOT$KEYRING" && ! -e "$SRC" && ! -e "$PIN" ]]
check "brave: nothing of the Brave repo is installed on a fingerprint mismatch" $?
installed_lacks brave-browser peazip
check "brave: neither Brave nor PeaZip is installed after the failure" $?
installed_has firefox-esr bat
check "brave: the core list was already installed (it runs first)" $?

# A keyring with one extra key is refused too.
reset_state
printf 'FPR=%s\n' CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC >>"$FAKE_STATE/curl-files/brave-browser-archive-keyring.gpg"
pk
[[ "$rc" != 0 && ! -e "$KCS_ROOT$KEYRING" ]]
check "brave: a keyring with an extra key is refused" $?

# --- PeaZip checksum mismatch -------------------------------------------------
reset_state
export PACKAGES_PEAZIP_SHA256=1111111111111111111111111111111111111111111111111111111111111111
pk
[[ "$rc" != 0 ]] && grep -qi 'checksum mismatch' "$WORK/out"
check "peazip: a checksum mismatch fails the module and is reported" $?
installed_lacks peazip
check "peazip: nothing is installed on a checksum mismatch" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "peazip: the temporary download is removed after a mismatch" $?
installed_has brave-browser firefox-esr
check "peazip: Brave and the core list were installed before PeaZip failed" $?

# The real pinned checksum is used when no override is set: the fixture differs.
reset_state
unset PACKAGES_PEAZIP_SHA256
pk
[[ "$rc" != 0 ]] && installed_lacks peazip
check "peazip: without the test override the pinned sha256 rejects any other file" $?
grep -Eq '^_PACKAGES_PEAZIP_SHA256=.?b4ec801e857f232518cfc91d74690d27d35dbf911308b671d5156fc5c631956c' \
  "$REPO_ROOT/modules/15-packages.sh"
check "peazip: the module pins the sha256 of the GTK2 11.4.0 .deb" $?

# --- PeaZip already installed --------------------------------------------------
reset_state
printf 'peazip\n' >>"$FAKE_STATE/installed"
printf 'peazip 11.4.0\n' >"$FAKE_STATE/versions"
pk
! grep -qx "$DEB_URL" "$FAKE_STATE/curl.log"
check "peazip: the same version installed means no download" $?
reset_state
printf 'peazip\n' >>"$FAKE_STATE/installed"
printf 'peazip 10.9.0\n' >"$FAKE_STATE/versions"
pk
grep -qx "$DEB_URL" "$FAKE_STATE/curl.log" && grep -q '^peazip 11.4.0$' "$FAKE_STATE/versions"
check "peazip: an older installed version is upgraded to the pinned one" $?

# --- unrar not available --------------------------------------------------------
reset_state
FAKE_NO_CANDIDATE="unrar" pk
[[ "$rc" == 0 ]] && installed_lacks unrar && installed_has bat brave-browser peazip &&
  grep -q '\[warn\].*unrar' "$WORK/out"
check "unrar: with no candidate (non-free off) it is skipped with a warning, the rest installs" $?

# --- the .deb install itself fails: the temporary download is still removed ---
reset_state
FAKE_APT_FAIL_DEB=1 pk
[[ "$rc" != 0 && -z "$(ls -A "$TMPDIR")" ]]
check "peazip: a failing .deb install fails the module and removes the download" $?

# --- apt failure ------------------------------------------------------------------
reset_state
FAKE_APT_RC=100 pk
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?

# --- static checks on the data and the module --------------------------------------
LIST="$REPO_ROOT/files/packages/core.apt"
pkgs="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$')"
! grep -Eqx 'yay|downgrade|pacman-contrib|rebuild-detector|pkgfile|librewolf|which|flatpak|nano-syntax-highlighting|bat-extras' <<<"$pkgs"
check "core.apt: none of the dropped entries is listed" $?
! grep -Eq '^(fd|tldr|man-pages|noto-fonts.*|ttf-(dejavu|liberation|opensans)|firefox|brave.*|peazip)$' <<<"$pkgs"
check "core.apt: no Arch names, and Brave and PeaZip are not in the list" $?
[[ -z "$(sort <<<"$pkgs" | uniq -d)" ]]
check "core.apt: no duplicate entries" $?
! grep -Eq 'i386|lib32|multilib|yay|pacman|flatpak' "$REPO_ROOT/modules/15-packages.sh"
check "the module source has no i386, multilib, yay, pacman or flatpak" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
