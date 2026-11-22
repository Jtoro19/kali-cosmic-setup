#!/usr/bin/env bash
# tests/lib-fakes.sh: fake system commands for the tests. Sourced by tests
# (never run on its own, so run-tests.sh skips it). The fakes record what they
# were asked to do under $FAKE_STATE and never touch the real system.
#
# Usage in a test:
#   FAKE_STATE="$WORK/state"; mkdir -p "$FAKE_STATE"
#   make_fakes "$WORK/bin"
#   PATH="$WORK/bin:$PATH" ...

# make_fakes <bindir>: write the fake commands into <bindir>.
make_fakes() {
  local bin="$1"
  mkdir -p -- "$bin"

  # sudo: logs its arguments. `sudo -v` fails when FAKE_SUDO_FAIL is set.
  cat >"$bin/sudo" <<'EOS'
#!/bin/sh
echo "$*" >>"${SUDO_LOG:-${FAKE_STATE:-/dev/null}/sudo.log}"
case "$1" in
  -v) [ -n "${FAKE_SUDO_FAIL:-}" ] && exit 1; exit 0 ;;
  -n) shift; [ "$1" = "-v" ] && exit 0; exec "$@" ;;
esac
exit 99
EOS

  # dpkg-query -W -f='${Status}' <pkg>: reads $FAKE_STATE/installed, one entry
  # per line: "name" (installed) or "name:rc" (removed, config files remain).
  cat >"$bin/dpkg-query" <<'EOS'
#!/bin/sh
for a in "$@"; do pkg="$a"; done
if grep -qx -- "$pkg" "$FAKE_STATE/installed" 2>/dev/null; then
  printf 'install ok installed'
  exit 0
fi
if grep -qx -- "$pkg:rc" "$FAKE_STATE/installed" 2>/dev/null; then
  printf 'deinstall ok config-files'
  exit 0
fi
echo "dpkg-query: no packages found matching $pkg" >&2
exit 1
EOS

  # apt-get: logs "<args> [DEBIAN_FRONTEND=...]"; `install` marks the named
  # packages as installed.
  cat >"$bin/apt-get" <<'EOS'
#!/bin/sh
echo "$* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >>"$FAKE_STATE/apt.log"
[ "$1" = "-y" ] && shift
cmd=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -o) skip=1 ;;
    -*) ;;
    *)
      if [ -z "$cmd" ]; then cmd="$a"
      elif [ "$cmd" = install ]; then echo "$a" >>"$FAKE_STATE/installed"; fi
      ;;
  esac
done
exit "${FAKE_APT_RC:-0}"
EOS

  # curl -fsSL -o <file> <url>: copies $FAKE_KEY_FILE and logs the URL.
  cat >"$bin/curl" <<'EOS'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "$url" >>"$FAKE_STATE/curl.log"
cp -- "$FAKE_KEY_FILE" "$out"
EOS

  # gpg: a fake that reads the fingerprint from a "FPR=<hex>" line in the key
  # file. Supports `--show-keys --with-colons <file>` and `--dearmor -o <out> <in>`.
  cat >"$bin/gpg" <<'EOS'
#!/bin/sh
mode=""
out=""
in=""
while [ $# -gt 0 ]; do
  case "$1" in
    --show-keys) mode=show ;;
    --dearmor) mode=dearmor ;;
    -o) out="$2"; shift ;;
    -*) ;;
    *) in="$1" ;;
  esac
  shift
done
case "$mode" in
  show)
    fpr="$(sed -n 's/^FPR=//p' "$in")"
    [ -n "$fpr" ] || exit 2
    echo "pub:-:255:22:0000000000000000:1700000000:::-:::scESC:::::::"
    echo "fpr:::::::::$fpr:"
    ;;
  dearmor) cp -- "$in" "$out" ;;
  *) exit 99 ;;
esac
EOS

  # systemctl: state in $FAKE_STATE (enabled = enabled units, default = boot
  # target). Every call is logged to systemctl.log. `enable` and `disable`
  # keep $KCS_ROOT/etc/systemd/system/display-manager.service in step like the
  # Alias=display-manager.service of a real display manager unit.
  cat >"$bin/systemctl" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/systemctl.log"
# FAKE_FAIL="|systemctl enable cosmic-greeter.service|systemd-sysusers ..." makes
# exactly those commands fail (full command line, pipe separated).
case "|${FAKE_FAIL:-}|" in *"|systemctl $*|"*) exit 1 ;; esac
sysd="${KCS_ROOT:-}/etc/systemd/system"
dm="$sysd/display-manager.service"
cmd="$1"
shift
case "$cmd" in
  is-enabled)
    for a in "$@"; do unit="$a"; done
    grep -qx -- "$unit" "$FAKE_STATE/enabled" 2>/dev/null
    ;;
  get-default)
    cat "$FAKE_STATE/default" 2>/dev/null || echo multi-user.target
    ;;
  set-default) echo "$1" >"$FAKE_STATE/default" ;;
  daemon-reload) ;;
  enable)
    for u in "$@"; do
      case "$u" in -*) continue ;; esac
      echo "$u" >>"$FAKE_STATE/enabled"
      case "$u" in
        cosmic-greeter.service | greetd.service | gdm3.service | lightdm.service | sddm.service)
          mkdir -p "$sysd"
          # FAKE_NO_ALIAS: the alias link is not created (another display manager holds it).
          [ -n "${FAKE_NO_ALIAS:-}" ] || ln -sfn "$u" "$dm"
          ;;
      esac
    done
    ;;
  disable)
    for u in "$@"; do
      case "$u" in -*) continue ;; esac
      grep -vx -- "$u" "$FAKE_STATE/enabled" >"$FAKE_STATE/enabled.new" 2>/dev/null
      mv -- "$FAKE_STATE/enabled.new" "$FAKE_STATE/enabled"
      if [ "$(readlink "$dm" 2>/dev/null)" = "$u" ]; then rm -f -- "$dm"; fi
    done
    ;;
  *) exit 0 ;;
esac
EOS

  # getent passwd <name>: users listed in $FAKE_STATE/users exist.
  cat >"$bin/getent" <<'EOS'
#!/bin/sh
[ "$1" = passwd ] && grep -qx -- "$2" "$FAKE_STATE/users" 2>/dev/null
EOS

  # systemd-sysusers / systemd-tmpfiles: log the call; sysusers creates the
  # cosmic-greeter user in the fake user list.
  cat >"$bin/systemd-sysusers" <<'EOS'
#!/bin/sh
case "|${FAKE_FAIL:-}|" in *"|systemd-sysusers $*|"*) exit 1 ;; esac
echo "$*" >>"$FAKE_STATE/sysusers.log"
echo cosmic-greeter >>"$FAKE_STATE/users"
EOS
  cat >"$bin/systemd-tmpfiles" <<'EOS'
#!/bin/sh
case "|${FAKE_FAIL:-}|" in *"|systemd-tmpfiles $*|"*) exit 1 ;; esac
echo "$*" >>"$FAKE_STATE/tmpfiles.log"
mkdir -p "${KCS_ROOT:-}/var/lib/cosmic-greeter"
EOS

  chmod +x "$bin"/*
}

# fake_key_file <path> <fingerprint>: a key fixture the fake gpg understands.
fake_key_file() {
  printf '%s\nFPR=%s\n%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$2" \
    '-----END PGP PUBLIC KEY BLOCK-----' >"$1"
}
