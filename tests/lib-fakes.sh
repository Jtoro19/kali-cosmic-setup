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
# FAKE_SUDO_MODE: password (default), passwordless (`-n -k true` works, `-v`
# fails like sudo without a terminal under verifypw=all) or cached (only a
# cached timestamp lets `-n` commands work: `-n -k true` fails).
mode="${FAKE_SUDO_MODE:-password}"
case "$1" in
  -v) [ "$mode" = passwordless ] && exit 1; [ -n "${FAKE_SUDO_FAIL:-}" ] && exit 1; exit 0 ;;
  -n)
    shift
    if [ "$1" = "-k" ]; then
      [ "$mode" = passwordless ] && { shift; exec "$@"; }
      exit 1
    fi
    [ "$1" = "-v" ] && exit 0
    exec "$@"
    ;;
esac
exit 99
EOS

  # dpkg-query -W -f='${Status}' <pkg>: reads $FAKE_STATE/installed, one entry
  # per line: "name" (installed) or "name:rc" (removed, config files remain).
  cat >"$bin/dpkg-query" <<'EOS'
#!/bin/sh
for a in "$@"; do pkg="$a"; done
# -f='${Version}': the version recorded in $FAKE_STATE/versions ("name version").
case "$*" in
  *'${Version}'*)
    v="$(sed -n "s/^$pkg //p" "$FAKE_STATE/versions" 2>/dev/null | head -n 1)"
    [ -n "$v" ] || exit 1
    printf '%s' "$v"
    exit 0
    ;;
esac
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

  # apt-get: logs "<args> [DEBIAN_FRONTEND=...]" to apt.log (and the call order
  # to all.log). `install` marks the named packages as installed. Simulations
  # (-s) never change state: `-s purge` prints $FAKE_STATE/sim-purge (default:
  # one "Purg <pkg>" line per named package) and `-s autoremove` prints
  # $FAKE_STATE/sim-autoremove. A real `purge` records the display manager
  # state at that moment in purge-state.log, then removes the named packages
  # and everything listed in sim-purge from $FAKE_STATE/installed.
  cat >"$bin/apt-get" <<'EOS'
#!/bin/sh
echo "$* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >>"$FAKE_STATE/apt.log"
echo "apt-get $*" >>"$FAKE_STATE/all.log"
cmd=""
skip=0
sim=0
pk=""
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -o) skip=1 ;;
    -s) sim=1 ;;
    -*) ;;
    *)
      if [ -z "$cmd" ]; then cmd="$a"
      else
        pk="$pk $a"
        if [ "$cmd" = install ] && [ "$sim" = 0 ]; then
          case "$a" in
            # A local .deb: FAKE_DEB_PACKAGE (default peazip) becomes installed at
            # FAKE_DEB_VERSION; the file must exist when apt-get runs.
            *.deb)
              if [ -f "$a" ]; then echo "deb-file-present $a" >>"$FAKE_STATE/all.log"
              else echo "deb-file-MISSING $a" >>"$FAKE_STATE/all.log"; exit 100; fi
              [ -n "${FAKE_APT_FAIL_DEB:-}" ] && exit 100
              # FAKE_APT_KILL_PARENT: end the calling shell (the module) with SIGTERM
              # right after the deb is seen, like an interrupted run.
              [ -n "${FAKE_APT_KILL_PARENT:-}" ] && { kill -TERM "$PPID"; exit 143; }
              dp="${FAKE_DEB_PACKAGE:-peazip}"
              echo "$dp" >>"$FAKE_STATE/installed"
              grep -v "^$dp " "$FAKE_STATE/versions" >"$FAKE_STATE/versions.new" 2>/dev/null
              echo "$dp ${FAKE_DEB_VERSION:-11.4.0}" >>"$FAKE_STATE/versions.new"
              mv -- "$FAKE_STATE/versions.new" "$FAKE_STATE/versions"
              ;;
            *)
              # FAKE_NEEDS_UPDATE="pkg ...": these packages cannot be installed
              # until a successful `apt-get update` (lists-fresh; brave-browser
              # also needs the Brave sources file to exist at that update).
              case " ${FAKE_NEEDS_UPDATE:-} " in
                *" $a "*)
                  f=lists-fresh
                  [ "$a" = brave-browser ] && f=lists-fresh-brave
                  [ -f "$FAKE_STATE/$f" ] || { echo "E: Unable to locate package $a" >&2; exit 100; }
                  ;;
              esac
              echo "$a" >>"$FAKE_STATE/installed"
              # brave-keyring's postinst links its key into trusted.gpg.d (global
              # trust); installing brave-browser pulls brave-keyring in.
              # FAKE_CODE_ADDS_REPO: the code deb's postinst leaves global trust behind.
              if [ "$a" = code ] && [ -n "${FAKE_CODE_ADDS_REPO:-}" ]; then
                mkdir -p "${KCS_ROOT:-}/etc/apt/trusted.gpg.d" "${KCS_ROOT:-}/usr/share/keyrings"
                echo key >"${KCS_ROOT:-}/etc/apt/trusted.gpg.d/microsoft.gpg"
                echo key >"${KCS_ROOT:-}/usr/share/keyrings/microsoft.gpg"
              fi
              if [ "$a" = brave-browser ]; then
                mkdir -p "${KCS_ROOT:-}/etc/apt/trusted.gpg.d"
                ln -sf /usr/share/keyrings/brave-browser-archive-keyring.gpg \
                  "${KCS_ROOT:-}/etc/apt/trusted.gpg.d/brave-browser-release.gpg"
              fi
              ;;
          esac
        fi
      fi
      ;;
  esac
done
# FAKE_APT_FAIL_UPDATE_NTH=2 makes the 2nd `apt-get update` of a run fail.
if [ "$cmd" = update ] && [ -n "${FAKE_APT_FAIL_UPDATE_NTH:-}" ]; then
  echo x >>"$FAKE_STATE/update.count"
  [ "$(wc -l <"$FAKE_STATE/update.count")" -eq "$FAKE_APT_FAIL_UPDATE_NTH" ] && exit 1
fi
if [ "$cmd" = update ]; then
  touch "$FAKE_STATE/lists-fresh"
  [ -f "${KCS_ROOT:-}/etc/apt/sources.list.d/brave-browser.sources" ] && touch "$FAKE_STATE/lists-fresh-brave"
fi
if [ "$sim" = 1 ]; then
  case "$cmd" in
    purge)
      if [ -f "$FAKE_STATE/sim-purge" ]; then cat "$FAKE_STATE/sim-purge"
      else for p in $pk; do echo "Purg $p [1.0]"; done; fi
      ;;
    autoremove) [ -f "$FAKE_STATE/sim-autoremove" ] && cat "$FAKE_STATE/sim-autoremove" ;;
  esac
  exit 0
fi
if [ "$cmd" = purge ]; then
  {
    echo "default-dm=$(cat "${KCS_ROOT:-}/etc/X11/default-display-manager" 2>/dev/null)"
    echo "link=$(readlink "${KCS_ROOT:-}/etc/systemd/system/display-manager.service" 2>/dev/null)"
  } >>"$FAKE_STATE/purge-state.log"
  gone="$pk $(sed -n 's/^Purg \([^ ]*\).*/\1/p' "$FAKE_STATE/sim-purge" 2>/dev/null)"
  for p in $gone; do
    grep -vx -- "$p" "$FAKE_STATE/installed" >"$FAKE_STATE/installed.new" 2>/dev/null
    mv -- "$FAKE_STATE/installed.new" "$FAKE_STATE/installed"
  done
fi
exit "${FAKE_APT_RC:-0}"
EOS

  # curl -fsSL -o <file> <url>: copies $FAKE_KEY_FILE and logs the URL.
  cat >"$bin/curl" <<'EOS'
#!/bin/sh
ORIG_ARGS="$*"
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
echo "$ORIG_ARGS" >>"$FAKE_STATE/curl-args.log"
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 22
# $FAKE_STATE/curl-files/<basename of the URL> overrides the default payload.
if [ -f "$FAKE_STATE/curl-files/${url##*/}" ]; then
  cp -- "$FAKE_STATE/curl-files/${url##*/}" "$out"
else
  cp -- "$FAKE_KEY_FILE" "$out"
fi
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
    fprs="$(sed -n 's/^FPR=//p' "$in")"
    [ -n "$fprs" ] || exit 2
    for fpr in $fprs; do
      echo "pub:-:255:22:0000000000000000:1700000000:::-:::scESC:::::::"
      echo "fpr:::::::::$fpr:"
    done
    ;;
  dearmor) cp -- "$in" "$out" ;;
  *) exit 99 ;;
esac
EOS

  # systemctl: state in $FAKE_STATE (enabled = enabled units, active = active
  # units, units = installed unit files, default = boot target). Every call is logged to systemctl.log. `enable` and `disable`
  # keep $KCS_ROOT/etc/systemd/system/display-manager.service in step like the
  # Alias=display-manager.service of a real display manager unit.
  cat >"$bin/systemctl" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/systemctl.log"
# FAKE_FAIL="|systemctl enable x.service|systemd-sysusers ..." makes exactly
# those commands fail (full command line, pipe separated). Every fake logs its
# call first and only then fails, so a failed call still shows in the logs.
case "|${FAKE_FAIL:-}|" in *"|systemctl $*|"*) exit 1 ;; esac
# `systemctl --user ...`: the user manager. FAKE_NO_USER_BUS=1 means there is none
# (show-environment fails; FAKE_USER_ENV sets its output). State: $FAKE_STATE/user-enabled and user-active;
# `enable --now` also marks the unit active.
if [ "$1" = "--user" ]; then
  shift
  ucmd="$1"
  shift
  case "$ucmd" in
    show-environment)
      [ -n "${FAKE_NO_USER_BUS:-}" ] && exit 1
      # FAKE_USER_ENV: the environment of the user manager (default: the one a
      # login after the data-control line has).
      printf '%s\n' "${FAKE_USER_ENV-PATH=/usr/bin
COSMIC_DATA_CONTROL_ENABLED=1}"
      exit 0
      ;;
    is-enabled | is-active)
      for a in "$@"; do unit="$a"; done
      f=user-enabled
      [ "$ucmd" = is-active ] && f=user-active
      grep -qx -- "$unit" "$FAKE_STATE/$f" 2>/dev/null
      exit $?
      ;;
    enable)
      now=0
      for u in "$@"; do [ "$u" = "--now" ] && now=1; done
      for u in "$@"; do
        case "$u" in -*) continue ;; esac
        echo "$u" >>"$FAKE_STATE/user-enabled"
        [ "$now" = 1 ] && echo "$u" >>"$FAKE_STATE/user-active"
      done
      exit 0
      ;;
    *) exit 0 ;;
  esac
fi
sysd="${KCS_ROOT:-}/etc/systemd/system"
dm="$sysd/display-manager.service"
cmd="$1"
shift
case "$cmd" in
  is-enabled)
    for a in "$@"; do unit="$a"; done
    # A unit listed in $FAKE_STATE/masked prints "masked" and is not enabled.
    if grep -qx -- "$unit" "$FAKE_STATE/masked" 2>/dev/null; then echo masked; exit 1; fi
    grep -qx -- "$unit" "$FAKE_STATE/enabled" 2>/dev/null
    ;;
  is-active)
    for a in "$@"; do unit="$a"; done
    grep -qx -- "$unit" "$FAKE_STATE/active" 2>/dev/null
    ;;
  list-unit-files)
    # `list-unit-files --no-legend -- <unit>`: prints a row when the unit is
    # listed in $FAKE_STATE/units (one unit file per line), nothing otherwise.
    for a in "$@"; do unit="$a"; done
    grep -qx -- "$unit" "$FAKE_STATE/units" 2>/dev/null && echo "$unit enabled enabled"
    exit 0
    ;;
  get-default)
    cat "$FAKE_STATE/default" 2>/dev/null || echo multi-user.target
    ;;
  set-default) echo "$1" >"$FAKE_STATE/default" ;;
  daemon-reload)
    # Unit files written under $KCS_ROOT/etc/systemd/system become known units.
    for f in "$sysd"/*.service; do
      [ -f "$f" ] || continue
      grep -qx -- "${f##*/}" "$FAKE_STATE/units" 2>/dev/null || echo "${f##*/}" >>"$FAKE_STATE/units"
    done
    ;;
  enable)
    for u in "$@"; do
      case "$u" in -*) continue ;; esac
      # Like systemd: enabling a masked unit fails.
      if grep -qx -- "$u" "$FAKE_STATE/masked" 2>/dev/null; then exit 1; fi
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
      # FAKE_DISABLE_DROPS_ALIAS="gdm3.service cosmic-greeter.service": disabling
      # these also deletes display-manager.service, like systemd processing the
      # unit's [Install] Alias=display-manager.service, whatever it points to.
      case " ${FAKE_DISABLE_DROPS_ALIAS:-} " in *" $u "*) rm -f -- "$dm" ;; esac
    done
    ;;
  *) exit 0 ;;
esac
EOS

  # getent passwd <name>: users listed in $FAKE_STATE/users exist.
  cat >"$bin/getent" <<'EOS'
#!/bin/sh
case "$1" in
  passwd) grep -qx -- "$2" "$FAKE_STATE/users" 2>/dev/null ;;
  # `getent group <g>`: groups listed in $FAKE_STATE/groups exist.
  group) grep -qx -- "$2" "$FAKE_STATE/groups" 2>/dev/null ;;
  *) exit 1 ;;
esac
EOS

  # useradd <opts> <name>: logs the call and records the user in the fake user list.
  cat >"$bin/useradd" <<'EOS'
#!/bin/sh
echo "useradd $*" >>"$FAKE_STATE/all.log"
echo "$*" >>"$FAKE_STATE/useradd.log"
for a in "$@"; do name="$a"; done
echo "$name" >>"$FAKE_STATE/users"
EOS

  # id -nG: the groups of the user in $FAKE_STATE/usergroups; every other call
  # is the real id. usermod -aG <group> <user>: logs and records the group.
  cat >"$bin/id" <<'EOS'
#!/bin/sh
if [ "$1" = "-nG" ]; then cat "$FAKE_STATE/usergroups" 2>/dev/null; exit 0; fi
exec /usr/bin/id "$@"
EOS
  cat >"$bin/usermod" <<'EOS'
#!/bin/sh
echo "usermod $*" >>"$FAKE_STATE/all.log"
echo "$*" >>"$FAKE_STATE/usermod.log"
echo "$2" >>"$FAKE_STATE/usergroups"
EOS

  # systemd-sysusers / systemd-tmpfiles: log the call; sysusers creates the
  # cosmic-greeter user in the fake user list.
  cat >"$bin/systemd-sysusers" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/sysusers.log"
case "|${FAKE_FAIL:-}|" in *"|systemd-sysusers $*|"*) exit 1 ;; esac
echo cosmic-greeter >>"$FAKE_STATE/users"
EOS
  cat >"$bin/systemd-tmpfiles" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/tmpfiles.log"
case "|${FAKE_FAIL:-}|" in *"|systemd-tmpfiles $*|"*) exit 1 ;; esac
mkdir -p "${KCS_ROOT:-}/var/lib/cosmic-greeter"
EOS

  # debconf-show <pkg>: prints the shared display manager answer stored in
  # $FAKE_STATE/debconf (nothing when unset), like the real command.
  cat >"$bin/debconf-show" <<'EOS'
#!/bin/sh
echo "debconf-show $*" >>"$FAKE_STATE/all.log"
case "|${FAKE_FAIL:-}|" in *"|debconf-show $*|"*) exit 1 ;; esac
echo "  greetd/daemon_name: /usr/sbin/greetd"
# A preseeded answer for the code package (see debconf-set-selections below).
if [ "$(cat "$FAKE_STATE/debconf-code" 2>/dev/null)" = false ]; then
  echo "* code/add-microsoft-repo: false"
fi
# FAKE_DEBCONF_BIG: a long output after the answer (a reader that stops early
# would kill this writer with SIGPIPE).
if [ -n "${FAKE_DEBCONF_BIG:-}" ]; then
  i=0
  while [ "$i" -lt 20000 ]; do echo "  padding/question: x"; i=$((i + 1)); done
fi
if [ -s "$FAKE_STATE/debconf" ]; then
  echo "* shared/default-x-display-manager: $(cat "$FAKE_STATE/debconf")"
fi
EOS

  # debconf-set-selections: reads the selections on stdin, logs them and
  # stores the display manager answer in $FAKE_STATE/debconf.
  cat >"$bin/debconf-set-selections" <<'EOS'
#!/bin/sh
echo "debconf-set-selections" >>"$FAKE_STATE/all.log"
case "|${FAKE_FAIL:-}|" in *"|debconf-set-selections|"*) exit 1 ;; esac
while IFS= read -r line; do
  echo "$line" >>"$FAKE_STATE/debconf.log"
  set -- $line
  if [ "$2" = shared/default-x-display-manager ]; then echo "$4" >"$FAKE_STATE/debconf"; fi
  if [ "$2" = code/add-microsoft-repo ]; then echo "$4" >"$FAKE_STATE/debconf-code"; fi
done
EOS

  # ln: records the call, FAKE_NO_LN makes it a no-op, otherwise the real ln.
  cat >"$bin/ln" <<'EOS'
#!/bin/sh
echo "ln $*" >>"$FAKE_STATE/all.log"
[ -n "${FAKE_NO_LN:-}" ] && exit 0
# FAKE_LN_NOOP_NTH=2: only the 2nd ln call of a run does nothing.
if [ -n "${FAKE_LN_NOOP_NTH:-}" ]; then
  echo x >>"$FAKE_STATE/ln.count"
  [ "$(wc -l <"$FAKE_STATE/ln.count")" -eq "$FAKE_LN_NOOP_NTH" ] && exit 0
fi
exec /usr/bin/ln "$@"
EOS

  # dpkg --compare-versions <a> <op> <b>: ge/gt/le/lt/eq via sort -V (enough for
  # the version shapes the tests use; the real dpkg runs on Kali).
  cat >"$bin/dpkg" <<'EOS'
#!/bin/sh
[ "$1" = "--compare-versions" ] || exit 2
a="$2"; op="$3"; b="$4"
top="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)"
case "$op" in
  ge) [ "$a" = "$b" ] || [ "$top" = "$a" ] ;;
  gt) [ "$a" != "$b" ] && [ "$top" = "$a" ] ;;
  le) [ "$a" = "$b" ] || [ "$top" = "$b" ] ;;
  lt) [ "$a" != "$b" ] && [ "$top" = "$b" ] ;;
  eq) [ "$a" = "$b" ] ;;
  *) exit 2 ;;
esac
EOS

  # apt-cache policy <pkg>: "Candidate: (none)" for the packages listed in
  # FAKE_NO_CANDIDATE (space separated), a version for the others.
  cat >"$bin/apt-cache" <<'EOS'
#!/bin/sh
for a in "$@"; do pkg="$a"; done
echo "$pkg:"
# FAKE_NEEDS_UPDATE: no candidate until the lists were refreshed (see apt-get).
case " ${FAKE_NEEDS_UPDATE:-} " in
  *" $pkg "*)
    f=lists-fresh
    [ "$pkg" = brave-browser ] && f=lists-fresh-brave
    [ -f "$FAKE_STATE/$f" ] || FAKE_NO_CANDIDATE="${FAKE_NO_CANDIDATE:-} $pkg"
    ;;
esac
case " ${FAKE_NO_CANDIDATE:-} " in
  *" $pkg "*) echo "  Installed: (none)"; echo "  Candidate: (none)" ;;
  *) echo "  Installed: (none)"; echo "  Candidate: 1.0-1" ;;
esac
EOS

  # gsettings get|set <schema> <key> [value]: values live in $FAKE_STATE/gsettings
  # (default gtk-theme 'Adwaita', color-scheme 'default'); every call is logged
  # with the session bus address it saw. Like the real one it needs a session bus
  # (DBUS_SESSION_BUS_ADDRESS) and fails without one; FAKE_GSETTINGS_FAIL=1 makes
  # every call fail.
  cat >"$bin/gsettings" <<'EOS'
#!/bin/sh
echo "gsettings $* bus=${DBUS_SESSION_BUS_ADDRESS:-none}" >>"$FAKE_STATE/gsettings.log"
[ -n "${FAKE_GSETTINGS_FAIL:-}" ] && exit 1
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || { echo "Unable to autolaunch a dbus-daemon without a $DISPLAY" >&2; exit 1; }
store="$FAKE_STATE/gsettings"; mkdir -p "$store"
case "$1" in
  get)
    if [ -f "$store/$2.$3" ]; then cat "$store/$2.$3"
    else case "$3" in gtk-theme) echo "'Adwaita'" ;; color-scheme) echo "'default'" ;; *) echo "''" ;; esac; fi
    ;;
  set)
    [ -n "${FAKE_GSETTINGS_SETFAIL:-}" ] && exit 1
    # FAKE_GSETTINGS_NOPERSIST=1: a backend that accepts the write and drops it.
    [ -n "${FAKE_GSETTINGS_NOPERSIST:-}" ] && exit 0
    printf '%s\n' "$4" >"$store/$2.$3"
    ;;
  *) exit 2 ;;
esac
EOS

  # dconf update <dbdir>: like the real one, compiles every <dbdir>/<name>.d
  # directory into the binary database <dbdir>/<name>. Every call is logged.
  # FAKE_DCONF_RC=<n>: fail with that status and build nothing.
  cat >"$bin/dconf" <<'EOS'
#!/bin/sh
echo "dconf $*" >>"$FAKE_STATE/dconf.log"
[ "$1" = update ] || exit 2
[ -n "${FAKE_DCONF_RC:-}" ] && exit "$FAKE_DCONF_RC"
dir="${2:-/etc/dconf/db}"
for d in "$dir"/*.d; do
  [ -d "$d" ] || continue
  printf 'fake-gvdb\n' >"${d%.d}"
done
EOS

  # dbus-run-session -- <cmd...>: a private session bus for one command (the
  # address is fake); FAKE_NO_DBUS_RUN=1 makes it fail like a missing program.
  cat >"$bin/dbus-run-session" <<'EOS'
#!/bin/sh
echo "dbus-run-session $*" >>"$FAKE_STATE/gsettings.log"
[ -n "${FAKE_NO_DBUS_RUN:-}" ] && exit 127
[ "$1" = "--" ] && shift
# FAKE_LINGER=1: leave a daemon behind that keeps the output pipe open for a few
# seconds, like gvfsd-fuse on a private bus.
[ -n "${FAKE_LINGER:-}" ] && { sleep 4 & }
DBUS_SESSION_BUS_ADDRESS=unix:path=/private-fake-bus
export DBUS_SESSION_BUS_ADDRESS
"$@"
EOS

  # stat: FAKE_NOT_OWNED (colon separated paths) "belong to root" for `stat -c %u`;
  # everything else goes to the real stat.
  cat >"$bin/stat" <<'EOS'
#!/bin/sh
if [ "$1" = "-c" ] && [ "$2" = "%u" ]; then
  shift 2
  [ "$1" = "--" ] && shift
  for p in "$@"; do
    mine=$(/usr/bin/stat -c %u -- "$p") || exit 1
    old="$IFS"; IFS=:
    for n in $FAKE_NOT_OWNED; do [ "$p" = "$n" ] && mine=$((mine + 1)); done
    IFS="$old"
    echo "$mine"
  done
  exit 0
fi
exec /usr/bin/stat "$@"
EOS

  chmod +x "$bin"/*
}

# fake_key_file <path> <fingerprint>: a key fixture the fake gpg understands.
fake_key_file() {
  printf '%s\nFPR=%s\n%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$2" \
    '-----END PGP PUBLIC KEY BLOCK-----' >"$1"
}
