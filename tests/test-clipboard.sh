#!/usr/bin/env bash
# tests/test-clipboard.sh: modules/30-clipboard.sh (wl-clipboard, wl-clip-persist
# built from a pinned upstream tag, the data-control environment line and the
# user unit) against fake apt-get, git, cargo and systemctl, a temporary HOME and
# a temporary root. Never touches the real system and never uses the network.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2016: the fake commands are written as single-quoted scripts on purpose.
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
BIN="$KCS_ROOT/usr/local/bin/wl-clip-persist"
UNIT="$HOME_DIR/.config/systemd/user/wl-clip-persist.service"
ENVF="$KCS_ROOT/etc/environment"
COMMIT=e26fde01c13922e3a65049dafb7d5adfbc52626e

# git: `clone ... <url> <dest>` makes <dest> with a Cargo.lock; `-C <dir> rev-parse
# HEAD` prints $FAKE_GIT_HEAD (default: the pinned commit). Every call is logged.
cat >"$WORK/bin/git" <<EOS
#!/bin/sh
echo "git \$*" >>"\$FAKE_STATE/git.log"
[ -n "\${FAKE_GIT_FAIL:-}" ] && exit 128
if [ "\$1" = clone ]; then
  for a in "\$@"; do dest="\$a"; done
  mkdir -p "\$dest/src"
  echo lock >"\$dest/Cargo.lock"
  echo '[package]' >"\$dest/Cargo.toml"
  exit 0
fi
if [ "\$1" = -C ] && [ "\$3" = rev-parse ]; then echo "\${FAKE_GIT_HEAD:-$COMMIT}"; exit 0; fi
exit 0
EOS
# cargo build --release --locked --manifest-path <dir>/Cargo.toml --target-dir <t>:
# writes a binary that reports its version like the real one.
cat >"$WORK/bin/cargo" <<'EOS'
#!/bin/sh
echo "cargo $*" >>"$FAKE_STATE/cargo.log"
[ -n "${FAKE_CARGO_FAIL:-}" ] && exit 101
while [ $# -gt 0 ]; do
  case "$1" in --target-dir) t="$2"; shift ;; esac
  shift
done
mkdir -p "$t/release"
printf '#!/bin/sh\necho "wl-clip-persist 0.5.0"\n' >"$t/release/wl-clip-persist"
chmod +x "$t/release/wl-clip-persist"
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

# clip <install.sh args...>
clip() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only clipboard "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata -------------------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^clipboard +no ' <<<"$out" >/dev/null
check "metadata: clipboard is a default (not opt-in) module" $?
grep -qx 'ExecStart=/usr/local/bin/wl-clip-persist --clipboard regular' "$REPO_ROOT/files/clipboard/wl-clip-persist.service" &&
  grep -qx 'WantedBy=graphical-session.target' "$REPO_ROOT/files/clipboard/wl-clip-persist.service"
check "the shipped unit runs the absolute /usr/local path and hangs off graphical-session.target" $?

# --- dry-run ---------------------------------------------------------------------------
reset_state
clip --dry-run
[[ "$rc" == 0 && ! -e "$BIN" && ! -e "$UNIT" && ! -e "$ENVF" && ! -s "$FAKE_STATE/git.log" && ! -s "$FAKE_STATE/cargo.log" ]] &&
  [[ ! -s "$FAKE_STATE/apt.log" ]]
check "dry-run: exit 0, no clone, no build, no apt-get, no file written" $?
grep -q 'wl-clip-persist' "$WORK/out" && grep -q 'COSMIC_DATA_CONTROL_ENABLED=1' "$WORK/out"
check "dry-run: reports the build and the environment line" $?

# --- fresh run ---------------------------------------------------------------------------
reset_state
clip
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
grep -qx wl-clipboard "$FAKE_STATE/installed" && grep -qx cargo "$FAKE_STATE/installed" && grep -qx rustc "$FAKE_STATE/installed" &&
  grep -qx git "$FAKE_STATE/installed"
check "packages: wl-clipboard and the build dependencies come from apt" $?
grep -q -- "--branch v0.5.0 https://github.com/Linus789/wl-clip-persist.git" "$FAKE_STATE/git.log"
check "source: the pinned upstream tag v0.5.0 is cloned shallow over https" $?
grep -q -- "rev-parse HEAD" "$FAKE_STATE/git.log"
check "source: the checked-out commit is read back" $?
grep -q -- 'build --release --locked' "$FAKE_STATE/cargo.log"
check "build: cargo build --release --locked" $?
[[ -x "$BIN" && "$(stat -c %a "$BIN")" == 755 && "$("$BIN" --version)" == "wl-clip-persist 0.5.0" ]]
check "install: the binary is /usr/local/bin/wl-clip-persist (0755)" $?
! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "build: the source and target directories are removed after the install" $?
[[ "$(grep -c '^COSMIC_DATA_CONTROL_ENABLED=1$' "$ENVF")" == 1 ]]
check "env: COSMIC_DATA_CONTROL_ENABLED=1 is in /etc/environment once" $?
cmp -s -- "$REPO_ROOT/files/clipboard/wl-clip-persist.service" "$UNIT"
check "unit: installed in ~/.config/systemd/user" $?
grep -qx 'wl-clip-persist.service' "$FAKE_STATE/user-enabled"
check "unit: enabled for the user" $?
# --- second run ---------------------------------------------------------------------------
rc=0
: >"$FAKE_STATE/apt.log"
clip
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/git.log" && ! -s "$FAKE_STATE/cargo.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "second run: total changes: 0, no clone, no build, no apt-get" $?
! compgen -G "$HOME_DIR/.config/systemd/user/*.bak.*" >/dev/null && ! compgen -G "$ENVF.bak.*" >/dev/null
check "second run: no backup files" $?

# --- version drift: rebuild only when the installed version differs -------------------------------
printf '#!/bin/sh\necho "wl-clip-persist 0.4.0"\n' >"$BIN"
printf 'wl-clip-persist.service\ngraphical-session.target\n' >"$FAKE_STATE/user-active"
clip
[[ "$rc" == 0 && "$("$BIN" --version)" == "wl-clip-persist 0.5.0" ]] && grep -q 'build --release' "$FAKE_STATE/cargo.log"
check "version: an older installed binary is rebuilt from the pinned tag" $?
grep -q -- '--user try-restart wl-clip-persist.service' "$FAKE_STATE/systemctl.log"
check "version: the running user service is restarted after a rebuild" $?

# --- pin verification ----------------------------------------------------------------------------
reset_state
FAKE_GIT_HEAD=0000000000000000000000000000000000000000 clip
[[ "$rc" != 0 && ! -e "$BIN" && ! -s "$FAKE_STATE/cargo.log" ]] && grep -qi 'commit' "$WORK/out"
check "pin: a checkout whose commit differs from the pin fails before any build" $?
! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "pin: the rejected checkout is removed" $?
reset_state
FAKE_GIT_FAIL=1 clip
[[ "$rc" != 0 && ! -e "$BIN" && ! -e "$UNIT" ]]
check "clone failure: the module fails and installs nothing" $?
reset_state
FAKE_CARGO_FAIL=1 clip
[[ "$rc" != 0 && ! -e "$BIN" ]] && ! compgen -G "$WORK/cache/kali-cosmic-setup/src/*" >/dev/null
check "build failure: the module fails, no binary, source removed" $?

# --- no user manager ---------------------------------------------------------------------------------
reset_state
FAKE_NO_USER_BUS=1 clip
[[ "$rc" == 0 && -f "$UNIT" && ! -s "$FAKE_STATE/user-enabled" ]] && grep -q 'systemctl --user enable --now wl-clip-persist.service' "$WORK/out"
check "no user manager: the unit is written, nothing is enabled, the command to run later is shown" $?

# --- /etc/environment and legacy ----------------------------------------------------------------------
reset_state
mkdir -p "$KCS_ROOT/etc" "$HOME_DIR/.config/autostart"
printf 'PATH=/usr/bin\nFOO=bar\n' >"$ENVF"
printf '[Desktop Entry]\nExec=wl-clip-persist\n' >"$HOME_DIR/.config/autostart/wl-clip-persist.desktop"
clip
grep -qx 'PATH=/usr/bin' "$ENVF" && grep -qx 'FOO=bar' "$ENVF" && grep -qx 'COSMIC_DATA_CONTROL_ENABLED=1' "$ENVF"
check "env: existing /etc/environment lines are kept" $?
[[ ! -e "$HOME_DIR/.config/autostart/wl-clip-persist.desktop" ]] && compgen -G "$HOME_DIR/.config/autostart/wl-clip-persist.desktop.bak.*" >/dev/null
check "legacy: the old autostart entry is removed with a backup" $?

# --- files owned by someone else, symlinks (never through sudo) ------------------------
reset_state
mkdir -p "$(dirname "$UNIT")" "$HOME_DIR/.config/autostart"
printf '[Unit]\nDescription=mine\n' >"$UNIT"
printf '[Desktop Entry]\nExec=wl-clip-persist\n' >"$HOME_DIR/.config/autostart/wl-clip-persist.desktop"
FAKE_NOT_OWNED="$UNIT:$HOME_DIR/.config/autostart/wl-clip-persist.desktop" clip
[[ "$rc" == 0 && "$(cat "$UNIT")" == $'[Unit]\nDescription=mine' && -e "$HOME_DIR/.config/autostart/wl-clip-persist.desktop" ]] &&
  grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a unit file and a legacy autostart entry owned by someone else are skipped, no sudo write, nothing removed" $?
reset_state
mkdir -p "$(dirname "$UNIT")" "$HOME_DIR/dotfiles" "$WORK/outside"
printf 'x\n' >"$WORK/outside/wl-clip-persist.service"
ln -s "$WORK/outside/wl-clip-persist.service" "$UNIT"
clip
[[ "$rc" == 0 && -L "$UNIT" && "$(cat "$WORK/outside/wl-clip-persist.service")" == x ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a unit file linked outside the home directory is skipped with a warning, the link is not replaced" $?
reset_state
mkdir -p "$(dirname "$UNIT")" "$HOME_DIR/dotfiles"
ln -s "$HOME_DIR/dotfiles/wl-clip-persist.service" "$UNIT"
clip
[[ "$rc" == 0 && -L "$UNIT" ]] && cmp -s "$REPO_ROOT/files/clipboard/wl-clip-persist.service" "$HOME_DIR/dotfiles/wl-clip-persist.service"
check "symlink: a unit file linked into the home directory is written through the link, the link stays" $?

# --- static ---------------------------------------------------------------------------------------------
M="$REPO_ROOT/modules/30-clipboard.sh"
grep -q 'e26fde01c13922e3a65049dafb7d5adfbc52626e' "$M" && grep -q 'v0.5.0' "$M"
check "the module pins tag v0.5.0 and commit e26fde0" $?
! grep -Eq 'curl .*\| *(ba)?sh|wget|cargo install' "$M"
check "the module has no curl-pipe-shell, no wget and no cargo install (a locked build of the pinned checkout)" $?
grep '^| clipboard ' "$REPO_ROOT/README.md" | grep -q 'systemctl --user disable --now wl-clip-persist'
check "README: the clipboard row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
