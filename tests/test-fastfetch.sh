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

# git: `init <dir>`, `-C <dir> remote add origin <url>`, `-C <dir> fetch ... origin
# <sha>` (FAKE_GIT_FAIL_REPO=<substring of the URL> fails it, FAKE_GIT_SLEEP=<s>
# hangs it), `-C <dir> checkout` fills <dir> with images in the root and in the
# subdirectories the sources use (logos, images, png), plus a loli* file, a text
# file, an image with the wrong content, one with BAD content and a 2 KiB file;
# `-C <dir> rev-parse HEAD` prints the fetched sha (FAKE_GIT_HEAD overrides).
# Every call is logged with GIT_TERMINAL_PROMPT.
cat >"$WORK/bin/git" <<'EOS'
#!/bin/sh
echo "git $* [prompt=${GIT_TERMINAL_PROMPT:-unset}]" >>"$FAKE_STATE/git.log"
if [ "$1" = init ]; then
  for a in "$@"; do dest="$a"; done
  mkdir -p "$dest/.git"
  exit 0
fi
if [ "$1" = -C ]; then
  d="$2"
  shift 2
  case "$1" in
    remote) echo "$4" >"$d/.url"; exit 0 ;;
    lfs)
      if [ "$2" = pull ] && [ -n "${FAKE_GIT_LFS_FAIL:-}" ]; then exit 1; fi
      exit 0
      ;;
    fetch)
      for a in "$@"; do sha="$a"; done
      case "$(cat "$d/.url")" in *"${FAKE_GIT_FAIL_REPO:-@@none@@}"*) exit 128 ;; esac
      [ -n "${FAKE_GIT_SLEEP:-}" ] && exec sleep "$FAKE_GIT_SLEEP"
      echo "$sha" >"$d/.sha"
      exit 0
      ;;
    checkout)
      n="$(sed 's|.*/\([^/]*\)\.git|\1|' "$d/.url")"
      for sub in "" logos images png; do
        mkdir -p "$d/$sub"
        echo "PNG img-$n-a" >"$d/$sub/a.png"
        echo "JPG img-$n-b" >"$d/$sub/b.JPG"
        echo "WEBP img-$n-c" >"$d/$sub/c.webp"
        echo "x" >"$d/$sub/loli-x.png"
        echo "text" >"$d/$sub/readme.txt"
      done
      echo hidden >"$d/.git/z.png"
      echo "PNG BAD" >"$d/d.png"
      echo "<html>not a png</html>" >"$d/fake.png"
      { printf 'PNG '; head -c 2044 /dev/zero | tr '\0' 'x'; } >"$d/big.png"
      exit 0
      ;;
    rev-parse) echo "${FAKE_GIT_HEAD:-$(cat "$d/.sha")}"; exit 0 ;;
  esac
fi
exit 0
EOS
# magick [-limit k v]... <FMT:in[0]> -resize <geom> <FMT:out>: fails when the format
# prefix is missing, the content does not start with the forced format's tag, or
# the file contains BAD; otherwise copies the input to the output. Logged.
cat >"$WORK/bin/magick" <<'EOS'
#!/bin/sh
echo "magick $*" >>"$FAKE_STATE/magick.log"
while [ "$1" = -limit ]; do shift 3; done
in="$1"; shift 3; out="$1"
fmt="${in%%:*}"
[ "$fmt" = "$in" ] && exit 1
f="${in#*:}"; f="${f%\[0\]}"
case "$fmt" in PNG) tag=PNG ;; JPEG) tag=JPG ;; WEBP) tag=WEBP ;; *) exit 1 ;; esac
[ "$(head -c "${#tag}" "$f")" = "$tag" ] || exit 1
grep -q BAD "$f" && exit 1
cp "$f" "${out#*:}"
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
  rm -rf -- "${FAKE_STATE:?}" "${KCS_ROOT:?}" "${HOME_DIR:?}" "${WORK:?}/cache" "${WORK:?}/tmp" "${WORK:?}/state-home"
  mkdir -p "$FAKE_STATE" "$KCS_ROOT" "$HOME_DIR" "$WORK/tmp"
  : >"$FAKE_STATE/installed"
}

# ff <install.sh args...>: the module as a zsh user unless FF_SHELL says otherwise.
ff() {
  rm -f -- "${FAKE_STATE:?}"/*.log
  rc=0
  HOME="$HOME_DIR" USER=tester PATH="$WORK/bin:$PATH" KCS_TEST=1 KCS_LOGIN_SHELL="${FF_SHELL:-/usr/bin/zsh}" \
    KCS_SKIP_SUDO=1 KCS_SKIP_OS_CHECK=1 XDG_CACHE_HOME="$WORK/cache" XDG_STATE_HOME="$WORK/state-home" XDG_RUNTIME_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
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
[[ "$(grep -c ' fetch ' "$FAKE_STATE/git.log")" == 6 ]] && ! grep ' fetch ' "$FAKE_STATE/git.log" | grep -qv -- '--depth 1' &&
  ! grep ' remote add' "$FAKE_STATE/git.log" | grep -qv 'https://github.com/' && ! grep '^git ' "$FAKE_STATE/git.log" | grep -qv 'prompt=0' && ! grep -q 'git clone' "$FAKE_STATE/git.log"
check "fetch: six shallow https fetches with GIT_TERMINAL_PROMPT=0 (no branch clone)" $?
ok=0
while IFS='|' read -r _ _ sha _; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && grep -q -- "fetch -q --depth 1 origin $sha" "$FAKE_STATE/git.log" || ok=1
done < <(sed -n 's/^  "\(.*\)"$/\1/p' "$REPO_ROOT/modules/45-fastfetch.sh")
[[ "$ok" == 0 && "$(grep -c 'rev-parse HEAD' "$FAKE_STATE/git.log")" == 6 ]]
check "pins: every source is fetched by its 40-hex commit and the checked-out HEAD is read back" $?
grep -q "init -q $WORK/cache/" "$FAKE_STATE/git.log" && ! grep -q "$WORK/tmp" "$FAKE_STATE/git.log" && [[ -z "$(ls -A "$WORK/tmp")" ]]
check "scratch: the clones live under the cache directory, not in the temp directory" $?
for p in ronin thunder menhoudj themes mahe sofija; do compgen -G "$IMG/$p-*" >/dev/null || { echo "no images for $p"; false; }; done
check "pool: every source has images named <prefix>-<name>" $?
[[ -f "$IMG/ronin-a.png" && -f "$IMG/ronin-b.JPG" && -f "$IMG/ronin-c.webp" ]]
check "pool: png, jpg (any case) and webp are copied" $?
! compgen -G "$IMG/*loli*" >/dev/null && ! compgen -G "$IMG/*readme*" >/dev/null && ! compgen -G "$IMG/*z.png" >/dev/null
check "pool: loli* files, non-images and .git contents are not copied" $?
[[ -f "$BAD/ronin-d.png" && ! -e "$IMG/ronin-d.png" ]] && grep -q 'ronin-d.png' "$WORK/out"
check "validation: an image that magick cannot read goes to bad/ with a warning" $?
grep -q -- "-resize 600x600>" "$FAKE_STATE/magick.log"
check "resize: new images are shrunk to at most 600x600" $?
[[ -z "$(ls -A "$WORK/tmp")" && -z "$(find "$WORK/cache" -maxdepth 3 -name 'fastfetch-images.*')" ]]
check "cleanup: the clone and staging directories are removed" $?
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
[[ "$rc" == 0 ]] && grep -q 'could not fetch Ronin-CK/fastfetchPNG-images' "$WORK/out" && ! compgen -G "$IMG/ronin-*" >/dev/null && compgen -G "$IMG/thunder-*" >/dev/null &&
  grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$HOME_DIR/.zshrc"
check "clone failure: one failing source warns, the others and the block still succeed (exit 0)" $?
ff
[[ "$rc" == 0 && "$(grep -c ' fetch ' "$FAKE_STATE/git.log")" == 1 ]] && grep -q 'Ronin-CK' "$FAKE_STATE/git.log" && compgen -G "$IMG/ronin-*" >/dev/null
check "clone failure: the next run fetches only the source that is missing" $?
reset_state
FAKE_GIT_LFS_FAIL=1 ff
[[ "$rc" == 0 ]] && grep -q 'git lfs pull failed for mahe' "$WORK/out"
check "lfs failure: a warning, the run still succeeds" $?
reset_state
FASTFETCH_SKIP_IMAGES=1 ff
[[ "$rc" == 0 && ! -s "$FAKE_STATE/git.log" && ! -d "$IMG" ]] && grep -qx '# >>> kali-cosmic-setup:fastfetch >>>' "$HOME_DIR/.zshrc"
check "FASTFETCH_SKIP_IMAGES=1: no clone, the block is still written" $?

# --- hardening: formats, limits, size cap, staging --------------------------------------------
reset_state
ff
! grep -v -- '-limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit time 60 ' "$FAKE_STATE/magick.log" | grep -q . &&
  grep -q -- 'PNG:.*a.png\[0\] -resize' "$FAKE_STATE/magick.log" && grep -q -- 'JPEG:.*b.JPG\[0\]' "$FAKE_STATE/magick.log" && grep -q -- 'WEBP:.*c.webp\[0\]' "$FAKE_STATE/magick.log"
check "magick: every call forces the format by extension (PNG:, JPEG:, WEBP:), takes frame [0] and sets memory/map/disk/time limits" $?
[[ -f "$BAD/ronin-fake.png" && ! -e "$IMG/ronin-fake.png" ]] && grep -q 'ronin-fake.png' "$WORK/out"
check "content check: a file named .png whose content is not a PNG goes to bad/, never into the pool" $?
[[ -f "$IMG/ronin-big.png" ]]
check "size: a 2 KiB file is accepted under the default cap" $?
reset_state
FASTFETCH_MAX_FILE_BYTES=1024 ff
[[ ! -e "$IMG/ronin-big.png" && -f "$IMG/ronin-a.png" ]] && grep -q 'big.png is larger than 1024 bytes' "$WORK/out"
check "size: a file above the per-file cap is skipped with a warning" $?
reset_state
FASTFETCH_MAX_SOURCE_KB=0 ff
[[ "$rc" == 0 ]] && ! compgen -G "$IMG/ronin-*" >/dev/null && grep -q 'KB' "$WORK/out"
check "size: a checkout above the per-source cap is skipped with a warning (exit 0)" $?
reset_state
FASTFETCH_MAX_FILES=1 ff
[[ "$(find "$IMG" -name 'ronin-*' | wc -l)" == 1 ]] && grep -q 'more than 1 candidate' "$WORK/out"
check "size: more candidate images than the file-count cap are ignored with a warning" $?
reset_state
FAKE_GIT_SLEEP=20 KCS_NET_TIMEOUT=1 ff
[[ "$rc" == 0 ]] && grep -q 'could not fetch' "$WORK/out" && ! compgen -G "$IMG/*" >/dev/null
check "timeout: a hanging git fetch is cut off, the run warns and exits 0" $?
grep -q 'timeout -k' "$REPO_ROOT/modules/45-fastfetch.sh" && [[ "$(grep -c 'timeout -k' "$REPO_ROOT/modules/45-fastfetch.sh")" -ge 3 ]]
check "timeout: fetch, lfs pull and magick all run under timeout -k" $?

# --- pins: a mismatching or missing commit -----------------------------------------------------
reset_state
FAKE_GIT_HEAD=deadbeef ff
[[ "$rc" == 0 ]] && ! compgen -G "$IMG/*" >/dev/null && grep -q 'not the pinned' "$WORK/out" && [[ ! -d "$WORK/state-home/kali-cosmic-setup/fastfetch" ]]
check "pin: a checkout that is not the pinned commit warns, the source is skipped, no marker, exit 0" $?
reset_state
FAKE_GIT_FAIL_REPO=Thunder-Blaze ff
[[ "$rc" == 0 ]] && grep -q 'could not fetch Thunder-Blaze' "$WORK/out" && ! compgen -G "$IMG/thunder-*" >/dev/null && compgen -G "$IMG/ronin-*" >/dev/null &&
  [[ ! -e "$WORK/state-home/kali-cosmic-setup/fastfetch/thunder.commit" && -e "$WORK/state-home/kali-cosmic-setup/fastfetch/ronin.commit" ]]
check "pin: a pin that cannot be fetched (gone source) warns and skips that source only" $?
[[ "$(grep -c 'change.*fetch images for' "$WORK/out")" == 5 ]]
check "pin: the skipped source is not counted as a change" $?

# --- markers and an interrupted pool ---------------------------------------------------------------
reset_state
ff
for p in ronin thunder menhoudj themes mahe sofija; do
  sha="$(sed -n "s/^  \"$p|[^|]*|\([0-9a-f]*\)|.*/\1/p" "$REPO_ROOT/modules/45-fastfetch.sh")"
  [[ "$(<"$WORK/state-home/kali-cosmic-setup/fastfetch/$p.commit")" == "$sha" ]] || { echo "marker $p"; false; }
done
check "markers: each source records the pinned commit it was completed at" $?
reset_state
mkdir -p "$IMG" "$HOME_DIR/.config/fastfetch/.incoming-ronin"
echo "PNG img-partial" >"$IMG/ronin-a.png"
echo "half" >"$HOME_DIR/.config/fastfetch/.incoming-ronin/ronin-b.JPG"
ff
[[ "$rc" == 0 && "$(<"$IMG/ronin-a.png")" == "PNG img-partial" && -f "$IMG/ronin-b.JPG" && "$(<"$IMG/ronin-b.JPG")" == "JPG img-fastfetchPNG-images-b" ]] &&
  [[ ! -e "$HOME_DIR/.config/fastfetch/.incoming-ronin" && -e "$WORK/state-home/kali-cosmic-setup/fastfetch/ronin.commit" ]]
check "interrupted pool: a source with some files but no marker is completed, existing files are kept, leftovers of the staging dir are removed" $?
ff
grep -q 'total changes: 0' "$WORK/out" && [[ ! -s "$FAKE_STATE/git.log" ]]
check "interrupted pool: the repaired pool is stable (0 changes, no fetch)" $?
rm -f -- "$IMG"/ronin-*
ff
grep -q 'total changes: 0' "$WORK/out" && ! compgen -G "$IMG/ronin-*" >/dev/null
check "markers: images the user deleted from a completed source are not fetched again" $?
sha_old="$(<"$WORK/state-home/kali-cosmic-setup/fastfetch/thunder.commit")"
echo oldsha >"$WORK/state-home/kali-cosmic-setup/fastfetch/thunder.commit"
ff
[[ "$(grep -c ' fetch ' "$FAKE_STATE/git.log")" == 1 && "$(<"$WORK/state-home/kali-cosmic-setup/fastfetch/thunder.commit")" == "$sha_old" ]]
check "markers: a moved pin refetches only that source" $?

# --- the shell snippet ---------------------------------------------------------------------------
reset_state
ff
sed -n '/kali-cosmic-setup:fastfetch >>>/,/kali-cosmic-setup:fastfetch <<</p' "$HOME_DIR/.zshrc" | grep -qx '    unset img'
check "shell block: the img variable is unset after use" $?

# --- files owned by someone else, symlinks (never through sudo) -----------------------------
reset_state
mkdir -p "$HOME_DIR/.config/fastfetch"
printf 'alias x=y\n' >"$HOME_DIR/.zshrc"
FAKE_NOT_OWNED="$HOME_DIR/.config/fastfetch:$HOME_DIR/.zshrc" ff
[[ "$rc" == 0 && ! -d "$IMG" && ! -s "$FAKE_STATE/git.log" && "$(cat "$HOME_DIR/.zshrc")" == 'alias x=y' ]] &&
  grep -q '\[warn\].*not owned' "$WORK/out" && ! grep -q "$HOME_DIR" "$FAKE_STATE/sudo.log"
check "ownership: a fastfetch directory and an rc file owned by someone else are skipped, no clone, no sudo write" $?
reset_state
mkdir -p "$HOME_DIR/dotfiles" "$HOME_DIR/.config/fastfetch" "$WORK/outside"
printf 'alias x=y\n' >"$HOME_DIR/dotfiles/zshrc"
ln -s "$HOME_DIR/dotfiles/zshrc" "$HOME_DIR/.zshrc"
ln -s "$WORK/outside" "$HOME_DIR/.config/fastfetch/images"
ff
[[ "$rc" == 0 && -L "$HOME_DIR/.zshrc" ]] && grep -q 'kali-cosmic-setup:fastfetch' "$HOME_DIR/dotfiles/zshrc"
check "symlink: an rc file linked into the home directory gets the block through the link, the link stays" $?
[[ -z "$(ls -A "$WORK/outside")" && ! -s "$FAKE_STATE/git.log" ]] && grep -q '\[warn\].*symlink' "$WORK/out"
check "symlink: an images directory linked outside the home directory is not filled (warning, no clone)" $?

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
