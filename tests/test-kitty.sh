#!/usr/bin/env bash
# tests/test-kitty.sh: modules/40-kitty.sh (kitty from apt, the frosted config,
# the COSMIC accent sync for theme version 2, the clear alias in the rc file of
# the login shell, kitty as the COSMIC default terminal) against fake apt-get,
# systemctl and pkill, a temporary HOME and a temporary root. Never touches the
# real system. `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2016: the shell blocks under test contain literal $ on purpose.
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
printf '#!/bin/sh\necho "pkill $*" >>"$FAKE_STATE/pkill.log"\nexit 0\n' >"$WORK/bin/pkill"
chmod +x "$WORK/bin/pkill"
HOME_DIR="$WORK/home"
CFG="$HOME_DIR/.config"
SRC="$REPO_ROOT/files/kitty"
SHARE="$KCS_ROOT/usr/share/cosmic"
SA_DIR="$CFG/cosmic/com.system76.CosmicSettings.Shortcuts/v1"
SA_DEFAULT="$SHARE/com.system76.CosmicSettings.Shortcuts/v1/system_actions"
ALIAS='alias clear='\''printf "\e[H\e[2J\e[3J"'\'''

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# The shipped COSMIC 1.11 default map (the lines that matter, with its comments).
mk_default_actions() {
  mkdir -p "$(dirname "$SA_DEFAULT")"
  cat >"$SA_DEFAULT" <<'EOS'
{
    /// Opens the application library
    AppLibrary: "cosmic-app-library",
    /// Takes a screenshot
    Screenshot: "cosmic-screenshot",
    /// Opens the system default terminal
    Terminal: "cosmic-term",
    /// Opens the system default web browser
    WebBrowser: "xdg-open http://",
}
EOS
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR"
  : >"$FAKE_STATE/installed"
  mk_default_actions
}

# kt <install.sh args...>: the module as a zsh user unless KT_SHELL says otherwise.
kt() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_LOGIN_SHELL="${KT_SHELL:-/usr/bin/zsh}" \
    KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" \
    "$REPO_ROOT/install.sh" --only kitty "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# colors <theme dir> <mode>: run the sync script against the temp HOME and temp share.
run_colors() {
  HOME="$HOME_DIR" PATH="$WORK/bin:$PATH" COSMIC_SHARE_DIR="$SHARE" sh "$SRC/kitty-cosmic-colors.sh"
}
put_accent() { # put_accent <Dark|Light> <version> <hex>
  mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.$1/$2"
  printf '(\n    base: "%s",\n    hover: "#63BAC6FF",\n    pressed: "#000000FF",\n)\n' "$3" >"$CFG/cosmic/com.system76.CosmicTheme.$1/$2/accent"
}

# --- shipped data ----------------------------------------------------------------------
grep -q 'CosmicTheme.Dark/v2/accent' "$SRC/kitty-cosmic-colors.path" && grep -q 'CosmicTheme.Light/v2/accent' "$SRC/kitty-cosmic-colors.path" &&
  grep -q 'CosmicTheme.Mode/v1/is_dark' "$SRC/kitty-cosmic-colors.path" && ! grep -q '/v1/accent' "$SRC/kitty-cosmic-colors.path"
check "path unit: watches theme v2 accent (Dark and Light) and Mode v1 is_dark, no v1 accent" $?
grep -q 'v2/accent' "$SRC/kitty-cosmic-colors.sh" && ! grep -q 'v1/accent' "$SRC/kitty-cosmic-colors.sh"
check "color script: reads the v2 accent" $?
grep -qx 'include cosmic-colors.conf' "$SRC/kitty.conf" && grep -qx 'background_opacity 0.65' "$SRC/kitty.conf" && grep -qx 'background_blur 1' "$SRC/kitty.conf"
check "kitty.conf: frosted glass and the generated colors include" $?

# --- the color script (theme version 2) -----------------------------------------------------
reset_state
mkdir -p "$HOME_DIR/.config"
put_accent Dark v2 '#63D0DFFF'
run_colors
OUT="$CFG/kitty/cosmic-colors.conf"
[[ "$(sed -n 1p "$OUT")" == 'selection_background #63d0df' && "$(sed -n 2p "$OUT")" == 'selection_foreground #000000' ]]
check "colors: the v2 hex accent becomes selection_background, black text on a light accent" $?
put_accent Dark v2 '#112233FF'
run_colors
[[ "$(sed -n 1p "$OUT")" == 'selection_background #112233' && "$(sed -n 2p "$OUT")" == 'selection_foreground #ffffff' ]]
check "colors: a changed accent updates the file, white text on a dark accent" $?
put_accent Light v2 '#ABCDEF80'
run_colors
[[ "$(sed -n 1p "$OUT")" == 'selection_background #112233' ]]
check "colors: the Light accent is ignored while the theme is dark" $?
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Mode/v1"
printf 'false' >"$CFG/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"
run_colors
[[ "$(sed -n 1p "$OUT")" == 'selection_background #abcdef' ]]
check "colors: is_dark false selects the Light accent (alpha bytes are dropped)" $?
grep -q 'pkill -USR1 -x kitty' "$FAKE_STATE/pkill.log"
check "colors: running kitty windows are told to reload (USR1)" $?
reset_state
mkdir -p "$HOME_DIR/.config"
mkdir -p "$SHARE/com.system76.CosmicTheme.Dark/v2"
printf '( base: "#63D0DFFF", hover: "#63BAC6FF", )\n' >"$SHARE/com.system76.CosmicTheme.Dark/v2/accent"
run_colors
grep -qx 'selection_background #63d0df' "$CFG/kitty/cosmic-colors.conf"
check "colors: with no user theme file the shipped default accent is used (one-line RON too)" $?
reset_state
mkdir -p "$HOME_DIR/.config/cosmic/com.system76.CosmicTheme.Dark/v1"
printf '( base: ( red: 0.38, green: 0.81, blue: 0.87, alpha: 1.0, ), )\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v1/accent"
rm -rf -- "$SHARE"
run_colors
[[ ! -e "$CFG/kitty/cosmic-colors.conf" ]]
check "colors: the legacy v1 float file is not read, and a missing v2 file is not an error" $?
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Dark/v2"
printf '( base: ( red: 0.38 ) )\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v2/accent"
! run_colors 2>"$WORK/err"
check "colors: a v2 file with no hex base fails with a message" $?
grep -q 'no base' "$WORK/err"
check "colors: the message names the problem" $?

reset_state
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Dark/v2"
printf '( base: "#112233FF", hover: "#63BAC6FF", on: "#000000FF", base: "#AABBCCFF", )\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v2/accent"
run_colors
grep -qx 'selection_background #112233' "$CFG/kitty/cosmic-colors.conf"
check "colors: with several base: entries on one line the FIRST one is the accent" $?
printf '(\n    base: "#445566FF",\n    hover: "#63BAC6FF",\n    base: "#AABBCCFF",\n)\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v2/accent"
run_colors
grep -qx 'selection_background #445566' "$CFG/kitty/cosmic-colors.conf"
check "colors: with several base: lines the first one is the accent" $?
printf '(\r\n    base: "#778899FF",\r\n)\r\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v2/accent"
run_colors
grep -qx 'selection_background #778899' "$CFG/kitty/cosmic-colors.conf"
check "colors: a CRLF accent file is parsed" $?
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Mode/v1"
printf 'false' >"$CFG/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Light/v2"
printf '( base: "#ffffffFF", hover: "#000000FF", )\n' >"$CFG/cosmic/com.system76.CosmicTheme.Light/v2/accent"
run_colors
[[ "$(sed -n 1p "$CFG/kitty/cosmic-colors.conf")" == 'selection_background #ffffff' && "$(sed -n 2p "$CFG/kitty/cosmic-colors.conf")" == 'selection_foreground #000000' ]]
check "colors: Light single-line RON with a white accent gives black text" $?

# --- dry-run ----------------------------------------------------------------------------------------
reset_state
kt --dry-run
[[ "$rc" == 0 && -z "$(find "$HOME_DIR" -type f 2>/dev/null)" && ! -s "$FAKE_STATE/apt.log" && ! -s "$FAKE_STATE/pkill.log" ]]
check "dry-run: exit 0, no file, no apt-get, no color run" $?

# --- fresh run (zsh) ----------------------------------------------------------------------------------
reset_state
kt
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
grep -qx kitty "$FAKE_STATE/installed"
check "kitty is installed from apt" $?
cmp -s "$SRC/kitty.conf" "$CFG/kitty/kitty.conf" && cmp -s "$SRC/kitty-cosmic-colors.sh" "$HOME_DIR/.local/bin/kitty-cosmic-colors.sh" &&
  [[ "$(stat -c %a "$HOME_DIR/.local/bin/kitty-cosmic-colors.sh")" == 755 ]] &&
  cmp -s "$SRC/kitty-cosmic-colors.path" "$CFG/systemd/user/kitty-cosmic-colors.path" &&
  cmp -s "$SRC/kitty-cosmic-colors.service" "$CFG/systemd/user/kitty-cosmic-colors.service"
check "files: config, script (0755) and both user units are installed" $?
grep -qx 'kitty-cosmic-colors.path' "$FAKE_STATE/user-enabled"
check "the path unit is enabled for the user" $?
[[ "$(grep -c "alias clear=" "$HOME_DIR/.zshrc")" == 1 ]] && grep -qxF "$ALIAS" "$HOME_DIR/.zshrc" && [[ ! -e "$HOME_DIR/.bashrc" ]]
check "zsh login shell: the clear alias is one managed block in ~/.zshrc and ~/.bashrc is not created" $?
grep -qx '# >>> kali-cosmic-setup:kitty-clear >>>' "$HOME_DIR/.zshrc"
check "the block carries the kali-cosmic-setup markers" $?
[[ "$(sed -n 's/^Terminal: *//p;s/^    Terminal: *//p' "$SA_DIR/system_actions")" == '"kitty",' ]] &&
  grep -qx '    Screenshot: "cosmic-screenshot",' "$SA_DIR/system_actions" && grep -qx '    AppLibrary: "cosmic-app-library",' "$SA_DIR/system_actions" &&
  grep -qx '    WebBrowser: "xdg-open http://",' "$SA_DIR/system_actions" && ! grep -q 'cosmic-term' "$SA_DIR/system_actions"
check "system_actions: the full 1.11 map is written with only Terminal changed to kitty" $?
[[ "$(grep -c '' "$SA_DIR/system_actions")" == "$(grep -c '' "$SA_DEFAULT")" ]]
check "system_actions: same number of lines as the shipped map (comments and entries kept)" $?
M="$CFG/cosmic-mimeapps.list"
grep -qx '\[Default Applications\]' "$M" && grep -qx 'x-scheme-handler/terminal=kitty.desktop' "$M" && grep -qx 'application/x-terminal-emulator=kitty.desktop' "$M"
check "mimeapps: kitty.desktop is the default terminal handler" $?

# --- second run -------------------------------------------------------------------------------------------
: >"$FAKE_STATE/apt.log"
kt
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/apt.log" && ! -s "$FAKE_STATE/pkill.log" ]]
check "second run: total changes: 0, nothing reinstalled, no color run" $?
! compgen -G "$HOME_DIR/.zshrc.bak.*" >/dev/null && ! compgen -G "$SA_DIR/system_actions.bak.*" >/dev/null && ! compgen -G "$M.bak.*" >/dev/null
check "second run: no backup files" $?

# --- bash login shell ----------------------------------------------------------------------------------------
reset_state
KT_SHELL=/bin/bash kt
[[ "$rc" == 0 ]] && grep -qxF "$ALIAS" "$HOME_DIR/.bashrc" && [[ ! -e "$HOME_DIR/.zshrc" ]]
check "bash login shell: the block goes to ~/.bashrc and ~/.zshrc is not created" $?
KT_SHELL=/bin/bash kt
grep -q 'total changes: 0' "$WORK/out"
check "bash login shell: second run changes nothing" $?

# --- another login shell -----------------------------------------------------------------------------------
reset_state
KT_SHELL=/usr/bin/fish kt
[[ "$rc" == 0 && ! -e "$HOME_DIR/.zshrc" && ! -e "$HOME_DIR/.bashrc" && -f "$CFG/kitty/kitty.conf" ]] && grep -q 'fish' "$WORK/out"
check "fish login shell: the module warns, writes no rc block and still configures kitty" $?

# --- legacy alias ------------------------------------------------------------------------------------------------
reset_state
printf 'export A=1\n# clear que también borra el historial de scroll\n%s\necho end\n' "$ALIAS" >"$HOME_DIR/.zshrc"
kt
[[ "$(grep -c "alias clear=" "$HOME_DIR/.zshrc")" == 1 ]] && ! grep -q 'borra el historial' "$HOME_DIR/.zshrc" && grep -qx 'export A=1' "$HOME_DIR/.zshrc" &&
  grep -qx 'echo end' "$HOME_DIR/.zshrc" && compgen -G "$HOME_DIR/.zshrc.bak.*" >/dev/null
check "legacy: the unmanaged alias and its old comment are removed, other lines kept, backup made" $?
kt
grep -q 'total changes: 0' "$WORK/out"
check "legacy: a second run changes nothing" $?

# --- system_actions of an existing user ------------------------------------------------------------------------------
reset_state
mkdir -p "$SA_DIR"
sed 's/AppLibrary: "cosmic-app-library"/AppLibrary: "my-launcher"/' "$SA_DEFAULT" >"$SA_DIR/system_actions"
kt
grep -qx '    Terminal: "kitty",' "$SA_DIR/system_actions" && grep -qx '    AppLibrary: "my-launcher",' "$SA_DIR/system_actions" &&
  compgen -G "$SA_DIR/system_actions.bak.*" >/dev/null
check "existing map: only the default cosmic-term terminal is switched to kitty, the user's other entries stay, backup made" $?
reset_state
mkdir -p "$SA_DIR"
sed 's/"cosmic-term"/"alacritty"/' "$SA_DEFAULT" >"$SA_DIR/system_actions"
kt
grep -qx '    Terminal: "alacritty",' "$SA_DIR/system_actions" && grep -qi 'another Terminal' "$WORK/out"
check "existing map: a terminal the user chose is kept and the run warns" $?
reset_state
mkdir -p "$SA_DIR"
printf '{\n    Screenshot: "x",\n}\n' >"$SA_DIR/system_actions"
kt
[[ "$(cat -- "$SA_DIR/system_actions")" == $'{\n    Screenshot: "x",\n}' ]] && grep -qi 'system_actions' "$WORK/out"
check "existing map: a map with no Terminal entry is left alone with a warning" $?
reset_state
rm -rf -- "$SHARE"
kt
[[ "$rc" == 0 && ! -e "$SA_DIR/system_actions" ]] && grep -qi 'system_actions' "$WORK/out"
check "no shipped map: no partial map is written, the run warns" $?

# --- a failing colour sync only warns -----------------------------------------------------------------------------
reset_state
mkdir -p "$CFG/cosmic/com.system76.CosmicTheme.Dark/v2"
printf '( base: ( red: 0.38 ) )\n' >"$CFG/cosmic/com.system76.CosmicTheme.Dark/v2/accent"
kt
[[ "$rc" == 0 ]] && grep -q '\[warn\].*colou\?r' "$WORK/out" && ! grep -q '\[error\]' "$WORK/out" &&
  grep -qxF "$ALIAS" "$HOME_DIR/.zshrc" && [[ -f "$SA_DIR/system_actions" && -f "$CFG/cosmic-mimeapps.list" ]]
check "colour sync failure: the module warns and still finishes (alias, system_actions, mimeapps written), exit 0" $?

# --- mimeapps with another default ---------------------------------------------------------------------------------------
reset_state
mkdir -p "$CFG"
printf '[Default Applications]\nx-scheme-handler/terminal=foot.desktop\ntext/html=x.desktop\n' >"$CFG/cosmic-mimeapps.list"
kt
grep -qx 'x-scheme-handler/terminal=foot.desktop' "$CFG/cosmic-mimeapps.list" && grep -qx 'text/html=x.desktop' "$CFG/cosmic-mimeapps.list" &&
  grep -qx 'application/x-terminal-emulator=kitty.desktop' "$CFG/cosmic-mimeapps.list"
check "mimeapps: another terminal handler is kept (the helper warns), other entries preserved" $?

# --- no user manager -----------------------------------------------------------------------------------------------------------
reset_state
FAKE_NO_USER_BUS=1 kt
[[ "$rc" == 0 && -f "$CFG/systemd/user/kitty-cosmic-colors.path" && ! -s "$FAKE_STATE/user-enabled" ]] && grep -q 'systemctl --user enable --now kitty-cosmic-colors.path' "$WORK/out"
check "no user manager: units are written, nothing is enabled, the command to run later is shown" $?

# --- files owned by someone else, symlinks (never through sudo) ------------------------
reset_state
mkdir -p "$CFG/kitty" "$SA_DIR"
printf 'font_size 9\n' >"$CFG/kitty/kitty.conf"
printf '{ Terminal: "cosmic-term", }\n' >"$SA_DIR/system_actions"
printf 'alias x=y\n' >"$HOME_DIR/.zshrc"
FAKE_NOT_OWNED="$CFG/kitty/kitty.conf:$SA_DIR/system_actions:$HOME_DIR/.zshrc" kt
[[ "$rc" == 0 && "$(cat "$CFG/kitty/kitty.conf")" == 'font_size 9' && "$(cat "$SA_DIR/system_actions")" == '{ Terminal: "cosmic-term", }' &&
  "$(cat "$HOME_DIR/.zshrc")" == 'alias x=y' ]] && grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: kitty.conf, system_actions and the rc file owned by someone else are skipped, no sudo write" $?
[[ -f "$CFG/cosmic-mimeapps.list" && -f "$HOME_DIR/.local/bin/kitty-cosmic-colors.sh" ]]
check "ownership: the files that are the user's are still written" $?
reset_state
mkdir -p "$HOME_DIR/dotfiles" "$WORK/outside"
printf 'alias x=y\n' >"$HOME_DIR/dotfiles/zshrc"
ln -s "$HOME_DIR/dotfiles/zshrc" "$HOME_DIR/.zshrc"
mkdir -p "$CFG/kitty"
printf 'font_size 9\n' >"$WORK/outside/kitty.conf"
ln -s "$WORK/outside/kitty.conf" "$CFG/kitty/kitty.conf"
kt
[[ "$rc" == 0 && -L "$HOME_DIR/.zshrc" ]] && grep -q 'kali-cosmic-setup:kitty-clear' "$HOME_DIR/dotfiles/zshrc" && grep -qx 'alias x=y' "$HOME_DIR/dotfiles/zshrc"
check "symlink: an rc file linked into the home directory gets the block through the link, the link stays" $?
[[ -L "$CFG/kitty/kitty.conf" && "$(cat "$WORK/outside/kitty.conf")" == 'font_size 9' ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: a kitty.conf linked outside the home directory is skipped with a warning, the link is not replaced" $?

# --- static --------------------------------------------------------------------------------------------------------------------------
grep -qi 'stale' "$REPO_ROOT/specs/kitty.md" && grep -q 'system_actions' <(grep -i 'stale' "$REPO_ROOT/specs/kitty.md")
check "spec: notes that the copied system_actions map can go stale after COSMIC updates" $?
grep '^| kitty ' "$REPO_ROOT/README.md" | grep -q 'system_actions.bak'
check "README: the kitty revert restores system_actions from its .bak (it never just deletes the key)" $?
grep '^| kitty ' "$REPO_ROOT/README.md" | grep -q 'kitty-cosmic-colors.path'
check "README: the kitty row has a revert column" $?
! LC_ALL=C grep -q '[^ -~]' "$SRC/kitty-cosmic-colors.sh"
check "the color script is plain ASCII" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
