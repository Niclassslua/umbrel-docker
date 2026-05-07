#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UMBRELCTL="${REPO_DIR}/umbrelctl"

err() { printf "ERROR: %s\n" "$*" >&2; }

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Missing required command: ${cmd}"
    exit 1
  fi
}

require_cmd jq
require_cmd rsync

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

DATA_DIR="${WORKDIR}/umbrel-data"
BACKUP_DIR="${WORKDIR}/umbrel-backups"
STATE_FILE="${DATA_DIR}/.umbrel-docker/update-state.json"

mkdir -p "${DATA_DIR}/subdir" "${DATA_DIR}/.umbrel-docker"
printf "hello\n" >"${DATA_DIR}/subdir/file.txt"
dd if=/dev/zero of="${DATA_DIR}/subdir/blob.bin" bs=1024 count=512 >/dev/null 2>&1

# Source functions without running main.
source <(sed '$d' "${UMBRELCTL}")

DATA_DIR="${WORKDIR}/umbrel-data"
BACKUP_DIR="${WORKDIR}/umbrel-backups"
BACKUP_ENABLED="true"
OLD_IMAGE="umbrel:1.5.0"
UMBREL_UPDATE_STATE_FILE="${STATE_FILE}"
UMBREL_UPDATE_VERSION="1.6.1"
UMBREL_UPDATE_CHANNEL="stable"
OUTPUT_FILE="${WORKDIR}/backup-output.txt"

backup_data_dir >"${OUTPUT_FILE}"

grep -Eq '^==> Creating backup snapshot: [0-9]+%$' "${OUTPUT_FILE}"
grep -Fx '==> Creating backup snapshot: 100%' "${OUTPUT_FILE}" >/dev/null
grep -Eq '^==> Creating backup archive: [0-9]+%$' "${OUTPUT_FILE}"
grep -Fx '==> Creating backup archive: 100%' "${OUTPUT_FILE}" >/dev/null

if [[ ! -s "${STATE_FILE}" ]]; then
  err "Expected backup progress state file at ${STATE_FILE}"
  exit 1
fi

jq -e '
  .running == true
  and .progress == 45
  and .description == "Backup created"
  and .error == false
  and .version == "1.6.1"
  and .channel == "stable"
' "${STATE_FILE}" >/dev/null

archive="$(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -name umbrel-data.tar -print | head -n1)"
if [[ -z "${archive}" || ! -s "${archive}" ]]; then
  err "Expected backup archive to be created"
  exit 1
fi

if tar -tf "${archive}" | grep -Fx 'umbrel-data/.umbrel-docker/update-state.json' >/dev/null; then
  err "Transient update-state.json should not be included in backup archive"
  exit 1
fi

printf "backup progress test passed\n"
