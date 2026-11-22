#!/usr/bin/env bash
# tests/test-user-paths.sh: the user-file helpers of lib/common.sh:
# user_path_writable / user_path_resolve (ownership and symlink guard for
# everything below $HOME), ensure_ini_line (CRLF files, "key = value" spacing,
# temp-file cleanup) and ensure_gsetting (timeouts, failed set, read-back).
# Fake stat, sudo and gsettings, a temporary HOME: nothing real is touched.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2251,SC2319,SC2016,SC2031
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export HOME="$WORK/home"
export TMPDIR="$WORK/tmp"
mkdir -p "$FAKE_STATE" "$HOME" "$TMPDIR"
make_fakes "$WORK/bin"
export PATH="$WORK/bin:$PATH"

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

# --- ensure_ini_line: CRLF and spacing ----------------------------------------
F="$WORK/crlf.ini"
printf '[Settings]\r\nkey=value\r\nother=1\r\n' >"$F"
cr_out="$(h "ensure_ini_line '$F' Settings 'key=value'" 2>&1)"
[[ -z "$cr_out" ]] && [[ "$(printf '[Settings]\r\nkey=value\r\nother=1\r\n' | cmp - "$F" && echo same)" == same ]]
check "CRLF file: an existing key=value line is present (no change, no backup)" $?
! ls "$F".bak.* >/dev/null 2>&1
check "CRLF file: no backup was made for the unchanged file" $?
h "ensure_ini_line '$F' Settings 'key=new' replace" >/dev/null 2>&1
grep -qx $'key=new\r' "$F" && grep -qx $'other=1\r' "$F" && ! grep -q 'key=value' "$F"
check "CRLF file: replace rewrites the key in place and keeps the CR line ending" $?
printf '[A]\r\nx=1\r\n' >"$F"
h "ensure_ini_line '$F' A 'y=2'" >/dev/null 2>&1
grep -qx $'y=2\r' "$F" && grep -qx $'x=1\r' "$F"
check "CRLF file: a new key added under the section keeps CRLF" $?
printf '[A]\r\nx=1\r\n' >"$F"
h "ensure_ini_line '$F' B 'y=2'" >/dev/null 2>&1
grep -q '^\[B\]' "$F" && grep -qx 'y=2' "$F"
check "CRLF file: a missing section is appended" $?

F="$WORK/spaced.ini"
printf '[Settings]\nkey = value\n  other   =   1  \n' >"$F"
h "ensure_ini_line '$F' Settings 'key=value'" >/dev/null 2>&1
[[ "$(cat "$F")" == $'[Settings]\nkey = value\n  other   =   1  ' ]] && ! ls "$F".bak.* >/dev/null 2>&1
check "spaced key: 'key = value' counts as key=value (present, no change)" $?
h "ensure_ini_line '$F' Settings 'key=new'" >"$WORK/o" 2>&1
grep -q 'key = value' "$F" && ! grep -q 'key=new' "$F" && grep -q '\[warn\].*key' "$WORK/o"
check "spaced key: a different value under 'key = value' is a conflict, kept with a warning (policy keep)" $?
h "ensure_ini_line '$F' Settings 'key=new' replace" >/dev/null 2>&1
[[ "$(grep -c '^key' "$F")" == 1 ]] && grep -qx 'key=new' "$F" && ! grep -q 'key = value' "$F" && grep -q 'other   =   1' "$F"
check "spaced key: replace rewrites that line instead of adding a second key" $?
h "ensure_ini_line '$F' Settings 'other=1'" >/dev/null 2>&1
[[ "$(grep -c 'other' "$F")" == 1 ]]
check "spaced key with surrounding blanks: 'other   =   1  ' is present" $?
printf '[Settings]\nkeyx=1\n' >"$F"
h "ensure_ini_line '$F' Settings 'key=1'" >/dev/null 2>&1
grep -qx 'key=1' "$F" && grep -qx 'keyx=1' "$F"
check "a longer key that starts with the same text is not the key" $?

# --- ensure_ini_line: temp file cleanup on a failing write ---------------------
F="$WORK/fail.ini"
printf '[S]\na=1\n' >"$F"
cat >"$WORK/bin/install" <<'EOS'
#!/bin/sh
exit 1
EOS
chmod +x "$WORK/bin/install"
rm -f -- "$TMPDIR"/*
h "ensure_ini_line '$F' S 'b=2'" >/dev/null 2>&1
rc=$?
[[ "$rc" != 0 ]] && [[ -z "$(find "$TMPDIR" -type f)" ]]
check "ensure_ini_line: a failing install ends the module and leaves no temp file behind" $?
rm -f -- "$WORK/bin/install"

# --- user_path_writable / user_path_resolve -----------------------------------
mkdir -p "$HOME/.config/app"
touch "$HOME/.config/app/a.conf"
h "user_path_writable '$HOME/.config/app/a.conf' && user_path_writable '$HOME/.config/app/new.conf'"
check "user_path_writable: owned files and missing files under an owned directory pass" $?
FAKE_NOT_OWNED="$HOME/.config/app/a.conf" h "user_path_writable '$HOME/.config/app/a.conf'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\].*not owned' "$WORK/o"
check "user_path_writable: a file owned by someone else fails with a warning" $?
FAKE_NOT_OWNED="$HOME/.config/app" h "user_path_writable '$HOME/.config/app/new.conf'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q 'chown' "$WORK/o"
check "user_path_writable: a directory owned by someone else fails, the warning names the fix" $?
FAKE_NOT_OWNED="$HOME/.config" h "user_path_writable '$HOME/.config/app/deep/er/new.conf'" >/dev/null 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]]
check "user_path_writable: the nearest existing parent is checked for a path that does not exist yet" $?
h "user_path_writable '/etc/hostname-not-in-home'" >/dev/null 2>&1
check "user_path_writable: a path outside \$HOME is not this helper's business (passes)" $?
warn_out="$(FAKE_NOT_OWNED="$HOME/.config/app/a.conf" h "user_path_writable '$HOME/.config/app/a.conf' || true; user_path_writable '$HOME/.config/app/a.conf' || true" 2>&1)"
[[ "$(grep -c 'not owned' <<<"$warn_out")" == 1 ]]
check "user_path_writable: warns once per path" $?

# Symlinks: resolved when the target is inside $HOME and owned by the user.
mkdir -p "$HOME/dotfiles" "$WORK/outside"
echo x >"$HOME/dotfiles/real.conf"
ln -s "$HOME/dotfiles/real.conf" "$HOME/.config/app/link.conf"
[[ "$(h "user_path_resolve '$HOME/.config/app/link.conf'")" == "$(readlink -f "$HOME/dotfiles/real.conf")" ]]
check "user_path_resolve: a symlink into \$HOME resolves to its target" $?
ln -s "$WORK/outside/x.conf" "$HOME/.config/app/out.conf"
h "user_path_resolve '$HOME/.config/app/out.conf'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\].*symlink' "$WORK/o"
check "user_path_resolve: a symlink pointing outside \$HOME is skipped with a warning" $?
FAKE_NOT_OWNED="$(readlink -f "$HOME/dotfiles/real.conf")" h "user_path_resolve '$HOME/.config/app/link.conf'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\]' "$WORK/o"
check "user_path_resolve: a symlink whose target belongs to someone else is skipped" $?
[[ "$(h "user_path_resolve '$HOME/.config/app/a.conf'")" == "$HOME/.config/app/a.conf" ]]
check "user_path_resolve: a plain path is returned unchanged" $?

# The write helpers follow the symlink instead of replacing it.
printf '[S]\na=1\n' >"$HOME/dotfiles/real.ini"
ln -s "$HOME/dotfiles/real.ini" "$HOME/.config/app/link.ini"
h "ensure_ini_line '$HOME/.config/app/link.ini' S 'b=2'" >/dev/null 2>&1
[[ -L "$HOME/.config/app/link.ini" ]] && grep -qx 'b=2' "$HOME/dotfiles/real.ini"
check "ensure_ini_line through a symlink edits the target and keeps the symlink" $?
printf 'one\n' >"$WORK/src.txt"
h "install_file '$WORK/src.txt' '$HOME/.config/app/link.conf' 0644" >/dev/null 2>&1
[[ -L "$HOME/.config/app/link.conf" && "$(cat "$HOME/dotfiles/real.conf")" == one ]]
check "install_file through a symlink writes the target and keeps the symlink" $?
h "install_file '$WORK/src.txt' '$HOME/.config/app/out.conf' 0644" >"$WORK/o" 2>&1
[[ -L "$HOME/.config/app/out.conf" && ! -e "$WORK/outside/x.conf" ]] && grep -q '\[warn\].*symlink' "$WORK/o"
check "install_file never replaces a symlink that points outside \$HOME (skipped with a warning)" $?

# Not owned: no write, no sudo, for every writing helper.
: >"$FAKE_STATE/sudo.log"
U="$HOME/.config/app/owned-by-root.conf"
printf '[S]\na=1\n' >"$U"
printf 'line\n' >"$HOME/.config/app/rc"
export FAKE_NOT_OWNED="$U:$HOME/.config/app/rc"
h "install_file '$WORK/src.txt' '$U' 0644; ensure_ini_line '$U' S 'b=2' replace; ensure_line '$U' 'x'; ensure_block '$U' n 'c'; remove_line '$U' 'a=1'; remove_exact_block '$U' 'a=1'; ensure_file_content '$U' 'zzz'" >"$WORK/o" 2>&1
rc=$?
unset FAKE_NOT_OWNED
[[ "$rc" == 0 && "$(cat "$U")" == $'[S]\na=1' ]] && ! grep -q "$HOME" "$FAKE_STATE/sudo.log" && [[ "$(grep -c 'not owned' "$WORK/o")" == 1 ]] &&
  ! ls "$U".bak.* >/dev/null 2>&1
check "install_file, ensure_ini_line, ensure_line, ensure_block, remove_line, remove_exact_block and ensure_file_content skip a file owned by someone else (no write, no sudo, no backup)" $?

# --- $HOME itself, symlink loops ------------------------------------------------
h "user_path_writable '$HOME'" >"$WORK/o" 2>&1
[[ ! -s "$WORK/o" ]]
check "user_path_writable: the path \$HOME itself passes without a warning" $?
FAKE_NOT_OWNED="$HOME" h "user_path_writable '$HOME'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\].*not owned' "$WORK/o" && ! grep -q 'symlink' "$WORK/o"
check "user_path_writable: a \$HOME owned by someone else is reported as not owned" $?
ln -s "$HOME/loop-b" "$HOME/loop-a"
ln -s "$HOME/loop-a" "$HOME/loop-b"
h "user_path_writable '$HOME/loop-a'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\].*loop' "$WORK/o"
check "user_path_writable: a symlink loop is a clean skip with a warning" $?
h "user_path_writable '$HOME/loop-a/child.conf'" >"$WORK/o" 2>&1 && rc_cmd=0 || rc_cmd=1
[[ $rc_cmd != 0 ]] && grep -q '\[warn\].*loop' "$WORK/o"
check "user_path_writable: a path below a symlink loop is a clean skip with a warning" $?
h "install_file '$WORK/src.txt' '$HOME/loop-a' 0644; ensure_line '$HOME/loop-b' x; ensure_block '$HOME/loop-b' n c" >"$WORK/o" 2>&1
rc=$?
[[ $rc == 0 ]] && ! grep -q '\[error\]' "$WORK/o"
check "install_file, ensure_line and ensure_block skip a symlink loop without failing" $?
rm -f -- "$HOME/loop-a" "$HOME/loop-b"

# --- ensure_block: a missing end marker ---------------------------------------
B="$WORK/nomarker.rc"
printf 'before\n# >>> kali-cosmic-setup:x >>>\nold\nafter the lost end marker\nmore\n' >"$B"
cp -- "$B" "$WORK/nomarker.orig"
h "ensure_block '$B' x 'new content'" >"$WORK/o" 2>&1
rc=$?
cmp -s "$B" "$WORK/nomarker.orig" && [[ "$rc" == 0 ]] && grep -q '\[warn\].*end marker' "$WORK/o" && ! ls "$B".bak.* >/dev/null 2>&1
check "ensure_block: a begin marker with no end marker is malformed, warned about and the file is left untouched" $?
printf 'a\n# >>> kali-cosmic-setup:x >>>\nold\n# <<< kali-cosmic-setup:x <<<\nz\n' >"$B"
h "ensure_block '$B' x 'new'" >/dev/null 2>&1
[[ "$(cat "$B")" == $'a\n# >>> kali-cosmic-setup:x >>>\nnew\n# <<< kali-cosmic-setup:x <<<\nz' ]]
check "ensure_block: a well-formed block is still updated in place" $?

# --- ensure_line: an existing differing value ---------------------------------
L="$WORK/environment"
printf 'PATH=/usr/bin\nCOSMIC_DATA_CONTROL_ENABLED=0\n' >"$L"
h "ensure_line '$L' 'COSMIC_DATA_CONTROL_ENABLED=1'" >"$WORK/o" 2>&1
[[ "$(cat "$L")" == $'PATH=/usr/bin\nCOSMIC_DATA_CONTROL_ENABLED=0' ]] && grep -q '\[warn\].*COSMIC_DATA_CONTROL_ENABLED' "$WORK/o" && ! ls "$L".bak.* >/dev/null 2>&1
check "ensure_line: another value of the same KEY= is kept with a warning, no duplicate, no change" $?
printf 'PATH=/usr/bin\n' >"$L"
h "ensure_line '$L' 'COSMIC_DATA_CONTROL_ENABLED=1'" >/dev/null 2>&1
printf 'XCOSMIC_DATA_CONTROL_ENABLED=5\n' >>"$L"
h "ensure_line '$L' 'COSMIC_DATA_CONTROL_ENABLED=1'" >/dev/null 2>&1
[[ "$(grep -c '^COSMIC_DATA_CONTROL_ENABLED=1$' "$L")" == 1 ]]
check "ensure_line: the line is added once, a longer key with the same tail is not the key" $?
printf 'plain line\n' >"$L"
h "ensure_line '$L' 'another plain line'" >/dev/null 2>&1
grep -qx 'another plain line' "$L"
check "ensure_line: a line without = is appended as before" $?

printf 'axb=2\n' >"$L"
h "ensure_line '$L' 'a.b=1'" >"$WORK/o" 2>&1
[[ "$(cat "$L")" == $'axb=2\na.b=1' ]] && ! grep -q '\[warn\]' "$WORK/o"
check "ensure_line: a line whose left side is not a valid KEY (a.b) is a plain line, the dot is not a regex wildcard" $?
printf 'export FOO=2\n' >"$L"
h "ensure_line '$L' 'export FOO=1'" >"$WORK/o" 2>&1
[[ "$(cat "$L")" == $'export FOO=2\nexport FOO=1' ]]
check "ensure_line: only a strict KEY=value line has the keep-the-other-value rule (export FOO=1 is a plain line)" $?
printf '_A1=2\n' >"$L"
h "ensure_line '$L' '_A1=1'" >"$WORK/o" 2>&1
[[ "$(cat "$L")" == '_A1=2' ]] && grep -q '\[warn\]' "$WORK/o"
check "ensure_line: a strict KEY with a digit and an underscore keeps another value" $?

# --- timeout -k on gsettings and dbus-run-session -----------------------------
grep -q 'timeout -k' <(sed -n '/^_gsettings_get/,/^}/p;/^_gsettings_run/,/^}/p' "$REPO_ROOT/lib/common.sh") && ! grep -q 'timeout "\${KCS_GSETTINGS_TIMEOUT:-20}" ' "$REPO_ROOT/lib/common.sh"
check "gsettings calls use timeout -k (a stuck gsettings or dbus-run-session is killed)" $?

# --- ensure_gsetting ----------------------------------------------------------
export DBUS_SESSION_BUS_ADDRESS=unix:path=/fake-session-bus
GSV="$FAKE_STATE/gsettings"
: >"$FAKE_STATE/gsettings.log"
rm -f -- "$TMPDIR"/*
h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >"$WORK/o" 2>&1
[[ "$(cat "$GSV/org.gnome.desktop.interface.color-scheme")" == "'prefer-dark'" ]] && [[ -z "$(find "$TMPDIR" -type f)" ]] && ! grep -q 'warn' "$WORK/o"
check "ensure_gsetting: sets the value, reads it back, leaves no temp file" $?
n="$(grep -c '^gsettings get' "$FAKE_STATE/gsettings.log")"
((n == 2))
check "ensure_gsetting: one read before the set and one read back after it" $?
: >"$FAKE_STATE/gsettings.log"
h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >"$WORK/o" 2>&1
! grep -q 'gsettings set' "$FAKE_STATE/gsettings.log"
check "ensure_gsetting: an equal value is not set again" $?
rm -rf -- "$GSV"
FAKE_GSETTINGS_NOPERSIST=1 h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >"$WORK/o" 2>&1
rc=$?
[[ "$rc" == 0 ]] && grep -q '\[warn\].*not persist\|\[warn\].*persist' "$WORK/o"
check "ensure_gsetting: a backend that drops the write is detected by the read-back (warning, no failure)" $?
rm -rf -- "$GSV"
FAKE_GSETTINGS_SETFAIL=1 h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >"$WORK/o" 2>&1
rc=$?
[[ "$rc" == 0 ]] && grep -q '\[warn\]' "$WORK/o" && ! grep -q '\[error\]' "$WORK/o" && ! grep -q 'total' "$WORK/o"
check "ensure_gsetting: a failing set is a warning, not a module failure" $?
rm -rf -- "$GSV"
h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >/dev/null 2>&1
grep -q 'KCS_GSETTINGS_TIMEOUT:-20' "$REPO_ROOT/lib/common.sh"
check "gsettings calls go through timeout 20 (default)" $?
# A set that hangs is cut off: the fake sleeps longer than the (shortened) limit.
cp "$WORK/bin/gsettings" "$WORK/gsettings.real"
cat >"$WORK/bin/gsettings" <<'EOS'
#!/bin/sh
[ "$1" = set ] && exec sleep 30
exec "$REAL_GSETTINGS" "$@"
EOS
chmod +x "$WORK/bin/gsettings"
rm -rf -- "$GSV"
start=$SECONDS
REAL_GSETTINGS="$WORK/gsettings.real" KCS_GSETTINGS_TIMEOUT=1 h "ensure_gsetting org.gnome.desktop.interface color-scheme \"'prefer-dark'\"" >"$WORK/o" 2>&1
rc=$?
[[ "$rc" == 0 ]] && ((SECONDS - start < 10)) && grep -q '\[warn\]' "$WORK/o"
check "ensure_gsetting: a hanging gsettings set is cut off by the timeout and warned about" $?
cp "$WORK/gsettings.real" "$WORK/bin/gsettings"
grep -q '</dev/null' <(sed -n '/^_gsettings_run/,/^}/p' "$REPO_ROOT/lib/common.sh")
check "gsettings calls read </dev/null and write to /dev/null" $?

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
