#!/usr/bin/env bash
# tests/test-login-rc.sh: the login-shell helpers of lib/common.sh
# (login_shell_name, login_rc_file) and the legacy-text removers (remove_line,
# remove_exact_block), plus user_systemd_ready. Fake getent and systemctl, a
# temporary HOME: nothing real is touched.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2251,SC2319,SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# shellcheck source=tests/lib-fakes.sh
source "$REPO_ROOT/tests/lib-fakes.sh"

export FAKE_STATE="$WORK/state"
export HOME="$WORK/home"
mkdir -p "$FAKE_STATE" "$HOME"
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

# A getent that knows the login shell of two users (the real passwd format).
mkdir -p "$WORK/getent"
cat >"$WORK/getent/getent" <<'EOS'
#!/bin/sh
[ "$1" = passwd ] || exit 2
case "$2" in
  zuser) echo "zuser:x:1000:1000:Z:/home/zuser:/usr/bin/zsh" ;;
  buser) echo "buser:x:1001:1001:B:/home/buser:/bin/bash" ;;
  fuser) echo "fuser:x:1002:1002:F:/home/fuser:/usr/bin/fish" ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$WORK/getent/getent"

# --- login shell from getent -------------------------------------------------------
[[ "$(PATH="$WORK/getent:$PATH" USER=zuser h 'login_shell_name')" == zsh ]]
check "login_shell_name: zsh from the passwd entry" $?
[[ "$(PATH="$WORK/getent:$PATH" USER=buser h 'login_shell_name')" == bash ]]
check "login_shell_name: bash from the passwd entry" $?
[[ "$(PATH="$WORK/getent:$PATH" USER=zuser h 'login_rc_file')" == "$HOME/.zshrc" ]]
check "login_rc_file: ~/.zshrc for a zsh login shell" $?
[[ "$(PATH="$WORK/getent:$PATH" USER=buser h 'login_rc_file')" == "$HOME/.bashrc" ]]
check "login_rc_file: ~/.bashrc for a bash login shell" $?
fout="$(PATH="$WORK/getent:$PATH" USER=fuser h 'login_rc_file' 2>&1)"
rc=$?
[[ "$rc" != 0 && "$fout" == *fish* ]]
check "login_rc_file: another shell fails with a warning naming it (the shell is never changed)" $?
! PATH="$WORK/getent:$PATH" USER=nobody h 'login_rc_file' >/dev/null 2>&1
check "login_rc_file: an unknown user fails" $?

# --- test-only override ----------------------------------------------------------------
[[ "$(PATH="$WORK/getent:$PATH" USER=zuser KCS_TEST=1 KCS_LOGIN_SHELL=/bin/bash h 'login_rc_file')" == "$HOME/.bashrc" ]]
check "override: KCS_LOGIN_SHELL wins when KCS_TEST is set" $?
[[ "$(PATH="$WORK/getent:$PATH" USER=zuser KCS_LOGIN_SHELL=/bin/bash h 'login_rc_file')" == "$HOME/.zshrc" ]]
check "override: KCS_LOGIN_SHELL is ignored without KCS_TEST" $?

# --- remove_line ---------------------------------------------------------------------------
F="$WORK/rc1"
cat >"$F" <<'EOS'
# keep me
# old comment
alias clear='x'
echo one
# >>> kali-cosmic-setup:kitty-clear >>>
alias clear='x'
# <<< kali-cosmic-setup:kitty-clear <<<
alias clear='x'
EOS
h "remove_line '$F' \"alias clear='x'\" '# old comment'" >"$WORK/o" 2>&1
[[ "$(grep -c "alias clear='x'" "$F")" == 1 ]] && ! grep -q 'old comment' "$F" && grep -qx '# keep me' "$F" &&
  grep -qx "# >>> kali-cosmic-setup:kitty-clear >>>" "$F" && grep -qx 'echo one' "$F"
check "remove_line: removes the unmanaged copies and the comment above, keeps the managed block" $?
ls "$F".bak.* >/dev/null 2>&1
check "remove_line: the file is backed up first" $?
before="$(cksum <"$F")"
h "remove_line '$F' \"alias clear='x'\" '# old comment'" >"$WORK/o" 2>&1
[[ "$(cksum <"$F")" == "$before" ]] && ! grep -q 'change' "$WORK/o"
check "remove_line: a second run changes nothing" $?
h "remove_line '$WORK/missing' 'x'"
check "remove_line: a missing file is fine" $?
F="$WORK/rc1d"
printf 'a\nb\n' >"$F"
h "DRY_RUN=1; remove_line '$F' b" >/dev/null 2>&1
[[ "$(cat -- "$F")" == $'a\nb' ]]
check "remove_line: dry-run leaves the file alone" $?

# --- remove_exact_block -----------------------------------------------------------------------
F="$WORK/rc2"
cat >"$F" <<'EOS'
top
# Legacy
if x; then
  y
fi
middle
# >>> kali-cosmic-setup:fastfetch >>>
# Legacy
if x; then
  y
fi
# <<< kali-cosmic-setup:fastfetch <<<
EOS
h "remove_exact_block '$F' $'# Legacy\nif x; then\n  y\nfi'" >"$WORK/o" 2>&1
[[ "$(grep -c '^# Legacy$' "$F")" == 1 ]] && grep -qx middle "$F" && grep -qx top "$F" && sed -n '/>>>/,/<<</p' "$F" | grep -qx 'fi'
check "remove_exact_block: removes the unmanaged text only, the managed block keeps its copy" $?
before="$(cksum <"$F")"
h "remove_exact_block '$F' $'# Legacy\nif x; then\n  y\nfi'" >"$WORK/o" 2>&1
[[ "$(cksum <"$F")" == "$before" ]]
check "remove_exact_block: a second run changes nothing" $?

# --- user_systemd_ready -----------------------------------------------------------------------
: >"$FAKE_STATE/systemctl.log"
h 'user_systemd_ready'
check "user_systemd_ready: true when the user manager answers" $?
! FAKE_NO_USER_BUS=1 h 'user_systemd_ready'
check "user_systemd_ready: false when there is no user manager (SSH without a session)" $?
grep -q -- '--user show-environment' "$FAKE_STATE/systemctl.log"
check "user_systemd_ready: asks the user manager with show-environment" $?
[[ "$(XDG_RUNTIME_DIR='' h 'user_systemd_ready; printf %s "${XDG_RUNTIME_DIR:-unset}"' | tail -n 1)" == "/run/user/$(id -u)" ]]
check "user_systemd_ready: points XDG_RUNTIME_DIR at /run/user/<uid> when unset" $?

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
