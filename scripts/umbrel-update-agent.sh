#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UMBRELCTL="${REPO_DIR}/umbrelctl"

CONTAINER_NAME="umbrel"
DATA_DIR="${REPO_DIR}/umbrel-data"
POLL_INTERVAL="3"
ONCE="false"
DAEMON="false"
LOG_FILE=""

REQUEST_DIR=""
REQUEST_FILE=""
ACTIVE_FILE=""
STATE_FILE=""
PID_FILE=""

info() { printf "==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
err() { printf "ERROR: %s\n" "$*" >&2; }

usage() {
  cat <<'EOF'
umbrel-update-agent.sh - host-side updater for umbrelOS UI update requests in Docker mode

Usage:
  bash ./scripts/umbrel-update-agent.sh [options]

Options:
  --name <container>            Container name (default: umbrel)
  --data-dir <path>             Data directory mounted into /data (default: ./umbrel-data)
  --poll-interval <sec>         Poll interval in seconds (default: 3)
  --once                        Process at most one request and exit
  --daemon                      Run in background and write PID file
  --log-file <path>             Log file path (default: <data-dir>/.umbrel-docker/update-agent.log)
  --help                        Show this help
EOF
}

validate_positive_int() {
  local value="$1"
  local name="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    err "${name} must be an integer >= 1"
    exit 1
  fi
}

require_cmd() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    err "Missing required command: ${name}"
    exit 1
  fi
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) CONTAINER_NAME="${2:?missing value for --name}"; shift 2 ;;
      --data-dir) DATA_DIR="${2:?missing value for --data-dir}"; shift 2 ;;
      --poll-interval) POLL_INTERVAL="${2:?missing value for --poll-interval}"; shift 2 ;;
      --once) ONCE="true"; shift 1 ;;
      --daemon) DAEMON="true"; shift 1 ;;
      --log-file) LOG_FILE="${2:?missing value for --log-file}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

init_paths() {
  REQUEST_DIR="${DATA_DIR}/.umbrel-docker"
  REQUEST_FILE="${REQUEST_DIR}/update-request.json"
  ACTIVE_FILE="${REQUEST_DIR}/update-request.active.json"
  STATE_FILE="${REQUEST_DIR}/update-state.json"
  PID_FILE="${REQUEST_DIR}/update-agent.pid"

  mkdir -p "${REQUEST_DIR}"
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${REQUEST_DIR}/update-agent.log"
  fi
}

log_line() {
  local message="$*"
  printf "%s %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${message}" >>"${LOG_FILE}"
}

write_state() {
  local running="$1"
  local progress="$2"
  local description="$3"
  local error="$4"
  local version="$5"
  local channel="$6"

  local tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"

  jq -cn \
    --argjson running "${running}" \
    --argjson progress "${progress}" \
    --arg description "${description}" \
    --arg error "${error}" \
    --arg version "${version}" \
    --arg channel "${channel}" \
    --arg updatedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      running: $running,
      progress: $progress,
      description: $description,
      error: ($error | if . == "" then false else . end),
      version: ($version | if . == "" then null else . end),
      channel: ($channel | if . == "" then null else . end),
      updatedAt: $updatedAt
    }' >"${tmp}"

  mv "${tmp}" "${STATE_FILE}"
}

request_archive_path() {
  local status="$1"
  printf "%s/update-request.%s.%s.json" "${REQUEST_DIR}" "${status}" "$(date -u '+%Y%m%d-%H%M%S')"
}

validate_request() {
  local version="$1"
  local channel="$2"

  if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    return 1
  fi
  if [[ "${channel}" != "stable" && "${channel}" != "beta" ]]; then
    return 1
  fi
  return 0
}

process_request_file() {
  local file="$1"
  local version channel requested_at
  version="$(jq -r '.version // empty' "${file}" 2>/dev/null || true)"
  channel="$(jq -r '.channel // "stable"' "${file}" 2>/dev/null || true)"
  requested_at="$(jq -r '.requestedAt // ""' "${file}" 2>/dev/null || true)"

  if ! validate_request "${version}" "${channel}"; then
    warn "Ignoring invalid update request payload in ${file}"
    log_line "invalid-request file=${file}"
    write_state false 0 "Invalid docker update request payload" "Invalid request payload" "${version}" "${channel}"
    mv -f "${file}" "$(request_archive_path invalid)"
    return 0
  fi

  log_line "request-start version=${version} channel=${channel} requested_at=${requested_at}"
  write_state true 10 "Running host update to ${version}" "" "${version}" "${channel}"

  set +e
  bash "${UMBRELCTL}" update \
    --name "${CONTAINER_NAME}" \
    --data-dir "${DATA_DIR}" \
    --ref "${version}" \
    --release-channel "${channel}" >>"${LOG_FILE}" 2>&1
  local rc=$?
  set -e

  if (( rc == 0 )); then
    log_line "request-success version=${version} channel=${channel}"
    write_state false 100 "Update to ${version} completed" "" "${version}" "${channel}"
    mv -f "${file}" "$(request_archive_path completed)"
  else
    warn "Host update failed for version ${version} (exit ${rc})"
    log_line "request-failed version=${version} channel=${channel} exit=${rc}"
    write_state false 0 "Update to ${version} failed" "Host update command failed (exit ${rc})" "${version}" "${channel}"
    mv -f "${file}" "$(request_archive_path failed)"
  fi
}

run_once() {
  if [[ -f "${ACTIVE_FILE}" ]]; then
    process_request_file "${ACTIVE_FILE}"
    return 0
  fi

  if [[ ! -f "${REQUEST_FILE}" ]]; then
    return 0
  fi

  mv -f "${REQUEST_FILE}" "${ACTIVE_FILE}"
  process_request_file "${ACTIVE_FILE}"
}

agent_loop() {
  while true; do
    run_once
    if [[ "${ONCE}" == "true" ]]; then
      break
    fi
    sleep "${POLL_INTERVAL}"
  done
}

start_daemon() {
  if [[ -f "${PID_FILE}" ]]; then
    local existing_pid
    existing_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" >/dev/null 2>&1; then
      info "Update agent already running (pid ${existing_pid})"
      return 0
    fi
  fi

  local -a args
  args=(
    --name "${CONTAINER_NAME}"
    --data-dir "${DATA_DIR}"
    --poll-interval "${POLL_INTERVAL}"
    --log-file "${LOG_FILE}"
  )
  [[ "${ONCE}" == "true" ]] && args+=(--once)

  nohup bash "$0" "${args[@]}" >>"${LOG_FILE}" 2>&1 &
  local daemon_pid=$!
  printf "%s\n" "${daemon_pid}" >"${PID_FILE}"
  info "Started update agent daemon (pid ${daemon_pid})"
}

main() {
  parse_options "$@"
  validate_positive_int "${POLL_INTERVAL}" "--poll-interval"
  require_cmd jq
  init_paths

  if [[ "${DAEMON}" == "true" ]]; then
    start_daemon
    return 0
  fi

  printf "%s\n" "$$" >"${PID_FILE}"
  trap 'rm -f "${PID_FILE}"' EXIT

  log_line "agent-start container=${CONTAINER_NAME} data_dir=${DATA_DIR}"
  agent_loop
}

main "$@"
