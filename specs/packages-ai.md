# packages-ai

## Purpose

Opt-in local LLM runtime on Kali: Ollama from its official release archives
(SHA-256 verified), the generic build by default and the ROCm build on AMD GPUs,
run by a dedicated `ollama` user as a systemd service that listens on
`127.0.0.1:11434` only. No model is pulled. `MODULE_OPTIN=1`, depends on
`packages`: `--all` skips it, `--only packages-ai` runs it after `packages`.

## Source of truth

eos `22-packages-ai.sh` (pacman: `ollama`, `ollama-rocm` on AMD, `ollama-cuda` on
NVIDIA; override `PACKAGES_AI_GPU_VENDORS`). Neither Kali nor Debian packages
Ollama, so the port uses the official release archives, as Ollama's manual
install documents (https://github.com/ollama/ollama/blob/main/docs/linux.mdx,
read 2026-11-22).

## Files and packages touched

- Packages: `zstd` (unpacks the archives), `curl`, `ca-certificates`.
- `/usr/local/bin/ollama` (0755) and `/usr/local/lib/ollama/` (the runner and
  GPU libraries; the binary finds them next to itself). Upstream's manual install
  extracts into `/usr`; the plan keeps `/usr/local` so nothing collides with
  Kali packages. Both layouts are the same relative layout (`bin/`, `lib/ollama/`).
- `/usr/local/lib/ollama/.kali-cosmic-setup`: one line `<version> <variant>`
  (generic or rocm), written after a successful install; it is how a later run
  knows whether the ROCm build is there.
- System user and group `ollama` (`useradd -r -s /usr/sbin/nologin -U -m -d
  /usr/share/ollama`); models live under `/usr/share/ollama/.ollama/models`.
- `/etc/systemd/system/ollama.service`: `User=ollama`, `ExecStart=/usr/local/bin/ollama
  serve`, `Environment="OLLAMA_HOST=127.0.0.1:11434"`, `Restart=always`,
  `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`. Enabled with `--now`.
- AMD only: the `ollama` user joins `render` and `video` (device access for
  `/dev/kfd` and `/dev/dri`, as Ollama's own install script does).
- The invoking user is not added to any group: the CLI talks to the service
  over HTTP, so no file access to `/usr/share/ollama` is needed.

## Release pin and checksums

Ollama v0.40.17 (stable, 2026-11-10). The sha256 values are the lines of the
release's own `sha256sum.txt` (and equal the GitHub asset digests):

- `ollama-linux-amd64.tar.zst` (1545470208 B)
  `1df9d6228bac5a22e420b242708c0d10e5b886db97bab99d446a41760f4e79af`
- `ollama-linux-amd64-rocm.tar.zst` (1054011284 B)
  `830e7068a16a3946edb1ee23f3ba455c9f966f9155be9934ca87f62004e20fe7`

URL: `https://github.com/ollama/ollama/releases/download/v0.40.17/<asset>`.
Updating needs a new version and both checksums in the module. Trust rests on
TLS plus the pinned hash; Ollama publishes no detached signature for the
archives. Only x86_64 is supported (the pinned archives are amd64); another
architecture fails with an error.
`PACKAGES_AI_SHA256` and `PACKAGES_AI_ROCM_SHA256` replace the pins only when
`KCS_TEST` is set (the tests serve fixtures); a real run ignores them.

## Decisions on ambiguities

- **ROCm layout (was UNRESOLVED in odd/verified-facts.md): overlay.** Upstream's
  manual install says to extract the base archive and then, on AMD, "also
  download and extract the additional ROCm package" into the same prefix. The
  module does exactly that, base first, then ROCm. The ROCm archive is 1.0 GB
  and the base 1.5 GB; the asset exists for the pinned version, so the ROCm path
  is kept. It was only exercised with fixtures: the VM has a virtio GPU and runs
  the generic build; the owner's host (RX 7900 XTX) is the real ROCm case.
- **Staging, then swap.** Archives are unpacked into `/usr/local/.ollama-stage`
  (same filesystem), checked for `bin/ollama` and `lib/ollama`, and only then
  `lib/ollama` is replaced and the binary installed, so a failed download or
  unpack leaves the previous install working. The old `lib/ollama` is removed
  first (upstream: old libraries must not mix with new ones). The replaced
  binary gets no `.bak` (reproducible release artifact, see packages-dev).
- **Downloads go to `/var/tmp`, not `/tmp`.** `/tmp` is a RAM-backed tmpfs on
  current Kali (the VM: 4 GB). The download directory is removed on success,
  failure and fail-fast exits (EXIT trap of the module).
- **Pinned version, never downgraded.** A run is a no-op when
  `/usr/local/bin/ollama --version` reports the pinned version or newer (first
  dotted number of the output; the client prints a warning line when no server
  runs) and, on AMD, the marker says rocm. An older version is replaced; a newer
  one is left alone (even if the marker says generic on an AMD host).
- **GPU selection.** `detect_gpu_vendors`: `amd` selects the ROCm overlay;
  everything else (Intel, virtio VM, no GPU) is generic. The generic archive
  bundles the CUDA runtimes, but the NVIDIA kernel driver is not installed by
  this repo: with an NVIDIA GPU the module warns and installs the generic build.
  `PACKAGES_AI_GPU_VENDORS` (set, even empty) replaces the detection, as in eos.
  A host that later gains an AMD GPU gets the ROCm overlay on the next run (the
  whole `lib/ollama` is replaced, base plus ROCm). A host that loses the GPU
  keeps the ROCm libraries (harmless).
- **Localhost only.** The unit sets `OLLAMA_HOST=127.0.0.1:11434` and no
  `OLLAMA_ORIGINS`. Verified with `ss -ltnp`: port 11434 only on 127.0.0.1.
  Ollama's default is also loopback, but the unit makes it explicit. A user
  drop-in under `ollama.service.d` could still override it; the module does not
  manage drop-ins.
- **Restart rule.** A first install starts the service with `enable --now`; an
  already running service is restarted once when the binary, the unit or the
  GPU groups changed.
- **No model is pulled**, and nothing runs `ollama pull`, `run` or `create`.
- **Dry-run** downloads nothing and creates no temp directory; it reports the
  URLs and checksums it would use.

## Hardware detection

`detect_gpu_vendors` (lspci by PCI vendor id, sysfs fallback). amd: ROCm build and
`render`/`video` membership for the service user. nvidia: warning. Anything else:
generic.

## Idempotency check

Packages only when missing; the archives only when the installed version is
older than the pin or the ROCm overlay is missing; the user when absent; the unit
file only when different (with a backup); group membership only when missing;
`enable --now` only when not enabled. A second run reports `total changes: 0`,
downloads nothing and restarts nothing.

## Revert

```bash
sudo systemctl disable --now ollama.service
sudo rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama
sudo rm -rf /usr/local/lib/ollama
sudo systemctl daemon-reload
sudo userdel ollama                 # also removes the group
sudo rm -rf /usr/share/ollama       # optional: downloaded models
```

## Verification

```bash
./install.sh --only packages-ai --dry-run      # nothing downloaded
./install.sh --only packages-ai                # then again: "total changes: 0"
ollama --version; systemctl is-active ollama
sudo ss -ltnp | grep 11434                     # 127.0.0.1:11434 only
curl -s 127.0.0.1:11434/api/version
tests/test-packages-ai.sh
```
