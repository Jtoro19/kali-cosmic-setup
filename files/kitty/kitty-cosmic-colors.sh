#!/bin/sh
# Set the kitty selection colors from the COSMIC accent color.
#
# COSMIC 1.11 writes theme version 2: ~/.config/cosmic/com.system76.CosmicTheme.<Dark|Light>/v2/accent
# is RON with hex strings, `( base: "#RRGGBBAA", hover: ...`, and the first
# `base` is the accent. (Theme version 1 stored float channels and is not read.)
# Mode/v1/is_dark holds the literal `true` or `false`. Until the user has changed
# the theme there is no user file: the shipped default under /usr/share/cosmic
# is read instead.
C="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic"
SHARE="${COSMIC_SHARE_DIR:-/usr/share/cosmic}"
OUT="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/cosmic-colors.conf"

if [ "$(cat "$C/com.system76.CosmicTheme.Mode/v1/is_dark" 2>/dev/null)" = "false" ]; then
  T=Light
else
  T=Dark
fi
F="$C/com.system76.CosmicTheme.$T/v2/accent"
[ -f "$F" ] || F="$SHARE/com.system76.CosmicTheme.$T/v2/accent"
[ -f "$F" ] || exit 0

hex="$(sed -n 's/.*base: *"#\([0-9A-Fa-f]\{6\}\)[0-9A-Fa-f]*".*/\1/p' "$F" | head -n 1)"
if [ -z "$hex" ]; then
  echo "kitty-cosmic-colors: no base: \"#RRGGBBAA\" color in $F" >&2
  exit 1
fi
hex="$(printf '%s' "$hex" | tr 'A-F' 'a-f')"
rest="${hex#??}"
r=$((0x${hex%????}))
g=$((0x${rest%??}))
b=$((0x${hex#????}))
# Black text on a light accent, white on a dark one (luminance above 0.6).
if [ $((299 * r + 587 * g + 114 * b)) -gt 153000 ]; then
  fg="#000000"
else
  fg="#ffffff"
fi

mkdir -p "$(dirname "$OUT")"
printf 'selection_background #%s\nselection_foreground %s\n' "$hex" "$fg" >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"

pkill -USR1 -x kitty 2>/dev/null
exit 0
