#!/bin/bash

set -euo pipefail

RUNNER_HOME=/home/docker/actions-runner
STATE_DIR=/runner-state
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
    if [[ -e "${runner_file}" && ! -L "${runner_file}" ]]; then
      echo "Refusing to replace existing runner configuration file: ${runner_file}" >&2
      exit 1
    fi
    ln -sfn "${STATE_DIR}/${state_file}" "${runner_file}"
  done
}

if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    sudo groupmod -g "$DOCKER_GID" docker 2>/dev/null || true
fi

cd "${RUNNER_HOME}"

prepare_state_links

if [[ "${EPHEMERAL:-false}" == "true" ]]; then
  echo "EPHEMERAL=true is incompatible with persistent runner state." >&2
  exit 1
fi

if state_is_configured; then
  echo "Existing runner registration found; starting without REG_TOKEN."
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
[ -n "${WORK_DIR:-}" ]     && CONFIG_ARGS+=(--work "${WORK_DIR}")
[ "${DISABLE_AUTO_UPDATE:-false}" = "true" ] && CONFIG_ARGS+=(--disableupdate)

umask 077
./config.sh "${CONFIG_ARGS[@]}"
umask 022

echo "Runner ${runner_name} registered successfully."
exec ./run.sh
