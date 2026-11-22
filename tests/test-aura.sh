#!/usr/bin/env bash
# tests/test-aura.sh: modules/60-aura.sh (Aura from its pinned release with a
# sha256 check, the restore unit and the Alt+S shortcut merged into the COSMIC
# custom shortcut map) against fake apt-get, curl and systemctl, a temporary HOME
# and a temporary root. Never touches the real system and never uses the network.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2016: single-quoted fixtures hold literal $ on purpose.
# shellcheck disable=SC2251,SC2319,SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export KCS_ROOT="$WORK/root"
make_fakes "$WORK/bin"
HOME_DIR="$WORK/home"
BINDIR="$HOME_DIR/.local/bin"
SHARE="$HOME_DIR/.local/share"
CFG="$HOME_DIR/.config/cosmic"
SC="$CFG/com.system76.CosmicSettings.Shortcuts/v1/custom"
UNIT="$HOME_DIR/.config/systemd/user/aura-restore.service"
MARKER="$WORK/state-home/kali-cosmic-setup/aura/version"
VER=v1.5.0
TGZ="aura-$VER-x86_64-linux.tar.gz"
URL="https://github.com/antwny/aura/releases/download/$VER/$TGZ"
DIR="aura-$VER-x86_64-linux"
ALT_ACTION="Spawn(\"$HOME_DIR/.local/bin/aura switcher\")"
ALT_FLAT="${ALT_ACTION// /}"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# mk_release <tag>: a tarball laid out like the release, in the fake curl dir.
mk_release() {
  rm -rf -- "$WORK/pkg" && mkdir -p "$WORK/pkg/$DIR"
  printf '#!/bin/sh\necho "aura %s"\n' "$1" >"$WORK/pkg/$DIR/aura"
  printf '#!/bin/sh\necho mpvpaper\n' >"$WORK/pkg/$DIR/mpvpaper"
  chmod +x "$WORK/pkg/$DIR/aura" "$WORK/pkg/$DIR/mpvpaper"
  echo '<svg/>' >"$WORK/pkg/$DIR/io.github.antwny.aura.svg"
  echo '<component/>' >"$WORK/pkg/$DIR/io.github.antwny.aura.metainfo.xml"
  printf '[Desktop Entry]\nName=Aura\nTryExec=aura\nExec=aura\nIcon=io.github.antwny.aura\n' >"$WORK/pkg/$DIR/io.github.antwny.aura.desktop"
  echo '#!/bin/sh' >"$WORK/pkg/$DIR/install.sh"
  tar -czf "$FAKE_STATE/curl-files/$TGZ" -C "$WORK/pkg" "$DIR"
  AURA_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$TGZ" | awk '{ print $1 }')"
  export AURA_SHA256
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache" "${WORK:?}/tmp" "${WORK:?}/state-home"
  mkdir -p "$FAKE_STATE/curl-files" "$KCS_ROOT" "$HOME_DIR" "$WORK/tmp"
  : >"$FAKE_STATE/installed"
  mk_release "$VER"
}

# au <install.sh args...>: the module as a user with a systemd user manager.
au() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST="${AU_KCS_TEST-1}" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state-home" XDG_RUNTIME_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
    "$REPO_ROOT/install.sh" --only aura "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# put_custom <content>: a fresh state with this custom shortcut file.
put_custom() {
  reset_state
  mkdir -p "$(dirname "$SC")"
  printf '%s' "$1" >"$SC"
}
flat() { tr -d ' \n\t' <"$1"; }

# --- metadata -----------------------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^aura +yes ' <<<"$out" >/dev/null
check "metadata: aura is an opt-in module" $?
[[ -f "$REPO_ROOT/specs/aura.md" && -f "$REPO_ROOT/files/aura/aura-restore" && -f "$REPO_ROOT/files/aura/aura-restore.service" ]]
check "spec and files/aura/* exist" $?
grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$(sed -n 's/^_AURA_VERSION="\(.*\)"/\1/p' "$REPO_ROOT/modules/60-aura.sh")" >/dev/null &&
  grep -Eq '^_AURA_SHA256="[0-9a-f]{64}"' "$REPO_ROOT/modules/60-aura.sh"
check "pin: a release tag and a 64-hex sha256 are hard-coded in the module" $?

# --- dry-run ---------------------------------------------------------------------------------
reset_state
au --dry-run
[[ "$rc" == 0 && ! -s "$FAKE_STATE/curl.log" && ! -e "$BINDIR/aura" && ! -e "$SC" && ! -e "$UNIT" ]] && ! grep -qE 'enable --now|daemon-reload' "$FAKE_STATE/systemctl.log" && grep -q 'would download' "$WORK/out"
check "dry-run: no download, no file, no systemctl, the download is announced" $?

# --- fresh run ---------------------------------------------------------------------------------
reset_state
au
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
ok=0
for p in mpv libmpv2 ffmpeg jq curl; do grep -qx "$p" "$FAKE_STATE/installed" || { echo "missing $p"; ok=1; }; done
check "packages: mpv, libmpv2 (the bundled mpvpaper links libmpv.so.2), ffmpeg, jq and curl come from apt" $ok
grep -qx "$URL" "$FAKE_STATE/curl.log" && ! grep -v '^https://github.com/antwny/aura/releases/download/' "$FAKE_STATE/curl.log" | grep -q . &&
  grep -q -- '--proto =https' "$FAKE_STATE/curl-args.log"
check "download: only the pinned https release URL, https enforced" $?
[[ -x "$BINDIR/aura" && -x "$BINDIR/mpvpaper" && "$(stat -c %a "$BINDIR/aura")" == 755 ]] && "$BINDIR/aura" | grep -q "aura $VER"
check "install: aura and mpvpaper are in ~/.local/bin (0755), like the upstream user install" $?
[[ -f "$SHARE/icons/hicolor/scalable/apps/io.github.antwny.aura.svg" && -f "$SHARE/metainfo/io.github.antwny.aura.metainfo.xml" ]]
check "install: icon and metainfo are in ~/.local/share" $?
D="$SHARE/applications/io.github.antwny.aura.desktop"
grep -qx "Exec=$BINDIR/aura" "$D" && grep -qx "TryExec=$BINDIR/aura" "$D" && [[ "$(grep -c '^TryExec=' "$D")" == 1 ]]
check "install: the desktop entry gets an absolute Exec and a single TryExec" $?
[[ "$(<"$MARKER")" == "$VER" ]]
check "marker: the installed version is recorded" $?
cmp -s "$REPO_ROOT/files/aura/aura-restore" "$BINDIR/aura-restore" && cmp -s "$REPO_ROOT/files/aura/aura-restore.service" "$UNIT" && [[ -x "$BINDIR/aura-restore" ]]
check "restore: script and user unit are installed" $?
grep -qx 'aura-restore.service' "$FAKE_STATE/user-enabled"
check "restore: the user unit is enabled" $?
[[ -z "$(ls -A "$WORK/tmp")" ]]
check "cleanup: no temporary directory is left" $?
# shortcut
f="$(flat "$SC")"
[[ "$f" == '{(modifiers:[Alt,],key:"s",description:Some("aurahud"),):'"$ALT_FLAT,}" ]]
check "shortcut: a fresh custom map holds exactly the Alt+S entry that starts aura switcher" $?
# --- second run ------------------------------------------------------------------------------------
nbak="$(find "$HOME_DIR" -name '*.bak.*' | wc -l)"
au
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/curl.log" ]] && [[ "$(find "$HOME_DIR" -name '*.bak.*' | wc -l)" == "$nbak" ]]
check "second run: total changes: 0, no download, no new backup" $?

# --- tampered download, wrong architecture --------------------------------------------------------------
reset_state
echo tampered >>"$FAKE_STATE/curl-files/$TGZ"
au
[[ "$rc" != 0 && ! -e "$BINDIR/aura" && ! -e "$MARKER" && ! -e "$SC" && ! -e "$UNIT" ]] && grep -qi 'checksum mismatch' "$WORK/out"
check "tampered archive: checksum mismatch fails the module, nothing is installed, no shortcut" $?
reset_state
AU_KCS_TEST='' au
[[ "$rc" != 0 && ! -e "$BINDIR/aura" ]] && grep -qi 'checksum mismatch' "$WORK/out"
check "pin: the AURA_SHA256 override works only with KCS_TEST (a real run uses the pinned value)" $?
reset_state
printf '#!/bin/sh\necho aarch64\n' >"$WORK/bin/uname"
chmod +x "$WORK/bin/uname"
au
[[ "$rc" != 0 && ! -s "$FAKE_STATE/curl.log" && ! -e "$SC" ]] && grep -q 'x86_64' "$WORK/out"
check "architecture: the x86_64-only release is refused on another machine, no download" $?
rm -f -- "$WORK/bin/uname"
reset_state
FAKE_CURL_FAIL=1 au
[[ "$rc" != 0 && ! -e "$BINDIR/aura" && ! -e "$SC" ]]
check "download failure: the module fails, nothing is installed, no shortcut" $?
reset_state
rm -rf -- "$WORK/pkg" && mkdir -p "$WORK/pkg/$DIR" && echo x >"$WORK/pkg/$DIR/other"
tar -czf "$FAKE_STATE/curl-files/$TGZ" -C "$WORK/pkg" "$DIR"
AURA_SHA256="$(sha256sum "$FAKE_STATE/curl-files/$TGZ" | awk '{ print $1 }')" au
[[ "$rc" != 0 && ! -e "$BINDIR/aura" && ! -e "$MARKER" ]] && grep -q 'layout' "$WORK/out"
check "unexpected tarball layout: fails, nothing installed, no marker" $?

# --- version pin and reinstall --------------------------------------------------------------------------------
reset_state
au
mkdir -p "$(dirname "$MARKER")"
echo v1.4.0 >"$MARKER"
printf 'old binary\n' >"$BINDIR/aura"
au
[[ "$rc" == 0 && "$(<"$MARKER")" == "$VER" ]] && "$BINDIR/aura" | grep -q "aura $VER" && grep -qx "$URL" "$FAKE_STATE/curl.log"
check "upgrade: a marker with another version reinstalls the pinned release" $?
rm -f -- "$BINDIR/aura"
au
[[ -x "$BINDIR/aura" ]] && grep -qx "$URL" "$FAKE_STATE/curl.log"
check "repair: a missing binary is installed again even with the marker present" $?

# --- shortcut merge (the rule of specs/cosmic-settings.md) --------------------------------------------------------------
SHOT='    (
        modifiers: [
            Super,
            Shift,
        ],
        key: "s",
        description: Some("cosmic-screenshot"),
    ): Spawn("cosmic-screenshot"),'
put_custom "{
$SHOT
}"
au
f="$(flat "$SC")"
[[ "$rc" == 0 && "$f" == *'Spawn("cosmic-screenshot"),('* && "$f" == *"$ALT_FLAT,}" ]] && grep -q 'description: Some("cosmic-screenshot")' "$SC" && compgen -G "$SC.bak.*" >/dev/null
check "shortcut: the Alt+S entry is added next to the screenshot entry, which is kept, after a backup" $?
au
grep -q 'total changes: 0' "$WORK/out"
check "shortcut: stable on the next run (no duplicate)" $?
# The other order: aura first, then the cosmic-settings module adds its entry.
reset_state
au
HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state-home" \
  XDG_RUNTIME_DIR="$WORK/run" "$REPO_ROOT/install.sh" --only cosmic-settings >"$WORK/out2" 2>&1 </dev/null
[[ "$(grep -c 'key: "s"' "$SC")" == 2 ]] && grep -q 'aura switcher' "$SC" && grep -q 'cosmic-screenshot")' "$SC"
check "shortcut: cosmic-settings after aura keeps the Alt+S entry (both entries, either order)" $?
# A user binding on Alt+S is left alone with a warning.
put_custom '{
    (
        modifiers: [Alt],
        key: "s",
        description: None,
    ): Spawn("my-switcher"),
}'
cp "$SC" "$WORK/mine"
au
[[ "$rc" == 0 ]] && cmp -s "$WORK/mine" "$SC" && grep -q '\[warn\].*Alt+S' "$WORK/out" && [[ -x "$BINDIR/aura" ]]
check "shortcut: a user binding on Alt+S is left alone with a warning, aura is still installed" $?
# Comments and field order.
put_custom '{
    // (modifiers: [Alt], key: "s"): Spawn("old"),
    (key: "x", modifiers: [Ctrl], description: None): Spawn("flameshot gui") // mine
}'
au
[[ "$rc" == 0 ]] && grep -q 'Spawn("flameshot gui"), // mine' "$SC" && grep -q 'aura switcher' "$SC" && grep -q 'Spawn("old")' "$SC"
check "shortcut: comments are not bindings, a missing trailing comma is repaired, the user's entries are kept" $?
# An entry already there (any modifier order, key case) is recognised.
put_custom "{ (key: \"S\", modifiers: [Alt], description: Some(\"aurahud\")): $ALT_ACTION, }"
cp "$SC" "$WORK/same"
au
cmp -s "$WORK/same" "$SC" && ! compgen -G "$SC.bak.*" >/dev/null
check "shortcut: an existing aura entry is recognised (byte for byte unchanged)" $?
# Unrecognised files are untouched with a warning.
for junk in 'not a ron map' '{ junk }' '{ ( modifiers: [Ctrl] ): Spawn("x"), }'; do
  put_custom "$junk"
  au
  [[ "$rc" == 0 && "$(cat "$SC")" == "$junk" ]] && grep -q '\[warn\].*custom' "$WORK/out" && ! compgen -G "$SC.bak.*" >/dev/null
  check "shortcut: untouched with a warning for: $junk" $?
done
put_custom '{}'
au
[[ "$(flat "$SC")" == '{(modifiers:[Alt,],key:"s",description:Some("aurahud"),):'"$ALT_FLAT,}" ]]
check "shortcut: an empty map gets just the Alt+S entry" $?
# Never write through sudo into config owned by someone else.
reset_state
mkdir -p "$(dirname "$SC")"
printf '{}' >"$SC"
FAKE_NOT_OWNED="$SC" au
[[ "$rc" == 0 && "$(cat "$SC")" == '{}' ]] && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a shortcut file owned by someone else is not rewritten, no sudo write" $?

# --- legacy autostart and Aura's own autostart ---------------------------------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.config/autostart" "$HOME_DIR/.config/aura"
printf '[Desktop Entry]\nExec=/home/x/.local/bin/aura-autostart.sh\n' >"$HOME_DIR/.config/autostart/aura.desktop"
printf '[Desktop Entry]\nExec=/home/x/.local/bin/aura --hidden\n' >"$HOME_DIR/.config/autostart/io.github.antwny.aura.desktop"
printf '[Desktop Entry]\nExec=firefox\n' >"$HOME_DIR/.config/autostart/other.desktop"
printf '{"current":"/w/a.mp4","autostart":true,"auto_dark":true}' >"$HOME_DIR/.config/aura/config.json"
au
[[ "$rc" == 0 && ! -e "$HOME_DIR/.config/autostart/aura.desktop" && ! -e "$HOME_DIR/.config/autostart/io.github.antwny.aura.desktop" && -e "$HOME_DIR/.config/autostart/other.desktop" ]] &&
  compgen -G "$HOME_DIR/.config/autostart/aura.desktop.bak.*" >/dev/null
check "legacy: autostart entries that start aura are backed up and removed, others kept (the unit restores the wallpaper)" $?
jq -e '.autostart == false and .current == "/w/a.mp4" and .auto_dark == true' "$HOME_DIR/.config/aura/config.json" >/dev/null
check "autostart guard: Aura's own autostart is set to false, every other key is kept (aura keeps owning the theme keys)" $?
au
grep -q 'total changes: 0' "$WORK/out"
check "legacy and guard: a second run changes nothing" $?
reset_state
mkdir -p "$HOME_DIR/.config/aura"
printf 'not json' >"$HOME_DIR/.config/aura/config.json"
au
[[ "$rc" == 0 && "$(cat "$HOME_DIR/.config/aura/config.json")" == 'not json' ]] && grep -q '\[warn\].*JSON' "$WORK/out"
check "autostart guard: an invalid config is left alone with a warning" $?

# --- no systemd user manager ------------------------------------------------------------------------------------
reset_state
FAKE_NO_USER_BUS=1 au
[[ "$rc" == 0 && -f "$UNIT" && ! -s "$FAKE_STATE/user-enabled" ]] && grep -q '\[warn\].*systemctl --user enable' "$WORK/out"
check "no user manager: the unit file is installed, not enabled, the run says how to enable it" $?

# --- hygiene -----------------------------------------------------------------------------------------------------------------
! grep -nE 'curl[^|]*\|[^|]*(ba)?sh' "$REPO_ROOT/modules/60-aura.sh" | grep -q .
check "the module never pipes a download into a shell" $?
! grep -q 'install.sh' <(sed -n '/^_aura_download_install/,/^}/p' "$REPO_ROOT/modules/60-aura.sh" | grep -v '^[[:space:]]*#')
check "the upstream install.sh of the tarball is not run" $?
grep '^| aura ' "$REPO_ROOT/README.md" | grep -q 'aura-restore'
check "README: the aura row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
