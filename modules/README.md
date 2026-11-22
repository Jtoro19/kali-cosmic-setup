# Modules

Each module is one file `modules/NN-name.sh`, where `NN` is a two-digit order
prefix (for example `10-base.sh`). `install.sh` discovers every `modules/*.sh`,
sorted by file name. See `modules/06-desktop.sh` for a reference module.

## Contract

When sourced, a module must define:

| Name | Type | Meaning |
|------|------|---------|
| `MODULE_NAME` | string | Short name used by `--only` and `MODULE_DEPS` (for example `desktop`). Must be unique. |
| `MODULE_DESC` | string | One-line description shown by `--list`. |
| `MODULE_OPTIN` | `0` or `1` | `1` means the module is skipped by `--all` and runs only when named with `--only`. |
| `MODULE_DEPS` | string | Space-separated module names this module needs. May be empty. |
| `module_apply` | function | Does the work. Return non-zero on failure. |

Modules are sourced in a subshell, so their variables and functions never leak
between modules. A module must not source `lib/common.sh` itself: the helpers
are already loaded by `install.sh`. A module must not call `exit` itself (the
helpers do, see fail-fast below).

## Fail-fast contract

Each module runs in its own subshell with `set -e` active, and `module_apply` is
called plainly, so a module stops at its first failed command and the installer
marks it failed (dependent modules are skipped, the final exit status is
non-zero). Do not guard commands with `|| true` unless failure is truly fine.

Some helpers are called as `helper || return 1`, which makes bash ignore `set -e`
inside the helper. So `run` and `run_sudo` are fail-fast on their own: on a
non-zero status in a real run they log `command failed (exit N): <cmd>` and
`exit` with that status, which ends only the current module. A call site that
really tolerates failure uses `run_may_fail` / `run_sudo_may_fail`: same as
`run` / `run_sudo`, but they return the status and the caller handles it, for
example `run_may_fail gtk-update-icon-cache ... || true`. Both are dry-run aware.

Real runs use `sudo -n` (through `run_sudo`, or write `sudo -n` yourself when
you must call sudo directly): the installer asks for the password once at the
start, so an expired timestamp must fail fast and never prompt. Nothing may wait
for input: use `-y` (the apt helpers already pass it, with `DEBIAN_FRONTEND=noninteractive`), run builds with `</dev/null` and set
`GIT_TERMINAL_PROMPT=0` for git (already exported by `install.sh`).

## Test-only environment variables

- `KCS_MODULES_DIR=<dir>`: make `install.sh` read modules from another directory
  (used by `tests/` with fake modules). Never set it in a real run.
- `KCS_SKIP_SUDO=1`: skip the initial `sudo -v` so tests can run a real (not
  dry-run) pass without sudo. Never set it in a real run.
- `KCS_SKIP_OS_CHECK=1`: skip the "is this Kali/Debian" refusal, so tests can do
  a real pass on another distribution. Never set it in a real run.
- `KCS_ROOT=<dir>`: prefix for the system paths the helpers write (see
  `rootpath` below), so tests can redirect `/etc` to a temp directory.
  Never set it in a real run.

Run `tests/run-tests.sh` after changing `install.sh` or `lib/common.sh`.

Module files only define metadata and `module_apply` at the top level. They
must not perform any action when sourced (the installer sources them just to
list them).

## Using the helpers

Do all work through the helpers in `lib/common.sh` (`run`, `run_sudo`,
`run_may_fail`, `run_sudo_may_fail`,
`install_file`, `install_template`, `ensure_line`, `ensure_block`,
`ensure_file_content`, `ensure_user_unit_enabled`, `ensure_system_unit_enabled`,
logging functions). They provide dry-run support and idempotency
automatically. Do not call `cp`, `tee`, `apt-get` or `systemctl` directly for
changes.

### apt helpers

- `pkg_installed <pkg>`: true when `dpkg-query` reports `install ok installed`.
- `apt_update_once [--force]`: refresh the package lists once per run.
- `apt_update_may_fail`: the same refresh but it returns the status instead of ending the module, for optional packages.
- `apt_full_upgrade`: `apt-get full-upgrade`, never a partial upgrade.
- `ensure_packages [--no-install-recommends] <pkg...>`: installs only the
  missing packages, non-interactively, keeping existing config files
  (`--force-confdef --force-confold`).
- Third-party repository, all idempotent and dry-run aware, with a backup when
  a different file is replaced:
  - `apt_install_key <url> <dest> <fingerprint>`: installs a signing key under
    `/etc/apt/keyrings` only after checking the expected full fingerprint with
    `gpg` (ASCII keys are dearmored). A keyring holding several keys takes all
    fingerprints, space or comma separated in one argument, and must hold exactly
    that set. A mismatch fails and installs nothing.
  - `apt_ensure_sources <name> <uri> <suite> <components> <signed-by>`: writes
    `/etc/apt/sources.list.d/<name>.sources` (deb822).
  - `apt_ensure_pin <name> <content>`: writes `/etc/apt/preferences.d/<name>`.
- `install_package_list <group>`: installs `files/packages/<group>.apt` (one
  package per line, `#` comments). Only missing packages are considered; one
  with no apt candidate is skipped with a warning. Refreshes the lists once, and
  only when something must be installed.
- `apt_has_candidate <pkg>`, `pkg_version <pkg>`: read-only queries.
- `download_verified <url> <dest> <sha256>`: downloads into a private temporary
  directory, checks the SHA-256 and only then moves the file to `<dest>`. An
  empty or malformed checksum is refused; there is no unverified mode.
  Dry-run downloads nothing.
- `rootpath <abs-path>`: the path under the test-only `KCS_ROOT` prefix
  (unchanged in a real run). Use it for system paths a test must redirect.
- `FILE_CHANGED` is 1 after `install_file` or a helper built on it changed a
  file (use it to run `systemctl daemon-reload` or `apt-get update` only when
  needed).

## Idempotency and backups

- Running a module twice must change nothing the second time.
- Check state first, act only when needed, and call `log_change` (directly or
  through a helper) once per real change.
- Any existing file that is modified is first copied to
  `<path>.bak.<YYYYmmdd-HHMMSS>` (the helpers do this).
- Never hardcode `/home/<user>` or a uid: use `$HOME`, `$USER` and
  `$XDG_RUNTIME_DIR`.
- Detect hardware (CPU and GPU vendor) at run time instead of assuming a machine.

## Opt-in modules

Set `MODULE_OPTIN=1` for anything machine-specific or intrusive (for example
virtualization, tablets, bootloader). `--all` skips them; `--only <name>` runs
them. An opt-in module that is a dependency of a selected module is pulled in
automatically.

## Specs

Every module has a spec in `specs/<name>.md`, written from the template in
`specs/README.md`, before the module is implemented.
