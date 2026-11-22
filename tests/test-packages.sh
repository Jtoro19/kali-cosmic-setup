#!/usr/bin/env bash
# tests/test-packages.sh: modules/15-packages.sh (core list, Brave vendor repo,
# PeaZip upstream .deb) against fake apt-get, dpkg-query, apt-cache, curl and
# gpg. Never touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2030/SC2031: the sections that run in a ( ) subshell do so on purpose, to
# source the library and module without leaking into this shell.
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
# test-only override of the pinned checksum (the fixture is not the real deb);
# it is honoured only with KCS_TEST=1 (PK_KCS_TEST= empty simulates a real run).
pk() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  PATH="$WORK/bin:$PATH" KCS_TEST="${PK_KCS_TEST-1}" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
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
[[ -z "$(ls -A "$TMPDIR")" ]]
check "dry-run: no temporary directory or file is created" $?
grep -q 'dry-run.*peazip' "$WORK/out"
check "dry-run: reports that peazip would be installed" $?
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
grep -q "^deb-file-present .*/$DEB\$" "$FAKE_STATE/all.log"
check "run: the .deb existed on disk when apt-get installed it" $?
grep -qx "$BRAVE_KEY_URL" "$FAKE_STATE/curl.log" && grep -qx "$DEB_URL" "$FAKE_STATE/curl.log"
check "run: the Brave key and the PeaZip .deb come from the official URLs" $?
[[ -z "$(ls -A "$TMPDIR")" ]]
check "run: no temporary files are left behind" $?
# Every download is https-only, TLS 1.2+, with timeouts and a bounded retry.
[[ "$(wc -l <"$FAKE_STATE/curl-args.log")" -ge 2 ]] &&
  ! grep -qv -e "--proto =https" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--proto-redir =https" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--tlsv1.2" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--connect-timeout 15" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--max-time 600" "$FAKE_STATE/curl-args.log" &&
  ! grep -qv -e "--retry 2" "$FAKE_STATE/curl-args.log"
check "downloads: curl is https-only with TLS 1.2, timeouts and --retry 2" $?
! grep -q 'wget' "$REPO_ROOT/lib/common.sh" "$REPO_ROOT/modules/15-packages.sh"
check "downloads: no wget fallback remains" $?

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

# --- Brave's global trust symlink -------------------------------------------
# brave-keyring's postinst links its key into /etc/apt/trusted.gpg.d, which makes
# the key trusted for every repository (wider than Signed-By plus the pin). The
# module removes that symlink after installing brave-browser.
TRUST="$KCS_ROOT/etc/apt/trusted.gpg.d/brave-browser-release.gpg"
reset_state
pk
[[ "$rc" == 0 && ! -e "$TRUST" && ! -L "$TRUST" ]] && grep -q 'remove.*brave-browser-release.gpg' "$WORK/out"
check "brave trust: the postinst symlink in trusted.gpg.d is removed and logged" $?
pk
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -L "$TRUST" ]]
check "brave trust: a second run has nothing to remove (total changes: 0)" $?
# An upgrade of brave-keyring recreates it: the next run removes it again.
mkdir -p "$(dirname "$TRUST")"
ln -sf /usr/share/keyrings/brave-browser-archive-keyring.gpg "$TRUST"
pk
[[ "$rc" == 0 && ! -L "$TRUST" ]] && grep -q 'total changes: 1' "$WORK/out"
check "brave trust: a symlink recreated by an upgrade is removed again (1 change)" $?
ln -sf /usr/share/keyrings/brave-browser-archive-keyring.gpg "$TRUST"
pk --dry-run
[[ "$rc" == 0 && -L "$TRUST" ]] && grep -q 'remove.*brave-browser-release.gpg' "$WORK/out"
check "brave trust: dry-run reports the removal and keeps the symlink" $?
rm -f -- "$TRUST"
printf 'admin file\n' >"$TRUST"
pk
[[ "$rc" == 0 && -f "$TRUST" && ! -L "$TRUST" ]] && grep -q '\[warn\].*brave-browser-release.gpg' "$WORK/out"
check "brave trust: a regular file there (not our symlink) is left alone with a warning" $?

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

# A forced exit (SIGTERM, or a fail-fast helper) in the middle of the install
# still removes the user temp dir and the root-owned staging dir (EXIT trap).
reset_state
FAKE_APT_KILL_PARENT=1 pk
[[ "$rc" != 0 && -z "$(ls -A "$TMPDIR")" ]]
check "peazip: a forced exit removes the user temp dir and the root-owned staging dir" $?
grep -q "^deb-file-present .*/$DEB\$" "$FAKE_STATE/all.log" &&
  grep -q 'rm -rf' "$FAKE_STATE/sudo.log"
check "peazip: the root-owned staging dir was removed through sudo by the trap" $?

# A real run (no KCS_TEST marker) ignores a PACKAGES_PEAZIP_SHA256 in the environment.
reset_state
PK_KCS_TEST='' pk
[[ "$rc" != 0 ]] && grep -qi 'checksum mismatch' "$WORK/out" && installed_lacks peazip
check "peazip: PACKAGES_PEAZIP_SHA256 is ignored without the KCS_TEST marker" $?

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

reset_state
printf 'peazip\n' >>"$FAKE_STATE/installed"
printf 'peazip 11.10.0\n' >"$FAKE_STATE/versions"
pk
[[ "$rc" == 0 ]] && ! grep -qx "$DEB_URL" "$FAKE_STATE/curl.log" && grep -q '^peazip 11.10.0$' "$FAKE_STATE/versions"
check "peazip: a newer installed version (11.10.0 > 11.4.0) is not downgraded" $?
reset_state
printf 'peazip\n' >>"$FAKE_STATE/installed"
printf 'peazip 11.4.0-1\n' >"$FAKE_STATE/versions"
pk
! grep -qx "$DEB_URL" "$FAKE_STATE/curl.log"
check "peazip: 11.4.0-1 counts as the pinned version or newer (dpkg ordering)" $?

# Tilde and revision ordering. The fake dpkg uses sort -V, which matches Debian
# ordering for these shapes (11.4.0~rc1 < 11.4.0 < 11.4.0-1); the real dpkg runs
# on Kali. A pre-release of the pinned version must be upgraded.
reset_state
printf 'peazip\n' >>"$FAKE_STATE/installed"
printf 'peazip 11.4.0~rc1\n' >"$FAKE_STATE/versions"
pk
grep -qx "$DEB_URL" "$FAKE_STATE/curl.log" && grep -q '^peazip 11.4.0$' "$FAKE_STATE/versions"
check "peazip: 11.4.0~rc1 sorts before the pinned 11.4.0 and is upgraded" $?
for pair in "11.4.0~rc1 lt 11.4.0" "11.4.0 lt 11.4.0-1" "11.4.0~rc1 lt 11.4.0-1" "11.10.0 gt 11.4.0"; do
  # shellcheck disable=SC2086  # the three words are the operands
  PATH="$WORK/bin:$PATH" dpkg --compare-versions $pair
  check "fake dpkg: $pair" $?
done

# The verified .deb is copied to a root-owned location and apt installs that
# copy, never the file in the user-writable download directory.
reset_state
pk
dest="$(sed -n 's/.*install -m0644 [^ ]* //p' "$FAKE_STATE/sudo.log" | head -n 1)"
[[ -n "$dest" ]] && grep -qx "deb-file-present $dest" "$FAKE_STATE/all.log"
check "peazip: apt installs a root-installed copy (sudo install -m0644), not the user download" $?
grep -q 'mktemp -d' "$FAKE_STATE/sudo.log" && grep -q 'rm -rf' "$FAKE_STATE/sudo.log" && [[ -z "$(ls -A "$TMPDIR")" ]]
check "peazip: the root-owned directory is created by root and both temp dirs are cleaned up" $?
reset_state
export PACKAGES_PEAZIP_SHA256=1111111111111111111111111111111111111111111111111111111111111111
pk
! grep -q 'install -m0644' "$FAKE_STATE/sudo.log"
check "peazip: a mismatch stops before anything is copied to the root-owned location" $?
reset_state

# --- a failed update then a re-run: Brave still gets its lists ----------------
reset_state
export FAKE_NEEDS_UPDATE=brave-browser
FAKE_APT_FAIL_UPDATE_NTH=2 pk
[[ "$rc" != 0 ]] && installed_lacks brave-browser && [[ -f "$KCS_ROOT$KEYRING" ]]
check "brave: a failed apt-get update fails the module but leaves the repo files" $?
pk
[[ "$rc" == 0 ]] && installed_has brave-browser peazip &&
  grep -q 'apt-get .* update' "$FAKE_STATE/all.log"
check "brave: the re-run updates again (no candidate) and installs brave-browser" $?
unset FAKE_NEEDS_UPDATE

# --- wiped lists before the PeaZip runtime dependency ------------------------
reset_state
pk
rm -f "$FAKE_STATE/lists-fresh" "$FAKE_STATE/lists-fresh-brave"
grep -vx 'peazip\|libgtk2.0-0t64' "$FAKE_STATE/installed" >"$FAKE_STATE/installed.new"
mv -- "$FAKE_STATE/installed.new" "$FAKE_STATE/installed"
: >"$FAKE_STATE/versions"
FAKE_NEEDS_UPDATE=libgtk2.0-0t64 pk
[[ "$rc" == 0 ]] && installed_has libgtk2.0-0t64 peazip
check "peazip: the lists are refreshed before the libgtk2.0-0t64 runtime install" $?

# --- the .deb changes between the download check and apt-get install --------
reset_state
(
  export DRY_RUN=0 PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1
  set +e
  # shellcheck source=lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
  # shellcheck source=modules/15-packages.sh
  source "$REPO_ROOT/modules/15-packages.sh"
  # A download that passes its own check, then the file is swapped.
  download_verified() { printf 'tampered\n' >"$2"; }
  PACKAGES_PEAZIP_SHA256="$PZ_SUM" KCS_TEST=1 _packages_peazip >"$WORK/tamper.out" 2>&1
  echo $? >"$WORK/tamper.rc"
)
[[ "$(cat "$WORK/tamper.rc")" != 0 ]] && ! grep -q 'deb-file' "$FAKE_STATE/all.log" 2>/dev/null &&
  grep -qi 'checksum' "$WORK/tamper.out"
check "peazip: a .deb that no longer matches the sha256 is not passed to apt-get" $?

# --- real gpg: the pub:/fpr: extraction on a real key -------------------------
if command -v gpg >/dev/null 2>&1; then
  GH="$(mktemp -d "$WORK/gnupg.XXXXXX")"
  chmod 0700 "$GH"
  GNUPGHOME="$GH" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'kcs test <kcs@example.invalid>' ed25519 sign never >/dev/null 2>&1
  GNUPGHOME="$GH" gpg --batch --export >"$WORK/real.key" 2>/dev/null
  want_fpr="$(GNUPGHOME="$GH" gpg --batch --with-colons --list-keys 2>/dev/null |
    awk -F: '/^fpr:/ { print $10; exit }')"
  got_fpr="$(
    set -euo pipefail
    # shellcheck source=lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
    LANG=de_DE.UTF-8 _gpg_primary_fingerprints "$WORK/real.key"
  )"
  [[ -n "$want_fpr" && "$got_fpr" == "$want_fpr" ]]
  check "gpg: the real fingerprint extraction returns the primary key fingerprint" $?
  (
    set -euo pipefail
    # shellcheck source=lib/common.sh
    source "$REPO_ROOT/lib/common.sh"
    _key_has_fingerprint "$WORK/real.key" "${want_fpr,,}" &&
      ! _key_has_fingerprint "$WORK/real.key" "$want_fpr AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  )
  check "gpg: _key_has_fingerprint accepts the exact fingerprint and rejects a superset" $?
else
  printf 'skip - gpg is not installed: real fingerprint extraction not tested\n'
fi

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

# --- virtio GPU: browsers start with X11 ---------------------------------------
CHR=/etc/chromium.d/kali-cosmic-setup-virtio-gpu
BDESK=/usr/local/share/applications/brave-browser.desktop
BSRC=/usr/share/applications/brave-browser.desktop
CHR_LINE="export CHROMIUM_FLAGS=\"\$CHROMIUM_FLAGS --ozone-platform=x11\""
set_gpus() { # set_gpus <vendor id...>: fake /sys/class/drm cards (and connectors)
  local i=0 v
  rm -rf -- "${KCS_ROOT:?}/sys"
  for v in "$@"; do
    mkdir -p "$KCS_ROOT/sys/class/drm/card$i/device" "$KCS_ROOT/sys/class/drm/card$i-Virtual-1"
    echo "$v" >"$KCS_ROOT/sys/class/drm/card$i/device/vendor"
    i=$((i + 1))
  done
}
write_brave_src() {
  mkdir -p "$KCS_ROOT/usr/share/applications"
  cat >"$KCS_ROOT$BSRC" <<'EOS'
[Desktop Entry]
Version=1.0
Name=Brave Web Browser
Exec=/usr/bin/brave-browser-stable %U
StartupNotify=true
Icon=brave-browser
[Desktop Action new-window]
Name=New Window
Exec=/usr/bin/brave-browser-stable
[Desktop Action new-private-window]
Name=New Incognito Window
Exec=/usr/bin/brave-browser-stable --incognito
EOS
}
snap() { find "$KCS_ROOT" -type f -exec md5sum {} + 2>/dev/null | sort; }

reset_state
set_gpus 0x1af4
write_brave_src
pk
[[ "$rc" == 0 && -f "$KCS_ROOT$CHR" && "$(stat -c %a "$KCS_ROOT$CHR")" == 644 ]] &&
  grep -q 'kali-cosmic-setup: virtio-gpu browser workaround' "$KCS_ROOT$CHR" &&
  grep -qxF "$CHR_LINE" "$KCS_ROOT$CHR"
check "virtio: the chromium.d drop-in is written (0644, marker, flag), chromium need not be installed" $?
[[ "$(grep -c '^Exec=' "$KCS_ROOT$BDESK")" == 3 ]] &&
  grep -qx 'Exec=/usr/bin/brave-browser-stable --ozone-platform=x11 %U' "$KCS_ROOT$BDESK" &&
  grep -qx 'Exec=/usr/bin/brave-browser-stable --ozone-platform=x11' "$KCS_ROOT$BDESK" &&
  grep -qx 'Exec=/usr/bin/brave-browser-stable --ozone-platform=x11 --incognito' "$KCS_ROOT$BDESK" &&
  [[ "$(head -n1 "$KCS_ROOT$BDESK")" == '# kali-cosmic-setup: virtio-gpu browser workaround'* ]]
check "virtio: the Brave desktop entry is generated with the flag in every Exec line and a marker first" $?
diff <(grep -v -e '^Exec=' -e '^# kali-cosmic-setup' "$KCS_ROOT$BDESK") <(grep -v '^Exec=' "$KCS_ROOT$BSRC") >/dev/null
check "virtio: every other line of the desktop entry is kept" $?
before="$(snap)"
pk
[[ "$rc" == 0 && "$(snap)" == "$before" ]] && grep -q 'total changes: 0' "$WORK/out"
check "virtio: a second run changes nothing (total changes: 0)" $?
sed -i 's/^Name=Brave Web Browser/Name=Brave Renamed/' "$KCS_ROOT$BSRC"
pk
[[ "$rc" == 0 ]] && grep -qx 'Name=Brave Renamed' "$KCS_ROOT$BDESK" && grep -q 'total changes: 1' "$WORK/out"
check "virtio: a changed source desktop entry regenerates the generated one (1 change)" $?

# Not virtual: the marker files are removed, other files are left.
set_gpus 0x8086
pk
[[ "$rc" == 0 && ! -e "$KCS_ROOT$CHR" && ! -e "$KCS_ROOT$BDESK" && -f "$KCS_ROOT$BSRC" ]] &&
  grep -q 'total changes: 2' "$WORK/out"
check "real GPU: both marker files are removed (2 changes), the source entry stays" $?
pk
grep -q 'total changes: 0' "$WORK/out"
check "real GPU: a second run changes nothing" $?
set_gpus 0x1af4 0x10de
pk
[[ ! -e "$KCS_ROOT$CHR" && ! -e "$KCS_ROOT$BDESK" ]]
check "mixed virtio and real GPUs: nothing is written" $?

# Files without the marker are never touched, with a warning.
set_gpus 0x8086
mkdir -p "$KCS_ROOT/etc/chromium.d" "$KCS_ROOT/usr/local/share/applications"
echo '# mine' >"$KCS_ROOT$CHR"
echo '[Desktop Entry]' >"$KCS_ROOT$BDESK"
pk
[[ "$rc" == 0 && "$(<"$KCS_ROOT$CHR")" == '# mine' && "$(<"$KCS_ROOT$BDESK")" == '[Desktop Entry]' ]] &&
  grep -q '\[warn\].*kali-cosmic-setup-virtio-gpu' "$WORK/out" &&
  grep -q '\[warn\].*brave-browser.desktop' "$WORK/out"
check "real GPU: files without the marker are left alone with a warning each" $?
set_gpus 0x1af4
pk
[[ "$rc" == 0 && "$(<"$KCS_ROOT$CHR")" == '# mine' && "$(<"$KCS_ROOT$BDESK")" == '[Desktop Entry]' ]] &&
  ! ls "$KCS_ROOT"/etc/chromium.d/*.bak.* >/dev/null 2>&1 &&
  grep -q '\[warn\].*kali-cosmic-setup-virtio-gpu' "$WORK/out" && grep -q '\[warn\].*brave-browser.desktop' "$WORK/out"
check "virtio: files without the marker are not replaced (no backup) and warn" $?

# virtio without the Brave source entry: only the drop-in.
reset_state
set_gpus 0x1af4
pk
[[ "$rc" == 0 && -f "$KCS_ROOT$CHR" && ! -e "$KCS_ROOT$BDESK" ]]
check "virtio: without /usr/share/applications/brave-browser.desktop only the drop-in is written" $?

# Dry-run writes nothing.
reset_state
set_gpus 0x1af4
write_brave_src
pk --dry-run
[[ "$rc" == 0 && ! -e "$KCS_ROOT$CHR" && ! -e "$KCS_ROOT$BDESK" ]] && grep -q '\[change\]' "$WORK/out"
check "virtio dry-run: nothing is written, the changes are reported" $?
pk
set_gpus 0x8086
pk --dry-run
[[ -f "$KCS_ROOT$CHR" && -f "$KCS_ROOT$BDESK" ]]
check "real GPU dry-run: nothing is removed" $?

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
