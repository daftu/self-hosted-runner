#!/bin/bash

set -euo pipefail

RUNNER_HOME=/home/docker/actions-runner
DATA_ROOT="${RUNNER_HOME}/.runner-data"
STATE_DIR=
WORK_PATH=
DIAG_PATH=
REPLICA_NAME=
RUNNER_WORK_DIR=
STATE_FILES=(
  .runner
  .runner_migrated
  .credentials
  .credentials_migrated
  .credentials_rsaparams
  .credential_store
  .certificates
  .options
  .setup_info
)

resolve_replica_storage() {
  local container_name

  if [[ ! -S /var/run/docker.sock ]]; then
    echo "Docker socket is required to resolve persistent runner storage." >&2
    exit 1
  fi

  container_name="$(curl --silent --show-error --fail \
    --unix-socket /var/run/docker.sock \
    "http://localhost/containers/${HOSTNAME}/json" | jq -r '.Name')"
  container_name="${container_name#/}"

  if [[ -z "${container_name}" || "${container_name}" == "null" || ! "${container_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Could not resolve a safe Docker Compose container name for persistent runner storage." >&2
    exit 1
  fi

  STATE_DIR="${DATA_ROOT}/${container_name}/state"
  DIAG_PATH="${DATA_ROOT}/${container_name}/diag"
  REPLICA_NAME="${container_name}"
}

link_persistent_directory() {
  local runner_path="$1" persistent_path="$2"

  mkdir -p "${persistent_path}"
  if [[ -L "${runner_path}" ]]; then
    ln -sfn "${persistent_path}" "${runner_path}"
    return
  fi
  if [[ -d "${runner_path}" ]]; then
    if [[ -n "$(find "${runner_path}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      echo "Refusing to replace non-empty runner directory: ${runner_path}" >&2
      exit 1
    fi
    rmdir "${runner_path}"
  elif [[ -e "${runner_path}" ]]; then
    echo "Refusing to replace runner path: ${runner_path}" >&2
    exit 1
  fi
  ln -s "${persistent_path}" "${runner_path}"
}

prepare_replica_storage() {
  local configured_work_dir

  configured_work_dir="${WORK_DIR:-_work}"
  if [[ "${configured_work_dir}" == /* || "${configured_work_dir}" == *".."* ]]; then
    echo "WORK_DIR must be a relative path inside the runner directory." >&2
    exit 1
  fi

  resolve_replica_storage
  RUNNER_WORK_DIR=".runner-data/${REPLICA_NAME}/${configured_work_dir}"
  WORK_PATH="${RUNNER_HOME}/${RUNNER_WORK_DIR}"

  mkdir -p "${STATE_DIR}" "${WORK_PATH}" "${DIAG_PATH}"
  chmod 700 "${STATE_DIR}" "${WORK_PATH}" "${DIAG_PATH}"
  link_persistent_directory "${RUNNER_HOME}/_diag" "${DIAG_PATH}"
  echo "Using persistent runner storage for ${REPLICA_NAME}."
}

migrate_work_directory() {
  local temporary_runner_file

  [[ -f "${STATE_DIR}/.runner" ]] || return
  if jq -e --arg work_folder "${RUNNER_WORK_DIR}" \
    '.workFolder == $work_folder' "${STATE_DIR}/.runner" >/dev/null; then
    return
  fi
  temporary_runner_file="$(mktemp "${STATE_DIR}/.runner.XXXXXX")"
  if ! jq --arg work_folder "${RUNNER_WORK_DIR}" \
    'if has("workFolder") then .workFolder = $work_folder else error("missing workFolder") end' \
    "${STATE_DIR}/.runner" > "${temporary_runner_file}"; then
    rm -f "${temporary_runner_file}"
    echo "Could not migrate the runner work directory." >&2
    exit 1
  fi
  chmod 600 "${temporary_runner_file}"
  mv "${temporary_runner_file}" "${STATE_DIR}/.runner"
}

state_is_configured() {
  [[ -f "${STATE_DIR}/.runner" ]] \
    && [[ -f "${STATE_DIR}/.credentials" ]] \
    && [[ -f "${STATE_DIR}/.credentials_rsaparams" ]]
}

state_has_files() {
  local state_file
  for state_file in "${STATE_FILES[@]}"; do
    [[ -e "${STATE_DIR}/${state_file}" ]] && return 0
  done
  return 1
}

prepare_state_links() {
  local state_file runner_file

  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"

  for state_file in "${STATE_FILES[@]}"; do
    runner_file="${RUNNER_HOME}/${state_file}"
    [[ -e "${STATE_DIR}/${state_file}" ]] || continue
    if [[ -e "${runner_file}" && ! -L "${runner_file}" ]]; then
      echo "Refusing to replace existing runner configuration file: ${runner_file}" >&2
      exit 1
    fi
    ln -sfn "${STATE_DIR}/${state_file}" "${runner_file}"
  done
}

persist_registration_state() {
  local state_file runner_file

  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"

  for state_file in "${STATE_FILES[@]}"; do
    runner_file="${RUNNER_HOME}/${state_file}"
    if [[ -L "${runner_file}" ]]; then
      echo "Unexpected state link before initial registration: ${runner_file}" >&2
      exit 1
    fi
    [[ -e "${runner_file}" ]] && mv "${runner_file}" "${STATE_DIR}/${state_file}"
  done

  if ! state_is_configured; then
    echo "Runner registration completed without all required state files." >&2
    exit 1
  fi

  prepare_state_links
}

if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    sudo groupmod -g "$DOCKER_GID" docker 2>/dev/null || true
fi

cd "${RUNNER_HOME}"
prepare_replica_storage

if [[ "${EPHEMERAL:-false}" == "true" ]]; then
  echo "EPHEMERAL=true is incompatible with persistent runner state." >&2
  exit 1
fi

if state_is_configured; then
  echo "Existing runner registration found; starting without REG_TOKEN."
  migrate_work_directory
  prepare_state_links
  exec ./run.sh
fi

if state_has_files; then
  echo "Runner state is incomplete. Remove the affected state volume or restore all registration files before starting." >&2
  exit 1
fi

: "${REPO:?REPO env var required for first registration}"
: "${REG_TOKEN:?REG_TOKEN env var required for first registration}"
: "${NAME:?NAME env var required for first registration}"

runner_suffix="${HOSTNAME:-$(hostname)}"
runner_suffix="${runner_suffix:0:12}"
runner_name="${NAME}-${runner_suffix}"

CONFIG_ARGS=(--unattended --url "https://github.com/${REPO}" --token "${REG_TOKEN}" --name "${runner_name}")

[ -n "${LABELS:-}" ]       && CONFIG_ARGS+=(--labels "${LABELS}")
[ -n "${RUNNER_GROUP:-}" ] && CONFIG_ARGS+=(--runnergroup "${RUNNER_GROUP}")
CONFIG_ARGS+=(--work "${RUNNER_WORK_DIR}")
[ "${DISABLE_AUTO_UPDATE:-true}" = "true" ] && CONFIG_ARGS+=(--disableupdate)

umask 077
./config.sh "${CONFIG_ARGS[@]}"
umask 022
persist_registration_state

echo "Runner ${runner_name} registered successfully."
exec ./run.sh
