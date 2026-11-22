# fastfetch

## Purpose

Show fastfetch with a random image as the logo every time a kitty terminal
opens, and build the pool of images it picks from. `MODULE_OPTIN=0`,
`MODULE_DEPS="kitty"` (the block only acts when `$TERM == xterm-kitty`).

## Source of truth

eos `45-fastfetch.sh` and `specs/fastfetch.md`, ported to apt. No payload files:
the images are fetched at run time into the user's home. Nothing from the
reference machine's `~/.config/fastfetch` and no image is committed here
(`tests/test-fastfetch.sh` checks that `files/` holds no image).
Facts checked on the VM are in `odd/verified-facts.md` section 7: fastfetch
2.69.0 from Kali still accepts `--kitty <path>` (short for `--logo-type kitty
--logo <path>`) and `--logo-width <num>`; `magick` (ImageMagick 7) exists.

## Files and packages touched

- Packages (Kali): `fastfetch`, `imagemagick`, `git`, `git-lfs`.
- `~/.config/fastfetch/images/`: image pool, files named `<prefix>-<basename>`.
- `~/.config/fastfetch/bad/`: images that failed validation (never deleted).
- `~/.local/state/kali-cosmic-setup/fastfetch/<prefix>.commit`: per-source done markers.
- A managed block `fastfetch` in the rc file of the login shell (`~/.zshrc` for
  zsh, `~/.bashrc` for bash; another shell gets a warning and no block). The
  legacy unmanaged copy of the snippet (the same lines without the "(kitty only)"
  suffix) is removed first from the same file. The block body is valid bash and zsh.
- No services or units.

### Image sources and trust model

The pool comes from six third-party GitHub repositories that this project does
not control. The trust model is therefore explicit:

- **Pinned.** Every source is fetched by a commit sha (`git init`, `remote add`,
  `fetch --depth 1 origin <sha>`, `checkout FETCH_HEAD`) and `git rev-parse HEAD`
  must equal the pin. A source whose pin cannot be fetched (the repository is
  gone, the commit was removed) or does not check out warns and is skipped; the
  other sources and the rest of the module are unaffected, and the skipped source
  is retried on the next run (not counted as a change).
- **Not trusted as code or as images.** Nothing from a repository is executed.
  Candidate files are decoded by ImageMagick forced to the format of the
  extension (`PNG:`, `JPEG:`, `WEBP:` prefixes, so the content is never guessed
  and a `.png` that is not a PNG is rejected), first frame only (`[0]`), under
  `-limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit time 60` and
  `timeout -k 5 90`, and re-encoded (shrunk to at most 600x600) into a staging
  directory. Metadata and trailing data do not survive. Files that fail go to
  `~/.config/fastfetch/bad` and are never used.
- **Bounded.** `timeout -k 10 300` on `git fetch` and `git lfs pull`
  (`KCS_NET_TIMEOUT`); a checkout larger than 512 MiB
  (`FASTFETCH_MAX_SOURCE_KB`), more than 400 candidate images per source
  (`FASTFETCH_MAX_FILES`) or a file larger than 5 MiB (`FASTFETCH_MAX_FILE_BYTES`)
  is skipped or ignored with a warning. The fetch size itself is only bounded by
  the timeout (git offers no portable cap on a by-sha shallow fetch).
- **Scratch area** under `${XDG_CACHE_HOME:-~/.cache}/kali-cosmic-setup`, never
  the (often tmpfs) `/tmp`; removed on exit.
- **Staged, then moved.** Validated files are copied into
  `~/.config/fastfetch/.incoming-<prefix>` (same filesystem as the pool) and
  renamed into `images/` one by one (`mv -n`: an existing file is never
  overwritten); the per-source marker
  `~/.local/state/kali-cosmic-setup/fastfetch/<prefix>.commit`, holding the pinned
  commit, is written last. An interrupted run has no marker, so the next run
  repeats that source: files already in the pool are kept, the rest is added and
  leftovers of the staging directory are removed.

| Prefix | Repo | Pinned commit | Notes |
|--------|------|---------------|-------|
| `ronin` | Ronin-CK/fastfetchPNG-images | `fb4d6bb8fae85c99cb113afabcb711efe83d39c5` | head of `master`, root |
| `thunder` | Thunder-Blaze/FastfetchPngs | `2619f112c2d7fc1514f098b6a9fc16fe20ff5124` | root |
| `menhoudj` | menhoudj/my-fastfetch-config | `ce85cb63c7d89653accff5ab8535dca65aa4d0b5` | `logos/` |
| `themes` | CheikhNaro/ffthemes | `f154ff8f9447fb6876c1b60e4b6023d6b16c53c9` | root |
| `mahe` | Maheswara660/fastfetch | `2df4f8b517ae2dae11d350cac146fc4c65d88540` | `images/`, Git LFS (`git lfs pull`; a failed pull leaves no marker so it is retried) |
| `sofija` | sofijacom/dotfiles-fastfetch | `9a661c2602f8f3eba92632a855a29147b308451b` | `png/` |

The pins are the heads on 2026-11-22 (`git ls-remote`). `*.png`, `*.jpg`,
`*.jpeg`, `*.webp` (any case) are considered, excluding `*/.git/*` and `loli*`;
the pool file is `<prefix>-<name>` with unusual characters replaced by `_`.
Moving a pin fetches that source again and adds only the new images.

## Decisions on ambiguities

1. **Follow eos, fetch at run time, but pinned.** The pool is fetched into the
   user's home only, never committed. eos cloned the moving default branch; the
   port pins each source (see the trust model) so a repository takeover or a
   force-push cannot change what is decoded on your machine without a change to
   this repository. A gone or offline repo only warns (the module succeeds).
   `FASTFETCH_SKIP_IMAGES=1` skips the pool.
2. **`--kitty` is still valid** in fastfetch 2.69 (verified), so the block keeps
   `fastfetch --kitty "$img" --logo-width 20`; with an empty pool it runs plain
   `fastfetch`. The block ends with `unset img`, so the variable does not leak
   into the interactive shell.
3. **rc file by login shell** (see specs/kitty.md decision 4). The managed block
   goes after the kitty module's block in the same file. The legacy unmanaged
   snippet (without `unset img`) is still recognised and removed.
4. **Third-party content.** Files named `loli*` are excluded; review the folder and
   delete what you do not want. A source is complete once its marker holds the
   pinned commit, so images you delete are not fetched again (until the pin
   moves).

## Hardware detection

None.

## User files

The image pool directories and the rc file go through the shared guard
`user_path_writable` (lib/common.sh): a directory or file owned by another user
is skipped with a warning (the pool is not fetched; never a write through sudo),
and a symlink is followed only when its target is inside `$HOME` (an `images`
link pointing elsewhere is not filled).

## Idempotency check

Packages when missing; a source only when its marker does not hold the pinned
commit; the block only when its text differs. A second run reports `total changes: 0`.

## Revert

Remove the `fastfetch` block from the rc file. To get the legacy unmanaged
snippet back, restore the rc file from the `.bak.<timestamp>` made when the
module removed it. `rm -r ~/.config/fastfetch/images ~/.config/fastfetch/bad
~/.local/state/kali-cosmic-setup/fastfetch`,
`sudo apt-get purge fastfetch imagemagick git-lfs` (only if nothing else needs
them; `git` is kept).

## Verification

```bash
./install.sh --only fastfetch --dry-run
./install.sh --only fastfetch            # then again: "total changes: 0"
fd . ~/.config/fastfetch/images | wc -l
# open kitty: fastfetch shows a random image as the logo
tests/test-fastfetch.sh
```
