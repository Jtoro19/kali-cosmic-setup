#!/usr/bin/env bash
# tests/test-applets.sh: modules/50-applets.sh (Workspace Icons and Lock Keys built
# from pinned upstream commits with cargo, installed like the eos module, no Now
# Playing) against fake apt-get, git and cargo, a temporary HOME and a temporary
# root. Never touches the real system and never uses the network.
# `! cmd; check $?` is deliberate: check reads the inverted status.
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
CFG="$HOME_DIR/.config"
WI_ID=io.github.crocodile.cosmic-ext-applet-workspace-icons
LK_ID=com.lucianosb.cosmic-ext-lock-keys
WI_BIN="$HOME_DIR/.local/bin/cosmic-ext-applet-workspace-icons"
LK_BIN="$KCS_ROOT/usr/local/bin/cosmic-ext-lock-keys"
WI_DESKTOP="$HOME_DIR/.local/share/applications/$WI_ID.desktop"
LK_DESKTOP="$KCS_ROOT/usr/local/share/applications/$LK_ID.desktop"
MARK="$HOME_DIR/.local/state/kali-cosmic-setup/applets"
WI_COMMIT=3cf946a85c4fd3eb3b5cf6cfb4ba43f14206ab77
LK_COMMIT=1be12f5668dc449af6992944342a1f684764ce02
M="$REPO_ROOT/modules/50-applets.sh"

# git: `init <dir>` makes a source tree for the applet named by the remote
# (written to <dir>/.url by `remote add`); `-C <dir> rev-parse HEAD` prints the
# pinned commit of that applet (FAKE_GIT_HEAD overrides). Every call is logged.
cat >"$WORK/bin/git" <<EOS
#!/bin/sh
echo "git \$*" >>"\$FAKE_STATE/git.log"
[ -n "\${FAKE_GIT_FAIL:-}" ] && exit 128
if [ "\$1" = init ]; then
  for a in "\$@"; do dest="\$a"; done
  mkdir -p "\$dest"
  exit 0
fi
if [ "\$1" = -C ] && [ "\$3" = remote ]; then
  echo "\$6" >"\$2/.url"
  exit 0
fi
if [ "\$1" = -C ] && [ "\$3" = checkout ]; then
  d="\$2"
  case "\$(cat "\$d/.url")" in
    *workspace-icons*)
      name=cosmic-ext-applet-workspace-icons
      mkdir -p "\$d/resources"
      echo svg >"\$d/resources/$WI_ID.svg"
      echo metainfo >"\$d/resources/$WI_ID.metainfo.xml"
      ;;
    *)
      name=cosmic-ext-lock-keys
      mkdir -p "\$d/data/icons"
      echo caps >"\$d/data/icons/caps-lock-symbolic.svg"
      echo num >"\$d/data/icons/num-lock-symbolic.svg"
      ;;
  esac
  printf '[package]\nname = "%s"\n' "\$name" >"\$d/Cargo.toml"
  echo lock >"\$d/Cargo.lock"
  exit 0
fi
if [ "\$1" = -C ] && [ "\$3" = rev-parse ]; then
  case "\$(cat "\$2/.url")" in
    *workspace-icons*) echo "\${FAKE_GIT_HEAD:-$WI_COMMIT}" ;;
    *) echo "\${FAKE_GIT_HEAD:-$LK_COMMIT}" ;;
  esac
  exit 0
fi
exit 0
EOS
# cargo build --release --locked --manifest-path <dir>/Cargo.toml --target-dir <t>:
# writes a binary named after the package in the manifest.
cat >"$WORK/bin/cargo" <<'EOS'
#!/bin/sh
echo "cargo $*" >>"$FAKE_STATE/cargo.log"
[ -n "${FAKE_CARGO_FAIL:-}" ] && exit 101
while [ $# -gt 0 ]; do
  case "$1" in --target-dir) t="$2"; shift ;; --manifest-path) m="$2"; shift ;; esac
  shift
done
name="$(sed -n 's/^name = "\(.*\)"/\1/p' "$m")"
mkdir -p "$t/release"
printf '#!/bin/sh\necho "%s built"\n' "$name" >"$t/release/$name"
chmod +x "$t/release/$name"
EOS
chmod +x "$WORK/bin/git" "$WORK/bin/cargo"

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR"
  : >"$FAKE_STATE/installed"
}

# ap <install.sh args...>
ap() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only applets "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata and shipped data --------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^applets +no ' <<<"$out" >/dev/null
check "metadata: applets is a default (not opt-in) module" $?
! grep -rq 'Now[P]laying' "$REPO_ROOT/modules" "$REPO_ROOT/files" "$REPO_ROOT/tests" "$REPO_ROOT/specs/applets.md"
check "Now Playing is dropped: no Now-Playing id anywhere in the module, files, tests or spec" $?
grep -q 'Now Playing' "$REPO_ROOT/specs/applets.md" && grep -qi 'dropped' "$REPO_ROOT/specs/applets.md"
check "the spec says why Now Playing is dropped" $?
grep -q "$WI_COMMIT" "$M" && grep -q "$LK_COMMIT" "$M"
check "the module pins both applets to a commit" $?
! grep -Eq 'curl .*\| *(ba)?sh|wget|cargo install|sudo cargo|run_sudo cargo' "$M"
check "no curl-pipe-shell, no wget, no cargo install, cargo never runs as root" $?
grep -qx 'Exec=/usr/local/bin/cosmic-ext-lock-keys' "$REPO_ROOT/files/applets/$LK_ID.desktop" && grep -qx 'X-CosmicApplet=true' "$REPO_ROOT/files/applets/$LK_ID.desktop"
check "the Lock Keys desktop entry is an applet entry with an absolute /usr/local Exec" $?

# --- dry-run ----------------------------------------------------------------------------
reset_state
ap --dry-run
[[ "$rc" == 0 && ! -e "$WI_BIN" && ! -e "$LK_BIN" && ! -e "$WI_DESKTOP" && ! -e "$LK_DESKTOP" && ! -d "$HOME_DIR/.config" && ! -s "$FAKE_STATE/git.log" &&
  ! -s "$FAKE_STATE/cargo.log" && ! -s "$FAKE_STATE/apt.log" && ! -d "$WORK/cache/kali-cosmic-setup/src" ]]
check "dry-run: exit 0, no clone, no build, no apt-get, no file, no source directory" $?
[[ "$(grep -c 'build and install' "$WORK/out")" == 2 ]] && grep -q 'libxkbcommon-dev' "$WORK/out"
check "dry-run: reports both builds and the build packages it would install" $?

# --- fresh run ---------------------------------------------------------------------------
reset_state
ap
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
for p in build-essential cargo rustc git pkg-config libxkbcommon-dev; do grep -qx "$p" "$FAKE_STATE/installed" || { echo "missing $p"; false; }; done
check "packages: the verified minimal build set comes from apt" $?
! grep -Eq 'libwayland-dev|libinput-dev|libudev-dev|libssl-dev|cmake|\bjust\b|libclang' "$M"
check "packages: no -dev library that a real build showed to be unneeded" $?
grep -q -- "fetch.* origin $WI_COMMIT" "$FAKE_STATE/git.log" && grep -q -- "fetch.* origin $LK_COMMIT" "$FAKE_STATE/git.log" &&
  grep -q 'github.com/crocodile/cosmic-ext-applet-workspace-icons' "$FAKE_STATE/git.log" && grep -q 'github.com/lucianosb/cosmic-applet-lock-keys' "$FAKE_STATE/git.log"
check "source: each applet is fetched shallow over https at its pinned commit" $?
[[ "$(grep -c 'rev-parse HEAD' "$FAKE_STATE/git.log")" == 2 ]]
check "source: the checked-out commit is read back for each applet" $?
[[ "$(grep -c 'build --release --locked' "$FAKE_STATE/cargo.log")" == 2 ]]
check "build: cargo build --release --locked, once per applet" $?
[[ -x "$WI_BIN" && "$(stat -c %a "$WI_BIN")" == 755 && "$("$WI_BIN")" == "cosmic-ext-applet-workspace-icons built" ]]
check "install: the Workspace Icons binary is in ~/.local/bin (0755)" $?
[[ -x "$LK_BIN" && "$(stat -c %a "$LK_BIN")" == 755 && "$("$LK_BIN")" == "cosmic-ext-lock-keys built" ]]
check "install: the Lock Keys binary is /usr/local/bin/cosmic-ext-lock-keys (0755, outside dpkg territory)" $?
grep -qx "Exec=$HOME_DIR/.local/bin/cosmic-ext-applet-workspace-icons" "$WI_DESKTOP" && grep -qx 'X-CosmicApplet=true' "$WI_DESKTOP" && ! grep -q '@HOME@' "$WI_DESKTOP"
check "Workspace Icons desktop entry: absolute Exec in the user's home, applet flag" $?
cmp -s "$REPO_ROOT/files/applets/$LK_ID.desktop" "$LK_DESKTOP"
check "Lock Keys desktop entry is in /usr/local/share/applications" $?
[[ -f "$HOME_DIR/.local/share/icons/hicolor/scalable/apps/$WI_ID.svg" && -f "$HOME_DIR/.local/share/metainfo/$WI_ID.metainfo.xml" ]]
check "Workspace Icons icon and metainfo are installed under ~/.local/share" $?
[[ -f "$KCS_ROOT/usr/local/share/icons/hicolor/scalable/apps/caps-lock-symbolic.svg" && -f "$KCS_ROOT/usr/local/share/icons/hicolor/scalable/apps/num-lock-symbolic.svg" ]]
check "Lock Keys caps and num lock icons are installed under /usr/local/share/icons" $?
ok=0
while IFS= read -r -d '' f; do
  rel="${f#"$REPO_ROOT"/files/applets/cosmic/}"
  cmp -s "$f" "$CFG/cosmic/$rel" || ok=1
done < <(find "$REPO_ROOT/files/applets/cosmic" -type f -print0)
[[ "$ok" == 0 && -f "$CFG/cosmic/$WI_ID/v3/pill_style" ]]
check "config: the eight Workspace Icons v3 key files are installed byte for byte" $?
[[ "$(<"$MARK/cosmic-ext-applet-workspace-icons.commit")" == "$WI_COMMIT" && "$(<"$MARK/cosmic-ext-lock-keys.commit")" == "$LK_COMMIT" ]]
check "marker: the built commit of each applet is recorded" $?
! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "cleanup: the checkout and its target directory are removed after the build" $?
! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log" 2>/dev/null
check "nothing in the home directory was written through sudo" $?

# --- second run ---------------------------------------------------------------------------
: >"$FAKE_STATE/apt.log"
ap
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/git.log" && ! -s "$FAKE_STATE/cargo.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "second run: total changes: 0, no clone, no build, no apt-get" $?
! compgen -G "$HOME_DIR/.local/share/applications/*.bak.*" >/dev/null && ! find "$HOME_DIR" "$KCS_ROOT" -name '*.bak.*' | grep -q .
check "second run: no backup files" $?
ap --dry-run
grep -q 'Nothing to change\|total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/cargo.log" ]]
check "dry-run after a real run: nothing to change" $?

# --- rebuilds: pin moved, artifact missing ---------------------------------------------------
printf 'oldcommit\n' >"$MARK/cosmic-ext-lock-keys.commit"
ap
[[ "$rc" == 0 && "$(grep -c 'build --release' "$FAKE_STATE/cargo.log")" == 1 ]] && grep -q 'lock-keys' "$FAKE_STATE/cargo.log" &&
  [[ "$(<"$MARK/cosmic-ext-lock-keys.commit")" == "$LK_COMMIT" ]]
check "pin moved: only the applet whose recorded commit differs is rebuilt, and the marker is updated" $?
rm -f -- "$WI_BIN"
ap
[[ "$rc" == 0 && "$(grep -c 'build --release' "$FAKE_STATE/cargo.log")" == 1 ]] && [[ -x "$WI_BIN" ]]
check "a missing binary is rebuilt even when the marker matches" $?
printf '#!/bin/sh\necho x\n' >"$WI_BIN"
rm -f -- "$LK_DESKTOP"
ap
[[ "$rc" == 0 && ! -s "$FAKE_STATE/cargo.log" && -f "$LK_DESKTOP" ]]
check "a missing desktop entry is restored without a rebuild" $?
printf '[Desktop Entry]\nName=changed\n' >"$WI_DESKTOP"
ap
cmp -s <(sed "s|@HOME@|$HOME_DIR|g" "$REPO_ROOT/files/applets/$WI_ID.desktop.in") "$WI_DESKTOP" && ls "$WI_DESKTOP".bak.* >/dev/null 2>&1
check "a drifted desktop entry is rewritten after a backup" $?

# --- pin verification, failures ---------------------------------------------------------------
reset_state
FAKE_GIT_HEAD=deadbeef ap
[[ "$rc" != 0 && ! -s "$FAKE_STATE/cargo.log" && ! -e "$WI_BIN" && ! -e "$LK_BIN" ]] && grep -q '\[error\].*pinned' "$WORK/out"
check "pin: a checkout at another commit is refused before any build or install" $?
! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "pin: the refused checkout is removed" $?
reset_state
FAKE_CARGO_FAIL=1 ap
[[ "$rc" != 0 && ! -e "$WI_BIN" && ! -e "$LK_BIN" && ! -e "$MARK/cosmic-ext-applet-workspace-icons.commit" ]]
check "a failing build fails the module, installs nothing and records no marker" $?
! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "a failing build still removes the checkout (EXIT trap)" $?
reset_state
FAKE_GIT_FAIL=1 ap
[[ "$rc" != 0 && ! -s "$FAKE_STATE/cargo.log" ]]
check "a failing fetch fails the module without building" $?
reset_state
FAKE_APT_RC=100 ap
[[ "$rc" != 0 && ! -s "$FAKE_STATE/cargo.log" ]]
check "a failing apt-get fails the module without building" $?

# --- user files owned by someone else, symlinks ---------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.local/bin"
FAKE_NOT_OWNED="$HOME_DIR/.local/bin" ap
[[ "$rc" == 0 && ! -e "$WI_BIN" && -x "$LK_BIN" ]] && grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log" &&
  [[ ! -e "$MARK/cosmic-ext-applet-workspace-icons.commit" ]] && [[ "$(grep -c 'build --release' "$FAKE_STATE/cargo.log")" == 1 ]]
check "ownership: ~/.local/bin owned by someone else skips Workspace Icons (no build, no marker, no sudo), Lock Keys is still built" $?
reset_state
mkdir -p "$HOME_DIR/.local/share/applications" "$WORK/outside"
printf 'x\n' >"$WORK/outside/$WI_ID.desktop"
ln -s "$WORK/outside/$WI_ID.desktop" "$WI_DESKTOP"
ap
[[ "$rc" == 0 && -L "$WI_DESKTOP" && "$(cat "$WORK/outside/$WI_ID.desktop")" == x ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a desktop entry linked outside the home directory is skipped with a warning, the link is not replaced" $?

# --- the marker is recorded only after every artifact is installed ----------------------------
reset_state
mkdir -p "$HOME_DIR/.local/share/icons"
FAKE_NOT_OWNED="$HOME_DIR/.local/share/icons" ap
[[ "$rc" == 0 && ! -e "$WI_BIN" && ! -e "$MARK/cosmic-ext-applet-workspace-icons.commit" ]] &&
  [[ "$(grep -c 'build --release' "$FAKE_STATE/cargo.log")" == 1 ]] && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "marker: an icon directory owned by someone else skips the whole Workspace Icons install (no binary, no marker, no build); Lock Keys still builds" $?
FAKE_NOT_OWNED="$HOME_DIR/.local/share/icons" ap
[[ "$rc" == 0 && ! -e "$WI_BIN" && ! -e "$MARK/cosmic-ext-applet-workspace-icons.commit" ]]
check "marker: a second run with the same obstacle still records nothing" $?
reset_state
mkdir -p "$HOME_DIR/.local/share/metainfo"
FAKE_NOT_OWNED="$HOME_DIR/.local/share/metainfo" ap
[[ ! -e "$WI_BIN" && ! -e "$MARK/cosmic-ext-applet-workspace-icons.commit" ]]
check "marker: a metainfo directory owned by someone else also prevents the binary and the marker" $?

# --- an applet registered but its binary skipped ------------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.local/bin"
FAKE_NOT_OWNED="$HOME_DIR/.local/bin" ap
[[ -f "$WI_DESKTOP" ]] && grep -q '\[warn\].*Workspace Icons.*registered.*binary.*skipped' "$WORK/out"
check "registered, not installed: the run warns that the desktop entry exists but the binary was skipped" $?
reset_state
ap
! grep -q 'registered' "$WORK/out"
check "registered, not installed: no such warning on a normal run" $?

# --- symlink loop ----------------------------------------------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.local"
ln -s "$HOME_DIR/.local/loop-b" "$HOME_DIR/.local/loop-a"
ln -s "$HOME_DIR/.local/loop-a" "$HOME_DIR/.local/loop-b"
ln -s "$HOME_DIR/.local/loop-a" "$HOME_DIR/.local/bin"
ap
[[ "$rc" == 0 && ! -e "$WI_BIN" ]] && grep -q '\[warn\].*loop' "$WORK/out" && ! grep -q '\[error\]' "$WORK/out"
check "symlink loop: ~/.local/bin looping is a clean skip with a warning (exit 0, no marker)" $?

# --- Workspace Icons config follows XDG_CONFIG_HOME ----------------------------------------------------------
reset_state
XDG_CONFIG_HOME="$WORK/xdgcfg" ap
[[ -f "$WORK/xdgcfg/cosmic/$WI_ID/v3/pill_style" && ! -e "$CFG/cosmic/$WI_ID" ]]
check "config: the Workspace Icons keys go under XDG_CONFIG_HOME when it is set" $?
XDG_CONFIG_HOME="$WORK/xdgcfg" ap
grep -q 'total changes: 0' "$WORK/out"
check "config: second run with XDG_CONFIG_HOME changes nothing" $?
reset_state
ap
[[ -f "$CFG/cosmic/$WI_ID/v3/pill_style" ]]
check "config: without XDG_CONFIG_HOME the keys are under ~/.config" $?

# --- spec and README notes -------------------------------------------------------------------------------------
grep -qi 'crates.io' "$REPO_ROOT/specs/applets.md" && grep -q 'Cargo.lock' <(grep -i 'trust' "$REPO_ROOT/specs/applets.md")
check "spec: states the crates.io / Cargo.lock trust limit" $?
grep '^| applets ' "$REPO_ROOT/README.md" | grep -q '/\.cargo' && grep '^| applets ' "$REPO_ROOT/README.md" | grep -q '\.bak' &&
  grep '^| applets ' "$REPO_ROOT/README.md" | grep -q 'purge.*libxkbcommon-dev'
check "README: the applets revert covers the ~/.cargo cache, the .bak files and the build packages" $?
grep -q 'XDG_CONFIG_HOME' "$M"
check "the module resolves the Workspace Icons config directory through XDG_CONFIG_HOME" $?

# --- static ------------------------------------------------------------------------------------------
grep '^| applets ' "$REPO_ROOT/README.md" | grep -q 'cosmic-ext-lock-keys'
check "README: the applets row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
