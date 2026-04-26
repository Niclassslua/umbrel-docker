#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UMBRELCTL="${REPO_DIR}/umbrelctl"
REMOTE_TAGS_URL="https://github.com/getumbrel/umbrel.git"

MODE="smoke"
MIN_VERSION="1.0.0"
INCLUDE_PRERELEASE="true"
RUNTIME_PROFILE="minimal"
HEALTH_TIMEOUT="240"
BASE_PORT="18080"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
WORKDIR="${SCRIPT_DIR}/artifacts/${RUN_ID}"
KEEP_SUCCESS="false"
KEEP_FAILURE="true"
KEEP_FAILURE_CONTAINERS="false"
BUILD_NO_CACHE="false"
BUILD_PULL="false"
REUSE_BUILD_CACHE="true"
FINAL_CONTAINER_SWEEP="true"

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
FINISHED_AT=""

CASE_SPECS_FILE=""
CASE_RESULTS_FILE=""
REPORT_FILE=""
SUMMARY_FILE=""
CURRENT_CASE_CONTAINER=""

declare -a VERSIONS=()
declare -A BUILD_OK=()
declare -A BUILD_ERROR=()
declare -A VERSION_REMOTE_REF=()
BUILD_CACHE_KEY=""

info() { printf "==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
err() { printf "ERROR: %s\n" "$*" >&2; }

usage() {
  cat <<'EOF'
upgrade-matrix.sh - full Docker upgrade matrix tests for umbrelctl

Usage:
  bash ./tests/upgrade-matrix.sh [options]

Options:
  --mode <smoke|full>                 Test profile (default: smoke)
  --min-version <semver>              Minimum version to include (default: 1.0.0)
  --include-prerelease <true|false>   Include prereleases (default: true)
  --runtime-profile <minimal|compat>  Runtime profile passed to umbrelctl (default: minimal)
  --health-timeout <sec>              Health check timeout (default: 240)
  --base-port <int>                   First host port (default: 18080)
  --workdir <path>                    Artifact directory (default: ./tests/artifacts/<run-id>)
  --keep-success <true|false>         Keep successful case artifacts (default: false)
  --keep-failure <true|false>         Keep failed/blocked case artifacts (default: true)
  --keep-failure-containers <true|false>
                                      Keep failed/blocked containers for debugging (default: false)
  --build-no-cache                    Pass --no-cache to umbrelctl build
  --build-pull                        Pass --pull to umbrelctl build
  --reuse-build-cache <true|false>    Reuse previously built matrix images when cache-key matches (default: true)
  --final-container-sweep <true|false>
                                      End-of-run best-effort cleanup of tracked containers (default: true)
  --help                              Show this help
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Missing required command: ${cmd}"
    exit 1
  fi
}

is_true() { [[ "${1}" == "true" ]]; }
is_false() { [[ "${1}" == "false" ]]; }

validate_bool() {
  local value="$1"
  local name="$2"
  if ! is_true "${value}" && ! is_false "${value}"; then
    err "${name} must be true or false."
    exit 1
  fi
}

semver_ge() {
  local value="$1"
  local min="$2"
  [[ "$(printf "%s\n%s\n" "${value}" "${min}" | sort -V | head -n1)" == "${min}" ]]
}

file_hash_or_missing() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    printf "missing"
    return
  fi
  shasum "${file}" | awk '{print $1}'
}

compute_build_cache_key() {
  if [[ -n "${BUILD_CACHE_KEY}" ]]; then
    printf "%s" "${BUILD_CACHE_KEY}"
    return
  fi

  BUILD_CACHE_KEY="$(
    {
      printf "dockerfile=%s\n" "$(file_hash_or_missing "${REPO_DIR}/Dockerfile")"
      printf "entry=%s\n" "$(file_hash_or_missing "${REPO_DIR}/entry.sh")"
      printf "patch=%s\n" "$(file_hash_or_missing "${REPO_DIR}/scripts/patch-umbrel.js")"
      printf "umbrelctl=%s\n" "$(file_hash_or_missing "${UMBRELCTL}")"
    } | shasum | awk '{print $1}'
  )"
  printf "%s" "${BUILD_CACHE_KEY}"
}

image_label_value() {
  local image="$1"
  local key="$2"
  docker image inspect "${image}" 2>/dev/null | jq -r --arg key "${key}" '.[0].Config.Labels[$key] // ""'
}

image_matches_cache_key() {
  local image="$1"
  local version="$2"
  local expected_ref="$3"
  local expected_key="$4"
  local key_label ref_label version_label

  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    return 1
  fi

  key_label="$(image_label_value "${image}" "umbrel.matrix.cache-key")"
  ref_label="$(image_label_value "${image}" "umbrel.matrix.ref")"
  version_label="$(image_label_value "${image}" "umbrel.matrix.version")"

  [[ "${key_label}" == "${expected_key}" && "${ref_label}" == "${expected_ref}" && "${version_label}" == "${version}" ]]
}

sanitize_case_part() {
  printf "%s" "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

case_container_name() {
  local case_id="$1"
  local hash
  hash="$(printf "%s" "${case_id}" | shasum | awk '{print substr($1,1,10)}')"
  printf "umbrel-test-%s" "${hash}"
}

count_backup_dirs() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    printf "0"
    return
  fi
  find "${dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

docker_container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

docker_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || printf "false")" == "true" ]]
}

capture_inspect() {
  local container="$1"
  local out_file="$2"
  if docker_container_exists "${container}"; then
    docker inspect "${container}" >"${out_file}" 2>/dev/null || printf "[]\n" >"${out_file}"
  else
    printf "[]\n" >"${out_file}"
  fi
}

run_and_capture() {
  local stdout_log="$1"
  local stderr_log="$2"
  shift 2

  mkdir -p "$(dirname "${stdout_log}")" "$(dirname "${stderr_log}")"
  : >>"${stdout_log}"
  : >>"${stderr_log}"

  set +e
  "$@" > >(tee -a "${stdout_log}") 2> >(tee -a "${stderr_log}" >&2)
  local rc=$?
  set -e
  return "${rc}"
}

append_case_result() {
  local case_dir="$1"
  local case_id="$2"
  local case_type="$3"
  local source="$4"
  local target="$5"
  local status="$6"
  local duration="$7"
  local container_name="$8"
  local port="$9"
  local artifacts_path="${10}"
  local error_summary="${11}"

  local result_json
  result_json="$(jq -cn \
    --arg id "${case_id}" \
    --arg type "${case_type}" \
    --arg source "${source}" \
    --arg target "${target}" \
    --arg status "${status}" \
    --argjson duration_sec "${duration}" \
    --arg container_name "${container_name}" \
    --argjson port "${port}" \
    --arg artifacts_path "${artifacts_path}" \
    --arg error_summary "${error_summary}" \
    '{
      id: $id,
      type: $type,
      source: $source,
      target: (if $target == "" then null else $target end),
      status: $status,
      duration_sec: $duration_sec,
      container_name: $container_name,
      port: $port,
      artifacts_path: $artifacts_path,
      error_summary: (if $error_summary == "" then null else $error_summary end)
    }'
  )"

  printf "%s\n" "${result_json}" >>"${CASE_RESULTS_FILE}"
  printf "%s\n" "${result_json}" >"${case_dir}/result.json"
}

wait_container_healthy() {
  local container="$1"
  local timeout="$2"
  local case_dir="$3"
  local start now elapsed stable_since logs state status exit_code restarting rest
  start="$(date +%s)"
  stable_since=""

  while true; do
    now="$(date +%s)"
    elapsed="$(( now - start ))"
    if (( elapsed >= timeout )); then
      printf "Health timeout after %ss\n" "${timeout}" >"${case_dir}/health-error.txt"
      docker logs --tail 300 "${container}" >"${case_dir}/health-timeout-logs.txt" 2>&1 || true
      return 1
    fi

    logs="$(docker logs --tail 300 "${container}" 2>&1 || true)"
    state="$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Restarting}}' "${container}" 2>/dev/null || printf "missing|-1|false")"
    status="${state%%|*}"
    rest="${state#*|}"
    exit_code="${rest%%|*}"
    restarting="${state##*|}"

    if [[ "${status}" == "missing" || "${status}" == "exited" || "${status}" == "dead" ]] && [[ "${restarting}" != "true" ]]; then
      printf "Container exited during health check (status=%s exit_code=%s)\n" "${status}" "${exit_code}" >"${case_dir}/health-error.txt"
      printf "%s\n" "${logs}" >"${case_dir}/health-fatal-logs.txt"
      return 1
    fi

    if printf "%s" "${logs}" | grep -Eq "Failed to start app environment|\\[escapes-base\\]|Cannot find module|SyntaxError|Failed to ensure directory|Failed to watch directory|Failed to apply shares|Failed to start external storage"; then
      printf "Fatal startup log pattern detected\n" >"${case_dir}/health-error.txt"
      printf "%s\n" "${logs}" >"${case_dir}/health-fatal-logs.txt"
      return 1
    fi

    if docker_is_running "${container}"; then
      if printf "%s" "${logs}" | grep -Eq "Listening on port|Starting backups"; then
        return 0
      fi
      if [[ -z "${stable_since}" ]]; then
        stable_since="${now}"
      elif (( now - stable_since >= 15 )); then
        return 0
      fi
    else
      stable_since=""
    fi

    sleep 2
  done
}

cleanup_case() {
  local status="$1"
  local container_name="$2"
  local case_dir="$3"

  if [[ "${status}" == "passed" ]]; then
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    if is_false "${KEEP_SUCCESS}"; then
      rm -rf "${case_dir}"
    fi
    return
  fi

  if is_true "${KEEP_FAILURE_CONTAINERS}"; then
    if docker_container_exists "${container_name}" && docker_is_running "${container_name}"; then
      docker stop "${container_name}" >/dev/null 2>&1 || true
    fi
  else
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
  fi

  if is_false "${KEEP_FAILURE}"; then
    rm -rf "${case_dir}"
  fi
}

final_container_sweep() {
  if is_false "${FINAL_CONTAINER_SWEEP}"; then
    return
  fi
  if [[ ! -s "${CASE_RESULTS_FILE}" ]]; then
    return
  fi

  local -a containers=()
  local container status
  mapfile -t containers < <(jq -r '.container_name' "${CASE_RESULTS_FILE}" | sed '/^$/d' | sort -u)
  if (( ${#containers[@]} == 0 )); then
    return
  fi

  info "Final container cleanup sweep (${#containers[@]} tracked containers)"
  for container in "${containers[@]}"; do
    status="$(jq -r --arg c "${container}" 'select(.container_name == $c) | .status' "${CASE_RESULTS_FILE}" | tail -n1)"
    if [[ "${status}" == "passed" ]]; then
      docker rm -f "${container}" >/dev/null 2>&1 || true
      continue
    fi

    if is_true "${KEEP_FAILURE_CONTAINERS}"; then
      if docker_container_exists "${container}" && docker_is_running "${container}"; then
        docker stop "${container}" >/dev/null 2>&1 || true
      fi
    else
      docker rm -f "${container}" >/dev/null 2>&1 || true
    fi
  done
}

on_exit_cleanup() {
  local exit_code=$?
  if (( exit_code == 0 )); then
    return
  fi
  if [[ -z "${CURRENT_CASE_CONTAINER}" ]]; then
    return
  fi

  warn "Run interrupted; cleaning active container ${CURRENT_CASE_CONTAINER}"
  if is_true "${KEEP_FAILURE_CONTAINERS}"; then
    if docker_container_exists "${CURRENT_CASE_CONTAINER}" && docker_is_running "${CURRENT_CASE_CONTAINER}"; then
      docker stop "${CURRENT_CASE_CONTAINER}" >/dev/null 2>&1 || true
    fi
  else
    docker rm -f "${CURRENT_CASE_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:?missing value for --mode}"; shift 2 ;;
      --min-version) MIN_VERSION="${2:?missing value for --min-version}"; shift 2 ;;
      --include-prerelease) INCLUDE_PRERELEASE="${2:?missing value for --include-prerelease}"; shift 2 ;;
      --runtime-profile) RUNTIME_PROFILE="${2:?missing value for --runtime-profile}"; shift 2 ;;
      --health-timeout) HEALTH_TIMEOUT="${2:?missing value for --health-timeout}"; shift 2 ;;
      --base-port) BASE_PORT="${2:?missing value for --base-port}"; shift 2 ;;
      --workdir) WORKDIR="${2:?missing value for --workdir}"; shift 2 ;;
      --keep-success) KEEP_SUCCESS="${2:?missing value for --keep-success}"; shift 2 ;;
      --keep-failure) KEEP_FAILURE="${2:?missing value for --keep-failure}"; shift 2 ;;
      --keep-failure-containers) KEEP_FAILURE_CONTAINERS="${2:?missing value for --keep-failure-containers}"; shift 2 ;;
      --build-no-cache) BUILD_NO_CACHE="true"; shift 1 ;;
      --build-pull) BUILD_PULL="true"; shift 1 ;;
      --reuse-build-cache) REUSE_BUILD_CACHE="${2:?missing value for --reuse-build-cache}"; shift 2 ;;
      --final-container-sweep) FINAL_CONTAINER_SWEEP="${2:?missing value for --final-container-sweep}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

validate_args() {
  [[ "${MODE}" == "smoke" || "${MODE}" == "full" ]] || { err "--mode must be smoke or full"; exit 1; }
  [[ "${RUNTIME_PROFILE}" == "minimal" || "${RUNTIME_PROFILE}" == "compat" ]] || { err "--runtime-profile must be minimal or compat"; exit 1; }
  [[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] || { err "--health-timeout must be an integer"; exit 1; }
  [[ "${BASE_PORT}" =~ ^[0-9]+$ ]] || { err "--base-port must be an integer"; exit 1; }

  validate_bool "${INCLUDE_PRERELEASE}" "--include-prerelease"
  validate_bool "${KEEP_SUCCESS}" "--keep-success"
  validate_bool "${KEEP_FAILURE}" "--keep-failure"
  validate_bool "${KEEP_FAILURE_CONTAINERS}" "--keep-failure-containers"
  validate_bool "${REUSE_BUILD_CACHE}" "--reuse-build-cache"
  validate_bool "${FINAL_CONTAINER_SWEEP}" "--final-container-sweep"

  [[ "${MIN_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "--min-version must be X.Y.Z"; exit 1; }
}

prepare_paths() {
  mkdir -p "${WORKDIR}/cases" "${WORKDIR}/builds"
  CASE_SPECS_FILE="${WORKDIR}/case-specs.ndjson"
  CASE_RESULTS_FILE="${WORKDIR}/case-results.ndjson"
  REPORT_FILE="${WORKDIR}/report.json"
  SUMMARY_FILE="${WORKDIR}/summary.md"
  : >"${CASE_SPECS_FILE}"
  : >"${CASE_RESULTS_FILE}"
}

fetch_versions() {
  info "Fetching versions from ${REMOTE_TAGS_URL}"
  local refs
  if ! refs="$(git ls-remote --tags --refs "${REMOTE_TAGS_URL}" 2>/dev/null)"; then
    err "Failed to load remote tags from ${REMOTE_TAGS_URL}"
    exit 1
  fi
  if [[ -z "${refs}" ]]; then
    err "Remote tag list is empty for ${REMOTE_TAGS_URL}"
    exit 1
  fi

  local stable_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
  local prerelease_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$'
  local pattern="${stable_pattern}"
  if is_true "${INCLUDE_PRERELEASE}"; then
    pattern="${prerelease_pattern}"
  fi

  local -a collected=()
  local raw_ref raw_tag normalized
  while IFS= read -r raw_ref; do
    raw_tag="${raw_ref#refs/tags/}"
    normalized="${raw_tag#v}"
    [[ "${normalized}" =~ ${pattern} ]] || continue
    semver_ge "${normalized}" "${MIN_VERSION}" || continue
    collected+=("${normalized}")

    if [[ -z "${VERSION_REMOTE_REF[$normalized]+x}" ]]; then
      VERSION_REMOTE_REF["${normalized}"]="${raw_tag}"
    elif [[ "${raw_tag}" == "${normalized}" && "${VERSION_REMOTE_REF[$normalized]}" != "${normalized}" ]]; then
      VERSION_REMOTE_REF["${normalized}"]="${raw_tag}"
    fi
  done < <(printf "%s\n" "${refs}" | awk '{print $2}')

  if (( ${#collected[@]} == 0 )); then
    err "No versions matched filter (min=${MIN_VERSION}, include-prerelease=${INCLUDE_PRERELEASE})"
    exit 1
  fi

  mapfile -t VERSIONS < <(printf "%s\n" "${collected[@]}" | sort -uV)
  info "Loaded ${#VERSIONS[@]} versions for matrix"
}

CASE_COUNTER=0

add_case() {
  local case_type="$1"
  local source="$2"
  local target="${3:-}"

  local case_id source_id target_id
  source_id="$(sanitize_case_part "${source}")"
  if [[ "${case_type}" == "happy" ]]; then
    target_id="$(sanitize_case_part "${target}")"
    case_id="$(printf "%04d-%s-to-%s" "${CASE_COUNTER}" "${source_id}" "${target_id}")"
  else
    case_id="$(printf "%04d-%s-rollback" "${CASE_COUNTER}" "${source_id}")"
  fi

  jq -cn \
    --arg id "${case_id}" \
    --arg type "${case_type}" \
    --arg source "${source}" \
    --arg target "${target}" \
    '{
      id: $id,
      type: $type,
      source: $source,
      target: (if $target == "" then null else $target end)
    }' >>"${CASE_SPECS_FILE}"

  CASE_COUNTER=$((CASE_COUNTER + 1))
}

generate_full_cases() {
  local n="${#VERSIONS[@]}"
  local i j
  for ((i = 0; i < n; i++)); do
    for ((j = i + 1; j < n; j++)); do
      add_case "happy" "${VERSIONS[$i]}" "${VERSIONS[$j]}"
    done
  done
  for ((i = 0; i < n; i++)); do
    add_case "rollback" "${VERSIONS[$i]}"
  done
}

generate_smoke_cases() {
  local n="${#VERSIONS[@]}"
  local -a anchor_indexes=(0 $((n / 4)) $((n / 2)) $(((3 * n) / 4)) $((n - 1)))
  local -a anchors=()
  local idx ver
  declare -A seen_anchors=()
  for idx in "${anchor_indexes[@]}"; do
    (( idx >= 0 && idx < n )) || continue
    ver="${VERSIONS[$idx]}"
    if [[ -z "${seen_anchors[$ver]+x}" ]]; then
      seen_anchors["$ver"]="1"
      anchors+=("${ver}")
    fi
  done

  declare -A added_happy=()
  local src dst key
  for ((idx = 0; idx + 1 < ${#anchors[@]}; idx++)); do
    src="${anchors[$idx]}"
    dst="${anchors[$((idx + 1))]}"
    key="${src}|${dst}"
    if [[ -z "${added_happy[$key]+x}" ]]; then
      added_happy["$key"]="1"
      add_case "happy" "${src}" "${dst}"
    fi
  done

  src="${anchors[0]}"
  dst="${anchors[$((${#anchors[@]} - 1))]}"
  if [[ "${src}" != "${dst}" ]]; then
    key="${src}|${dst}"
    if [[ -z "${added_happy[$key]+x}" ]]; then
      add_case "happy" "${src}" "${dst}"
    fi
  fi

  add_case "rollback" "${anchors[0]}"
  if [[ "${anchors[0]}" != "${anchors[$((${#anchors[@]} - 1))]}" ]]; then
    add_case "rollback" "${anchors[$((${#anchors[@]} - 1))]}"
  fi
}

generate_cases() {
  info "Generating ${MODE} cases"
  if [[ "${MODE}" == "full" ]]; then
    generate_full_cases
  else
    generate_smoke_cases
  fi

  local total
  total="$(wc -l <"${CASE_SPECS_FILE}" | tr -d ' ')"
  if [[ "${total}" == "0" ]]; then
    err "No test cases generated."
    exit 1
  fi
  info "Generated ${total} test cases"
}

build_required_images() {
  local -a required_versions=()
  mapfile -t required_versions < <(jq -r '.source, .target // empty' "${CASE_SPECS_FILE}" | sed '/^$/d' | sort -uV)

  local version image_tag version_safe build_stdout build_stderr build_ref build_cache_key
  local -a cmd=()
  build_cache_key="$(compute_build_cache_key)"

  for version in "${required_versions[@]}"; do
    image_tag="umbrel-matrix:${version}"
    version_safe="$(sanitize_case_part "${version}")"
    build_stdout="${WORKDIR}/builds/${version_safe}.stdout.log"
    build_stderr="${WORKDIR}/builds/${version_safe}.stderr.log"
    build_ref="${VERSION_REMOTE_REF[$version]:-$version}"

    mkdir -p "$(dirname "${build_stdout}")" "$(dirname "${build_stderr}")"
    : >"${build_stdout}"
    : >"${build_stderr}"

    if is_true "${REUSE_BUILD_CACHE}" && is_false "${BUILD_NO_CACHE}" && is_false "${BUILD_PULL}" \
      && image_matches_cache_key "${image_tag}" "${version}" "${build_ref}" "${build_cache_key}"; then
      info "Reusing cached matrix image ${image_tag} (ref=${build_ref})"
      printf "reused image=%s ref=%s cache-key=%s\n" "${image_tag}" "${build_ref}" "${build_cache_key}" >"${build_stdout}"
      BUILD_OK["${version}"]="1"
      BUILD_ERROR["${version}"]=""
      continue
    fi

    info "Building matrix image ${image_tag} (ref=${build_ref})"
    cmd=(bash "${UMBRELCTL}" build --ref "${build_ref}" --image "${image_tag}" \
      --label "umbrel.matrix.cache-key=${build_cache_key}" \
      --label "umbrel.matrix.ref=${build_ref}" \
      --label "umbrel.matrix.version=${version}")
    if is_true "${BUILD_NO_CACHE}"; then
      cmd+=(--no-cache)
    fi
    if is_true "${BUILD_PULL}"; then
      cmd+=(--pull)
    fi

    if run_and_capture "${build_stdout}" "${build_stderr}" "${cmd[@]}"; then
      BUILD_OK["${version}"]="1"
      BUILD_ERROR["${version}"]=""
    else
      BUILD_OK["${version}"]="0"
      BUILD_ERROR["${version}"]="build failed for ${version} (ref=${build_ref})"
      warn "Build failed for ${version} (ref=${build_ref}); dependent cases will be blocked."
    fi
  done
}

run_happy_case() {
  local case_dir="$1"
  local stdout_log="$2"
  local stderr_log="$3"
  local source="$4"
  local target="$5"
  local container_name="$6"
  local data_dir="$7"
  local backup_dir="$8"
  local port="$9"

  local source_image="umbrel-matrix:${source}"
  local target_image="umbrel-matrix:${target}"
  local before_backups after_backups active_image

  docker rm -f "${container_name}" >/dev/null 2>&1 || true

  if ! run_and_capture "${stdout_log}" "${stderr_log}" bash "${UMBRELCTL}" up \
    --name "${container_name}" \
    --image "${source_image}" \
    --skip-build \
    --data-dir "${data_dir}" \
    --port "${port}" \
    --runtime-profile "${RUNTIME_PROFILE}"; then
    printf "source deployment failed\n" >"${case_dir}/error.txt"
    return 1
  fi

  if ! wait_container_healthy "${container_name}" "${HEALTH_TIMEOUT}" "${case_dir}"; then
    printf "source health check failed\n" >"${case_dir}/error.txt"
    return 1
  fi

  capture_inspect "${container_name}" "${case_dir}/docker-inspect-before.json"
  before_backups="$(count_backup_dirs "${backup_dir}")"

  if ! run_and_capture "${stdout_log}" "${stderr_log}" bash "${UMBRELCTL}" update \
    --name "${container_name}" \
    --data-dir "${data_dir}" \
    --image "${target_image}" \
    --backup-dir "${backup_dir}" \
    --health-timeout "${HEALTH_TIMEOUT}" \
    --runtime-profile "${RUNTIME_PROFILE}"; then
    printf "upgrade command failed\n" >"${case_dir}/error.txt"
    return 1
  fi

  after_backups="$(count_backup_dirs "${backup_dir}")"
  if (( after_backups <= before_backups )); then
    printf "backup was not created during update\n" >"${case_dir}/error.txt"
    return 1
  fi

  if ! docker_is_running "${container_name}"; then
    printf "container is not running after update\n" >"${case_dir}/error.txt"
    return 1
  fi

  active_image="$(docker inspect -f '{{.Config.Image}}' "${container_name}" 2>/dev/null || true)"
  if [[ "${active_image}" != "${target_image}" ]]; then
    printf "unexpected image after update: expected=%s actual=%s\n" "${target_image}" "${active_image}" >"${case_dir}/error.txt"
    return 1
  fi

  capture_inspect "${container_name}" "${case_dir}/docker-inspect-after.json"
  return 0
}

run_rollback_case() {
  local case_dir="$1"
  local stdout_log="$2"
  local stderr_log="$3"
  local source="$4"
  local container_name="$5"
  local data_dir="$6"
  local backup_dir="$7"
  local port="$8"

  local source_image="umbrel-matrix:${source}"
  local case_hash bad_image bad_ctx before_backups after_backups active_image
  case_hash="$(printf "%s" "${container_name}" | shasum | awk '{print substr($1,1,8)}')"
  bad_image="umbrel-bad:${source//[^a-zA-Z0-9_.-]/-}-${case_hash}"
  bad_ctx="${case_dir}/bad-image"

  docker rm -f "${container_name}" >/dev/null 2>&1 || true

  if ! run_and_capture "${stdout_log}" "${stderr_log}" bash "${UMBRELCTL}" up \
    --name "${container_name}" \
    --image "${source_image}" \
    --skip-build \
    --data-dir "${data_dir}" \
    --port "${port}" \
    --runtime-profile "${RUNTIME_PROFILE}"; then
    printf "source deployment failed\n" >"${case_dir}/error.txt"
    return 1
  fi

  if ! wait_container_healthy "${container_name}" "${HEALTH_TIMEOUT}" "${case_dir}"; then
    printf "source health check failed\n" >"${case_dir}/error.txt"
    return 1
  fi

  capture_inspect "${container_name}" "${case_dir}/docker-inspect-before.json"
  before_backups="$(count_backup_dirs "${backup_dir}")"

  mkdir -p "${bad_ctx}"
  cat >"${bad_ctx}/Dockerfile" <<EOF
FROM ${source_image}
ENTRYPOINT ["sh","-lc","echo forced-fail >&2; exit 42"]
EOF

  if ! run_and_capture "${stdout_log}" "${stderr_log}" docker build -t "${bad_image}" "${bad_ctx}"; then
    printf "failed to build bad image for rollback test\n" >"${case_dir}/error.txt"
    return 1
  fi

  if run_and_capture "${stdout_log}" "${stderr_log}" bash "${UMBRELCTL}" update \
    --name "${container_name}" \
    --data-dir "${data_dir}" \
    --image "${bad_image}" \
    --backup-dir "${backup_dir}" \
    --health-timeout "${HEALTH_TIMEOUT}" \
    --runtime-profile "${RUNTIME_PROFILE}"; then
    printf "rollback test expected update failure but got success\n" >"${case_dir}/error.txt"
    return 1
  fi

  after_backups="$(count_backup_dirs "${backup_dir}")"
  if (( after_backups <= before_backups )); then
    printf "backup was not created during rollback test\n" >"${case_dir}/error.txt"
    return 1
  fi

  if ! docker_is_running "${container_name}"; then
    printf "container is not running after rollback\n" >"${case_dir}/error.txt"
    return 1
  fi

  active_image="$(docker inspect -f '{{.Config.Image}}' "${container_name}" 2>/dev/null || true)"
  if [[ "${active_image}" != "${source_image}" ]]; then
    printf "rollback image mismatch: expected=%s actual=%s\n" "${source_image}" "${active_image}" >"${case_dir}/error.txt"
    return 1
  fi

  capture_inspect "${container_name}" "${case_dir}/docker-inspect-after.json"
  return 0
}

execute_cases() {
  local case_json case_id case_type source target case_dir stdout_log stderr_log
  local container_name data_dir backup_dir status duration error_summary case_start case_end port
  local case_index=0
  local -A SOURCE_UNUSABLE=()
  local -A SOURCE_UNUSABLE_REASON=()
  local -A SOURCE_BOOTSTRAP_FAILURES=()

  while IFS= read -r case_json; do
    [[ -z "${case_json}" ]] && continue

    case_id="$(jq -r '.id' <<<"${case_json}")"
    case_type="$(jq -r '.type' <<<"${case_json}")"
    source="$(jq -r '.source' <<<"${case_json}")"
    target="$(jq -r '.target // ""' <<<"${case_json}")"

    case_dir="${WORKDIR}/cases/${case_id}"
    stdout_log="${case_dir}/stdout.log"
    stderr_log="${case_dir}/stderr.log"
    container_name="$(case_container_name "${case_id}")"
    CURRENT_CASE_CONTAINER="${container_name}"
    data_dir="${case_dir}/data"
    backup_dir="${case_dir}/backups"
    port=$((BASE_PORT + case_index))

    mkdir -p "${case_dir}"
    : >"${stdout_log}"
    : >"${stderr_log}"

    case_start="$(date +%s)"
    status="failed"
    error_summary=""

    info "Running case ${case_id} (${case_type})"

    if [[ "${BUILD_OK[$source]:-0}" != "1" ]]; then
      status="blocked"
      error_summary="source build unavailable: ${source}"
    elif [[ "${SOURCE_UNUSABLE[$source]:-0}" == "1" ]]; then
      status="blocked"
      error_summary="source runtime unavailable: ${SOURCE_UNUSABLE_REASON[$source]}"
    elif [[ "${case_type}" == "happy" && "${BUILD_OK[$target]:-0}" != "1" ]]; then
      status="blocked"
      error_summary="target build unavailable: ${target}"
    else
      if [[ "${case_type}" == "happy" ]]; then
        if run_happy_case "${case_dir}" "${stdout_log}" "${stderr_log}" "${source}" "${target}" "${container_name}" "${data_dir}" "${backup_dir}" "${port}"; then
          status="passed"
        else
          status="failed"
        fi
      else
        if run_rollback_case "${case_dir}" "${stdout_log}" "${stderr_log}" "${source}" "${container_name}" "${data_dir}" "${backup_dir}" "${port}"; then
          status="passed"
        else
          status="failed"
        fi
      fi

      if [[ "${status}" != "passed" ]]; then
        if [[ -f "${case_dir}/error.txt" ]]; then
          error_summary="$(head -n1 "${case_dir}/error.txt")"
        else
          error_summary="case failed without explicit error marker"
        fi

        if [[ "${error_summary}" == "source deployment failed" || "${error_summary}" == "source health check failed" ]]; then
          SOURCE_BOOTSTRAP_FAILURES["${source}"]="$(( ${SOURCE_BOOTSTRAP_FAILURES["${source}"]:-0} + 1 ))"
          if (( SOURCE_BOOTSTRAP_FAILURES["${source}"] >= 2 )); then
            SOURCE_UNUSABLE["${source}"]="1"
            SOURCE_UNUSABLE_REASON["${source}"]="${error_summary}"
            warn "Marking source ${source} as runtime-unusable after case ${case_id}: ${error_summary}"
          else
            warn "Observed bootstrap failure for source ${source} in case ${case_id}; waiting for one more failure before blocking remaining cases."
          fi
        else
          # Source bootstrapped in this case, so clear transient bootstrap-failure streak.
          SOURCE_BOOTSTRAP_FAILURES["${source}"]="0"
        fi
      else
        SOURCE_BOOTSTRAP_FAILURES["${source}"]="0"
      fi
    fi

    if [[ "${status}" == "blocked" ]]; then
      capture_inspect "${container_name}" "${case_dir}/docker-inspect-before.json"
      capture_inspect "${container_name}" "${case_dir}/docker-inspect-after.json"
    fi

    case_end="$(date +%s)"
    duration=$((case_end - case_start))

    append_case_result \
      "${case_dir}" \
      "${case_id}" \
      "${case_type}" \
      "${source}" \
      "${target}" \
      "${status}" \
      "${duration}" \
      "${container_name}" \
      "${port}" \
      "${case_dir}" \
      "${error_summary}"

    cleanup_case "${status}" "${container_name}" "${case_dir}"
    CURRENT_CASE_CONTAINER=""
    case_index=$((case_index + 1))
  done <"${CASE_SPECS_FILE}"
}

write_report() {
  FINISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local versions_json
  versions_json="$(printf "%s\n" "${VERSIONS[@]}" | jq -R . | jq -s .)"

  jq -n \
    --arg run_id "${RUN_ID}" \
    --arg mode "${MODE}" \
    --arg started_at "${STARTED_AT}" \
    --arg finished_at "${FINISHED_AT}" \
    --argjson version_set "${versions_json}" \
    --slurpfile cases "${CASE_RESULTS_FILE}" \
    '
    def count_status($s): ($cases | map(select(.status == $s)) | length);
    {
      run_id: $run_id,
      mode: $mode,
      started_at: $started_at,
      finished_at: $finished_at,
      version_set: $version_set,
      counts: {
        total: ($cases | length),
        passed: count_status("passed"),
        failed: count_status("failed"),
        blocked: count_status("blocked"),
        skipped: count_status("skipped")
      },
      cases: $cases
    }' >"${REPORT_FILE}"
}

write_summary() {
  local failed_rows top_patterns mode_expectations
  failed_rows="$(jq -r '.cases[] | select(.status == "failed" or .status == "blocked") | "| `\(.id)` | \(.type) | \(.source) | \(.target // "-") | \(.status) | \((.error_summary // "-") | gsub("\\|"; "\\\\|")) | `\(.artifacts_path)` |"' "${REPORT_FILE}")"
  top_patterns="$(jq -r '.cases | map(select(.status == "failed" or .status == "blocked") | (.error_summary // "unknown")) | group_by(.) | map({error:.[0], count:length}) | sort_by(-.count) | .[] | "- \(.count)x `\(.error)`"' "${REPORT_FILE}")"

  mode_expectations=""
  if [[ "${MODE}" == "full" ]]; then
    local n expected_happy expected_rollback
    n="${#VERSIONS[@]}"
    expected_happy=$((n * (n - 1) / 2))
    expected_rollback="${n}"
    mode_expectations="- Expected happy cases: \`${expected_happy}\`\n- Expected rollback cases: \`${expected_rollback}\`"
  fi

  {
    echo "# Upgrade Matrix Summary"
    echo
    echo "- Run ID: \`${RUN_ID}\`"
    echo "- Mode: \`${MODE}\`"
    echo "- Started: \`${STARTED_AT}\`"
    echo "- Finished: \`${FINISHED_AT}\`"
    echo "- Workdir: \`${WORKDIR}\`"
    echo "- Versions in scope: \`${#VERSIONS[@]}\`"
    if [[ -n "${mode_expectations}" ]]; then
      printf "%b\n" "${mode_expectations}"
    fi
    echo
    echo "## Counts"
    echo
    echo "- Total: \`$(jq -r '.counts.total' "${REPORT_FILE}")\`"
    echo "- Passed: \`$(jq -r '.counts.passed' "${REPORT_FILE}")\`"
    echo "- Failed: \`$(jq -r '.counts.failed' "${REPORT_FILE}")\`"
    echo "- Blocked: \`$(jq -r '.counts.blocked' "${REPORT_FILE}")\`"
    echo "- Skipped: \`$(jq -r '.counts.skipped' "${REPORT_FILE}")\`"
    echo
    echo "## Failed/Blocked Cases"
    echo
    if [[ -z "${failed_rows}" ]]; then
      echo "_None_"
    else
      echo "| Case | Type | Source | Target | Status | Error | Artifacts |"
      echo "|---|---|---|---|---|---|---|"
      printf "%s\n" "${failed_rows}"
    fi
    echo
    echo "## Top Error Patterns"
    echo
    if [[ -z "${top_patterns}" ]]; then
      echo "- none"
    else
      printf "%s\n" "${top_patterns}"
    fi
  } >"${SUMMARY_FILE}"
}

final_exit_code() {
  local failed blocked
  failed="$(jq -r '.counts.failed' "${REPORT_FILE}")"
  blocked="$(jq -r '.counts.blocked' "${REPORT_FILE}")"
  if (( failed > 0 || blocked > 0 )); then
    return 1
  fi
  return 0
}

main() {
  trap on_exit_cleanup EXIT
  parse_args "$@"
  validate_args

  require_cmd bash
  require_cmd git
  require_cmd docker
  require_cmd jq
  require_cmd awk
  require_cmd sed
  require_cmd sort
  require_cmd tee
  require_cmd shasum

  if [[ ! -x "${UMBRELCTL}" ]]; then
    err "umbrelctl not found or not executable at ${UMBRELCTL}"
    exit 1
  fi

  prepare_paths
  fetch_versions
  generate_cases
  build_required_images
  execute_cases
  final_container_sweep
  write_report
  write_summary

  info "Report written to ${REPORT_FILE}"
  info "Summary written to ${SUMMARY_FILE}"

  if final_exit_code; then
    info "Upgrade matrix completed successfully."
    exit 0
  fi

  warn "Upgrade matrix completed with failed/blocked cases."
  exit 1
}

main "$@"
