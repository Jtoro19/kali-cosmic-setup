#!/usr/bin/env bash
# tests/test-install-args.sh: install.sh option parsing (--keyboard, errors,
# --list, empty module set) and the Kali/Debian refusal. Fake modules in a
# temp dir; no sudo and no system changes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/modules" "$WORK/cache" "$WORK/root/etc"

cat >"$WORK/modules/10-probe.sh" <<EOM
MODULE_NAME="probe"; MODULE_DESC="records KEYBOARD_CHOICE"; MODULE_OPTIN=0; MODULE_DEPS=""
module_apply() {
  printf '%s' "\${KEYBOARD_CHOICE-unset}" >"$WORK/kbd"
  touch "$WORK/ran"
}
EOM

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# inst <args...>: run install.sh against the fake modules; sets rc and $WORK/out.
inst() {
  rm -f -- "$WORK/kbd" "$WORK/ran"
  rc=0
  KCS_MODULES_DIR="$WORK/modules" KCS_SKIP_SUDO=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- --keyboard -------------------------------------------------------------
KCS_SKIP_OS_CHECK=1 inst --all --keyboard us:altgr-intl
[[ "$rc" == 0 && "$(<"$WORK/kbd")" == "us:altgr-intl" ]]
check "--keyboard <layout>:<variant> is exported to modules" $?
KCS_SKIP_OS_CHECK=1 inst --all --keyboard=latam
[[ "$rc" == 0 && "$(<"$WORK/kbd")" == "latam" ]]
check "--keyboard=<layout> is accepted" $?
KCS_SKIP_OS_CHECK=1 inst --all --keyboard keep
[[ "$rc" == 0 && "$(<"$WORK/kbd")" == "keep" ]]
check "--keyboard keep is accepted" $?
KCS_SKIP_OS_CHECK=1 inst --all
[[ "$rc" == 0 && -z "$(<"$WORK/kbd")" ]]
check "without --keyboard the variable is empty" $?
KCS_SKIP_OS_CHECK=1 inst --all --keyboard 'bad value!'
[[ "$rc" == 2 && ! -e "$WORK/ran" ]]
check "--keyboard with an invalid value exits 2 before running modules" $?
KCS_SKIP_OS_CHECK=1 inst --all --keyboard
[[ "$rc" == 2 ]]
check "--keyboard without a value exits 2" $?

# --- --list and empty module set -------------------------------------------
inst --list
[[ "$rc" == 0 ]] && grep -q 'probe' "$WORK/out"
check "--list shows the modules" $?
mkdir -p "$WORK/none"
rc=0
KCS_MODULES_DIR="$WORK/none" XDG_CACHE_HOME="$WORK/cache" \
  "$REPO_ROOT/install.sh" --dry-run --all >"$WORK/out" 2>&1 </dev/null || rc=$?
[[ "$rc" == 0 ]] && grep -q 'Nothing to change' "$WORK/out"
check "--dry-run --all with no modules succeeds and changes nothing" $?

# --- OS refusal -------------------------------------------------------------
os_release() { printf '%s\n' "$@" >"$WORK/root/etc/os-release"; }
export KCS_ROOT="$WORK/root"

os_release 'ID=arch'
inst --all
[[ "$rc" != 0 && ! -e "$WORK/ran" ]] && grep -q 'Kali' "$WORK/out"
check "a real run on Arch is refused before any module" $?
inst --all --dry-run
[[ "$rc" == 0 ]]
check "--dry-run on Arch is allowed" $?
KCS_SKIP_OS_CHECK=1 inst --all
[[ "$rc" == 0 && -e "$WORK/ran" ]]
check "KCS_SKIP_OS_CHECK=1 bypasses the refusal (tests only)" $?
os_release 'ID=kali' 'ID_LIKE=debian'
inst --all
[[ "$rc" == 0 && -e "$WORK/ran" ]]
check "Kali is accepted" $?
os_release 'ID=ubuntu' 'ID_LIKE="ubuntu debian"'
inst --all
[[ "$rc" == 0 && -e "$WORK/ran" ]]
check "an ID_LIKE that contains debian is accepted" $?
rm -f -- "$WORK/root/etc/os-release"
inst --all
[[ "$rc" != 0 && ! -e "$WORK/ran" ]]
check "a missing os-release is refused" $?

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
