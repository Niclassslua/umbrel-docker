#!/usr/bin/env bash
set -Eeuo pipefail

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR

[ ! -f "/run/entry.sh" ] && error "Script must run inside Docker container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

echo "❯ Starting umbrelOS for Docker $(</run/version)..."
echo "❯ For support visit https://github.com/dockur/umbrel/issues"

if [ ! -S /var/run/docker.sock ]; then
  error "Docker socket is missing? Please bind /var/run/docker.sock in your compose file." && exit 13
fi

net="umbrel_main_network"
docker network rm "$net" &>/dev/null || true

if ! docker network inspect "$net" &>/dev/null; then
  if ! docker network create --driver=bridge --subnet="10.21.0.0/16" "$net" >/dev/null; then
    error "Failed to create network '$net'!" && exit 14
  fi
  if ! docker network inspect "$net" &>/dev/null; then
    error "Network '$net' does not exist?" && exit 15
  fi
fi

target=$(hostname -s)

if ! docker inspect "$target" &>/dev/null; then
  error "Failed to find a container with name: '$target'!" && exit 16
fi

resp=$(docker inspect "$target")
network=$(echo "$resp" | jq -r '.[0].NetworkSettings.Networks["umbrel_main_network"]')

if [ -z "$network" ] || [[ "$network" == "null" ]]; then
  if ! docker network connect "$net" "$target"; then
    error "Failed to connect container to network '$net'!" && exit 17
  fi
fi

mount=$(echo "$resp" | jq -r '.[0].Mounts[] | select(.Destination == "/data").Source')

if [ -z "$mount" ] || [[ "$mount" == "null" ]] || [ ! -d "/data" ]; then
  error "You did not bind the /data folder!" && exit 18
fi

# Convert Windows paths to Linux path
if [[ "$mount" == *":\\"* ]]; then
  mount="${mount,,}"
  mount="${mount//\\//}"
  mount="//${mount/:/}"
fi

if [[ "$mount" != "/"* ]]; then
  error "Please bind the /data folder to an absolute path!" && exit 19
fi

# Mirror external folder to local filesystem
if [[ "$mount" != "/data" ]]; then
  mkdir -p "$mount"
  rm -rf "$mount"
  ln -s /data "$mount"
fi

# Create directories
mkdir -p "/images"
mkdir -p "$mount/tor/data"
mkdir -p /run/avahi-daemon /var/log/samba /run/samba
chmod 700 "$mount/tor/data"
chmod -R 700 "$mount/tor/data/*" &>/dev/null || true

# Enable mDNS discovery used by umbreld's SMB network scan.
mkdir -p /run/dbus
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
  rm -f /run/dbus/pid /run/dbus/system_bus_socket
  dbus-daemon --system --fork || warn "Failed to start dbus-daemon"
fi
if ! pgrep -x avahi-daemon >/dev/null 2>&1; then
  rm -f /run/avahi-daemon/pid
  avahi-daemon -D || warn "Failed to start avahi-daemon"
fi

# Build deterministic IPv4 host mappings for SMB mDNS targets so smbclient
# does not pick unusable link-local addresses.
if command -v avahi-browse >/dev/null 2>&1; then
  while IFS=';' read -r event _iface proto _name _service _domain mdnsHost address _port _rest; do
    [ "$event" = "=" ] || continue
    [ "$proto" = "IPv4" ] || continue
    [ -n "${mdnsHost:-}" ] || continue
    [ -n "${address:-}" ] || continue
    [[ "$mdnsHost" == *.local ]] || continue

    escapedHost="${mdnsHost//./\\.}"
    sed -i "/[[:space:]]${escapedHost}\$/d" /etc/hosts
    printf '%s %s\n' "$address" "$mdnsHost" >> /etc/hosts
  done < <(timeout 5 avahi-browse --resolve --terminate _smb._tcp --parsable 2>/dev/null || true)
fi

trap - ERR
cd /opt/umbreld

export UMBREL_DOCKER_MODE="true"
export UMBREL_RUNTIME_PROFILE="${UMBREL_RUNTIME_PROFILE:-minimal}"
export UMBREL_DATA_DIR="$mount"
exec ./umbreld --data-directory "$mount" --log-level normal
