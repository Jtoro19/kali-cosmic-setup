#!/usr/bin/env bash
# tests/test-cosmic-settings.sh: modules/20-cosmic-settings.sh against fake apt
# and dpkg-query and a temporary HOME. Never touches the real system.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# shellcheck disable=SC2319
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
CFG="$HOME_DIR/.config/cosmic"
SRC="$REPO_ROOT/files/cosmic"
SC=com.system76.CosmicSettings.Shortcuts/v1/custom

failures=0
check() { # check <description> <status>
  if (($2 == 0)); then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    failures=$((failures + 1))
  fi
}

reset_state() {
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR"
  : >"$FAKE_STATE/installed"
}

# cs <install.sh args...>: run the module with HOME in the work directory.
cs() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" PATH="$WORK/bin:$PATH" KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" \
    "$REPO_ROOT/install.sh" --only cosmic-settings "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# shipped_keys: every file under files/cosmic except the shortcuts file the
# module merges itself, as a path relative to files/cosmic.
shipped_keys() { (cd "$SRC" && find . -type f ! -path "*/$SC" | sed 's|^\./||' | sort); }

# --- the shipped tree ---------------------------------------------------------
! grep -rq -e '/home/' -e '@HOME@' "$SRC"
check "files/cosmic holds no personal path or placeholder" $?
[[ -z "$(find "$SRC" -type f \( -name '*font*' -o -name 'xkb_config' -o -name 'system_actions' -o -name '*.bak*' \))" ]]
check "files/cosmic ships no font, xkb_config, system_actions or backup key" $?
! grep -q 'aura' "$SRC/$SC"
check "the shortcuts seed has no Alt+S aura entry (it moves to the aura module)" $?
[[ -z "$(find "$SRC" -type f -path '*Theme*/v1/*' ! -path '*Theme.Mode/*')" ]]
check "no stale CosmicTheme v1 keys are shipped (COSMIC 1.11 reads v2)" $?

# --- dry-run ------------------------------------------------------------------
reset_state
cs --dry-run
[[ "$rc" == 0 && -z "$(find "$HOME_DIR" -type f 2>/dev/null)" && ! -s "$FAKE_STATE/apt.log" ]]
check "dry-run succeeds, writes nothing and runs no apt-get" $?
grep -q 'papirus-icon-theme' "$WORK/out" && grep -q 'CosmicTk/v1/icon_theme' "$WORK/out"
check "dry-run reports the package and the keys it would install" $?

# --- fresh run ----------------------------------------------------------------
reset_state
cs
[[ "$rc" == 0 ]]
check "fresh run succeeds" $?
grep -qx 'papirus-icon-theme' "$FAKE_STATE/installed"
check "papirus-icon-theme is installed" $?
ok=0
while IFS= read -r rel; do cmp -s -- "$SRC/$rel" "$CFG/$rel" || ok=1; done < <(shipped_keys)
check "every shipped key is installed byte-exact under ~/.config/cosmic" $ok
[[ "$(cat "$CFG/com.system76.CosmicTk/v1/icon_theme")" == '"Papirus-Dark"' ]]
check "the icon theme key reads back as Papirus-Dark" $?
[[ "$(cat "$CFG/com.system76.CosmicTheme.Mode/v1/is_dark")" == true ]] &&
  grep -q '#6E22A8FF' "$CFG/com.system76.CosmicTheme.Dark.Builder/v2/accent"
check "dark mode and the purple accent are seeded when missing" $?
[[ ! -e "$CFG/com.system76.CosmicComp/v1/xkb_config" ]]
check "xkb_config is never written (the keyboard module owns it)" $?
[[ ! -e "$CFG/com.system76.CosmicSettings.Shortcuts/v1/system_actions" ]]
check "system_actions is not written (the kitty module owns the terminal action)" $?
grep -q 'Spawn("cosmic-screenshot")' "$CFG/$SC" && ! grep -q 'aura' "$CFG/$SC"
check "shortcuts: Super+Shift+S screenshot, no Alt+S" $?
! grep -rq '@HOME@' "$CFG"
check "no placeholder is left in the installed keys" $?
cs
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/apt.log" ]]
check "second run: total changes: 0 and no apt-get" $?
cs --dry-run
grep -q 'Nothing to change\|total changes: 0' "$WORK/out"
check "dry-run after a real run reports nothing to change" $?

# --- backups and user edits ---------------------------------------------------
reset_state
mkdir -p "$CFG/com.system76.CosmicTk/v1"
printf '"Adwaita"' >"$CFG/com.system76.CosmicTk/v1/icon_theme"
cs
[[ "$rc" == 0 && "$(cat "$CFG/com.system76.CosmicTk/v1/icon_theme")" == '"Papirus-Dark"' ]] &&
  [[ "$(cat "$CFG"/com.system76.CosmicTk/v1/icon_theme.bak.*)" == '"Adwaita"' ]]
check "a differing shipped key is replaced after a .bak.<timestamp> backup" $?
[[ -z "$(find "$CFG" -name '*.bak.*' ! -path '*CosmicTk*')" ]]
check "keys that did not exist get no backup" $?
mkdir -p "$CFG/com.system76.CosmicSomethingElse/v1"
printf 'keep' >"$CFG/com.system76.CosmicSomethingElse/v1/own"
cs
[[ "$(cat "$CFG/com.system76.CosmicSomethingElse/v1/own")" == keep ]]
check "keys that are not shipped are never touched" $?

# --- seed-only keys -----------------------------------------------------------
reset_state
mkdir -p "$CFG/com.system76.CosmicTheme.Mode/v1" "$CFG/com.system76.CosmicTheme.Dark.Builder/v2" \
  "$CFG/com.system76.CosmicTheme.Dark/v2" "$CFG/com.system76.CosmicPortal/v1"
printf 'false' >"$CFG/com.system76.CosmicTheme.Mode/v1/is_dark"
printf 'Some("#112233FF")' >"$CFG/com.system76.CosmicTheme.Dark.Builder/v2/accent"
printf 'MINE' >"$CFG/com.system76.CosmicTheme.Dark/v2/accent_button"
printf 'MINE' >"$CFG/com.system76.CosmicPortal/v1/screenshot"
cs
[[ "$rc" == 0 && "$(cat "$CFG/com.system76.CosmicTheme.Mode/v1/is_dark")" == false &&
  "$(cat "$CFG/com.system76.CosmicTheme.Dark.Builder/v2/accent")" == 'Some("#112233FF")' &&
  "$(cat "$CFG/com.system76.CosmicTheme.Dark/v2/accent_button")" == MINE &&
  "$(cat "$CFG/com.system76.CosmicPortal/v1/screenshot")" == MINE ]]
check "dark mode, accent and portal screenshot values chosen by the user or aura are kept" $?
[[ -z "$(find "$CFG" -name '*.bak.*')" ]]
check "seed-only keys that exist are not even backed up" $?
cs
grep -q 'total changes: 0' "$WORK/out"
check "seed-only: second run changes nothing" $?

# --- shortcuts: own only the screenshot entry ---------------------------------
AURA='{
    (
        modifiers: [
            Alt,
        ],
        key: "s",
        description: Some("aurahud"),
    ): Spawn("/home/u/.local/bin/aura switcher"),
}'
reset_state
mkdir -p "$(dirname "$CFG/$SC")"
printf '%s' "$AURA" >"$CFG/$SC"
cs
[[ "$rc" == 0 ]] && grep -q 'Spawn("cosmic-screenshot")' "$CFG/$SC" && grep -q 'aurahud' "$CFG/$SC" &&
  grep -q 'aura switcher' "$CFG/$SC" && [[ "$(tail -n 1 "$CFG/$SC")" == '}' ]]
check "shortcuts: a custom file with only the aura entry gets the screenshot entry added, aura kept" $?
ls "$CFG/$SC".bak.* >/dev/null 2>&1
check "shortcuts: the merge backs up the previous custom file" $?
[[ "$(grep -c 'key: "s"' "$CFG/$SC")" == 2 ]]
check "shortcuts: the merged file has exactly the two entries" $?
cs
grep -q 'total changes: 0' "$WORK/out"
check "shortcuts: the merged file is stable on the next run" $?
# Aura adds its entry to our file (the other order): nothing is removed.
reset_state
cs
{ sed '$d' "$CFG/$SC"; printf '    (\n        modifiers: [\n            Alt,\n        ],\n        key: "s",\n        description: Some("aurahud"),\n    ): Spawn("aura switcher"),\n}\n'; } >"$WORK/both"
cp "$WORK/both" "$CFG/$SC"
cs
grep -q 'total changes: 0' "$WORK/out" && cmp -s "$WORK/both" "$CFG/$SC"
check "shortcuts: a file with both entries is left byte for byte alone" $?
# Super+Shift+S already bound by the user to something else: do not duplicate the key.
reset_state
mkdir -p "$(dirname "$CFG/$SC")"
printf '{\n    (\n        modifiers: [Shift, Super],\n        key: "s",\n        description: None,\n    ): Spawn("flameshot gui"),\n}' >"$CFG/$SC"
cp "$CFG/$SC" "$WORK/mine"
cs
[[ "$rc" == 0 ]] && cmp -s "$WORK/mine" "$CFG/$SC"
check "shortcuts: a user binding on Super+Shift+S is respected (no duplicate key)" $?
# Empty map and unreadable formats.
reset_state
mkdir -p "$(dirname "$CFG/$SC")"
printf '{}' >"$CFG/$SC"
cs
cmp -s "$SRC/$SC" "$CFG/$SC"
check "shortcuts: an empty map is replaced by the seed" $?
reset_state
mkdir -p "$(dirname "$CFG/$SC")"
printf 'not a ron map' >"$CFG/$SC"
cs
[[ "$rc" == 0 && "$(cat "$CFG/$SC")" == 'not a ron map' ]] && grep -q '\[warn\].*custom' "$WORK/out"
check "shortcuts: an unrecognised file is left alone with a warning" $?

# --- shortcuts: merge shape and "already bound" detection ----------------------
# flat <file>: the file without whitespace, for shape checks.
flat() { tr -d ' \n\t' <"$1"; }
# balanced <file>: braces and parentheses balance.
balanced() {
  local f
  f="$(flat "$1")"
  local o="${f//[^(]/}" c="${f//[^)]/}" ob="${f//[^\{]/}" cb="${f//[^\}]/}"
  [[ ${#o} == "${#c}" && ${#ob} == "${#cb}" ]]
}
put_custom() { # put_custom <content>: a fresh state with this custom file
  reset_state
  mkdir -p "$(dirname "$CFG/$SC")"
  printf '%s' "$1" >"$CFG/$SC"
}

# W1: the last entry has no trailing comma.
put_custom '{
    (
        modifiers: [Ctrl],
        key: "f",
        description: None,
    ): Spawn("flameshot gui")
}'
cs
f="$(flat "$CFG/$SC")"
[[ "$rc" == 0 && "$f" == *'Spawn("flameshotgui"),('* && "$f" == *'Spawn("cosmic-screenshot"),}' ]] && balanced "$CFG/$SC"
check "shortcuts: a last entry without a trailing comma gets one before the new entry (valid map)" $?
cs
grep -q 'total changes: 0' "$WORK/out"
check "shortcuts: the repaired map is stable on the next run" $?
# A trailing comment after the last entry must not swallow the comma.
put_custom '{
    (
        modifiers: [Ctrl],
        key: "f",
        description: None,
    ): Spawn("flameshot gui") // mine
}'
cs
grep -q 'Spawn("flameshot gui"), // mine' "$CFG/$SC" && grep -q 'Spawn("cosmic-screenshot")' "$CFG/$SC" && balanced "$CFG/$SC"
check "shortcuts: the comma goes right after the last entry, before its trailing comment" $?
# A shape the module does not understand is left alone with a warning.
for junk in '{ junk }' '{ ( modifiers: [Ctrl], key: "f" ): Spawn("x"), ' '{ ( modifiers: [Ctrl] ): Spawn("x"), }' \
  '{ ( modifiers: [Ctrl], key: "f" ): Spawn("x") ( modifiers: [Alt], key: "g" ): Spawn("y"), }'; do
  put_custom "$junk"
  cs
  [[ "$rc" == 0 && "$(cat "$CFG/$SC")" == "$junk" ]] && grep -q '\[warn\].*custom' "$WORK/out" && ! ls "$CFG/$SC".bak.* >/dev/null 2>&1
  check "shortcuts: untouched with a warning for: $junk" $?
done

# W2: comments are not bindings.
put_custom '{
    // (modifiers: [Super, Shift], key: "s"): Spawn("old"),
    (
        modifiers: [Ctrl],
        key: "f",
        description: None, // Super+Shift, key: "s"
    ): Spawn("flameshot gui"), // modifiers: [Shift, Super], key: "s"
}'
cs
[[ "$rc" == 0 ]] && grep -q 'Spawn("cosmic-screenshot")' "$CFG/$SC" && grep -q 'Spawn("old")' "$CFG/$SC" && balanced "$CFG/$SC"
check "shortcuts: a commented-out binding is not a binding, the entry is added" $?
# W2: field order and modifier order.
for entry in \
  '(key: "s", modifiers: [Shift, Super], description: None): Spawn("a"),' \
  '(key: "S", modifiers: [Super, Shift]): Spawn("cosmic-screenshot"),' \
  '(description: None, key: "s", modifiers: [Shift,Super]): Spawn("a"),'; do
  put_custom "{ $entry }"
  cs
  [[ "$rc" == 0 && "$(cat "$CFG/$SC")" == "{ $entry }" ]]
  check "shortcuts: already bound is detected for: $entry" $?
done
# The same combination bound with another key or other modifiers is not a duplicate.
put_custom '{ (modifiers: [Super, Shift, Ctrl], key: "s", description: None): Spawn("a"), (modifiers: [Super, Shift], key: "x", description: None): Spawn("b"), }'
cs
[[ "$(grep -c 'cosmic-screenshot' "$CFG/$SC")" == 2 ]] && balanced "$CFG/$SC"
check "shortcuts: other modifiers or another key are not Super+Shift+S" $?
cs
grep -q 'total changes: 0' "$WORK/out"
check "shortcuts: no duplicate entry is added on a second run" $?

# S5: never write through sudo into config the invoking user does not own.
cat >"$WORK/bin/stat" <<'EOS'
#!/bin/sh
# FAKE_NOT_OWNED: paths (colon separated) that "belong to root".
if [ "$1" = "-c" ] && [ "$2" = "%u" ]; then
  p="${4:-$3}"
  old="$IFS"; IFS=:
  for n in $FAKE_NOT_OWNED; do [ "$p" = "$n" ] && { echo $(($(/usr/bin/id -u) + 1)); exit 0; }; done
  IFS="$old"
fi
exec /usr/bin/stat "$@"
EOS
chmod +x "$WORK/bin/stat"
reset_state
mkdir -p "$CFG"
FAKE_NOT_OWNED="$CFG" cs
[[ "$rc" == 0 && -z "$(find "$CFG" -type f 2>/dev/null)" ]] && grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a ~/.config/cosmic owned by someone else is skipped with a warning, no sudo write" $?
reset_state
mkdir -p "$CFG/com.system76.CosmicTk/v1" "$CFG/com.system76.CosmicIdle/v1"
FAKE_NOT_OWNED="$CFG/com.system76.CosmicTk/v1" cs
[[ "$rc" == 0 && ! -e "$CFG/com.system76.CosmicTk/v1/icon_theme" && -e "$CFG/com.system76.CosmicIdle/v1/screen_off_time" &&
  -e "$CFG/$SC" ]] && grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a key dir owned by someone else is skipped, the other keys are written, no sudo write" $?
reset_state
mkdir -p "$(dirname "$CFG/$SC")"
printf '{}' >"$CFG/$SC"
FAKE_NOT_OWNED="$CFG/$SC" cs
[[ "$rc" == 0 && "$(cat "$CFG/$SC")" == '{}' ]] && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a shortcuts file owned by someone else is not rewritten" $?

# --- failures ---------------------------------------------------------------
reset_state
FAKE_APT_RC=100 cs
[[ "$rc" != 0 ]]
check "a failing apt-get fails the module" $?
! grep -Eq 'xkb|localectl|greeter' "$REPO_ROOT/modules/20-cosmic-settings.sh"
check "the module has no keyboard or greeter code" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
