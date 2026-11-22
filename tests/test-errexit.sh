#!/usr/bin/env bash
# tests/test-errexit.sh: a module must stop at its first failed command, even
# when a helper is called as `helper || return 1` (which disables errexit).
# Uses fake modules in a temp dir (KCS_MODULES_DIR) and never needs sudo.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/modules" "$WORK/cache" "$WORK/marks"
M="$WORK/marks"

cat >"$WORK/modules/10-run-false.sh" <<EOM
MODULE_NAME="runfalse"; MODULE_DESC="run false then touch"; MODULE_OPTIN=0; MODULE_DEPS=""
module_apply() {
  log_change "first change"
  run false
  touch "$M/mark1"
}
EOM

cat >"$WORK/modules/20-helper.sh" <<EOM
MODULE_NAME="helper"; MODULE_DESC="helper called with || return 1"; MODULE_OPTIN=0; MODULE_DEPS=""
_helper() {
  run false
  touch "$M/mark2"
}
module_apply() {
  _helper || return 1
}
EOM

cat >"$WORK/modules/30-bare-false.sh" <<EOM
MODULE_NAME="barefalse"; MODULE_DESC="bare false then touch"; MODULE_OPTIN=0; MODULE_DEPS=""
module_apply() {
  false
  touch "$M/mark3"
}
EOM

cat >"$WORK/modules/40-good.sh" <<EOM
MODULE_NAME="good"; MODULE_DESC="succeeds"; MODULE_OPTIN=0; MODULE_DEPS=""
module_apply() {
  log_change "good change"
  touch "$M/mark4"
}
EOM

failures=0
check() { # check <description> <condition-exit-status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

out="$WORK/out.txt"
rc=0
KCS_MODULES_DIR="$WORK/modules" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --all >"$out" 2>&1 </dev/null || rc=$?

for n in 1 2 3; do
  if [[ ! -e "$M/mark$n" ]]; then check "module $n stopped at its first failed command (mark$n not created)" 0; else check "module $n stopped at its first failed command (mark$n not created)" 1; fi
done
if [[ -e "$M/mark4" ]]; then check "an independent module after the failures still ran" 0; else check "an independent module after the failures still ran" 1; fi
((rc != 0))
check "install.sh exited non-zero (exit $rc)" $?
grep -q 'failed: runfalse helper barefalse' "$out"
check "summary lists the failed modules" $?
grep -q 'command failed (exit 1): false' "$out"
check "run reports the failed command" $?
grep -q 'total changes: 2' "$out"
check "changes of a failed module still count (total changes: 2)" $?
log="$(find "$WORK/cache/kali-cosmic-setup" -name 'install-*.log' 2>/dev/null | head -n1)"
[[ -n "$log" ]] && grep -q 'failed: runfalse helper barefalse' "$log"
check "the run log exists and holds the summary" $?

if ((failures > 0)); then
  printf '\n--- install.sh output ---\n'
  cat -- "$out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
