#!/usr/bin/env bash
# tests/test-sudo.sh: the password is asked once at the start of a real run
# (sudo -v), never in dry-run, and helpers then use `sudo -n`. A fake `sudo`
# in PATH records its arguments, so no real sudo is needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/modules" "$WORK/bin" "$WORK/cache"

cat >"$WORK/bin/sudo" <<'EOS'
#!/bin/sh
echo "$*" >>"$SUDO_LOG"
case "$1" in
  -v) [ -n "${FAKE_SUDO_FAIL:-}" ] && exit 1; exit 0 ;;
  -n) shift; [ "$1" = "-v" ] && exit 0; exec "$@" ;;
esac
exit 99
EOS
chmod +x "$WORK/bin/sudo"

cat >"$WORK/modules/10-one.sh" <<EOM
MODULE_NAME="one"; MODULE_DESC="uses run_sudo"; MODULE_OPTIN=0; MODULE_DEPS=""
module_apply() {
  run_sudo touch "$WORK/ran"
}
EOM

failures=0
check() {
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# inst <args...>: run install.sh with the fake sudo; sets rc, output in $WORK/out.
inst() {
  : >"$WORK/sudo.log"
  rm -f -- "$WORK/ran"
  rc=0
  PATH="$WORK/bin:$PATH" SUDO_LOG="$WORK/sudo.log" KCS_MODULES_DIR="$WORK/modules" \
    KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

inst "$REPO_ROOT/install.sh" --all
if [[ "$(head -n1 "$WORK/sudo.log")" == "-v" && "$rc" == "0" && -e "$WORK/ran" ]]; then
  check "real run: sudo -v first, module ran" 0
else check "real run: sudo -v first, module ran" 1; fi
if grep -qx -- '-n touch .*/ran' "$WORK/sudo.log"; then
  check "run_sudo uses sudo -n" 0
else check "run_sudo uses sudo -n" 1; fi
if (($(grep -c -x -- "-v" "$WORK/sudo.log") == 1)); then
  check "the password prompt (sudo -v) happens once" 0
else check "the password prompt (sudo -v) happens once" 1; fi

FAKE_SUDO_FAIL=1 inst "$REPO_ROOT/install.sh" --all
if [[ "$rc" != "0" && ! -e "$WORK/ran" ]] && grep -q 'sudo authentication failed' "$WORK/out"; then
  check "failed sudo -v stops before any module" 0
else check "failed sudo -v stops before any module" 1; fi

inst "$REPO_ROOT/install.sh" --all --dry-run
if [[ "$rc" == "0" && ! -s "$WORK/sudo.log" && ! -e "$WORK/ran" ]]; then
  check "dry-run never calls sudo" 0
else check "dry-run never calls sudo" 1; fi

inst env KCS_SKIP_SUDO=1 "$REPO_ROOT/install.sh" --all
if [[ "$(head -n1 "$WORK/sudo.log")" == "-n touch $WORK/ran" ]]; then
  check "KCS_SKIP_SUDO=1 skips sudo -v" 0
else check "KCS_SKIP_SUDO=1 skips sudo -v" 1; fi

inst "$REPO_ROOT/install.sh" --list
if [[ "$rc" == "0" && ! -s "$WORK/sudo.log" ]]; then
  check "--list never calls sudo" 0
else check "--list never calls sudo" 1; fi

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
