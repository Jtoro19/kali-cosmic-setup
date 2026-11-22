# clipboard

## Purpose

Keep the clipboard contents on COSMIC (Wayland) after the application that
copied them closes. By default the clipboard dies with its source app.
`MODULE_OPTIN=0`, no dependencies.

## Source of truth

eos `30-clipboard.sh`, `specs/clipboard.md` and `files/clipboard/wl-clip-persist.service`,
ported to apt. Facts checked on the Kali VM are in `odd/verified-facts.md`
(section 6: `wl-clipboard` 2.3.0-1 is in Kali, `wl-clip-persist` is not packaged
in Kali or Debian; tag v0.5.0 is commit `e26fde01c13922e3a65049dafb7d5adfbc52626e`).

## Files and packages touched

- Packages (Kali): `wl-clipboard`; for the build only, and only when a build is
  needed: `cargo`, `rustc`, `git`, `gcc`, `ca-certificates`. The crate graph of
  v0.5.0 is pure Rust (wayrs, no libwayland), so no `-dev` library is needed
  (verified: the build on the VM needed nothing else).
- `/usr/local/bin/wl-clip-persist` (0755, root-owned, system-wide like the eos
  package): built from the pinned tag.
- `/etc/environment`: one line `COSMIC_DATA_CONTROL_ENABLED=1`.
- `~/.config/systemd/user/wl-clip-persist.service` of the invoking user
  (`ExecStart=/usr/local/bin/wl-clip-persist --clipboard regular`, absolute path
  because zsh and the user manager do not share a `PATH`), enabled
  (`graphical-session.target.wants`).
- Removes a stale `~/.config/autostart/wl-clip-persist.desktop` (with a backup).
- Build artifacts live in `~/.cache/kali-cosmic-setup/src/wl-clip-persist` only
  while building; they are removed on success, failure and fail-fast exits.

## Decisions on ambiguities

1. **Build, do not install a binary.** Upstream publishes no release binary and
   no checksum, and the plan forbids unverified downloads. The module clones the
   tag (`--depth 1 --branch v0.5.0`, https only, `GIT_TERMINAL_PROMPT=0`),
   **compares `git rev-parse HEAD` with the pinned commit** and refuses to build on
   a mismatch (a moved tag), then runs `cargo build --release --locked` so that
   crate versions come from the repository's own `Cargo.lock`. Crates are
   fetched from crates.io by cargo (their checksums are in `Cargo.lock`).
2. **System-wide binary, user service.** eos installs the package system-wide and
   runs a user unit; the port keeps that split: `install -m 0755` to
   `/usr/local/bin` through sudo, unit in the user's home.
3. **Idempotency by version.** The build is skipped when
   `/usr/local/bin/wl-clip-persist --version` reports `0.5.0`; the build
   packages are then not even touched. A different version is rebuilt and the
   running service is restarted.
4. **Starting the unit.** With a reachable user manager the unit is enabled; it is
   started (or restarted when it changed) only when `graphical-session.target` is
   active, because the service needs the Wayland socket. Over SSH without a user
   manager (`systemctl --user show-environment` fails, `XDG_RUNTIME_DIR` is
   pointed at `/run/user/<uid>` first) the unit is written, nothing is enabled,
   and the module prints the one command to run after logging in.
5. **The environment line.** COSMIC's data-control protocol is gated by
   `COSMIC_DATA_CONTROL_ENABLED`; the line applies from the next login. A line
   with another value of that key is kept with a warning (never duplicated).
6. **Start only when the variable is there.** The unit is started (or restarted)
   only when `systemctl --user show-environment` contains
   `COSMIC_DATA_CONTROL_ENABLED=1`: the user manager takes the value from the
   login, so right after the module wrote the line the service would run without
   data-control and exit. Otherwise the unit is only enabled and the run says
   "log in again to start it".
7. **Security: data-control is global.** With the protocol enabled, any Wayland client
   in the session can read (and set) the clipboard, with no focus
   requirement. That is how a clipboard manager works and the price of
   persistence; the module does not hide it. Do not run this module if you want
   Wayland's focus-gated clipboard.
8. **Clone hardening and skip check.** `GIT_TERMINAL_PROMPT=0` and
   `timeout -k 10 600` (`KCS_NET_TIMEOUT` overrides, for the tests) on the
   clone. The build is skipped only when the binary reports the pinned version
   AND the marker `~/.local/state/kali-cosmic-setup/clipboard/wl-clip-persist.commit`
   holds the pinned commit (a version string alone proves nothing about the
   source); the marker is written after the install. Crates still come from
   crates.io, trusted through the pinned repository's own `Cargo.lock`.

## Hardware detection

None.

## Idempotency check

Packages and the build only when the pinned version is missing; the line only
when absent; the unit only when its bytes differ (then `daemon-reload`); enable
only when not enabled. A second run reports `total changes: 0`.

## Revert

```bash
systemctl --user disable --now wl-clip-persist.service
rm ~/.config/systemd/user/wl-clip-persist.service && systemctl --user daemon-reload
sudo rm /usr/local/bin/wl-clip-persist
sudo sed -i '/^COSMIC_DATA_CONTROL_ENABLED=1$/d' /etc/environment   # then log in again
```

## User files

The unit file and the legacy autostart entry go through the shared guard
`user_path_writable`: owned by another user means skipped with a warning (no
sudo, nothing removed); a symlinked unit is written through the link only when
the target is inside `$HOME`.

## Verification

```bash
./install.sh --only clipboard --dry-run   # nothing built
./install.sh --only clipboard             # then again: "total changes: 0"
systemctl --user is-active wl-clip-persist.service
# in the COSMIC session: copy from a short-lived process, kill it, paste
(sleep 30 | wl-copy --foreground hello &); sleep 1; pkill -x wl-copy; wl-paste   # hello
tests/test-clipboard.sh
```
