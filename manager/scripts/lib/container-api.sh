#!/bin/bash
# container-api.sh - Container runtime API helper
# Provides functions to create/manage sibling containers via the host's
# container runtime socket (Docker or Podman compatible).
#
# The Manager container must be started with:
#   -v /var/run/docker.sock:/var/run/docker.sock --security-opt label=disable
# or (Podman rootful):
#   -v /run/podman/podman.sock:/var/run/docker.sock --security-opt label=disable
#
# Usage:
#   source /opt/hiclaw/scripts/lib/container-api.sh
#   container_api_available           # returns 0 if socket is mounted
#   container_create_worker "alice"   # create and start a worker container
#   container_stop_worker "alice"     # stop a worker container
#   container_remove_worker "alice"   # remove a worker container
#   container_logs_worker "alice"     # get worker container logs

CONTAINER_SOCKET="${HICLAW_CONTAINER_SOCKET:-/var/run/docker.sock}"
CONTAINER_API_BASE="http://localhost"
WORKER_IMAGE="${HICLAW_WORKER_IMAGE:-hiclaw/worker-agent:latest}"
WORKER_CONTAINER_PREFIX="hiclaw-worker-"

_log() {
    echo "[hiclaw-container $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

_api() {
    local method="$1"
    local path="$2"
    local data="$3"
    if [ -n "${data}" ]; then
        curl -s --unix-socket "${CONTAINER_SOCKET}" \
            -X "${method}" \
            -H 'Content-Type: application/json' \
            -d "${data}" \
            "${CONTAINER_API_BASE}${path}"
    else
        curl -s --unix-socket "${CONTAINER_SOCKET}" \
            -X "${method}" \
            "${CONTAINER_API_BASE}${path}"
    fi
}

_api_code() {
    local method="$1"
    local path="$2"
    local data="$3"
    if [ -n "${data}" ]; then
        curl -s -o /dev/null -w '%{http_code}' --unix-socket "${CONTAINER_SOCKET}" \
            -X "${method}" \
            -H 'Content-Type: application/json' \
            -d "${data}" \
            "${CONTAINER_API_BASE}${path}"
    else
        curl -s -o /dev/null -w '%{http_code}' --unix-socket "${CONTAINER_SOCKET}" \
            -X "${method}" \
            "${CONTAINER_API_BASE}${path}"
    fi
}

# Check if container runtime socket is available
container_api_available() {
    if [ ! -S "${CONTAINER_SOCKET}" ]; then
        return 1
    fi
    local version
    version=$(_api GET /version 2>/dev/null)
    if echo "${version}" | grep -q '"ApiVersion"' 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get the Manager container's own IP (for Worker to connect back)
container_get_manager_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

# Create and start a Worker container
# Usage: container_create_worker <worker_name> [fs_access_key] [fs_secret_key]
# Returns: container ID on success, empty on failure
container_create_worker() {
    local worker_name="$1"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    local manager_ip
    manager_ip=$(container_get_manager_ip)

    if [ -z "${manager_ip}" ]; then
        _log "ERROR: Cannot determine Manager container IP"
        return 1
    fi

    # Build environment variables for the Worker
    # Use internal port 8080 for Docker network communication
    local fs_domain="${HICLAW_FS_DOMAIN%%:*}"
    local fs_endpoint="http://${fs_domain}:8080"
    local fs_access_key="${2:-${HICLAW_MINIO_USER:-${HICLAW_ADMIN_USER:-admin}}}"
    local fs_secret_key="${3:-${HICLAW_MINIO_PASSWORD:-${HICLAW_ADMIN_PASSWORD:-admin}}}"

    # Build ExtraHosts for local domains (*-local.hiclaw.io) that need
    # in-container resolution back to the Manager. Skip if user provides
    # real DNS-resolvable domains.
    local extra_hosts=""
    local matrix_host="${HICLAW_MATRIX_DOMAIN%%:*}"
    local matrix_client_host="${HICLAW_MATRIX_CLIENT_DOMAIN:-matrix-client-local.hiclaw.io}"
    local ai_gw_host="${HICLAW_AI_GATEWAY_DOMAIN:-llm-local.hiclaw.io}"
    local fs_host="${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}"

    for h in "${matrix_host}" "${matrix_client_host}" "${ai_gw_host}" "${fs_host}"; do
        if [[ "${h}" == *-local.hiclaw.io ]]; then
            extra_hosts="${extra_hosts}\"${h}:${manager_ip}\","
        fi
    done
    extra_hosts="${extra_hosts%,}"

    _log "Creating Worker container: ${container_name}"
    _log "  Image: ${WORKER_IMAGE}"
    _log "  FS endpoint: ${fs_endpoint}"
    _log "  Manager IP: ${manager_ip}"

    # Remove existing container with same name (if any)
    local existing
    existing=$(_api GET "/containers/${container_name}/json" 2>/dev/null)
    if echo "${existing}" | grep -q '"Id"' 2>/dev/null; then
        _log "Removing existing container: ${container_name}"
        _api DELETE "/containers/${container_name}?force=true" > /dev/null 2>&1
        sleep 1
    fi

    # Create the container
    local host_config="{}"
    if [ -n "${extra_hosts}" ]; then
        host_config="{\"ExtraHosts\":[${extra_hosts}]}"
        _log "  ExtraHosts: ${extra_hosts}"
    fi

    local create_payload
    create_payload=$(cat <<PAYLOAD
{
    "Image": "${WORKER_IMAGE}",
    "Env": [
        "HICLAW_WORKER_NAME=${worker_name}",
        "HICLAW_FS_ENDPOINT=${fs_endpoint}",
        "HICLAW_FS_ACCESS_KEY=${fs_access_key}",
        "HICLAW_FS_SECRET_KEY=${fs_secret_key}"
    ],
    "HostConfig": ${host_config}
}
PAYLOAD
)

    local create_resp
    create_resp=$(_api POST "/containers/create?name=${container_name}" "${create_payload}")
    local container_id
    container_id=$(echo "${create_resp}" | jq -r '.Id // empty' 2>/dev/null)

    if [ -z "${container_id}" ]; then
        _log "ERROR: Failed to create container. Response: ${create_resp}"
        return 1
    fi

    _log "Container created: ${container_id:0:12}"

    # Start the container
    local start_code
    start_code=$(_api_code POST "/containers/${container_id}/start")
    if [ "${start_code}" != "204" ] && [ "${start_code}" != "304" ]; then
        _log "ERROR: Failed to start container (HTTP ${start_code})"
        return 1
    fi

    _log "Worker container ${container_name} started successfully"
    echo "${container_id}"
    return 0
}

# Start an existing stopped Worker container
# Use this to wake up a container that was previously stopped (preserves container config).
# Different from container_create_worker which creates a new container from scratch.
container_start_worker() {
    local worker_name="$1"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    local code
    code=$(_api_code POST "/containers/${container_name}/start")
    if [ "${code}" = "204" ] || [ "${code}" = "304" ]; then
        _log "Worker ${container_name} started"
        return 0
    fi
    _log "WARNING: Start returned HTTP ${code}"
    return 1
}

# Stop a Worker container
container_stop_worker() {
    local worker_name="$1"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    local code
    code=$(_api_code POST "/containers/${container_name}/stop?t=10")
    if [ "${code}" = "204" ] || [ "${code}" = "304" ]; then
        _log "Worker ${container_name} stopped"
        return 0
    fi
    _log "WARNING: Stop returned HTTP ${code}"
    return 1
}

# Remove a Worker container (force)
container_remove_worker() {
    local worker_name="$1"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    _api DELETE "/containers/${container_name}?force=true" > /dev/null 2>&1
    _log "Worker ${container_name} removed"
}

# Get Worker container logs
container_logs_worker() {
    local worker_name="$1"
    local tail="${2:-50}"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    _api GET "/containers/${container_name}/logs?stdout=true&stderr=true&tail=${tail}"
}

# Get Worker container status
# Returns: "running", "exited", "created", or "not_found"
container_status_worker() {
    local worker_name="$1"
    local container_name="${WORKER_CONTAINER_PREFIX}${worker_name}"
    local inspect
    inspect=$(_api GET "/containers/${container_name}/json" 2>/dev/null)
    if echo "${inspect}" | grep -q '"Id"' 2>/dev/null; then
        echo "${inspect}" | jq -r '.State.Status // "unknown"' 2>/dev/null
    else
        echo "not_found"
    fi
}

# List all HiClaw Worker containers
container_list_workers() {
    _api GET "/containers/json?all=true&filters=%7B%22name%22%3A%5B%22${WORKER_CONTAINER_PREFIX}%22%5D%7D" 2>/dev/null | \
        jq -r '.[] | "\(.Names[0] | ltrimstr("/") | ltrimstr("'"${WORKER_CONTAINER_PREFIX}"'"))\t\(.State)\t\(.Status)"' 2>/dev/null
}
