# packages-dev

## Purpose

Opt-in development tools on Kali: toolchains and Docker from Kali, VS Code and
Claude Code from their vendors' signed apt repos, uv, engram and gentle-ai from
checksum-verified GitHub releases. Enables Docker (unix socket only) and MariaDB
(127.0.0.1 only). `MODULE_OPTIN=1`, depends on `packages`: `--all` skips it,
`--only packages-dev` runs it after `packages`.

## Source of truth

The eos `dev.pacman` and `dev.aur` lists and its services step. The Kali port is
the data file `files/packages/dev.apt` (one package per line, `#` comments, read
by `install_package_list dev`); the vendor and release steps are code in
`modules/16-packages-dev.sh` because they need a key, a pin or a checksum.

## Files and packages touched

- Packages: the list below, plus `gnupg curl ca-certificates` (already there
  from `packages`), `code` and `claude-code`.
- `/etc/apt/keyrings/packages.microsoft.gpg`, `/etc/apt/sources.list.d/vscode.sources`
  (deb822, `Signed-By` that key, suite `stable`, component `main`),
  `/etc/apt/preferences.d/vscode`.
- `/etc/apt/keyrings/claude-code.gpg`, `/etc/apt/sources.list.d/claude-code.sources`,
  `/etc/apt/preferences.d/claude-code`.
- Each pin file has two records: the first allows only the one package
  (`code`, `claude-code`) from the vendor host (priority 500), the second blocks
  every other package of that host (priority -1). The repos can never replace a
  Kali package.
- debconf answer `code code/add-microsoft-repo = false`.
- `/usr/local/bin/{uv,uvx,engram,gentle-ai}` (mode 0755).
- `/etc/mysql/mariadb.conf.d/99-kali-cosmic-localhost.cnf`.
- Units enabled with `--now`: `mariadb.service`, `docker.service`. The
  invoking user is added to the `docker` and `plugdev` groups.
- Kali tools are not touched; packages already installed are skipped.
- Order: dev list, vendor repos (one `apt-get update`), `code` and `claude-code`,
  release binaries, MariaDB drop-in and units, groups. A failure in a later step
  leaves the earlier ones installed; the next run continues.

## What the module installs

`files/packages/dev.apt` (21 entries): `build-essential`, `git`, `golang-go`,
`rustc`, `cargo`, `just`, `python3`, `python3-venv`, `python3-pip`, `python3-pil`,
`python3-pyqt5`, `python3-reportlab`, `docker.io`, `docker-buildx`,
`docker-compose`, `mariadb-server`, `meld`, `shellcheck`, `adb`, `fastboot`,
`android-udev-rules`. Vendor: VS Code (`code`), Claude Code (`claude-code`).
Releases: uv 0.13.9, engram 3.7.2, gentle-ai 4.6.0.

## Package mapping (eos to Kali)

| eos | Kali | note |
|-----|------|------|
| `base-devel` | `build-essential` | |
| `git`, `just`, `meld`, `shellcheck` | same | checked with `apt-cache policy` |
| `go` | `golang-go` | |
| `rust` | `rustc` `cargo` | |
| `python` | `python3 python3-venv python3-pip` | `python3` ships with Kali |
| `python-pillow`, `python-pyqt5`, `python-reportlab` | `python3-pil`, `python3-pyqt5`, `python3-reportlab` | `python3-pyqt5` pulls the Qt5 stack (large), kept as in eos |
| `docker`, `docker-buildx` | `docker.io`, `docker-buildx` | |
| `docker-compose` | `docker-compose` | Kali's 2.40.3 is Compose v2 and ships the `docker compose` plugin (`/usr/libexec/docker/cli-plugins/docker-compose`, symlinked as `docker-compose`); `docker-compose-v2` does not exist on Kali |
| `mariadb` | `mariadb-server` | Debian's postinst initializes the datadir: eos's `mariadb-install-db` step is dropped |
| `android-tools` | `adb` `fastboot` | |
| `android-udev` | `android-udev-rules` | its rules use group `plugdev` (below) |
| `uv` | GitHub release | not in Kali |
| `visual-studio-code-bin` (AUR) | `code` from the Microsoft repo | |
| `claude-code` (AUR) | `claude-code` from Anthropic's repo | |
| `engram-bin`, `gentle-ai` (AUR) | GitHub releases | |

## Decisions and ambiguities

- **VS Code repo.** Official Debian instructions at
  https://code.visualstudio.com/docs/setup/linux: key
  `https://packages.microsoft.com/keys/microsoft.asc`, repo
  `https://packages.microsoft.com/repos/code`, suite `stable`, component `main`.
  The docs publish no fingerprint. The downloaded key (`gpg --show-keys`,
  2026-11-22) is the single key `BC528686B50D79E339D3721CEB3E94ADBE1229CF`
  ("Microsoft (Release signing)"), the value the module pins; `apt_install_key`
  refuses any other. This is trust on first observation, not an official
  publication, the same status as the Brave key. The docs place the key in
  `/usr/share/keyrings/microsoft.gpg` with no pin; the module uses
  `/etc/apt/keyrings/` with a pin as BRIEF requires.
- **The code deb must not add its own repo.** Its postinst writes
  `vscode.sources` and a keyring unless debconf says `false`. The module
  preseeds `code code/add-microsoft-repo boolean false` with
  `debconf-set-selections` before every install or upgrade (skipped when
  `debconf-show code` already says false). Verified on the VM: after
  installing `code` the only new apt files are our own `vscode.sources` and
  `claude-code.sources`; `/etc/apt/trusted.gpg.d` and `/usr/share/keyrings` gained
  nothing, and `apt-cache policy code` shows the Microsoft origin at 500. As a
  safety net (the Brave case, see `specs/packages.md`) the module removes
  `/etc/apt/trusted.gpg.d/microsoft.gpg` if a future deb creates it (global
  trust, wider than `Signed-By` plus the pin). A keyring left in
  `/usr/share/keyrings` is inert and may serve other Microsoft repos: not touched.
- **Claude Code: Anthropic's signed apt repo.** The official documentation
  (https://code.claude.com/docs/en/setup, the former docs.anthropic.com page
  redirects there) lists three ways: the native installer
  `curl -fsSL https://claude.ai/install.sh | bash` (its headline method), the
  package managers (an apt repo among them) and npm. Decision by the
  orchestrator: use the signed apt repo, because the native installer pipes a
  script into a shell and cannot be verified by signature or checksum before it
  runs (BRIEF: third-party apt repos need a fingerprint-verified key and a pin;
  nothing unverified is executed). Repo from the docs:
  `https://downloads.claude.ai/claude-code/apt/stable`, suite `stable`,
  component `main`, key `https://downloads.claude.ai/keys/claude-code.asc`,
  fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` (printed in the docs
  and identical to the downloaded key: "Anthropic Claude Code Release Signing").
  The docs install the armored key as-is and use `signed-by` on a `.list`
  line; the module dearmors it into `/etc/apt/keyrings/claude-code.gpg` and
  writes a deb822 file like the other vendors. The `stable` channel (not
  `latest`) is the one the docs show first. Package `claude-code` installs
  `/usr/bin/claude` and does nothing else; verified on the VM: `claude
  --version` prints `2.1.323 (Claude Code)`. Nothing needing a login, an API
  key or any secret was run. A package-manager install does not auto-update:
  `apt upgrade` does it (Anthropic's note).
- **uv, engram, gentle-ai: system scope.** eos installs them as system packages;
  the Kali port installs to `/usr/local/bin` (root-owned, on every user's PATH),
  not per user. Versions and checksums are pinned in the module. Each archive
  was downloaded and its SHA-256 compared with the release's own checksum file
  and with the digest GitHub computes for the asset (they agree):
  uv 0.13.9 `uv-x86_64-unknown-linux-gnu.tar.gz`
  `a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5`
  (members `uv-x86_64-unknown-linux-gnu/uv` and `/uvx`); engram 3.7.2
  `engram_3.7.2_linux_amd64.tar.gz`
  `8db9d5db1c1574b8b830aac4ffbe86c024014aed6b9a3f0406ac3361a152cdf0` (member
  `engram`); gentle-ai 4.6.0 `gentle-ai_4.6.0_linux_amd64.tar.gz`
  `c645e8551f6e3f79831b142a6b087795dc3217e02e9dafb5b701dc4373b33e7d` (member
  `gentle-ai`). All three are stable (non-prerelease) latest releases.
  **Accepted risk**: gentle-ai also publishes `checksums.txt.minisig` but its
  minisign public key was not found, so its signature is not verified; the
  SHA-256 comes from the same GitHub release as the archive. engram and uv
  publish no signature at all. In every case trust rests on the GitHub release
  of the named project (TLS plus the pinned hash). Updating needs a new
  version, URL and checksum in the module.
- **Release idempotency.** Each tool is skipped when `/usr/local/bin/<tool>
  --version` reports the pinned version or a newer one (`dpkg
  --compare-versions ... ge`) and every binary exists, so a newer one is never
  downgraded; an older one is upgraded (the replaced binary is backed up as
  `.bak.<timestamp>`). The archive is verified by `download_verified`, again
  right before it is unpacked, and only the named members are extracted
  (`tar --no-same-owner`).
- **Test-only override**: `PACKAGES_DEV_UV_SHA256`, `PACKAGES_DEV_ENGRAM_SHA256`
  and `PACKAGES_DEV_GENTLE_AI_SHA256` replace the pinned checksums only when
  `KCS_TEST` is set (the tests serve fixtures); a real run ignores them.
- **Docker: unix socket only.** `docker.service` is enabled with `--now`. It
  runs `dockerd -H fd://` (the socket unit); the module writes no `daemon.json`
  and no `tcp://` host. Verified with `ss -ltnp`: the only listeners after the
  run are sshd (22, as before), `mariadbd` 127.0.0.1:3306 and `containerd`
  127.0.0.1:46851 (containerd's own loopback port, not reachable from the
  network). Docker also creates the `docker0` bridge and enables IP forwarding
  for containers; that is Docker's normal behavior, not a listener.
- **docker group is root-equivalent.** Anyone in `docker` can start a
  privileged container and read or write any file as root. The module adds the
  invoking user (opt-in module, the user asked for Docker); the membership takes
  effect after the next login. Remove it with `sudo gpasswd -d $USER docker`.
- **plugdev, not adbusers.** eos adds the user to `adbusers`. Kali's
  `android-udev-rules` (`/usr/lib/udev/rules.d/51-android.rules`) uses
  `GROUP="plugdev"` plus `TAG+="uaccess"` and no `adbusers` group exists, so the
  module ensures `plugdev` (already common on Kali; skipped when present).
- **MariaDB on localhost.** Debian's `50-server.cnf` already sets
  `bind-address = 127.0.0.1`; the module enforces it with a drop-in
  `99-kali-cosmic-localhost.cnf` (`[mysqld]`, `bind-address = 127.0.0.1`), read
  after `50-server.cnf`, so a later edit of the stock file cannot open the port.
  The drop-in is written before the unit is enabled. An already running server
  is restarted once when the drop-in is first written; otherwise it is only
  started by `enable --now`. Verified: `ss -ltnp` shows
  `127.0.0.1:3306` only and `select @@bind_address` returns `127.0.0.1`.
  `mariadb-server` was already installed on the VM, disabled.
- **Group changes and sessions.** The module never logs anything out; the
  `docker` and `plugdev` memberships need a new login.
- **Locale and downloads**: parsers run under `LC_ALL=C`; downloads use the
  helpers' `curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout
  15 --max-time 600 --retry 2`.
- **Dropped eos entries**: none beyond renames; the other eos package groups
  (gaming, media, office, printing, vmware) are outside this module.

## Hardware detection

None.

## Idempotency check

Packages install only when `dpkg-query` says they are missing; keys are not
downloaded when the keyring already holds the pinned fingerprint; sources, pins
and the drop-in are rewritten only when different (with a backup); the debconf
answer is set only when `debconf-show` does not already say false; release
binaries are skipped at the pinned version or newer; units are enabled only
when not enabled; group membership only when missing. A second run reports
`total changes: 0` and runs no `apt-get`, no download and no `systemctl` change.
`apt-get update` runs when a repo, key or pin changed or `code` or `claude-code`
has no candidate.

## Revert

```bash
sudo systemctl disable --now docker.service docker.socket mariadb.service
sudo gpasswd -d "$USER" docker
sudo apt-get purge code claude-code docker.io docker-buildx docker-compose mariadb-server
sudo apt-get autoremove          # review the list first
sudo rm -f /etc/apt/sources.list.d/vscode.sources /etc/apt/preferences.d/vscode \
  /etc/apt/keyrings/packages.microsoft.gpg \
  /etc/apt/sources.list.d/claude-code.sources /etc/apt/preferences.d/claude-code \
  /etc/apt/keyrings/claude-code.gpg \
  /etc/mysql/mariadb.conf.d/99-kali-cosmic-localhost.cnf \
  /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/engram /usr/local/bin/gentle-ai
echo "code code/add-microsoft-repo boolean true" | sudo debconf-set-selections   # optional: restore the deb's default
sudo apt-get update
# the other list entries (golang-go, rustc, cargo, python3-*, adb, ...): purge any you do not want
```

Data stays: `/var/lib/docker` and `/var/lib/mysql` are not removed by purge
(`apt-get purge` of mariadb-server may ask; back up first). Backups of replaced
files are `<file>.bak.<timestamp>` next to them.

## Verification

```bash
./install.sh --only packages-dev            # then again: "total changes: 0"
code --version; claude --version; uv --version; engram version; gentle-ai --version
docker --version; docker compose version
sudo docker run --rm hello-world            # needs network; "Hello from Docker!"
ss -ltnp                                    # 3306 only on 127.0.0.1; nothing new on 0.0.0.0 or ::
sudo mariadb -e 'select @@bind_address'     # 127.0.0.1
apt-cache policy code claude-code           # candidates from the vendor repos at 500
ls /etc/apt/sources.list.d /etc/apt/trusted.gpg.d   # no microsoft.gpg, only our .sources files
systemctl --failed
./install.sh --only packages-dev --dry-run  # "Nothing to change"
tests/test-packages-dev.sh
```
