#!/usr/bin/env bash
# install.sh: turn a fresh Kali Linux install (no desktop) into a configured COSMIC desktop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keyboard.sh
source "$SCRIPT_DIR/lib/keyboard.sh"

# KCS_MODULES_DIR is a test-only override (tests/test-errexit.sh uses fake modules).
MODULES_DIR="${KCS_MODULES_DIR:-$REPO_ROOT/modules}"

# Nothing may stop to ask for credentials: a failed git clone must fail fast.
export GIT_TERMINAL_PROMPT=0

# Parallel arrays describing discovered modules (same index = same module).
MOD_FILES=()
MOD_NAMES=()
MOD_OPTIN=()
MOD_DEPS=()
MOD_DESC=()

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --list              List available modules.
  --all               Run all non-opt-in modules.
  --only <module>     Run only this module plus its dependencies. Repeatable,
                      also accepts a comma-separated list. Opt-in modules run
                      only when named here.
  --keyboard <layout>[:<variant>]|keep
                      Keyboard layout for the keyboard module, for example
                      latam or us:altgr-intl; keep leaves the current layout.
                      Skips the layout menu. Ignored when the keyboard module
                      is not selected.
  --dry-run           Show what would change without applying anything.
  -h, --help          Show this help.

Examples:
  ./install.sh --list
  ./install.sh --all --dry-run
  ./install.sh --only desktop,kitty
  ./install.sh --all --keyboard latam
EOF
}

# read_meta <file>: print "name|optin|deps|desc" for one module.
# Runs in a subshell so module variables and functions never leak.
read_meta() (
  # shellcheck source=/dev/null
  source "$1"
  : "${MODULE_NAME:?MODULE_NAME is not set}"
  : "${MODULE_DESC:?MODULE_DESC is not set}"
  if [[ "$(type -t module_apply || true)" != "function" ]]; then
    echo "module_apply is not defined" >&2
    exit 1
  fi
  printf '%s|%s|%s|%s\n' "$MODULE_NAME" "${MODULE_OPTIN:-0}" "${MODULE_DEPS:-}" "$MODULE_DESC"
)

load_modules() {
  local f meta name optin deps desc i
  local -a files=()

  shopt -s nullglob
  files=("$MODULES_DIR"/*.sh)
  shopt -u nullglob

  for f in "${files[@]}"; do
    if ! meta="$(read_meta "$f")"; then
      log_error "invalid module file: $f"
      return 1
    fi
    IFS='|' read -r name optin deps desc <<<"$meta"
    if [[ ! "$optin" =~ ^[01]$ ]]; then
      log_error "MODULE_OPTIN must be 0 or 1 in $f"
      return 1
    fi
    for ((i = 0; i < ${#MOD_NAMES[@]}; i++)); do
      if [[ "${MOD_NAMES[$i]}" == "$name" ]]; then
        log_error "duplicate module name '$name' in $f"
        return 1
      fi
    done
    MOD_FILES+=("$f")
    MOD_NAMES+=("$name")
    MOD_OPTIN+=("$optin")
    MOD_DEPS+=("$deps")
    MOD_DESC+=("$desc")
  done
}

# index_of <name>: print the module index, or fail when unknown.
index_of() {
  local i
  for ((i = 0; i < ${#MOD_NAMES[@]}; i++)); do
    if [[ "${MOD_NAMES[$i]}" == "$1" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

declare -A SELECTED=()

# add_with_deps <name>: select a module and its dependencies transitively.
add_with_deps() {
  local name="$1" i dep
  local -a deps=()
  if ! i="$(index_of "$name")"; then
    log_error "unknown module: $name"
    return 1
  fi
  if [[ -n "${SELECTED[$name]:-}" ]]; then
    return 0
  fi
  SELECTED["$name"]=1
  read -ra deps <<<"${MOD_DEPS[$i]}"
  for dep in "${deps[@]}"; do
    add_with_deps "$dep" || return 1
  done
}

list_modules() {
  local i opt
  printf '%-20s %-7s %s\n' "MODULE" "OPT-IN" "DESCRIPTION"
  for ((i = 0; i < ${#MOD_NAMES[@]}; i++)); do
    opt="no"
    if [[ "${MOD_OPTIN[$i]}" == "1" ]]; then
      opt="yes"
    fi
    printf '%-20s %-7s %s\n' "${MOD_NAMES[$i]}" "$opt" "${MOD_DESC[$i]}"
  done
  if ((${#MOD_NAMES[@]} == 0)); then
    log_info "no modules found in $MODULES_DIR"
  fi
}

# run_module <file> <changes-out-file>: executed inside a subshell with
# errexit on. module_apply is called plainly (never as `module_apply || ...`),
# so the module stops at its first failed command. log_change mirrors the
# running count into <changes-out-file>, so a module that fails still reports
# the changes it made before failing.
run_module() {
  local file="$1" changes_file="$2"
  CHANGES=0
  _KCS_CHANGES_FILE="$changes_file"
  # shellcheck source=/dev/null
  source "$file"
  module_apply
  printf '%s\n' "$CHANGES" >"$changes_file"
}

# setup_logging: tee all output (stdout and stderr) to a log file under
# ${XDG_CACHE_HOME:-$HOME/.cache}/kali-cosmic-setup. Colors were decided when
# lib/common.sh was sourced (on only for a terminal), so the terminal keeps
# them; the log copy has the ANSI escape sequences stripped. Sets LOG_FILE and
# TEE_PID. Failing to create the log only warns.
LOG_FILE=""
TEE_PID=""
setup_logging() {
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/kali-cosmic-setup" file
  file="$dir/install-$(date +%Y%m%d-%H%M%S).log"
  if ! mkdir -p -- "$dir" || ! : >>"$file"; then
    log_warn "cannot write the log file $file; continuing without a log"
    return 0
  fi
  LOG_FILE="$file"
  exec > >(tee >(sed -u -e 's/\x1b\[[0-9;]*[A-Za-z]//g' >>"$LOG_FILE")) 2>&1
  TEE_PID=$!
}

# start_sudo: unless sudo needs no password, ask for it once, then keep the
# timestamp fresh in the background so no later step prompts. Stops the
# installer when sudo cannot be authenticated. Sets KEEPALIVE_PID.
KEEPALIVE_PID=""
start_sudo() {
  # `-n -k true` ignores any cached timestamp, so it succeeds only when sudo
  # needs no password at all (NOPASSWD). Plain `sudo -v` would still demand one
  # (and a terminal) when another matching sudoers rule requires it (verifypw).
  # The probe assumes a blanket rule (NOPASSWD: ALL, as on Kali test setups);
  # a NOPASSWD rule limited to a few commands would pass it while later
  # `sudo -n` calls fail, and the failing module then stops with that error.
  if sudo -n -k true >/dev/null 2>&1; then
    log_info "sudo needs no password; the rest runs unattended"
    return 0
  fi
  log_info "sudo is needed: type your password once; the rest runs unattended"
  if ! sudo -v; then
    log_error "sudo authentication failed; nothing was changed. Run the installer again and type your password when asked"
    exit 1
  fi
  if ! sudo -n -v 2>/dev/null; then
    log_error "sudo does not keep its credentials (timestamp_timeout=0?), so an unattended run is impossible"
    exit 1
  fi
  # The loop ends by itself when the installer exits. Its output is detached so
  # it never holds the log pipe open.
  while kill -0 "$$" 2>/dev/null; do
    sudo -n -v 2>/dev/null
    sleep 60
  done >/dev/null 2>&1 </dev/null &
  KEEPALIVE_PID=$!
}

# cleanup: EXIT trap. Removes the temp file, stops the sudo keepalive and lets
# the log pipe drain before the shell returns.
cleanup() {
  [[ -n "${CHANGES_FILE:-}" ]] && rm -f -- "$CHANGES_FILE"
  if [[ -n "$KEEPALIVE_PID" ]]; then
    # Its sleep first, so no orphan lingers for up to a minute.
    pkill -P "$KEEPALIVE_PID" 2>/dev/null || true
    kill "$KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$TEE_PID" ]]; then
    exec >&- 2>&-
    wait "$TEE_PID" 2>/dev/null || true
  fi
}

# --- Argument parsing -------------------------------------------------------

ACTION=""
ALL=0
ONLY=()

# Keyboard choice from --keyboard (<layout>[:<variant>] or keep); empty means
# "ask in the menu". Exported for the keyboard module.
KEYBOARD_CHOICE=""

add_only() {
  local p
  local -a parts=()
  IFS=',' read -ra parts <<<"$1"
  for p in "${parts[@]}"; do
    if [[ -n "$p" ]]; then
      ONLY+=("$p")
    fi
  done
}

if (($# == 0)); then
  usage
  exit 1
fi

while (($# > 0)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --list) ACTION="list" ;;
    --all)
      ALL=1
      ACTION="run"
      ;;
    --only)
      if (($# < 2)); then
        log_error "--only requires a module name"
        exit 2
      fi
      add_only "$2"
      ACTION="run"
      shift
      ;;
    --only=*)
      add_only "${1#--only=}"
      ACTION="run"
      ;;
    --keyboard)
      if (($# < 2)); then
        log_error "--keyboard requires a value: <layout>[:<variant>] or keep"
        exit 2
      fi
      KEYBOARD_CHOICE="$2"
      shift
      ;;
    --keyboard=*) KEYBOARD_CHOICE="${1#--keyboard=}" ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      log_error "unknown option: $1"
      usage
      exit 2
      ;;
  esac
  shift
done
export DRY_RUN

# Shape check only; the full check against the system XKB rules list runs
# once the selection is known (kbd_preflight), before sudo.
if [[ -n "$KEYBOARD_CHOICE" && ! "$KEYBOARD_CHOICE" =~ ^(keep|[A-Za-z0-9_]+(:[A-Za-z0-9_-]+)?)$ ]]; then
  log_error "invalid --keyboard value '$KEYBOARD_CHOICE': use <layout>[:<variant>] or keep"
  exit 2
fi
export KEYBOARD_CHOICE

if [[ -z "$ACTION" ]]; then
  log_error "nothing to do: use --list, --all or --only <module>"
  usage
  exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
  log_error "do not run as root; the installer uses sudo where needed"
  exit 1
fi

# Real runs only make sense on Kali (or another Debian-based system); a dry-run
# changes nothing, so it is allowed anywhere. KCS_SKIP_OS_CHECK=1 is test-only.
if [[ "$ACTION" == "run" && "$DRY_RUN" != "1" && "${KCS_SKIP_OS_CHECK:-0}" != "1" ]] &&
  ! os_is_debian_like; then
  log_error "this installer is for Kali Linux (Debian based); /etc/os-release does not say kali or debian. Use --dry-run to only see the plan"
  exit 1
fi

load_modules || exit 1

if [[ "$ACTION" == "list" ]]; then
  list_modules
  exit 0
fi

# --- Selection --------------------------------------------------------------

if ((ALL)); then
  for ((i = 0; i < ${#MOD_NAMES[@]}; i++)); do
    if [[ "${MOD_OPTIN[$i]}" == "0" ]]; then
      add_with_deps "${MOD_NAMES[$i]}" || exit 2
    fi
  done
fi
for name in "${ONLY[@]}"; do
  add_with_deps "$name" || exit 2
done

# --- Execution --------------------------------------------------------------

CHANGES_FILE="$(mktemp)"
trap cleanup EXIT

# The keyboard layout must be known before any module runs: validate --keyboard,
# or fail now when the menu would be needed and there is no terminal.
if [[ -n "${SELECTED[keyboard]:-}" ]]; then
  rc=0
  kbd_preflight || rc=$?
  ((rc == 0)) || exit "$rc"
fi

if ((${#SELECTED[@]} > 0)); then
  setup_logging
  if [[ -n "$LOG_FILE" ]]; then
    log_info "log file: $LOG_FILE"
  fi
  if [[ "$DRY_RUN" != "1" && "${KCS_SKIP_SUDO:-0}" != "1" ]]; then
    start_sudo
  fi
  # The layout menu runs here, once, after sudo and before stdin is closed so it
  # can read the keyboard (only when the keyboard module is selected and no
  # --keyboard was given; see specs/keyboard.md).
  if [[ -n "${SELECTED[keyboard]:-}" ]]; then
    rc=0
    kbd_ask_if_needed || rc=$?
    ((rc == 0)) || exit "$rc"
  fi
  # From here nothing may read the keyboard: any stray prompt sees EOF.
  exec </dev/null
fi

declare -A BAD=()
RAN=()
FAILED_LIST=()
SKIPPED_LIST=()
TOTAL_CHANGES=0

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "dry-run mode: nothing will be changed"
fi

for ((i = 0; i < ${#MOD_NAMES[@]}; i++)); do
  name="${MOD_NAMES[$i]}"
  if [[ -z "${SELECTED[$name]:-}" ]]; then
    continue
  fi

  blocker=""
  read -ra deps <<<"${MOD_DEPS[$i]}"
  for dep in "${deps[@]}"; do
    if [[ -n "${BAD[$dep]:-}" ]]; then
      blocker="$dep"
      break
    fi
  done
  if [[ -n "$blocker" ]]; then
    log_warn "skipping '$name': dependency '$blocker' failed or was skipped"
    BAD["$name"]=1
    SKIPPED_LIST+=("$name")
    continue
  fi

  log_info "module: $name"
  : >"$CHANGES_FILE"
  # errexit must be active inside the module: `( ... ) || rc=$?` would turn it
  # off for everything in the subshell, so capture the status the long way.
  rc=0
  set +e
  (
    set -e
    run_module "${MOD_FILES[$i]}" "$CHANGES_FILE"
  )
  rc=$?
  set -e
  n="$(<"$CHANGES_FILE")"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    n=0
  fi
  TOTAL_CHANGES=$((TOTAL_CHANGES + n))
  if ((rc == 0)); then
    RAN+=("$name")
    log_ok "module '$name' done"
  else
    log_error "module '$name' failed (exit $rc)"
    BAD["$name"]=1
    FAILED_LIST+=("$name")
  fi
done

# --- Summary ----------------------------------------------------------------

printf '\n'
log_info "modules run: ${#RAN[@]}${RAN[*]:+ (${RAN[*]})}"
if ((${#FAILED_LIST[@]} > 0)); then
  log_error "failed: ${FAILED_LIST[*]}"
fi
if ((${#SKIPPED_LIST[@]} > 0)); then
  log_warn "skipped: ${SKIPPED_LIST[*]}"
fi
if [[ "$DRY_RUN" == "1" ]]; then
  if ((TOTAL_CHANGES == 0)); then
    log_info "Nothing to change"
  else
    log_info "$TOTAL_CHANGES change(s) would be made"
  fi
else
  log_info "total changes: $TOTAL_CHANGES"
fi
if [[ -n "$LOG_FILE" ]]; then
  log_info "log file: $LOG_FILE"
fi

if ((${#FAILED_LIST[@]} > 0 || ${#SKIPPED_LIST[@]} > 0)); then
  exit 1
fi
