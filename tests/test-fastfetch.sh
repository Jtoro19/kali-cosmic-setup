#!/usr/bin/env bash
# tests/test-fastfetch.sh: modules/45-fastfetch.sh (packages, the image pool from
# third-party repos, the shell block in the rc file of the login shell) against
# fake apt-get, git and magick, a temporary HOME and a temporary root. Never
# touches the real system and never uses the network.
# `! cmd; check $?` is deliberate: check reads the inverted status.
# SC2016: the shell blocks under test contain literal $ on purpose.
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
IMG="$HOME_DIR/.config/fastfetch/images"
BAD="$HOME_DIR/.config/fastfetch/bad"

# git: `clone ... <url> <dest>` fills <dest> with images in the root and in the
# subdirectories the sources use (logos, images, png), plus a loli* file, a text
# file and an invalid image. FAKE_GIT_FAIL_REPO=<substring> fails the clones whose
# URL contains it. Every call is logged with GIT_TERMINAL_PROMPT.
cat >"$WORK/bin/git" <<'EOS'
#!/bin/sh
echo "git $* [prompt=${GIT_TERMINAL_PROMPT:-unset}]" >>"$FAKE_STATE/git.log"
if [ "$1" = clone ]; then
  for a in "$@"; do dest="$a"; url="$a"; done
  for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
  case "$url" in *"${FAKE_GIT_FAIL_REPO:-@@none@@}"*) exit 128 ;; esac
  n="$(echo "$url" | sed 's|.*/\([^/]*\)\.git|\1|')"
  for d in "" logos images png; do
    mkdir -p "$dest/$d"
    echo "img-$n-a" >"$dest/$d/a.png"
    echo "img-$n-b" >"$dest/$d/b.JPG"
    echo "img-$n-c" >"$dest/$d/c.webp"
    echo "x" >"$dest/$d/loli-x.png"
    echo "text" >"$dest/$d/readme.txt"
  done
  mkdir -p "$dest/.git"
  echo hidden >"$dest/.git/z.png"
  echo "BAD" >"$dest/d.png"
  exit 0
fi
if [ "$1" = -C ] && [ "$3" = lfs ] && [ "$4" = pull ] && [ -n "${FAKE_GIT_LFS_FAIL:-}" ]; then exit 1; fi
exit 0
EOS
# magick mogrify -resize <geom> <files...> (logged); magick identify <file> fails
# for a file that contains BAD.
cat >"$WORK/bin/magick" <<'EOS'
#!/bin/sh
echo "magick $*" >>"$FAKE_STATE/magick.log"
if [ "$1" = identify ]; then ! grep -q BAD "$2"; exit $?; fi
exit 0
EOS
chmod +x "$WORK/bin/git" "$WORK/bin/magick"

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
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache" "${WORK:?}/tmp"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR" "$WORK/tmp"
  : >"$FAKE_STATE/installed"
}

# ff <install.sh args...>: the module as a zsh user unless FF_SHELL says otherwise.
ff() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_LOGIN_SHELL="${FF_SHELL:-/usr/bin/zsh}" \
    KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
    "$REPO_ROOT/install.sh" --only fastfetch "$@" >"$WORK/out" 2>&1 </dev/null || rc=$?
}

# --- metadata ----------------------------------------------------------------------------
reset_state
out="$(PATH="$WORK/bin:$PATH" KCS_SKIP_OS_CHECK=1 "$REPO_ROOT/install.sh" --list 2>&1)"
grep -E '^fastfetch +no ' <<<"$out" >/dev/null
check "metadata: fastfetch is a default (not opt-in) module" $?
ff --dry-run
k="$(grep -n 'module: kitty$' "$WORK/out" | head -n 1 | cut -d: -f1)"
f="$(grep -n 'module: fastfetch$' "$WORK/out" | head -n 1 | cut -d: -f1)"
[[ -n "$k" && -n "$f" && "$k" -lt "$f" ]]
check "--only fastfetch pulls in its dependency kitty first" $?

# --- dry-run --------------------------------------------------------------------------------
reset_state
ff --dry-run
[[ "$rc" == 0 && ! -d "$IMG" && ! -e "$HOME_DIR/.zshrc" && ! -s "$FAKE_STATE/git.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "dry-run: exit 0, no clone, no image directory, no rc file, no apt-get" $?
[[ "$(grep -c 'would fetch' "$WORK/out")" == 6 ]]
check "dry-run: reports the six sources it would fetch" $?

# --- fresh run (zsh) ------------------------------------------------------------------------------
reset_state
ff
[[ "$rc" == 0 ]]
check "fresh run: exit 0" $?
for p in fastfetch imagemagick git git-lfs; do grep -qx "$p" "$FAKE_STATE/installed" || { echo "missing $p"; false; }; done
check "packages: fastfetch, imagemagick, git and git-lfs come from apt" $?
[[ "$(grep -c '^git clone' "$FAKE_STATE/git.log")" == 6 ]] && ! grep '^git clone' "$FAKE_STATE/git.log" | grep -qv -- '--depth 1' &&
  ! grep '^git clone' "$FAKE_STATE/git.log" | grep -qv 'https://github.com/' && ! grep '^git clone' "$FAKE_STATE/git.log" | grep -qv 'prompt=0'
check "clones: six shallow https clones with GIT_TERMINAL_PROMPT=0" $?
grep -q -- '--branch master https://github.com/Ronin-CK/fastfetchPNG-images.git' "$FAKE_STATE/git.log"
check "clones: the ronin source uses its branch" $?
[[ "$(grep -c 'lfs pull' "$FAKE_STATE/git.log")" == 1 ]] && grep -q 'Maheswara660/fastfetch' "$FAKE_STATE/git.log"
check "lfs: git lfs pull runs only for the LFS source" $?
for p in ronin thunder menhoudj themes mahe sofija; do compgen -G "$IMG/$p-*" >/dev/null || { echo "no images for $p"; false; }; done
check "pool: every source has images named <prefix>-<name>" $?
[[ -f "$IMG/ronin-a.png" && -f "$IMG/ronin-b.JPG" && -f "$IMG/ronin-c.webp" ]]
check "pool: png, jpg (any case) and webp are copied" $?
! compgen -G "$IMG/*loli*" >/dev/null && ! compgen -G "$IMG/*readme*" >/dev/null && ! compgen -G "$IMG/*z.png" >/dev/null
check "pool: loli* files, non-images and .git contents are not copied" $?
[[ -f "$BAD/ronin-d.png" && ! -e "$IMG/ronin-d.png" ]] && grep -q 'ronin-d.png' "$WORK/out"
check "validation: an image that magick cannot read goes to bad/ with a warning" $?
grep -q 'magick mogrify -resize 600x600>' "$FAKE_STATE/magick.log"
check "resize: new images are shrunk to at most 600x600" $?
[[ -z "$(ls -A "$WORK/tmp")" ]]
check "cleanup: the clone directory is removed" $?
rcf="$HOME_DIR/.zshrc"
grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$rcf" && grep -qx '        fastfetch --kitty "$img" --logo-width 20' "$rcf" && grep -q 'xterm-kitty' "$rcf" && [[ ! -e "$HOME_DIR/.bashrc" ]]
check "zsh login shell: the fastfetch block is in ~/.zshrc and ~/.bashrc is not created" $?
# --- second run --------------------------------------------------------------------------------------
: >"$FAKE_STATE/apt.log"
nbak="$(find "$HOME_DIR" -name '*.bak.*' | wc -l)"
ff
[[ "$rc" == 0 ]] && grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/git.log" && ! -s "$FAKE_STATE/apt.log" ]]
check "second run: total changes: 0, no clone" $?
[[ "$(find "$HOME_DIR" -name '*.bak.*' | wc -l)" == "$nbak" ]]
check "second run: no new backup files" $?

# --- bash login shell -----------------------------------------------------------------------------------
reset_state
FF_SHELL=/bin/bash ff
[[ "$rc" == 0 ]] && grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$HOME_DIR/.bashrc" && [[ ! -e "$HOME_DIR/.zshrc" ]]
check "bash login shell: the block goes to ~/.bashrc and ~/.zshrc is not created" $?

# --- another shell --------------------------------------------------------------------------------------
reset_state
FF_SHELL=/usr/bin/fish ff
[[ "$rc" == 0 && ! -e "$HOME_DIR/.zshrc" && ! -e "$HOME_DIR/.bashrc" ]] && compgen -G "$IMG/ronin-*" >/dev/null && grep -q fish "$WORK/out"
check "fish login shell: the images are fetched, no rc block is written, the run warns" $?

# --- legacy snippet --------------------------------------------------------------------------------------
reset_state
cat >"$HOME_DIR/.zshrc" <<'EOS'
export A=1
# Fastfetch with a random image as logo
if [[ $TERM == xterm-kitty ]]; then
    sleep 0.1
    img=$(find ~/.config/fastfetch/images -type f 2>/dev/null | shuf -n 1)
    if [[ -n $img ]]; then
        fastfetch --kitty "$img" --logo-width 20
    else
        fastfetch
    fi
fi
echo end
EOS
ff
[[ "$(grep -c 'fastfetch --kitty' "$HOME_DIR/.zshrc")" == 1 ]] && grep -qx 'export A=1' "$HOME_DIR/.zshrc" && grep -qx 'echo end' "$HOME_DIR/.zshrc" &&
  grep -q '(kitty only)' "$HOME_DIR/.zshrc" && compgen -G "$HOME_DIR/.zshrc.bak.*" >/dev/null
check "legacy: the unmanaged snippet is removed, the managed block added once, other lines kept, backup made" $?
ff
grep -q 'total changes: 0' "$WORK/out"
check "legacy: a second run changes nothing" $?

# --- network trouble --------------------------------------------------------------------------------------
reset_state
FAKE_GIT_FAIL_REPO=Ronin-CK ff
[[ "$rc" == 0 ]] && grep -q 'could not clone Ronin-CK/fastfetchPNG-images' "$WORK/out" && ! compgen -G "$IMG/ronin-*" >/dev/null && compgen -G "$IMG/thunder-*" >/dev/null &&
  grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$HOME_DIR/.zshrc"
check "clone failure: one failing source warns, the others and the block still succeed (exit 0)" $?
ff
[[ "$rc" == 0 && "$(grep -c '^git clone' "$FAKE_STATE/git.log")" == 1 ]] && grep -q 'Ronin-CK' "$FAKE_STATE/git.log" && compgen -G "$IMG/ronin-*" >/dev/null
check "clone failure: the next run fetches only the source that is missing" $?
reset_state
FAKE_GIT_LFS_FAIL=1 ff
[[ "$rc" == 0 ]] && grep -q 'git lfs pull failed for mahe' "$WORK/out"
check "lfs failure: a warning, the run still succeeds" $?
reset_state
FASTFETCH_SKIP_IMAGES=1 ff
[[ "$rc" == 0 && ! -s "$FAKE_STATE/git.log" && ! -d "$IMG" ]] && grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$HOME_DIR/.zshrc"
check "FASTFETCH_SKIP_IMAGES=1: no clone, the block is still written" $?

# --- nothing personal in the repository -----------------------------------------------------------------------
[[ -z "$(find "$REPO_ROOT/files" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null)" && ! -e "$REPO_ROOT/files/fastfetch" ]]
check "the repository ships no image: the pool is fetched into the home directory at run time" $?
grep '^| fastfetch ' "$REPO_ROOT/README.md" | grep -q '.config/fastfetch'
check "README: the fastfetch row has a revert column" $?

if ((failures > 0)); then
  printf '\n--- last install.sh output ---\n'
  cat -- "$WORK/out"
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
