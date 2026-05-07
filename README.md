# umbrel-docker

Run [Umbrel OS](https://github.com/getumbrel/umbrel) in Docker, with a host-side CLI for building, starting, updating, backing up, and inspecting the container.

`umbrel-docker` builds an upstream Umbrel ref into a Docker image and runs `umbreld` inside a single container. That container mounts the host Docker socket, so Umbrel can still create and manage app containers on the host Docker daemon.

This is useful when you want an Umbrel-style environment on a Linux server, macOS machine, or NAS without flashing an OS image to dedicated hardware.

> [!IMPORTANT]
> This project mounts `/var/run/docker.sock` into the Umbrel container. That gives the container broad control over the host Docker daemon and is effectively root-equivalent on many systems. Only run images and refs you trust.

## What This Repo Provides

- A multi-stage `Dockerfile` that builds Umbrel from a git tag, branch, or commit SHA.
- `umbrelctl`, a local CLI for the full container lifecycle.
- A build-time patcher that adapts upstream Umbrel for Docker mode.
- A host-side update agent so updates initiated from the Umbrel UI can safely rebuild and replace the container.
- Backup, restore, status, log, shell, and upgrade-matrix tooling.

## How It Works

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

The Docker image pulls the upstream [`getumbrel/umbrel`](https://github.com/getumbrel/umbrel) source during the build, applies Docker-mode patches from [`scripts/patch-umbrel.js`](scripts/patch-umbrel.js), builds the UI and backend, and packages the result with the system dependencies Umbrel expects.

The runtime container:

- runs `umbreld` with `UMBREL_DOCKER_MODE=true`;
- mounts your data directory to `/data`;
- mounts the host Docker socket;
- creates and joins the `umbrel_main_network` Docker network;
- exposes the web UI and SMB/discovery ports;
- starts helper services such as D-Bus, Avahi, and Samba where needed.

## Requirements

- Docker Engine or Docker Desktop with the daemon running.
- A Docker socket at `/var/run/docker.sock`.
- Bash.
- `git`, used by `./umbrelctl versions`.
- `jq`, used by updates, backups, and the update agent.
- `rsync`, used for pre-update backups and restores.
- Network access during builds to GitHub, Debian package mirrors, Docker's package repository, npm, Node.js, and yq release downloads.

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

The first build can take a while because it downloads the upstream source, installs dependencies, builds the web UI, and creates the final runtime image.

To keep UI-triggered updates working, start the host update agent:

```bash
./umbrelctl agent start --daemon
```

## Data And State

| Path | Purpose |
| --- | --- |
| `./umbrel-data/` | Persistent Umbrel data, mounted to `/data` in the container. |
| `./umbrel-backups/` | Default location for pre-update backup archives. |
| `./umbrel-data/.umbrel-docker/` | Update-agent requests, state, PID, and logs. |
| `.umbrelctl.conf` | Optional local defaults written by `./umbrelctl config set`. |

These paths are intentionally local state and should not be committed.

## Common Commands

### Check The Host

```bash
./umbrelctl check
```

Validates Docker, the Docker socket, `git`, `jq`, `rsync`, the configured data directory, the configured web UI port, and local config.

### List Umbrel Versions

```bash
./umbrelctl versions
./umbrelctl versions --all
./umbrelctl versions --limit 10
```

By default this lists stable upstream release tags. `--all` includes prerelease and extra semver-like tags.

### Build An Image

```bash
./umbrelctl build --ref 1.6.1
./umbrelctl build --ref master
./umbrelctl build --ref 1.6.1 --no-cache
./umbrelctl build --ref 1.6.1 --image my-umbrel:1.6.1
```

Both `1.6.1` and `v1.6.1` style refs are accepted. For release refs, `umbrelctl` tries compatible Node.js versions automatically if the first build attempt fails.

### Start Or Recreate The Container

```bash
./umbrelctl up --ref 1.6.1 --port 8080
./umbrelctl up --ref 1.6.1 --port 8080 --follow
./umbrelctl up --skip-build
./umbrelctl up --runtime-profile compat
./umbrelctl up --release-channel beta
```

`up` builds by default, removes any existing container with the same name, starts the new one, and leaves the data directory intact.

The web UI is mapped from container port `80` to the host port selected with `--port` or `HOST_PORT`. The container also maps SMB/discovery ports `139`, `445`, `3702/tcp`, `3702/udp`, `5355/tcp`, and `5355/udp`.

> [!NOTE]
> Because those SMB/discovery ports are fixed in the current CLI, only one default `umbrelctl up` instance can bind them on a host at a time. If you want concurrent instances, use distinct names/data/web ports and customize the fixed SMB/discovery port handling first.

### Stop The Container

```bash
./umbrelctl down
./umbrelctl down --name umbrel-test
```

This removes the container but does not delete `./umbrel-data`.

### Inspect And Debug

```bash
./umbrelctl status
./umbrelctl logs
./umbrelctl logs --tail 50
./umbrelctl logs --follow
./umbrelctl shell
```

`status` detects containers whose name contains `umbrel` or whose image starts with `umbrel:`. `shell` opens an interactive Bash session inside the running container.

### Update

```bash
./umbrelctl update --ref 1.6.1
./umbrelctl update --ref 1.6.1 --follow
./umbrelctl update --ref 1.6.1 --no-backup
./umbrelctl update --ref 1.6.1 --force
./umbrelctl update --image my-umbrel:custom
```

The update flow:

1. Inspects the current container and captures its run configuration.
2. Creates a backup of the data directory, unless `--no-backup` is used.
3. Builds or pulls the target image.
4. Replaces the old container with the new one.
5. Waits for the new container to become healthy.
6. Rolls back to the old image automatically if health checks fail.

### UI-Triggered Updates

Umbrel normally expects OS-level update machinery. In Docker mode, the patched UI writes update requests to:

```text
<data-dir>/.umbrel-docker/update-request.json
```

The host update agent watches that file and runs `umbrelctl update` on the host:

```bash
./umbrelctl agent start
./umbrelctl agent start --daemon
./umbrelctl agent status
./umbrelctl agent logs --follow
./umbrelctl agent stop
```

The agent stores state and logs in `<data-dir>/.umbrel-docker/`. During a UI-triggered update, the host updater shows live backup progress and writes the same progress to `update-state.json` while it snapshots and archives the data directory.

### Backups

```bash
./umbrelctl backups list
./umbrelctl backups prune --keep 3
./umbrelctl backups restore 20250420-120000-umbrel-1.5.0
./umbrelctl backups restore /absolute/path/to/backup --force
```

Backups are tar archives created from an rsync snapshot of the data directory. `umbrelctl update` shows snapshot and archive progress by comparing copied/archive size against the measured data size. Restore stops the container if needed, overwrites the data directory, and restarts the container if it was previously running.

## Configuration

`umbrelctl` reads `.umbrelctl.conf` from the repo directory. CLI flags override config values.

```bash
./umbrelctl config show
./umbrelctl config set HOST_PORT 8080
./umbrelctl config set DATA_DIR /mnt/storage/umbrel-data
./umbrelctl config set REF 1.6.1
./umbrelctl config unset HOST_PORT
```

Supported keys:

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

`minimal` is the default Docker-oriented profile. It skips or adapts OS-specific services that do not map cleanly to a containerized runtime.

`compat` leaves more system-service behavior enabled and can be useful when debugging features that expect a fuller OS environment.

## Host Hardware Notes

- CPU temperature works best on Linux hosts where `/sys/class/thermal` or `/sys/class/hwmon` can be bind-mounted read-only.
- macOS runs Docker containers inside a Linux VM, so the container cannot read the Mac's real hardware sensors through normal Linux sysfs paths.
- Wi-Fi management is disabled in Docker mode because the container is not managing the host network stack.

## Upgrade Matrix Tests

The test harness can build versions, start containers, perform upgrades, verify health, and collect logs:

```bash
bash ./tests/backup-progress.sh
bash ./tests/upgrade-matrix.sh --help
bash ./tests/upgrade-matrix.sh --mode smoke
bash ./tests/upgrade-matrix.sh --mode full --min-version 1.0.0 --include-prerelease true
```

Artifacts are written to `./tests/artifacts/<run-id>/`. These tests can create and remove containers, images, data directories, and backups, so run them on a machine where that is acceptable.

## Troubleshooting

### Docker Socket Missing

`umbrelctl` and the container expect `/var/run/docker.sock`.

```bash
docker info
ls -l /var/run/docker.sock
```

If your Docker installation uses a different socket path, update the script or provide a compatible socket at that location.

### Port Already In Use

Use a different web UI port:

```bash
./umbrelctl up --ref 1.6.1 --port 8080
```

If startup fails on `139`, `445`, `3702`, or `5355`, another service is already using SMB or discovery ports on the host.

### UI Update Appears Stuck

Make sure the host update agent is running:

```bash
./umbrelctl agent status
./umbrelctl agent logs --follow
```

You can also run the update manually:

```bash
./umbrelctl update --ref <version>
```

### Build Fails For A Version

Try the ref with and without a leading `v`, or use `./umbrelctl versions --all` to confirm the tag exists. The build command already retries several Node.js versions for known release ranges.

```bash
./umbrelctl build --ref 1.6.1 --no-cache --pull
```

### Data Directory Permission Problems

Make sure the configured data directory exists and is writable by the user running `umbrelctl`:

```bash
./umbrelctl config show
./umbrelctl check
```

## Repo Layout

| Path | Purpose |
| --- | --- |
| [`Dockerfile`](Dockerfile) | Multi-stage image build for Umbrel. |
| [`entry.sh`](entry.sh) | Container entrypoint that prepares Docker networking, `/data`, discovery services, and `umbreld`. |
| [`umbrelctl`](umbrelctl) | Main host-side CLI. |
| [`scripts/patch-umbrel.js`](scripts/patch-umbrel.js) | Build-time patches applied to upstream Umbrel source. |
| [`scripts/umbrel-update-agent.sh`](scripts/umbrel-update-agent.sh) | Host daemon for UI-triggered updates. |
| [`tests/backup-progress.sh`](tests/backup-progress.sh) | Focused backup progress/state-file test. |
| [`tests/upgrade-matrix.sh`](tests/upgrade-matrix.sh) | End-to-end upgrade matrix runner. |

## License

MIT. See [`license.md`](license.md).
