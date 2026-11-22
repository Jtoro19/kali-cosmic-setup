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

# Image sources: "prefix|repo (owner/name)|commit|subdir|lfs".
# Every source is pinned to a commit (the head of its default branch when the
# pins were chosen, 2026-11-22) and fetched by that commit: nothing newer is ever
# fetched from a third-party repo unreviewed. Empty subdir means the repo root.
# The images are fetched at run time into the user's home; none is part of this
# repository. To move a pin, change the sha: the source is fetched again (new
# images are added, existing ones are kept).
_FASTFETCH_SOURCES=(
  "ronin|Ronin-CK/fastfetchPNG-images|fb4d6bb8fae85c99cb113afabcb711efe83d39c5||0"
  "thunder|Thunder-Blaze/FastfetchPngs|2619f112c2d7fc1514f098b6a9fc16fe20ff5124||0"
  "menhoudj|menhoudj/my-fastfetch-config|ce85cb63c7d89653accff5ab8535dca65aa4d0b5|logos|0"
  "themes|CheikhNaro/ffthemes|f154ff8f9447fb6876c1b60e4b6023d6b16c53c9||0"
  "mahe|Maheswara660/fastfetch|2df4f8b517ae2dae11d350cac146fc4c65d88540|images|1"
  "sofija|sofijacom/dotfiles-fastfetch|9a661c2602f8f3eba92632a855a29147b308451b|png|0"
)
# Chintanpatel24/awesome-fastfetch ("awesome-*" images) disappeared from
# GitHub in 2026-11; existing awesome-* files are kept, nothing new is fetched.

# Never stop to ask for credentials: a removed or private repo must fail fast
# so the module can warn and continue.
export GIT_TERMINAL_PROMPT=0

# Bounds (environment overrides are for the tests): network commands are cut off
# after _ff_net_timeout seconds; a file larger than FASTFETCH_MAX_FILE_BYTES, a
# checkout larger than FASTFETCH_MAX_SOURCE_KB or more than FASTFETCH_MAX_FILES
# candidate images per source is not used.
_ff_net_timeout() { echo "${KCS_NET_TIMEOUT:-300}"; }
_ff_max_file() { echo "${FASTFETCH_MAX_FILE_BYTES:-5242880}"; }
_ff_max_source_kb() { echo "${FASTFETCH_MAX_SOURCE_KB:-524288}"; }
_ff_max_files() { echo "${FASTFETCH_MAX_FILES:-400}"; }

# The shell block (bash and zsh compatible). The legacy snippet that older setups
# pasted into the rc file is kept verbatim for its removal; the managed block adds
# `unset img` so the variable does not leak into the interactive shell.
# shellcheck disable=SC2016  # literal shell text on purpose
_FASTFETCH_LEGACY_BODY='if [[ $TERM == xterm-kitty ]]; then
    sleep 0.1
    img=$(find ~/.config/fastfetch/images -type f 2>/dev/null | shuf -n 1)
    if [[ -n $img ]]; then
        fastfetch --kitty "$img" --logo-width 20
    else
        fastfetch
    fi
fi'
# shellcheck disable=SC2016
_FASTFETCH_BODY='if [[ $TERM == xterm-kitty ]]; then
    sleep 0.1
    img=$(find ~/.config/fastfetch/images -type f 2>/dev/null | shuf -n 1)
    if [[ -n $img ]]; then
        fastfetch --kitty "$img" --logo-width 20
    else
        fastfetch
    fi
    unset img
fi'

_ff_marker() { # <prefix>
  printf '%s/kali-cosmic-setup/fastfetch/%s.commit\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$1"
}

# _ff_source_current <prefix> <commit>: this source was fully processed at this pin.
_ff_source_current() {
  local m
  m="$(_ff_marker "$1")"
  [[ -f "$m" && "$(<"$m")" == "$2" ]]
}

# _ff_magick <format> <in> <out>: decode <in> as exactly <format> (never guessed
# from the content), with resource limits, shrink to at most 600x600 and write a
# re-encoded copy to <out> (metadata and trailing data do not survive).
_ff_magick() {
  timeout -k 5 90 magick -limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit time 60 \
    "$1:$2[0]" -resize '600x600>' "$1:$3" >/dev/null 2>&1 </dev/null
}

# _ff_format <file>: the ImageMagick format forced by the extension, or nothing.
_ff_format() {
  case "${1,,}" in
    *.png) echo PNG ;;
    *.jpg | *.jpeg) echo JPEG ;;
    *.webp) echo WEBP ;;
  esac
}

# _fastfetch_fetch_source <prefix> <repo> <commit> <subdir> <lfs> <images> <bad> <tmp>
# Fetch one repo at its pinned commit into <tmp>, verify the commit, validate
# every candidate image into a staging directory and only then move the valid
# ones into the pool (a per-source marker, written last, says it is complete).
# Returns non-zero when the pinned commit cannot be fetched or does not check out.
_fastfetch_fetch_source() {
  local prefix="$1" repo="$2" commit="$3" subdir="$4" lfs="$5"
  local images="$6" bad="$7" tmp="$8"
  local clone="$tmp/$prefix" stage="$tmp/stage-$prefix" incoming="$images/../.incoming-$prefix"
  local f name fmt dest head kb n=0 moved=0 rejected=0 complete=1 marker
  local limit
  limit="$(_ff_net_timeout)"

  mkdir -p -- "$clone" "$stage"
  git init -q "$clone" || return 1
  git -C "$clone" remote add origin "https://github.com/${repo}.git" || return 1
  if ! timeout -k 10 "$limit" git -C "$clone" fetch -q --depth 1 origin "$commit" </dev/null; then
    return 1
  fi
  git -C "$clone" checkout -q FETCH_HEAD || return 1
  head="$(git -C "$clone" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    log_warn "$repo: the checkout is ${head:-unknown}, not the pinned $commit"
    return 1
  fi
  kb="$(du -sk --exclude=.git -- "$clone" | cut -f1)"
  if ((kb > $(_ff_max_source_kb))); then
    log_warn "$repo at the pinned commit is ${kb} KB (limit $(_ff_max_source_kb) KB)"
    return 1
  fi
  if [[ "$lfs" == "1" ]]; then
    git -C "$clone" lfs install --local >/dev/null 2>&1 || true
    if ! timeout -k 10 "$limit" git -C "$clone" lfs pull </dev/null; then
      log_warn "git lfs pull failed for $prefix; LFS pointers are rejected by validation and $prefix is retried on the next run"
      complete=0
    fi
  fi

  # Validate into the staging directory: nothing reaches the pool unchecked.
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    if ((n > $(_ff_max_files))); then
      log_warn "$prefix: more than $(_ff_max_files) candidate images, ignoring the rest"
      break
    fi
    name="$prefix-$(basename -- "$f")"
    name="${name//[^A-Za-z0-9._-]/_}"
    [[ -e "$images/$name" ]] && continue
    if (($(stat -c %s -- "$f") > $(_ff_max_file))); then
      log_warn "$prefix: $(basename -- "$f") is larger than $(_ff_max_file) bytes: not used"
      continue
    fi
    fmt="$(_ff_format "$f")"
    if [[ -z "$fmt" ]] || ! _ff_magick "$fmt" "$f" "$stage/$name"; then
      rejected=$((rejected + 1))
      mkdir -p -- "$bad"
      cp -f -- "$f" "$bad/$name"
      log_warn "invalid image moved to $bad: $name"
      rm -f -- "$stage/$name"
    fi
  done < <(find "${clone}${subdir:+/$subdir}" -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
    -not -path '*/.git/*' -not -iname 'loli*' -print0 2>/dev/null | sort -z)

  # Move the validated files in (same filesystem as the pool, so each rename is
  # atomic); an interrupted move leaves no marker and the next run completes it.
  rm -rf -- "$incoming"
  mkdir -p -- "$incoming"
  for f in "$stage"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename -- "$f")"
    cp -- "$f" "$incoming/$name" && mv -n -- "$incoming/$name" "$images/$name" && moved=$((moved + 1))
  done
  rm -rf -- "$incoming"
  if ((complete)); then
    marker="$(_ff_marker "$prefix")"
    if user_path_writable "$marker"; then
      mkdir -p -- "$(dirname "$marker")"
      printf '%s\n' "$commit" >"$marker"
    fi
  fi
  if ((moved == 0 && rejected == 0)); then
    log_info "fastfetch: $prefix: no new images at $commit"
  else
    log_info "fastfetch: $prefix: $moved image(s) added, $rejected rejected"
  fi
}

# _fastfetch_images: build the image pool, source by source. Never fails the
# install because of third-party repos.
_fastfetch_images() {
  local images="$HOME/.config/fastfetch/images"
  local bad="$HOME/.config/fastfetch/bad"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/kali-cosmic-setup"
  local tmp="" entry prefix repo commit subdir lfs url
  local -a pending=()

  if [[ "${FASTFETCH_SKIP_IMAGES:-0}" == "1" ]]; then
    log_info "FASTFETCH_SKIP_IMAGES=1: skipping the image pool"
    return 0
  fi

  if ! user_path_writable "$images" || ! user_path_writable "$bad" || ! user_path_writable "$cache/x"; then
    log_warn "skipping the fastfetch image pool"
    return 0
  fi

  # A source is done when its marker holds the pinned commit.
  for entry in "${_FASTFETCH_SOURCES[@]}"; do
    IFS='|' read -r prefix _ commit _ <<<"$entry"
    _ff_source_current "$prefix" "$commit" && continue
    pending+=("$entry")
  done
  if ((${#pending[@]} == 0)); then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    for entry in "${pending[@]}"; do
      IFS='|' read -r prefix repo commit _ <<<"$entry"
      url="https://github.com/${repo}.git"
      printf '[dry-run] would fetch %s from %s at %s\n' "$prefix" "$url" "$commit"
      log_change "fetch images for $prefix"
    done
    return 0
  fi

  if ! command -v git >/dev/null 2>&1 || ! command -v magick >/dev/null 2>&1; then
    log_warn "git or magick missing; skipping the image pool"
    return 0
  fi

  mkdir -p -- "$images" "$bad" "$cache"
  # The scratch area is under the cache directory, not the (often tmpfs) /tmp.
  tmp="$(mktemp -d "$cache/fastfetch-images.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now on purpose
  trap "rm -rf -- '$tmp'" EXIT
  for entry in "${pending[@]}"; do
    IFS='|' read -r prefix repo commit subdir lfs <<<"$entry"
    if _fastfetch_fetch_source "$prefix" "$repo" "$commit" "$subdir" "$lfs" \
      "$images" "$bad" "$tmp"; then
      log_change "fetch images for $prefix"
    else
      log_warn "could not fetch $repo at the pinned commit $commit (gone, moved, too large or offline); skipping $prefix"
    fi
    rm -rf -- "${tmp:?}/$prefix" "${tmp:?}/stage-$prefix"
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
$_FASTFETCH_LEGACY_BODY"
  remove_exact_block "$rc" "$legacy"
  ensure_block "$rc" fastfetch "# Fastfetch with a random image as logo (kitty only)
$_FASTFETCH_BODY"
}

module_apply() {
  ensure_packages fastfetch imagemagick git git-lfs || return 1
  _fastfetch_images
  _fastfetch_block
}
