#!/usr/bin/env bash
# tests/test-keyboard.sh: the keyboard menu, --keyboard validation and
# modules/90-keyboard.sh against fake commands (debconf, dpkg-reconfigure,
# localectl, update-initramfs, setupcon) and a temporary root prefix. Never
# touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
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
HOME_DIR="$WORK/home"
GH="$WORK/greeter-home"
export KCS_GREETER_HOME="$GH"
KBD="$KCS_ROOT/etc/default/keyboard"
VC="$KCS_ROOT/etc/vconsole.conf"
XKB="$HOME_DIR/.config/cosmic/com.system76.CosmicComp/v1/xkb_config"
GXKB="$GH/.config/cosmic/com.system76.CosmicComp/v1/xkb_config"

# --- fakes of the keyboard tools ---------------------------------------------------------------
# debconf-show: the answers kept in $FAKE_STATE/kdc (question=value lines).
cat >"$WORK/bin/debconf-show" <<'EOS'
#!/bin/sh
echo "debconf-show $* LC_ALL=${LC_ALL:-}" >>"$FAKE_STATE/all.log"
# FAKE_DEBCONF_EMPTY=1: debconf-show prints nothing (an empty read).
[ -n "${FAKE_DEBCONF_EMPTY:-}" ] && exit 0
while IFS= read -r l; do
  q="${l%%=*}"; v="${l#*=}"
  echo "* keyboard-configuration/$q: $v"
done <"$FAKE_STATE/kdc"
EOS
# debconf-set-selections: "<pkg> <pkg>/<question> <type> <value>" lines on stdin.
cat >"$WORK/bin/debconf-set-selections" <<'EOS'
#!/bin/sh
echo "debconf-set-selections DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}" >>"$FAKE_STATE/all.log"
while IFS= read -r l; do
  echo "$l" >>"$FAKE_STATE/selections.log"
  set -- $l
  q="${2#keyboard-configuration/}"
  # FAKE_DC_KEEP_VARIANT=1: the display answer "variant" does not take the new value.
  [ "$q" = variant ] && [ -n "${FAKE_DC_KEEP_VARIANT:-}" ] && continue
  shift 3
  v="$*"
  grep -v "^$q=" "$FAKE_STATE/kdc" >"$FAKE_STATE/kdc.new"
  echo "$q=$v" >>"$FAKE_STATE/kdc.new"
  mv -- "$FAKE_STATE/kdc.new" "$FAKE_STATE/kdc"
done
EOS
# dpkg-reconfigure: like the real one, the config script reads /etc/default/keyboard
# FIRST and the file wins over the code answers (checked on the Kali VM), words the
# display answers itself, and the postinst writes the file back from the answers
# (FAKE_RECONF_NOOP=1: does nothing).
cat >"$WORK/bin/dpkg-reconfigure" <<'EOS'
#!/bin/sh
echo "dpkg-reconfigure $* DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-} LC_ALL=${LC_ALL:-}" >>"$FAKE_STATE/all.log"
[ -n "${FAKE_RECONF_NOOP:-}" ] && exit 0
get() { sed -n "s/^$1=//p" "$FAKE_STATE/kdc" | head -n 1; }
f="${KCS_ROOT:-}/etc/default/keyboard"
[ -e "$f" ] || printf 'XKBMODEL=""\nXKBLAYOUT=""\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' >"$f"
fl="$(sed -n 's/^XKBLAYOUT="\(.*\)"$/\1/p' "$f")"
fv="$(sed -n 's/^XKBVARIANT="\(.*\)"$/\1/p' "$f")"
fm="$(sed -n 's/^XKBMODEL="\(.*\)"$/\1/p' "$f")"
set_q() { grep -v "^$1=" "$FAKE_STATE/kdc" >"$FAKE_STATE/kdc.new"; echo "$1=$2" >>"$FAKE_STATE/kdc.new"; mv -- "$FAKE_STATE/kdc.new" "$FAKE_STATE/kdc"; }
set_q layoutcode "$fl"; set_q variantcode "$fv"; [ -n "$fm" ] && set_q modelcode "$fm"
set_q xkb-keymap "$fl${fv:+($fv)}"
# The display answers are worded from evdev.lst like the real package does: the same
# layout gives the same text before and after.
lst="${KCS_ROOT:-}/usr/share/X11/xkb/rules/evdev.lst"
ld="$(awk -v l="$fl" '/^! /{ c = ($2 == "layout"); next } c && $1 == l { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print; exit }' "$lst")"
vd="$(awk -v l="$fl:" -v v="$fv" '/^! /{ c = ($2 == "variant"); next } c && $1 == v && $2 == l { sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, ""); print; exit }' "$lst")"
# FAKE_DC_LOCALIZED=1: the display answers come out worded differently (localized).
[ -n "${FAKE_DC_LOCALIZED:-}" ] && { ld="[loc] $ld"; vd="[loc] $vd"; }
set_q layout "$ld"; [ -n "${FAKE_DC_KEEP_VARIANT:-}" ] || set_q variant "$ld${vd:+ - $vd}"
# FAKE_DC_EMPTY_VARIANT=1: the package leaves the variant display answer empty.
[ -n "${FAKE_DC_EMPTY_VARIANT:-}" ] && set_q variant ""
sed -i -e "s|^XKBMODEL=.*|XKBMODEL=\"$(get modelcode)\"|" -e "s|^XKBLAYOUT=.*|XKBLAYOUT=\"$(get layoutcode)\"|" \
  -e "s|^XKBVARIANT=.*|XKBVARIANT=\"$(get variantcode)\"|" -e "s|^XKBOPTIONS=.*|XKBOPTIONS=\"$(get optionscode)\"|" "$f"
EOS
# localectl status / set-x11-keymap: state in $FAKE_STATE/x11 (layout model variant
# options lines). FAKE_LOCALECTL_NOOP=1: the set call does nothing.
cat >"$WORK/bin/localectl" <<'EOS'
#!/bin/sh
echo "localectl $*" >>"$FAKE_STATE/all.log"
case "$1" in
  status)
    echo "   System Locale: LANG=en_US.UTF-8"
    echo "       VC Keymap: (unset)"
    echo "      X11 Layout: $(sed -n 1p "$FAKE_STATE/x11")"
    echo "       X11 Model: $(sed -n 2p "$FAKE_STATE/x11")"
    v="$(sed -n 3p "$FAKE_STATE/x11")"; [ -n "$v" ] && echo "     X11 Variant: $v"
    o="$(sed -n 4p "$FAKE_STATE/x11")"; [ -n "$o" ] && echo "     X11 Options: $o"
    ;;
  set-x11-keymap)
    [ -n "${FAKE_LOCALECTL_NOOP:-}" ] && exit 0
    printf '%s\n%s\n%s\n%s\n' "$2" "$3" "${4:-}" "${5:-}" >"$FAKE_STATE/x11"
    # Like systemd-localed: /etc/vconsole.conf follows (FAKE_VC_STALE=1: it does not).
    vc="${KCS_ROOT:-}/etc/vconsole.conf"
    if [ -z "${FAKE_VC_STALE:-}" ] && [ -f "$vc" ]; then
      sed -i -e "s|^XKBLAYOUT=.*|XKBLAYOUT=$2|" -e "s|^KEYMAP=.*|KEYMAP=map-$2|" "$vc"
    fi
    ;;
esac
exit 0
EOS
cat >"$WORK/bin/update-initramfs" <<'EOS'
#!/bin/sh
echo "update-initramfs $*" >>"$FAKE_STATE/all.log"
# FAKE_INITRAMFS_CLOBBER_MODEL=1: something rewrites the model in /etc/default/keyboard.
[ -n "${FAKE_INITRAMFS_CLOBBER_MODEL:-}" ] && sed -i 's|^XKBMODEL=.*|XKBMODEL="pc104"|' "${KCS_ROOT:-}/etc/default/keyboard"
exit 0
EOS
cat >"$WORK/bin/setupcon" <<'EOS'
#!/bin/sh
echo "setupcon $*" >>"$FAKE_STATE/all.log"
[ -n "${FAKE_SETUPCON_FAIL:-}" ] && exit 1
exit 0
EOS
# install: drop -o/-g (the tests do not run as root) and log the ownership asked.
cat >"$WORK/bin/install" <<'EOS'
#!/bin/sh
args=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) echo "install-owner $1 $2" >>"$FAKE_STATE/all.log"; shift 2 ;;
    *) args="$args '$1'"; shift ;;
  esac
done
eval "exec /usr/bin/install $args"
EOS
chmod +x "$WORK/bin"/*

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

# xkb rules list fixture, the same shape as the real evdev.lst.
write_lst() {
  mkdir -p "$KCS_ROOT/usr/share/X11/xkb/rules"
  cat >"$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst" <<'EOF'
! model
  pc105           Generic 105-key PC (intl.)

! layout
  us              English (US)
  es              Spanish
  latam           Spanish (Latin American)
  fr              French
  gb              English (UK)

! variant
  intl            us: English (US, intl., with dead keys)
  altgr-intl      us: English (intl., with AltGr dead keys)
  oss             fr: French (alt.)
  dvorak          us: English (Dvorak)

! option
  grp             Switching to another layout
EOF
  cp -- "$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst" "$WORK/lst.fixture"
}

# put_installer_layout <layout> [variant]: the system as the Kali installer left it.
put_installer_layout() {
  local l="$1" v="${2:-}"
  mkdir -p "$KCS_ROOT/etc/default" "$(dirname "$XKB")"
  printf '# KEYBOARD CONFIGURATION FILE\n\n# Consult the keyboard(5) manual page.\n\nXKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT="%s"\nXKBOPTIONS=""\n\nBACKSPACE="guess"\n' "$l" "$v" >"$KBD"
  printf 'XKBMODEL=pc105\nXKBLAYOUT=%s\nBACKSPACE=guess\nKEYMAP=la-latin1\n' "$l" >"$VC"
  local ld vd lst="$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst"
  ld="$(awk -v l="$l" '/^! /{ c = ($2 == "layout"); next } c && $1 == l { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print; exit }' "$lst")"
  vd="$(awk -v l="$l:" -v v="$v" '/^! /{ c = ($2 == "variant"); next } c && $1 == v && $2 == l { sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, ""); print; exit }' "$lst")"
  printf 'modelcode=pc105\nlayoutcode=%s\nvariantcode=%s\noptionscode=\nxkb-keymap=%s\nlayout=%s\nvariant=%s\ncompose=No compose key\n' \
    "$l" "$v" "${l}${v:+($v)}" "$ld" "$ld${vd:+ - $vd}" >"$FAKE_STATE/kdc"
  printf '%s\npc105\n%s\n\n' "$l" "$v" >"$FAKE_STATE/x11"
  printf '(\n    rules: "",\n    model: "pc105",\n    layout: "%s",\n    variant: "%s",\n    options: None,\n    repeat_delay: 450,\n    repeat_rate: 30,\n)' \
    "$l" "$v" >"$XKB"
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${GH:?}" "${WORK:?}/cache"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT/etc" "$HOME_DIR" "$GH"
  printf 'keyboard-configuration\nxkb-data\n' >"$FAKE_STATE/installed"
  write_lst
  put_installer_layout latam
}

# kb <install.sh args...>: run the keyboard module through install.sh.
kb() {
  rm -f -- "${FAKE_STATE:?}"/all.log "${FAKE_STATE:?}"/sudo.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only keyboard "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}
calls() { grep -c -- "^$*" "$FAKE_STATE/all.log" 2>/dev/null || true; }
dc() { sed -n "s/^$1=//p" "$FAKE_STATE/kdc" | head -n 1; }

# --- metadata -------------------------------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^keyboard +no ' <<<"$out" >/dev/null
check "metadata: keyboard is a default (not opt-in) module" $?
last_default="$(grep -E ' no +' <<<"$out" | tail -n 1 | awk '{print $1}')"
[[ "$last_default" == keyboard ]]
check "metadata: keyboard runs after every other default module" $?

# --- the menu ----------------------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/keyboard.sh
source "$REPO_ROOT/lib/keyboard.sh"
menu() { # menu <input>: run the menu with scripted input; sets mrc, KEYBOARD_CHOICE and $WORK/menu.out
  KEYBOARD_CHOICE=""
  mrc=0
  kbd_menu <<<"$1" >"$WORK/menu.out" 2>&1 || mrc=$?
}
declare -A OPT=([1]=us [2]=us:altgr-intl [3]=us:intl [4]=latam [5]=es [6]=keep)
for n in 1 2 3 4 5 6; do
  menu "$n"
  [[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "${OPT[$n]}" ]]
  check "menu: option $n gives ${OPT[$n]}" $?
done
menu "7
fr
oss"
[[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "fr:oss" ]]
check "menu: Other with a valid layout and variant" $?
menu "7
gb
"
[[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "gb" ]]
check "menu: Other with a layout and no variant" $?
menu "7
zz

gb
bogus
dvorak"
[[ "$mrc" == 1 ]]
check "menu: input that ends in the middle of Other fails (never hangs)" $?
menu "7
zz

fr
nope
oss"
[[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "fr:oss" ]] && grep -q "unknown layout 'zz'" "$WORK/menu.out" &&
  grep -q "type a layout name" "$WORK/menu.out" && grep -q "unknown variant 'nope' for 'fr'" "$WORK/menu.out"
check "menu: Other asks again on an empty or unknown layout and on an unknown variant" $?
menu "7
us
oss
dvorak"
[[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "us:dvorak" ]] && grep -q "unknown variant 'oss' for 'us'" "$WORK/menu.out"
check "menu: a variant of another layout is refused" $?
menu "

x
9
3"
[[ "$mrc" == 0 && "$KEYBOARD_CHOICE" == "us:intl" ]] && [[ "$(grep -c "invalid choice" "$WORK/menu.out")" == 4 ]]
check "menu: empty and invalid answers ask again (no default)" $?
menu ""
[[ "$mrc" == 1 && -z "$KEYBOARD_CHOICE" ]]
check "menu: an empty answer then end of input fails without a choice" $?
printf '' | kbd_menu >"$WORK/menu.out" 2>&1
[[ "$?" == 1 ]] && grep -q 'no keyboard choice' "$WORK/menu.out"
check "menu: end of input fails with a clear message" $?
put_installer_layout latam alt
menu "6"
grep -q '6) Keep current (layout: latam, variant: alt)' "$WORK/menu.out"
check "menu: Keep current shows the current layout and variant" $?
put_installer_layout latam
menu "6"
grep -q '6) Keep current (layout: latam, variant: none)' "$WORK/menu.out"
check "menu: Keep current shows no variant as none" $?
grep -q '1) English (US)' "$WORK/menu.out" && grep -q '7) Other' "$WORK/menu.out" && ! grep -q 'default' "$WORK/menu.out"
check "menu: lists the seven options and names no default" $?

# --- --keyboard parsing and validation --------------------------------------------------------------
reset_state
kb --dry-run --keyboard xx
[[ "$rc" == 2 ]] && grep -q "unknown keyboard layout 'xx'" "$WORK/out" && ! grep -q 'module: keyboard' "$WORK/out"
check "--keyboard with an unknown layout exits 2 before any module" $?
kb --dry-run --keyboard us:bogus
[[ "$rc" == 2 ]] && grep -q "unknown variant 'bogus' for the keyboard layout 'us'" "$WORK/out"
check "--keyboard with a variant of another layout exits 2" $?
kb --dry-run --keyboard fr:altgr-intl
[[ "$rc" == 2 ]]
check "--keyboard with a variant that belongs to another layout exits 2" $?
rm -f "$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst"
kb --dry-run --keyboard us
[[ "$rc" == 2 ]] && grep -q 'xkb-data' "$WORK/out"
check "--keyboard without the XKB rules list says so and exits 2" $?
kb --dry-run --keyboard keep
[[ "$rc" == 0 ]]
check "--keyboard keep needs no rules list" $?
write_lst
kb --dry-run --keyboard us:altgr-intl
[[ "$rc" == 0 ]]
check "--keyboard <layout>:<variant> is accepted" $?
kb --keyboard 'us;rm'
[[ "$rc" == 2 ]]
check "--keyboard with odd characters exits 2" $?

# --- no terminal and no --keyboard -----------------------------------------------------------------------
reset_state
kb
[[ "$rc" == 1 ]] && grep -q -- '--keyboard' "$WORK/out" && ! grep -q 'module: keyboard' "$WORK/out" &&
  [[ ! -s "$FAKE_STATE/all.log" && "$(dc layoutcode)" == latam ]]
check "no terminal and no --keyboard: exits 1 before any module, nothing changed" $?
kb --dry-run
[[ "$rc" == 0 ]] && grep -q 'no terminal' "$WORK/out" && grep -q 'nothing to plan' "$WORK/out"
check "dry-run without --keyboard and without a terminal plans nothing and does not fail" $?

# --- the menu through install.sh on a terminal ---------------------------------------------------------------
if command -v script >/dev/null 2>&1; then
  reset_state
  rm -f -- "$WORK/tty.out"
  # The input (a wrong answer, then option 2) is fed through a pseudo terminal.
  (sleep 1.5; printf 'x\n'; sleep 0.5; printf '2\n'; sleep 4) | HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 \
    XDG_CACHE_HOME="$WORK/cache" \
    script -qec "$REPO_ROOT/install.sh --only keyboard" /dev/null >"$WORK/tty.out" 2>&1
  grep -q 'Choose 1-7' "$WORK/tty.out" && grep -q 'invalid choice' "$WORK/tty.out" &&
    grep -q 'XKBLAYOUT="us"' "$KBD" && grep -q 'XKBVARIANT="altgr-intl"' "$KBD"
  check "terminal: the menu is shown once, a wrong answer asks again, option 2 is applied" $?
else
  printf 'skip - terminal menu test (script not installed)\n'
fi

# --- apply ----------------------------------------------------------------------------------------------------
reset_state
kb --dry-run --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'layout us, variant altgr-intl' "$WORK/out" && grep -q '/etc/default/keyboard' "$WORK/out" &&
  grep -q 'login screen' "$WORK/out" && grep -q 'XKBLAYOUT="latam"' "$KBD" && [[ ! -e "$GXKB" ]] &&
  [[ "$(calls update-initramfs)" == 0 && "$(calls dpkg-reconfigure)" == 0 && "$(calls localectl set-x11)" == 0 ]]
check "dry-run: prints the choice and the files, changes nothing" $?
reset_state
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]]
check "apply: exit 0" $?
grep -qx 'XKBMODEL="pc105"' "$KBD" && grep -qx 'XKBLAYOUT="us"' "$KBD" && grep -qx 'XKBVARIANT="altgr-intl"' "$KBD" &&
  grep -qx 'XKBOPTIONS=""' "$KBD" && grep -qx 'BACKSPACE="guess"' "$KBD" && grep -q 'Consult the keyboard' "$KBD" &&
  compgen -G "$KBD.bak.*" >/dev/null && grep -q latam "$KBD".bak.*
check "/etc/default/keyboard: chosen layout, model pc105, empty options, other lines kept, backup of the original" $?
[[ "$(dc layoutcode)" == us && "$(dc variantcode)" == altgr-intl && "$(dc modelcode)" == pc105 && -z "$(dc optionscode)" &&
  "$(dc xkb-keymap)" == 'us(altgr-intl)' && "$(dc layout)" == 'English (US)' &&
  "$(dc variant)" == 'English (US) - English (intl., with AltGr dead keys)' ]] && ! grep -q 'latam\|Latin' "$FAKE_STATE/kdc"
check "debconf: code and display answers hold the chosen layout, none the installer layout" $?
grep -q 'debconf-set-selections DEBIAN_FRONTEND=noninteractive' "$FAKE_STATE/all.log" &&
  grep -q 'dpkg-reconfigure -f noninteractive keyboard-configuration DEBIAN_FRONTEND=noninteractive' "$FAKE_STATE/all.log"
check "debconf: set and reconfigured non-interactively" $?
[[ "$(calls update-initramfs)" == 1 ]] && grep -q 'setupcon --save-only' "$FAKE_STATE/all.log"
check "initramfs and console cache refreshed once" $?
grep -q 'localectl set-x11-keymap us pc105 altgr-intl' "$FAKE_STATE/all.log" &&
  [[ "$(sed -n 1p "$FAKE_STATE/x11")" == us && "$(sed -n 3p "$FAKE_STATE/x11")" == altgr-intl ]]
check "localectl: X11 keymap set to the chosen layout" $?
grep -q 'layout: "us"' "$XKB" && grep -q 'variant: "altgr-intl"' "$XKB" && grep -q 'options: None' "$XKB" &&
  grep -q 'repeat_delay: 450' "$XKB" && grep -q 'repeat_rate: 30' "$XKB" && ! grep -q latam "$XKB"
check "COSMIC xkb_config of the user: chosen layout only, key repeat settings kept" $?
grep -q 'layout: "us"' "$GXKB" && grep -q 'variant: "altgr-intl"' "$GXKB" && ! grep -q latam "$GXKB" &&
  grep -q 'install-owner -o cosmic-greeter' "$FAKE_STATE/all.log"
check "COSMIC xkb_config of the greeter user: chosen layout, owned by the greeter" $?
grep -q 'is the only one configured' "$WORK/out" && grep -q 'reboot' "$WORK/out"
check "verification passes and the reboot hint is shown" $?
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ "$(calls update-initramfs)" == 0 &&
  "$(calls dpkg-reconfigure)" == 0 && "$(calls debconf-set-selections)" == 0 && "$(calls localectl set-x11)" == 0 ]]
check "second run: total changes: 0, no initramfs, no reconfigure, no localectl change" $?
kb --keyboard keep
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && grep -q 'keeping the current layout (us:altgr-intl)' "$WORK/out"
check "keep after the choice: 0 changes" $?

# --- a layout without a variant --------------------------------------------------------------------------------
reset_state
kb --keyboard es
[[ "$rc" == 0 ]] && grep -qx 'XKBVARIANT=""' "$KBD" && [[ "$(dc xkb-keymap)" == es && "$(dc variant)" == Spanish && -z "$(dc variantcode)" ]] &&
  grep -q 'variant: ""' "$XKB"
check "es without a variant: empty variant everywhere" $?
kb --keyboard es
grep -q 'total changes: 0' "$WORK/out"
check "es: second run 0 changes" $?

# --- keep changes nothing ------------------------------------------------------------------------------------------
reset_state
printf '(\n    rules: "",\n    model: "pc105",\n    layout: "latam,us",\n    variant: ",altgr-intl",\n    options: None,\n    repeat_delay: 600,\n    repeat_rate: 25,\n)' >"$XKB"
snapshot() { cat -- "$KBD" "$VC" "$FAKE_STATE/kdc" "$FAKE_STATE/x11" "$XKB"; }
before="$(snapshot)"
kb --keyboard keep
[[ "$rc" == 0 && "$(snapshot)" == "$before" ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/all.log" ]] &&
  [[ ! -e "$GXKB" ]] && ! compgen -G "$KBD.bak.*" >/dev/null
check "keep: nothing changes, no command runs, layouts added in COSMIC stay" $?
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && ! grep -q 'latam' "$XKB" && grep -q 'layout: "us"' "$XKB"
check "a chosen layout becomes the only configured one again (added layouts are replaced)" $?

# --- verification fails loudly ---------------------------------------------------------------------------------------
reset_state
FAKE_LOCALECTL_NOOP=1 kb --keyboard us:altgr-intl
[[ "$rc" != 0 ]] && grep -q 'did not replace the installer layout everywhere' "$WORK/out" &&
  grep -q 'localectl X11 Layout is "latam"' "$WORK/out" && grep -q "module 'keyboard' failed" "$WORK/out"
check "verify: a localectl that keeps the old layout fails the module and names the trace" $?
reset_state
FAKE_RECONF_NOOP=1 kb --keyboard us:altgr-intl
# the module rewrites /etc/default/keyboard itself, so a stale reconfigure is caught by debconf or fixed by the file
[[ "$rc" == 0 ]] && grep -qx 'XKBLAYOUT="us"' "$KBD"
check "verify: a reconfigure that does nothing still ends with the file correct" $?
reset_state
# the display answer keeps the installer layout: the reconfigure fake leaves "variant" alone
FAKE_DC_KEEP_VARIANT=1 kb --keyboard us:altgr-intl
[[ "$rc" != 0 ]] && grep -q 'debconf keyboard-configuration/variant is still the installer.s "Spanish (Latin American)"' "$WORK/out"
check "verify: an installer layout left in a debconf display answer fails loudly" $?

# --- the installer layout in /etc/vconsole.conf --------------------------------------------------------------------------
reset_state
FAKE_VC_STALE=1 kb --keyboard us:altgr-intl
[[ "$rc" != 0 ]] && grep -q 'vconsole.conf' "$WORK/out"
check "verify: /etc/vconsole.conf still holding the installer console keymap fails loudly" $?

# --- no greeter user ---------------------------------------------------------------------------------------------------------
reset_state
rm -rf -- "$GH"
KCS_GREETER_HOME="" kb --keyboard us
[[ "$rc" == 0 ]] && grep -q 'layout: "us"' "$XKB"
check "no cosmic-greeter user: the login screen step is skipped, the rest applies" $?

# --- a missing /etc/default/keyboard ------------------------------------------------------------------------------------------
reset_state
rm -f "$KBD"
kb --keyboard us
[[ "$rc" == 0 ]] && grep -qx 'XKBLAYOUT="us"' "$KBD" && grep -qx 'BACKSPACE="guess"' "$KBD"
check "a missing /etc/default/keyboard is created complete" $?

# --- M12b: a variant-only change keeps the same display text (the owner's real case) ---------------
reset_state
put_installer_layout us
kb --keyboard us:altgr-intl
[[ "$rc" == 0 && "$(dc layout)" == 'English (US)' && "$(dc variant)" == 'English (US) - English (intl., with AltGr dead keys)' ]] &&
  grep -q 'is the only one configured' "$WORK/out" && ! grep -q 'still the installer' "$WORK/out"
check "variant-only change us -> us:altgr-intl: the unchanged layout display text is not an installer trace" $?
reset_state
put_installer_layout us intl
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'is the only one configured' "$WORK/out"
check "variant-only change us:intl -> us:altgr-intl succeeds" $?
reset_state
put_installer_layout us altgr-intl
FAKE_DC_KEEP_VARIANT=1 kb --keyboard us:intl
[[ "$rc" != 0 ]] && grep -q 'debconf keyboard-configuration/variant is still the installer' "$WORK/out"
check "variant-only change: a variant display answer that stays the old one still fails" $?
reset_state
put_installer_layout us
kb --keyboard us
kb --keyboard us
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && grep -q 'is the only one configured' "$WORK/out"
check "plain us from the installer us, twice: the verification passes and the second run changes nothing" $?

# --- M12b W2: xkb-data missing at the start of a real run ------------------------------------------------
mv -- "$WORK/bin/apt-get" "$WORK/bin/apt-get.orig"
cat >"$WORK/bin/apt-get" <<'EOS'
#!/bin/sh
case "$*" in
  *install*xkb-data*)
    mkdir -p "${KCS_ROOT:-}/usr/share/X11/xkb/rules"
    cp -- "${KCS_LST_FIXTURE:?}" "${KCS_ROOT:-}/usr/share/X11/xkb/rules/evdev.lst"
    echo "xkb-data-installed" >>"$FAKE_STATE/all.log"
    ;;
esac
exec "$(dirname "$0")/apt-get.orig" "$@"
EOS
chmod +x "$WORK/bin/apt-get"
export KCS_LST_FIXTURE="$WORK/lst.fixture"
reset_state
rm -f -- "$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst"
printf 'keyboard-configuration\n' >"$FAKE_STATE/installed"
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'xkb-data-installed' "$FAKE_STATE/all.log" && grep -qx 'XKBVARIANT="altgr-intl"' "$KBD"
check "real run with xkb-data missing: it is installed before validating, then the layout applies" $?
reset_state
rm -f -- "$KCS_ROOT/usr/share/X11/xkb/rules/evdev.lst"
printf 'keyboard-configuration\n' >"$FAKE_STATE/installed"
kb --keyboard xx
[[ "$rc" == 2 ]] && grep -q "unknown keyboard layout 'xx'" "$WORK/out" && grep -qx 'XKBLAYOUT="latam"' "$KBD"
check "real run with xkb-data missing and a bad layout: validated after the install, exit 2, nothing applied" $?

# --- M12b W3: model and console cache are verified ------------------------------------------------------------------
reset_state
FAKE_INITRAMFS_CLOBBER_MODEL=1 kb --keyboard us:altgr-intl
[[ "$rc" != 0 ]] && grep -q 'XKBMODEL' "$WORK/out" && grep -q 'wanted "pc105"' "$WORK/out"
check "verify: an /etc/default/keyboard whose model is not pc105 fails loudly" $?
reset_state
mkdir -p "$KCS_ROOT/boot"
touch -d '2001-01-01' "$KCS_ROOT/boot/initrd.img-$(uname -r)"
FAKE_SETUPCON_FAIL=1 kb --keyboard us:altgr-intl
[[ "$rc" != 0 ]] && grep -q 'setupcon' "$WORK/out" && [[ "$(calls update-initramfs)" == 0 ]]
check "a failing setupcon fails the module loudly" $?
kb --keyboard us:altgr-intl
[[ "$rc" == 0 && "$(calls setupcon)" == 1 && "$(calls update-initramfs)" == 1 ]]
check "after a failed setupcon the next run retries the console cache and the initramfs" $?

# --- M12b S5: greeter files behind symlinks are never followed by root -----------------------------------------------------
reset_state
mkdir -p "$GH/.config/cosmic/com.system76.CosmicComp/v1" "$WORK/elsewhere"
echo precious >"$WORK/elsewhere/target"
ln -s "$WORK/elsewhere/target" "$GXKB"
kb --keyboard us:altgr-intl
[[ "$rc" == 0 && "$(<"$WORK/elsewhere/target")" == precious && -L "$GXKB" ]] && grep -q 'symlink' "$WORK/out" &&
  ! compgen -G "$GH/.config/cosmic/com.system76.CosmicComp/v1/xkb_config.bak.*" >/dev/null
check "a symlinked greeter xkb_config is skipped with a warning (target untouched)" $?
reset_state
mkdir -p "$GH/.config/cosmic" "$WORK/elsewhere/dir"
ln -s "$WORK/elsewhere/dir" "$GH/.config/cosmic/com.system76.CosmicComp"
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'symlink' "$WORK/out" && [[ -z "$(ls -A "$WORK/elsewhere/dir")" ]]
check "a symlinked parent directory of the greeter config is skipped with a warning" $?
# --- M12b S6/S8: the user name and the menu header ---------------------------------------------------------------------------
reset_state
kb --keyboard us:altgr-intl
! grep -q 'tester' "$WORK/out"
check "messages name the real user (id -un), not \$USER" $?
menu "6"
! grep -q 'is replaced by' "$WORK/menu.out" && grep -q 'Keep current' "$WORK/menu.out" && head -n 3 "$WORK/menu.out" | grep -qi 'keep'
check "menu header does not claim the installer layout is always replaced" $?

# --- final review W1: the display answers must describe the chosen layout ------------------------
reset_state
put_installer_layout us altgr-intl
sed -i 's/^variant=.*/variant=Spanish (Latin American)/' "$FAKE_STATE/kdc"
FAKE_DC_KEEP_VARIANT=1 kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'warn.*debconf keyboard-configuration/variant is "Spanish (Latin American)" (wanted "English (US) - English (intl., with AltGr dead keys)").*cosmetic' "$WORK/out"
check "W1: a display answer that stays stale only warns (it is cosmetic)" $?
reset_state
put_installer_layout us altgr-intl
sed -i -e 's/^variant=.*/variant=Spanish (Latin American)/' -e 's/^layout=.*/layout=Spanish (Latin American)/' "$FAKE_STATE/kdc"
kb --keyboard us:altgr-intl
[[ "$rc" == 0 && "$(dc layout)" == 'English (US)' && "$(dc variant)" == 'English (US) - English (intl., with AltGr dead keys)' ]]
check "W1: a stale display answer is rewritten on the next run" $?
kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "W1: and the run after that changes nothing" $?
reset_state
FAKE_DEBCONF_EMPTY=1 kb --keyboard us:altgr-intl
grep -q 'debconf-show returned nothing' "$WORK/out"
check "W1: an empty debconf-show read logs a warning instead of skipping silently" $?

# --- M13c: the display answers are cosmetic -------------------------------------------------------
reset_state
FAKE_DC_LOCALIZED=1 kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -qi 'warn.*cosmetic' "$WORK/out" && [[ "$(dc layoutcode)" == us && "$(dc variantcode)" == altgr-intl ]]
check "M13c: localized display wording succeeds with a warning" $?
FAKE_DC_LOCALIZED=1 kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ "$(calls dpkg-reconfigure)" == 0 && "$(calls debconf-set-selections)" == 0 ]]
check "M13c: and the second run with that wording changes nothing" $?
reset_state
FAKE_DC_EMPTY_VARIANT=1 kb --keyboard us:altgr-intl
[[ "$rc" == 0 ]] && grep -qi 'warn.*variant.*empty' "$WORK/out" && [[ "$(dc variantcode)" == altgr-intl ]]
check "M13c: an empty variant display answer only warns (it is cosmetic)" $?
reset_state
kb --keyboard latam
[[ "$rc" == 0 ]]
check "M13c: latam (no variant) run succeeds" $?
kb --keyboard latam
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out"
check "M13c: latam repeat run changes nothing" $?
reset_state
put_installer_layout us altgr-intl
kb --keyboard latam
grep -q 'LC_ALL=C' "$FAKE_STATE/sudo.log" && grep -q 'env DEBIAN_FRONTEND=noninteractive LC_ALL=C debconf-set-selections' "$FAKE_STATE/sudo.log" &&
  grep -q 'env DEBIAN_FRONTEND=noninteractive LC_ALL=C dpkg-reconfigure' "$FAKE_STATE/sudo.log" &&
  grep -q 'debconf-show keyboard-configuration LC_ALL=C' "$FAKE_STATE/all.log" && ! grep -q 'debconf-show.*LC_ALL=$' "$FAKE_STATE/all.log"
check "M13c: debconf-show, set-selections and dpkg-reconfigure run under LC_ALL=C" $?
! grep -q 'layout select $' "$FAKE_STATE/selections.log" && ! grep -q 'variant select $' "$FAKE_STATE/selections.log"
check "M13c: no display answer is written with an empty value" $?

# --- final review W2: the final message says when the login screen was skipped -------------------
reset_state
mkdir -p "$WORK/elsewhere"
mkdir -p "$GH"
ln -s "$WORK/elsewhere" "$GH/.config"
kb --keyboard us
[[ "$rc" == 0 ]] && grep -q 'login screen was skipped' "$WORK/out" && ! grep -q 'and the login screen)' "$WORK/out"
check "W2: with the greeter step skipped the final message does not claim the login screen" $?
reset_state
kb --keyboard us
grep -q 'and the login screen)' "$WORK/out"
check "W2: without a skip the final message still names the login screen" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
