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
- `~/.config/fastfetch/bad/`: images that failed `magick identify` (never deleted).
- A managed block `fastfetch` in the rc file of the login shell (`~/.zshrc` for
  zsh, `~/.bashrc` for bash; another shell gets a warning and no block). The
  legacy unmanaged copy of the snippet (the same lines without the "(kitty only)"
  suffix) is removed first from the same file. The block body is valid bash and zsh.
- No services or units.

### Image sources

All repos are cloned shallow (`--depth 1`) with `GIT_TERMINAL_PROMPT=0` into a
`mktemp -d` directory under `${TMPDIR:-/tmp}`, removed on exit.

| Prefix | Repo | Notes |
|--------|------|-------|
| `ronin` | Ronin-CK/fastfetchPNG-images | branch `master`, root |
| `thunder` | Thunder-Blaze/FastfetchPngs | root |
| `menhoudj` | menhoudj/my-fastfetch-config | `logos/` |
| `themes` | CheikhNaro/ffthemes | root |
| `mahe` | Maheswara660/fastfetch | `images/`, Git LFS (`git lfs pull`) |
| `sofija` | sofijacom/dotfiles-fastfetch | `png/` |

`*.png`, `*.jpg`, `*.jpeg`, `*.webp` (any case) are copied with
`cp --update=none`, excluding `*/.git/*` and `loli*`. New files are resized with
`magick mogrify -resize '600x600>'` and validated with `magick identify`; invalid
ones go to `bad/`. A source is done once any `<prefix>-*` file exists in `images`
or `bad`, so a second run clones nothing.

## Decisions on ambiguities

1. **Follow eos, fetch at run time.** The pool comes from third-party repos that
   this project does not control (they mix anime art, logos and game characters);
   it is fetched into the user's home only, never committed, and a gone or
   offline repo only warns (the module still succeeds). `FASTFETCH_SKIP_IMAGES=1`
   skips the pool.
2. **`--kitty` is still valid** in fastfetch 2.69 (verified), so the block keeps
   `fastfetch --kitty "$img" --logo-width 20`; with an empty pool it runs plain
   `fastfetch`.
3. **rc file by login shell** (see specs/kitty.md decision 4). The managed block
   goes after the kitty module's block in the same file.
4. **Third-party content.** Files named `loli*` are excluded; review the folder and
   delete what you do not want (a deleted source with no files left is fetched
   again on the next run: keep at least one file per prefix, or set
   `FASTFETCH_SKIP_IMAGES=1`).

## Hardware detection

None.

## Idempotency check

Packages when missing; a source only when no `<prefix>-*` file exists; the block
only when its text differs. A second run reports `total changes: 0`.

## Revert

Remove the `fastfetch` block from the rc file (or restore its backup),
`rm -r ~/.config/fastfetch/images ~/.config/fastfetch/bad`,
`sudo apt-get purge fastfetch`.

## Verification

```bash
./install.sh --only fastfetch --dry-run
./install.sh --only fastfetch            # then again: "total changes: 0"
fd . ~/.config/fastfetch/images | wc -l
# open kitty: fastfetch shows a random image as the logo
tests/test-fastfetch.sh
```
