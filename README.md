# umbrel-docker

Run [Umbrel OS](https://github.com/getumbrel/umbrel) inside a plain Docker container, on any Linux box, NAS, or Mac.

## Why this is harder than it sounds

umbrelOS isn't written to be containerized, it's written to *own a machine*. It expects to read real hardware sensors, manage its own network interfaces, commit an A/B OS partition after every update, run a hypervisor with AppArmor-confined VMs, and discover itself on the LAN via mDNS from an address it can see on its own network card. None of that holds inside a container: there's no hardware to read, only an internal Docker network to see, and on macOS the container is itself running inside a Linux VM.

This repo doesn't fork umbrelOS to paper over that gap. It builds the real upstream source and applies a small, targeted set of source patches (see [`scripts/patch-umbrel.js`](scripts/patch-umbrel.js)) plus a purpose-built entrypoint and CLI, so the OS's assumptions keep holding anyway. A few examples of what that actually took:

- **The container doesn't know its own address.** Docker only ever hands it an internal IP (`172.17.x.x`), so umbrelOS's self-signed HTTPS certificate and its mDNS self-advertisement both pointed at addresses nothing outside the container could ever reach — breaking remote app connectivity and same-network device discovery. `umbrelctl` detects the host's real LAN IP (and a host-level Tailscale IP, if present) and threads both through to the container.
- **Virtual machines, inside a container.** umbrelOS's Machines feature runs VMs via libvirt/QEMU, which normally lean on AppArmor, cgroup management, and a real dockerd's firewall chains — none of which exist inside a container. Getting a VM to actually boot took a tuned `qemu.conf`, manually scaffolded nftables chains, and stripping a hardcoded AppArmor seclabel out of the VM's own domain XML.
- **The container can accidentally reach out and kill the host.** With `--pid=host` (needed for other reasons), a naive "is my daemon already running" check can match the *host's* own dbus/avahi process instead of the container's — this happens for real on NAS boxes that already run both natively.
- **There's no A/B partition to commit to.** umbrelOS's normal update flow ends by committing an OS partition and rebooting. In Docker mode that step is replaced with simply recreating the container from a new image.

The result runs the real umbrelOS UI, app store, backups, and VMs, just inside `docker run` instead of on dedicated hardware.

> [!IMPORTANT]
> This project mounts `/var/run/docker.sock` into the Umbrel container. That gives the container broad control over the host Docker daemon and is effectively root-equivalent on many systems. Only run images and refs you trust.

## How It Fits Together

```text
Host machine
  |
  |-- umbrelctl
  |-- Docker daemon
  |     |
  |     |-- umbrel container
  |     |     |-- umbreld
  |     |     |-- web UI
  |     |     |-- docker CLI -> /var/run/docker.sock
  |     |
  |     |-- Umbrel app containers
  |
  |-- ./umbrel-data      -> mounted as /data
  |-- ./umbrel-backups   -> default update backup location
```

Building the image pulls the real upstream [`getumbrel/umbrel`](https://github.com/getumbrel/umbrel) source at whatever ref you ask for, runs it through the Docker-mode patches, and compiles the result — same UI, same backend, no fork to keep in sync.

At runtime, the container mounts your data directory to `/data` and the host's Docker socket, joins a dedicated `umbrel_main_network`, and starts the handful of system services umbrelOS still genuinely needs (D-Bus, Avahi, Samba) itself, since there's no host init system to hand that off to. Umbrel's own apps still run as ordinary containers on your *host's* Docker daemon, reached through that mounted socket — the umbrel container is a control plane, not a sandbox everything else lives inside.

`umbrelctl` is the piece standing in for everything an OS installer, an OTA updater, and a systemd unit would otherwise do: it builds the image, starts and recreates the container with the right capabilities and devices, backs up and restores `/data`, and drives updates end to end — including the ones triggered from inside the Umbrel UI itself, which have nowhere else to go in Docker mode (more on that below).

## Requirements

- Docker Engine or Docker Desktop with the daemon running, and a socket at `/var/run/docker.sock`.
- Bash, `git` (for `versions`), `jq` (updates/backups/agent), `rsync` (backups/restores).
- Network access during builds to GitHub, Debian mirrors, Docker's package repo, npm, Node.js, and yq release downloads.

Run the built-in environment check before first use:

```bash
./umbrelctl check
```

If Docker is installed outside the normal `PATH` on a NAS, `umbrelctl` automatically tries TerraMaster-style Docker paths such as `/Volume1/@apps/DockerEngine/dockerd/bin/docker`.

## Quick Start

```bash
# 1. Check the host environment
./umbrelctl check

# 2. List available Umbrel versions
./umbrelctl versions --limit 10

# 3. Build and start Umbrel
./umbrelctl up --ref 1.6.1 --port 8080

# 4. Open the web UI
./umbrelctl open
```

The first build takes a while — it's downloading upstream source, installing dependencies, and building the UI and backend from scratch. Later builds reuse Docker's layer and BuildKit caches and are much faster.

Umbrel's own in-UI "Update" button can't do anything useful by itself in Docker mode — there's no OS to update, only a container to replace. Start the host agent so that button keeps working instead of silently failing:

```bash
./umbrelctl agent start --daemon
```

## Data And State

Everything that should survive a rebuild lives under a couple of host paths — none of it belongs in this repo's git history.

| Path | Purpose |
| --- | --- |
| `./umbrel-data/` | Persistent Umbrel data, mounted to `/data` in the container. |
| `./umbrel-backups/` | Default location for pre-update backup archives. |
| `./umbrel-data/.umbrel-docker/` | Update-agent requests, state, PID, and logs. |
| `.umbrelctl.conf` | Optional local defaults written by `./umbrelctl config set`. |

## Common Commands

### Check The Host

```bash
./umbrelctl check
```

Validates Docker, the Docker socket, `git`, `jq`, `rsync`, the configured data directory, the configured web UI port, and local config — run it first on any new machine.

### List Umbrel Versions

```bash
./umbrelctl versions
./umbrelctl versions --all
./umbrelctl versions --limit 10
```

Lists stable upstream release tags by default; `--all` includes prereleases and other semver-like tags.

### Build An Image

```bash
./umbrelctl build --ref 1.6.1
./umbrelctl build --ref master
./umbrelctl build --ref 1.6.1 --no-cache
./umbrelctl build --ref 1.6.1 --image my-umbrel:1.6.1
```

Both `1.6.1` and `v1.6.1` style refs work. Upstream release ranges pin different Node.js versions than what's in this repo's default; if the first build attempt fails, `umbrelctl` automatically retries with the Node versions known to match that range.

### Start Or Recreate The Container

```bash
./umbrelctl up --ref 1.6.1 --port 8080
./umbrelctl up --ref 1.6.1 --port 8080 --follow
./umbrelctl up --skip-build
./umbrelctl up --runtime-profile compat
./umbrelctl up --release-channel beta
```

`up` builds by default, replaces any existing container of the same name, and leaves `/data` untouched. The web UI is mapped from container port `80` to whatever host port you pick with `--port`/`HOST_PORT`; SMB and network-discovery ports (`139`, `445`, `3702/tcp+udp`, `5355/tcp+udp`) are fixed.

> [!NOTE]
> Because those SMB/discovery ports are fixed, only one default `umbrelctl up` instance can bind them on a host at a time. Running several instances side by side means giving each a distinct name/data dir/web port and sorting out the fixed port handling yourself first.

### Stop The Container

```bash
./umbrelctl down
./umbrelctl down --name umbrel-test
```

Removes the container. `/data` is untouched either way.

### Inspect And Debug

```bash
./umbrelctl status
./umbrelctl logs
./umbrelctl logs --tail 50
./umbrelctl logs --follow
./umbrelctl shell
```

`status` picks up any container named like `umbrel` or running an `umbrel:`-tagged image. `shell` drops you into an interactive Bash session inside the running container — useful for poking at the patched umbreld source directly.

### Update

```bash
./umbrelctl update --ref 1.6.1
./umbrelctl update --ref 1.6.1 --follow
./umbrelctl update --ref 1.6.1 --no-backup
./umbrelctl update --ref 1.6.1 --force
./umbrelctl update --image my-umbrel:custom
```

There's no OS partition to swap here — an update means backing up, then swapping the whole container:

1. Inspect the running container and capture its exact run configuration (mounts, capabilities, devices, env).
2. Back up `/data`, unless `--no-backup` is set.
3. Build or pull the target image.
4. Remove the old container, start the new one with the captured configuration re-applied.
5. Wait for it to report healthy.
6. If it doesn't, automatically roll back to the previous image.

### UI-Triggered Updates

The patched UI can't run an update itself in Docker mode — it has no way to touch the host's Docker daemon or replace its own container from the inside. So instead, clicking "Update" just drops a request file for something on the host to pick up:

```text
<data-dir>/.umbrel-docker/update-request.json
```

That something is the update agent, which watches the file and runs `./umbrelctl update` on your behalf:

```bash
./umbrelctl agent start
./umbrelctl agent start --daemon
./umbrelctl agent status
./umbrelctl agent logs --follow
./umbrelctl agent stop
```

State and logs live in `<data-dir>/.umbrel-docker/`. While it works, the agent also writes live backup progress to `update-state.json`, so the Umbrel UI can keep showing a real progress bar instead of a spinner with no idea what's happening underneath it.

### Backups

```bash
./umbrelctl backups list
./umbrelctl backups prune --keep 3
./umbrelctl backups restore 20250420-120000-umbrel-1.5.0
./umbrelctl backups restore /absolute/path/to/backup --force
```

A backup is an rsync snapshot of `/data`, then tarred up; `update` reports progress on both steps by comparing bytes copied/archived against the measured data size as it goes, rather than leaving you staring at a frozen terminal for a multi-gigabyte data directory. Restore stops the container if it's running, replaces `/data`, and starts it back up.

## Configuration

`umbrelctl` reads defaults from `.umbrelctl.conf` in the repo directory; any CLI flag overrides them for that invocation.

```bash
./umbrelctl config show
./umbrelctl config set HOST_PORT 8080
./umbrelctl config set DATA_DIR /mnt/storage/umbrel-data
./umbrelctl config set REF 1.6.1
./umbrelctl config unset HOST_PORT
```

| Key | Default | Description |
| --- | --- | --- |
| `REF` | `1.5.0` | Default Umbrel git ref for `build`, `up`, and `update`. |
| `CONTAINER_NAME` | `umbrel` | Docker container name. |
| `DATA_DIR` | `./umbrel-data` | Host path mounted to `/data`. |
| `HOST_PORT` | `80` | Host port for the web UI. |
| `STOP_TIMEOUT` | `60` | Seconds to wait when stopping the container. |
| `RUNTIME_PROFILE` | `minimal` | Runtime profile, either `minimal` or `compat`. |
| `RELEASE_CHANNEL` | `stable` | Umbrel release channel, either `stable` or `beta`. |
| `HEALTH_TIMEOUT` | `180` | Seconds to wait for a new container to become healthy during update. |
| `BACKUP_DIR` | `<data-dir>/../umbrel-backups` | Backup root directory. |
| `BACKUP_ENABLED` | `true` | Whether updates create backups by default. |
| `BACKUPS_KEEP` | `5` | Number of backups retained by `backups prune`. |

## Runtime Profiles

Every place umbrelOS assumes it's talking to real hardware, the patches have to decide what to do instead — and that decision is the `minimal`/`compat` split.

`minimal`, the default, takes the honest option: things that need hardware that genuinely isn't there report themselves as unavailable rather than pretending. Wi-Fi management stays off (the container doesn't own the host's radio), the Thunderbolt authorization monitor never starts (there's nothing to authorize), and CPU temperature reporting returns a flat "normal" instead of failing outright when it can't read a real sensor.

`compat` leaves more of that OS-level service behavior switched on, which is occasionally useful for debugging something that specifically expects a fuller environment — at the cost of reintroducing checks that assume hardware which, inside a container, still isn't there.

## Host Hardware Notes

The sensor and radio gaps above are specific enough to be worth spelling out:

- **CPU temperature** only works where a real Linux host's `/sys/class/thermal` or `/sys/class/hwmon` can be bind-mounted in read-only. Elsewhere, docker mode reports a flat "normal" rather than throwing.
- **macOS** runs Docker containers inside a Linux VM of its own, so even a bind mount can't hand the container real Mac hardware sensors — there's a layer of virtualization in the way regardless of what this repo does.
- **Wi-Fi management** is disabled outright in Docker mode, since the container never owns the host's actual network stack.

## Upgrade Matrix Tests

The patch set in `scripts/patch-umbrel.js` has to keep working across upstream releases it wasn't necessarily written against. This harness is how that gets checked without doing it by hand: it builds versions, starts containers, walks through upgrades, verifies health, and collects logs.

```bash
bash ./tests/backup-progress.sh
bash ./tests/upgrade-matrix.sh --help
bash ./tests/upgrade-matrix.sh --mode smoke
bash ./tests/upgrade-matrix.sh --mode full --min-version 1.0.0 --include-prerelease true
```

Artifacts land in `./tests/artifacts/<run-id>/`. These tests create and remove containers, images, data directories, and backups, so only run them somewhere that's fine with that.

## License

MIT. See [`license.md`](license.md).
