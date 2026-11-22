#!/usr/bin/env bash
# modules/45-fastfetch.sh: fastfetch with a random image as the logo in kitty,
# plus the pool of images it picks from. See specs/fastfetch.md.

# shellcheck disable=SC2034  # metadata is read by install.sh
MODULE_NAME="fastfetch"
# shellcheck disable=SC2034
MODULE_DESC="fastfetch with a random logo image in kitty, image pool from third-party repos"
# shellcheck disable=SC2034
MODULE_OPTIN=0
# shellcheck disable=SC2034
MODULE_DEPS="kitty"

# Image sources: "prefix|repo (owner/name)|branch|subdir|lfs".
# Empty branch means the default branch; empty subdir means the repo root.
# The images are fetched at run time into the user's home; none is part of this
# repository.
_FASTFETCH_SOURCES=(
  "ronin|Ronin-CK/fastfetchPNG-images|master||0"
  "thunder|Thunder-Blaze/FastfetchPngs|||0"
  "menhoudj|menhoudj/my-fastfetch-config||logos|0"
  "themes|CheikhNaro/ffthemes|||0"
  "mahe|Maheswara660/fastfetch||images|1"
  "sofija|sofijacom/dotfiles-fastfetch||png|0"
)
# Chintanpatel24/awesome-fastfetch ("awesome-*" images) disappeared from
# GitHub in 2026-11; existing awesome-* files are kept, nothing new is fetched.

# Never stop to ask for credentials: a removed or private repo must fail fast
# so the module can warn and continue.
export GIT_TERMINAL_PROMPT=0

# The shell block (bash and zsh compatible). Kept in one place: the block and the
# legacy snippet differ only in the first comment line.
# shellcheck disable=SC2016  # literal shell text on purpose
_FASTFETCH_BODY='if [[ $TERM == xterm-kitty ]]; then
    sleep 0.1
    img=$(find ~/.config/fastfetch/images -type f 2>/dev/null | shuf -n 1)
    if [[ -n $img ]]; then
        fastfetch --kitty "$img" --logo-width 20
    else
        fastfetch
    fi
fi'

# _fastfetch_fetch_source <prefix> <repo> <branch> <subdir> <lfs> <images> <bad> <tmp>
# Clone one repo, copy matching images as <prefix>-<basename>, resize and
# validate only the newly copied files. Returns non-zero on clone failure.
_fastfetch_fetch_source() {
  local prefix="$1" repo="$2" branch="$3" subdir="$4" lfs="$5"
  local images="$6" bad="$7" tmp="$8"
  local clone="$tmp/$prefix" f dest
  local -a clone_args=(--depth 1 --quiet) fresh=()

  if [[ -n "$branch" ]]; then
    clone_args+=(--branch "$branch")
  fi
  if ! git clone "${clone_args[@]}" "https://github.com/${repo}.git" "$clone"; then
    return 1
  fi
  if [[ "$lfs" == "1" ]]; then
    git -C "$clone" lfs install --local >/dev/null 2>&1 || true
    if ! git -C "$clone" lfs pull; then
      log_warn "git lfs pull failed for $prefix; LFS pointers are rejected by validation"
    fi
  fi

  while IFS= read -r -d '' f; do
    dest="$images/$prefix-$(basename -- "$f")"
    if [[ ! -e "$dest" ]]; then
      cp --update=none -- "$f" "$dest"
      fresh+=("$dest")
    fi
  done < <(find "${clone}${subdir:+/$subdir}" -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
    -not -path '*/.git/*' -not -iname 'loli*' -print0 2>/dev/null)

  if ((${#fresh[@]} == 0)); then
    log_warn "no images found for $prefix in $repo"
    return 0
  fi
  # mogrify warnings about iCCP profiles are harmless.
  magick mogrify -resize '600x600>' "${fresh[@]}" 2>/dev/null || true
  for f in "${fresh[@]}"; do
    if ! magick identify "$f" >/dev/null 2>&1; then
      mv -- "$f" "$bad/"
      log_warn "invalid image moved to $bad: $(basename -- "$f")"
    fi
  done
  log_info "fastfetch: $prefix: ${#fresh[@]} image(s) copied"
}

# _fastfetch_images: build the image pool, source by source. Never fails the
# install because of third-party repos.
_fastfetch_images() {
  local images="$HOME/.config/fastfetch/images"
  local bad="$HOME/.config/fastfetch/bad"
  local tmp="" entry prefix repo branch subdir lfs url
  local -a pending=()

  if [[ "${FASTFETCH_SKIP_IMAGES:-0}" == "1" ]]; then
    log_info "FASTFETCH_SKIP_IMAGES=1: skipping the image pool"
    return 0
  fi

  # A source is done when any <prefix>-* file exists in images or bad.
  for entry in "${_FASTFETCH_SOURCES[@]}"; do
    prefix="${entry%%|*}"
    if compgen -G "$images/$prefix-*" >/dev/null ||
      compgen -G "$bad/$prefix-*" >/dev/null; then
      continue
    fi
    pending+=("$entry")
  done
  if ((${#pending[@]} == 0)); then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    for entry in "${pending[@]}"; do
      IFS='|' read -r prefix repo _ <<<"$entry"
      url="https://github.com/${repo}.git"
      printf '[dry-run] would fetch %s from %s\n' "$prefix" "$url"
      log_change "fetch images for $prefix"
    done
    return 0
  fi

  if ! command -v git >/dev/null 2>&1 || ! command -v magick >/dev/null 2>&1; then
    log_warn "git or magick missing; skipping the image pool"
    return 0
  fi

  mkdir -p -- "$images" "$bad"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fastfetch-images.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now on purpose
  trap "rm -rf -- '$tmp'" EXIT
  for entry in "${pending[@]}"; do
    IFS='|' read -r prefix repo branch subdir lfs <<<"$entry"
    log_change "fetch images for $prefix"
    if ! _fastfetch_fetch_source "$prefix" "$repo" "$branch" "$subdir" "$lfs" \
      "$images" "$bad" "$tmp"; then
      log_warn "could not clone $repo (network?); skipping $prefix"
    fi
  done
  rm -rf -- "$tmp"
  trap - EXIT
  return 0
}

# _fastfetch_block: the managed block in the rc file of the login shell, after
# removing the legacy unmanaged snippet that older setups pasted there.
_fastfetch_block() {
  local rc legacy
  rc="$(login_rc_file)" || return 0
  legacy="# Fastfetch with a random image as logo
$_FASTFETCH_BODY"
  remove_exact_block "$rc" "$legacy"
  ensure_block "$rc" fastfetch "# Fastfetch with a random image as logo (kitty only)
$_FASTFETCH_BODY"
}

module_apply() {
  ensure_packages fastfetch imagemagick git git-lfs || return 1
  _fastfetch_images
  _fastfetch_block
}
