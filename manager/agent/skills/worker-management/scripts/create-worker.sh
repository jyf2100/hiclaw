#!/bin/bash
# create-worker.sh - One-shot Worker creation script
#
# Automates the full Worker lifecycle: Matrix registration, room creation,
# Higress consumer setup, AI route & MCP authorization, config generation,
# MinIO sync, skills push, and container startup.
#
# Usage:
#   create-worker.sh --name <NAME> [--model <MODEL_ID>] [--mcp-servers s1,s2] [--skills s1,s2] [--room-key <KEY>] [--find-skills] [--skills-api-url <URL>] [--remote]
#
# Prerequisites:
#   - SOUL.md must already exist at ~/hiclaw-fs/agents/<NAME>/SOUL.md
#   - Environment: HICLAW_REGISTRATION_TOKEN, HICLAW_MATRIX_DOMAIN,
#     HICLAW_AI_GATEWAY_DOMAIN, HICLAW_ADMIN_USER, HIGRESS_COOKIE_FILE,
#     MANAGER_MATRIX_TOKEN

set -e
source /opt/hiclaw/scripts/lib/base.sh

# ============================================================
# Parse arguments
# ============================================================
WORKER_NAME=""
MODEL_ID=""
MCP_SERVERS=""
WORKER_SKILLS="file-sync"
ROOM_KEY=""
REMOTE_MODE=false
ENABLE_FIND_SKILLS=false
SKILLS_API_URL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name)       WORKER_NAME="$2"; shift 2 ;;
        --model)      MODEL_ID="$2"; shift 2 ;;
        --mcp-servers) MCP_SERVERS="$2"; shift 2 ;;
        --skills)     WORKER_SKILLS="$2"; shift 2 ;;
        --room-key)   ROOM_KEY="$2"; shift 2 ;;
        --find-skills) ENABLE_FIND_SKILLS=true; shift ;;
        --skills-api-url) SKILLS_API_URL="$2"; shift 2 ;;
        --remote)     REMOTE_MODE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${WORKER_NAME}" ]; then
    echo "Usage: create-worker.sh --name <NAME> [--model <MODEL_ID>] [--mcp-servers s1,s2] [--skills s1,s2] [--room-key <KEY>] [--find-skills] [--skills-api-url <URL>] [--remote]"
    exit 1
fi

# If find-skills is enabled, add it to the skills list
# Fallback: if HICLAW_SKILLS_API_URL env is set and no --skills-api-url was passed, use it
if [ -z "${SKILLS_API_URL}" ] && [ -n "${HICLAW_SKILLS_API_URL}" ]; then
    SKILLS_API_URL="${HICLAW_SKILLS_API_URL}"
fi
if [ "${ENABLE_FIND_SKILLS}" = true ]; then
    if ! echo "${WORKER_SKILLS}" | grep -q '\bfind-skills\b'; then
        WORKER_SKILLS="${WORKER_SKILLS},find-skills"
    fi
fi

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
MATRIX_SERVER="${HICLAW_MATRIX_SERVER:-${MATRIX_SERVER}}"
ADMIN_USER="${HICLAW_ADMIN_USER:-admin}"
MANAGER_USER="${HICLAW_MANAGER_USER:-manager}"
CONSUMER_NAME="worker-${WORKER_NAME}"
SOUL_FILE="/root/hiclaw-fs/agents/${WORKER_NAME}/SOUL.md"

if [ ! -f "${SOUL_FILE}" ]; then
    echo '{"error": "SOUL.md not found at '"${SOUL_FILE}"'. Write it first, then re-run."}'
    exit 1
fi

_fail() {
    echo '{"error": "'"$1"'"}'
    exit 1
}

# ============================================================
# Ensure credentials are available
# ============================================================
SECRETS_FILE="/data/hiclaw-secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
fi

if [ -z "${MANAGER_MATRIX_TOKEN}" ]; then
    MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD:-}"
    if [ -z "${MANAGER_PASSWORD}" ]; then
        _fail "MANAGER_MATRIX_TOKEN not set and HICLAW_MANAGER_PASSWORD not available"
    fi
    MANAGER_MATRIX_TOKEN=$(curl -sf -X POST ${MATRIX_SERVER}/_matrix/client/v3/login \
        -H 'Content-Type: application/json' \
        -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"manager"},"password":"'"${MANAGER_PASSWORD}"'"}' \
        2>/dev/null | jq -r '.access_token // empty')
    if [ -z "${MANAGER_MATRIX_TOKEN}" ]; then
        _fail "Failed to obtain Manager Matrix token"
    fi
    log "Obtained Manager Matrix token via login"
fi

if [ -z "${HIGRESS_COOKIE_FILE}" ] || [ ! -s "${HIGRESS_COOKIE_FILE}" ]; then
    HIGRESS_COOKIE_FILE="/tmp/higress-session-cookie-worker-create"
    ADMIN_PASSWORD="${HICLAW_ADMIN_PASSWORD:-admin}"
    curl -sf -o /dev/null -X POST http://127.0.0.1:8001/session/login \
        -H 'Content-Type: application/json' \
        -c "${HIGRESS_COOKIE_FILE}" \
        -d '{"username":"'"${ADMIN_USER}"'","password":"'"${ADMIN_PASSWORD}"'"}' 2>/dev/null \
        || _fail "Failed to login to Higress Console"
    log "Obtained Higress session cookie via login"
fi

# ============================================================
# Step 1: Register Matrix Account
# ============================================================
log "Step 1: Registering Matrix account for ${WORKER_NAME}..."
WORKER_USER_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"
WORKER_CREDS_FILE="/data/worker-creds/${WORKER_NAME}.env"
mkdir -p /data/worker-creds

# Reuse persisted password if available, otherwise generate new
if [ -f "${WORKER_CREDS_FILE}" ]; then
    source "${WORKER_CREDS_FILE}"
    log "  Loaded persisted credentials for ${WORKER_NAME}"
else
    WORKER_PASSWORD=$(generateKey 16)
fi
[ -z "${WORKER_MINIO_PASSWORD}" ] && WORKER_MINIO_PASSWORD=$(generateKey 24)

REG_RESP=$(curl -s -X POST ${MATRIX_SERVER}/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "'"${WORKER_NAME}"'",
        "password": "'"${WORKER_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' 2>/dev/null) || true

if echo "${REG_RESP}" | jq -e '.access_token' > /dev/null 2>&1; then
    WORKER_MATRIX_TOKEN=$(echo "${REG_RESP}" | jq -r '.access_token')
    log "  Registered new account: ${WORKER_USER_ID}"
else
    # Account already exists — login with persisted password
    log "  Account exists, logging in..."
    LOGIN_RESP=$(curl -s -X POST ${MATRIX_SERVER}/_matrix/client/v3/login \
        -H 'Content-Type: application/json' \
        -d '{
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": "'"${WORKER_NAME}"'"},
            "password": "'"${WORKER_PASSWORD}"'"
        }' 2>/dev/null) || true

    if echo "${LOGIN_RESP}" | jq -e '.access_token' > /dev/null 2>&1; then
        WORKER_MATRIX_TOKEN=$(echo "${LOGIN_RESP}" | jq -r '.access_token')
        log "  Logged in: ${WORKER_USER_ID}"
    else
        _fail "Failed to register or login Matrix account for ${WORKER_NAME}. If re-creating, delete /data/worker-creds/${WORKER_NAME}.env and try again."
    fi
fi

# Pre-generate gateway key if not loaded from persisted creds (for new workers)
[ -z "${WORKER_GATEWAY_KEY}" ] && WORKER_GATEWAY_KEY=$(generateKey 32)

# Persist credentials for future re-creation
cat > "${WORKER_CREDS_FILE}" <<CREDS
WORKER_PASSWORD="${WORKER_PASSWORD}"
WORKER_MINIO_PASSWORD="${WORKER_MINIO_PASSWORD}"
WORKER_GATEWAY_KEY="${WORKER_GATEWAY_KEY}"
CREDS
chmod 600 "${WORKER_CREDS_FILE}"

# ============================================================
# Step 1b: Create MinIO user with restricted permissions
# ============================================================
log "Step 1b: Creating MinIO user for ${WORKER_NAME}..."
POLICY_NAME="worker-${WORKER_NAME}"
POLICY_FILE=$(mktemp /tmp/minio-policy-XXXXXX.json)
cat > "${POLICY_FILE}" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::hiclaw-storage"],
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "agents/${WORKER_NAME}", "agents/${WORKER_NAME}/*",
            "shared", "shared/*"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::hiclaw-storage/agents/${WORKER_NAME}/*",
        "arn:aws:s3:::hiclaw-storage/shared/*"
      ]
    }
  ]
}
POLICY
mc admin user add hiclaw "${WORKER_NAME}" "${WORKER_MINIO_PASSWORD}" 2>/dev/null || true
mc admin policy remove hiclaw "${POLICY_NAME}" 2>/dev/null || true
mc admin policy create hiclaw "${POLICY_NAME}" "${POLICY_FILE}"
mc admin policy attach hiclaw "${POLICY_NAME}" --user "${WORKER_NAME}"
rm -f "${POLICY_FILE}"
log "  MinIO user ${WORKER_NAME} created with policy ${POLICY_NAME}"

# ============================================================
# Step 2: Create or Reuse Matrix Room (3-party)
# ============================================================
log "Step 2: Checking for existing Matrix room..."

# Function to URL encode room ID
_url_encode_room() {
    python3 -c "import urllib.parse; print(urllib.parse.quote(\"$1\", safe=''))"
}

# Normalize department/worker id for room-key generation
normalize_dept() {
    local d
    d=$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)
    case "$d" in
        libu-hr) echo "libu_hr" ;;
        *) echo "$d" ;;
    esac
}

# Room key templates:
#   make_room_key core
#   make_room_key exec gongbu
#   make_room_key cross gongbu hubu
#   make_room_key incident TASK-123
make_room_key() {
    local kind="${1:?kind required}"
    shift || true

    case "${kind}" in
        core)
            echo "core-governance"
            ;;
        exec)
            local dept="${1:?dept required}"
            echo "exec:$(normalize_dept "${dept}")"
            ;;
        cross)
            [ "$#" -ge 2 ] || { echo "cross requires >=2 departments" >&2; return 1; }
            printf '%s\n' "$@" \
                | while read -r d; do normalize_dept "$d"; done \
                | sort -u \
                | paste -sd+ - \
                | sed 's/^/cross:/'
            ;;
        incident)
            local task_id="${1:-global}"
            echo "incident:${task_id}"
            ;;
        *)
            echo "unknown kind: ${kind}" >&2
            return 1
            ;;
    esac
}

# Send a Matrix message with explicit @mention (MSC3952)
# usage: send_mentioned_message <room_id> <target_user_id> <text> [sender_token]
send_mentioned_message() {
    local room_id="${1:?room_id required}"
    local target_user_id="${2:?target_user_id required}"
    local text="${3:?text required}"
    local sender_token="${4:-${MANAGER_MATRIX_TOKEN:-}}"

    if [ -z "${sender_token}" ]; then
        echo "send_mentioned_message: sender token missing" >&2
        return 1
    fi

    local encoded_room
    encoded_room=$(_url_encode_room "${room_id}")

    local txn_id
    txn_id="$(date +%s%3N)-${RANDOM}"

    local msg_body payload resp http_code event_id
    msg_body="${target_user_id} ${text}"
    payload=$(jq -cn --arg body "${msg_body}" --arg uid "${target_user_id}" '{
        msgtype: "m.text",
        body: $body,
        "m.mentions": { user_ids: [$uid] }
    }')

    resp=$(curl -sS -w '\n%{http_code}' -X PUT "${MATRIX_SERVER}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}" \
        -H "Authorization: Bearer ${sender_token}" \
        -H 'Content-Type: application/json' \
        -d "${payload}" 2>/dev/null || true)

    http_code=$(echo "${resp}" | tail -n1)
    event_id=$(echo "${resp}" | sed '$d' | jq -r '.event_id // empty' 2>/dev/null || true)

    if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]] && [ -n "${event_id}" ]; then
        echo "${event_id}"
        return 0
    fi

    log "  WARNING: Failed to send mention to ${target_user_id} in room ${room_id} (HTTP ${http_code:-curl_error})"
    return 1
}

# Ensure a Matrix user is invited into a room (idempotent best-effort with warning)
# usage: ensure_room_member <room_id> <target_user_id> [sender_token]
ensure_room_member() {
    local room_id="${1:?room_id required}"
    local target_user_id="${2:?target_user_id required}"
    local sender_token="${3:-${MANAGER_MATRIX_TOKEN:-}}"

    [ -z "${sender_token}" ] && return 1

    local encoded_room
    encoded_room=$(_url_encode_room "${room_id}")

    local payload
    payload=$(jq -cn --arg uid "${target_user_id}" '{user_id: $uid}')

    local http_code
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${MATRIX_SERVER}/_matrix/client/v3/rooms/${encoded_room}/invite" \
        -H "Authorization: Bearer ${sender_token}" \
        -H 'Content-Type: application/json' \
        -d "${payload}" 2>/dev/null || true)

    case "${http_code}" in
        2*)
            return 0
            ;;
        *)
            log "  WARNING: Failed to invite ${target_user_id} into room ${room_id} (HTTP ${http_code:-curl_error})"
            return 1
            ;;
    esac
}

# Get workers that should interact with current worker for this room_key
# - If registry has .rooms schema, scope to same room_key members
# - Otherwise fallback to legacy behavior (all existing workers)
get_room_peer_workers() {
    local registry_file="${1:?registry file required}"
    local room_key="${2:?room_key required}"
    local self_worker="${3:?self worker required}"

    if [ ! -f "${registry_file}" ]; then
        return 0
    fi

    if jq -e --arg rk "${room_key}" '.rooms[$rk].members? != null' "${registry_file}" >/dev/null 2>&1; then
        jq -r --arg rk "${room_key}" --arg self "${self_worker}" \
            '.rooms[$rk].members // [] | .[] | select(. != $self)' \
            "${registry_file}" 2>/dev/null || true
    else
        jq -r --arg self "${self_worker}" \
            '.workers | keys[] | select(. != $self)' \
            "${registry_file}" 2>/dev/null || true
    fi
}

# Compute effective room key for this worker
# Default to exec:<worker> for backward-compatible one-worker-one-room behavior
if [ -z "${ROOM_KEY}" ]; then
    ROOM_KEY=$(make_room_key exec "${WORKER_NAME}")
fi

# Check if room already exists in registry
REGISTRY_FILE_CHECK="${HOME}/workers-registry.json"
EXISTING_ROOM_ID=""
ROOM_REUSE=false

if [ -f "${REGISTRY_FILE_CHECK}" ]; then
    EXISTING_ROOM_ID=$(jq -r --arg rk "${ROOM_KEY}" '.rooms[$rk].room_id // empty' "${REGISTRY_FILE_CHECK}" 2>/dev/null || true)

    # Backward compatibility: if no rooms map and room_key is default exec:<worker>, use per-worker room_id
    if [ -z "${EXISTING_ROOM_ID}" ] && [ "${ROOM_KEY}" = "exec:${WORKER_NAME}" ]; then
        EXISTING_ROOM_ID=$(jq -r --arg w "${WORKER_NAME}" '.workers[$w].room_id // empty' "${REGISTRY_FILE_CHECK}" 2>/dev/null || true)
    fi
fi

if [ -n "${EXISTING_ROOM_ID}" ]; then
    log "  Found existing room in registry: ${EXISTING_ROOM_ID}"

    # Check if Manager is still in this room
    ENCODED_ROOM=$(_url_encode_room "${EXISTING_ROOM_ID}")
    ROOM_STATE_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
        "${MATRIX_SERVER}/_matrix/client/v3/rooms/${ENCODED_ROOM}/state/m.room.name" \
        -H "Authorization: Bearer ${MANAGER_MATRIX_TOKEN}" 2>/dev/null || true)

    if [[ "${ROOM_STATE_CODE}" =~ ^2[0-9][0-9]$ ]]; then
        # Room exists and Manager is in it - reuse it
        ROOM_ID="${EXISTING_ROOM_ID}"
        ROOM_REUSE=true
        log "  ✅ Reusing existing room: ${ROOM_ID}"
    else
        log "  ⚠️ Existing room check failed (HTTP ${ROOM_STATE_CODE:-curl_error}), will create new room"
        EXISTING_ROOM_ID=""
    fi
fi

# Create new room if not reusing
if [ "${ROOM_REUSE}" = false ]; then
    log "  Creating new Matrix room..."
    ROOM_PAYLOAD=$(jq -cn \
        --arg rk "${ROOM_KEY}" \
        --arg admin "@${ADMIN_USER}:${MATRIX_DOMAIN}" \
        --arg manager "@${MANAGER_USER}:${MATRIX_DOMAIN}" \
        --arg worker "@${WORKER_NAME}:${MATRIX_DOMAIN}" \
        '{
            name: ("Worker Group: " + $rk),
            topic: ("Worker collaboration room (" + $rk + ")"),
            invite: [$admin, $manager, $worker],
            preset: "trusted_private_chat"
        }')

    ROOM_RESP=$(curl -sf -X POST ${MATRIX_SERVER}/_matrix/client/v3/createRoom \
        -H "Authorization: Bearer ${MANAGER_MATRIX_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "${ROOM_PAYLOAD}" 2>/dev/null) || _fail "Failed to create Matrix room"

    ROOM_ID=$(echo "${ROOM_RESP}" | jq -r '.room_id // empty')
    if [ -z "${ROOM_ID}" ]; then
        _fail "Failed to create Matrix room: ${ROOM_RESP}"
    fi
    log "  Room created: ${ROOM_ID}"
fi

# Ensure current worker/admin/manager are members of the interaction room
ensure_room_member "${ROOM_ID}" "@${WORKER_NAME}:${MATRIX_DOMAIN}" "${MANAGER_MATRIX_TOKEN}" || true
ensure_room_member "${ROOM_ID}" "@${ADMIN_USER}:${MATRIX_DOMAIN}" "${MANAGER_MATRIX_TOKEN}" || true
ensure_room_member "${ROOM_ID}" "@${MANAGER_USER}:${MATRIX_DOMAIN}" "${MANAGER_MATRIX_TOKEN}" || true

# ============================================================
# Step 3: Create Higress Consumer (key-auth)
# ============================================================
log "Step 3: Creating Higress consumer..."
WORKER_KEY="${WORKER_GATEWAY_KEY}"
CONSUMER_RESP=$(curl -sf -X POST http://127.0.0.1:8001/v1/consumers \
    -b "${HIGRESS_COOKIE_FILE}" \
    -H 'Content-Type: application/json' \
    -d '{
        "name": "'"${CONSUMER_NAME}"'",
        "credentials": [{
            "type": "key-auth",
            "source": "BEARER",
            "values": ["'"${WORKER_KEY}"'"]
        }]
    }' 2>/dev/null) || _fail "Failed to create Higress consumer"
log "  Consumer created: ${CONSUMER_NAME}"

# ============================================================
# Step 4: Authorize all AI Routes
# ============================================================
log "Step 4: Authorizing AI routes..."
AI_ROUTES=$(curl -sf http://127.0.0.1:8001/v1/ai/routes \
    -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null) || _fail "Failed to list AI routes"

ROUTE_NAMES=$(echo "${AI_ROUTES}" | jq -r '.data[]?.name // empty' 2>/dev/null || true)
for route_name in ${ROUTE_NAMES}; do
    [ -z "${route_name}" ] && continue
    ROUTE_RESP=$(curl -sf "http://127.0.0.1:8001/v1/ai/routes/${route_name}" \
        -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null) || continue
    ROUTE=$(echo "${ROUTE_RESP}" | jq '.data // .' 2>/dev/null)

    ALREADY=$(echo "${ROUTE}" | jq -r '.authConfig.allowedConsumers[]? // empty' 2>/dev/null | grep -c "^${CONSUMER_NAME}$" || true)
    if [ "${ALREADY}" -gt 0 ]; then
        log "  Route ${route_name}: already authorized"
        continue
    fi

    UPDATED=$(echo "${ROUTE}" | jq --arg c "${CONSUMER_NAME}" '.authConfig.allowedConsumers += [$c]')
    curl -sf -X PUT "http://127.0.0.1:8001/v1/ai/routes/${route_name}" \
        -b "${HIGRESS_COOKIE_FILE}" \
        -H 'Content-Type: application/json' \
        -d "${UPDATED}" > /dev/null 2>&1 || log "  WARNING: Failed to update route ${route_name}"
    log "  Route ${route_name}: authorized"
done

# ============================================================
# Step 5: Authorize MCP Servers
# ============================================================
log "Step 5: Authorizing MCP servers..."
ALL_MCP_RAW=$(curl -sf http://127.0.0.1:8001/v1/mcpServer \
    -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null) || true
ALL_MCP=$(echo "${ALL_MCP_RAW}" | jq '.data // .' 2>/dev/null || echo "${ALL_MCP_RAW}")

if [ -n "${MCP_SERVERS}" ]; then
    TARGET_MCP_LIST="${MCP_SERVERS}"
else
    TARGET_MCP_LIST=$(echo "${ALL_MCP}" | jq -r '.[].name // empty' 2>/dev/null | tr '\n' ',' || true)
    TARGET_MCP_LIST="${TARGET_MCP_LIST%,}"
fi

if [ -n "${TARGET_MCP_LIST}" ]; then
    IFS=',' read -ra MCP_ARR <<< "${TARGET_MCP_LIST}"
    for mcp_name in "${MCP_ARR[@]}"; do
        mcp_name=$(echo "${mcp_name}" | tr -d ' ')
        [ -z "${mcp_name}" ] && continue

        EXISTING_CONSUMERS=$(echo "${ALL_MCP}" | jq -r --arg n "${mcp_name}" \
            '.[] | select(.name == $n) | .consumerAuthInfo.allowedConsumers // [] | .[]' 2>/dev/null || true)
        CONSUMER_LIST="[\"manager\""
        for ec in ${EXISTING_CONSUMERS}; do
            [ "${ec}" = "manager" ] && continue
            [ "${ec}" = "${CONSUMER_NAME}" ] && continue
            CONSUMER_LIST="${CONSUMER_LIST},\"${ec}\""
        done
        CONSUMER_LIST="${CONSUMER_LIST},\"${CONSUMER_NAME}\"]"

        curl -sf -X PUT http://127.0.0.1:8001/v1/mcpServer/consumers \
            -b "${HIGRESS_COOKIE_FILE}" \
            -H 'Content-Type: application/json' \
            -d '{"mcpServerName":"'"${mcp_name}"'","consumers":'"${CONSUMER_LIST}"'}' > /dev/null 2>&1 \
            || log "  WARNING: Failed to authorize MCP server ${mcp_name}"
        log "  MCP ${mcp_name}: authorized"
    done
else
    log "  No MCP servers found, skipping"
fi

# ============================================================
# Step 6: Generate openclaw.json
# ============================================================
log "Step 6: Generating openclaw.json..."
GEN_ARGS=("${WORKER_NAME}" "${WORKER_MATRIX_TOKEN}" "${WORKER_KEY}")
if [ -n "${MODEL_ID}" ]; then
    GEN_ARGS+=("${MODEL_ID}")
fi
bash /opt/hiclaw/agent/skills/worker-management/scripts/generate-worker-config.sh "${GEN_ARGS[@]}"

# Generate mcporter-servers.json if MCP servers are authorized
if [ -n "${TARGET_MCP_LIST}" ]; then
    log "  Generating mcporter-servers.json..."
    # MCP servers are hosted on the AI Gateway domain
    AIGW_DOMAIN="${HICLAW_AI_GATEWAY_DOMAIN:-aigw-local.hiclaw.io}"
    MCPORTER_JSON='{"mcpServers":{'
    FIRST=true
    IFS=',' read -ra MCP_ARR2 <<< "${TARGET_MCP_LIST}"
    for mcp_name in "${MCP_ARR2[@]}"; do
        mcp_name=$(echo "${mcp_name}" | tr -d ' ')
        [ -z "${mcp_name}" ] && continue
        if [ "${FIRST}" = true ]; then FIRST=false; else MCPORTER_JSON="${MCPORTER_JSON},"; fi
        MCPORTER_JSON="${MCPORTER_JSON}\"${mcp_name}\":{\"url\":\"http://${AIGW_DOMAIN}:8080/mcp-servers/${mcp_name}/mcp\",\"transport\":\"http\",\"headers\":{\"Authorization\":\"Bearer ${WORKER_KEY}\"}}"
    done
    MCPORTER_JSON="${MCPORTER_JSON}}}"
    echo "${MCPORTER_JSON}" | jq . > "/root/hiclaw-fs/agents/${WORKER_NAME}/mcporter-servers.json"
fi

# ============================================================
# Step 6.5: Add existing Workers to new Worker's groupAllowFrom
# ============================================================
log "Step 6.5: Adding existing Workers to new Worker's groupAllowFrom..."
NEW_WORKER_CONFIG="/root/hiclaw-fs/agents/${WORKER_NAME}/openclaw.json"
REGISTRY_FILE_EARLY="${HOME}/workers-registry.json"
if [ -f "${REGISTRY_FILE_EARLY}" ]; then
    TARGET_PEERS=$(get_room_peer_workers "${REGISTRY_FILE_EARLY}" "${ROOM_KEY}" "${WORKER_NAME}")
    for ew in ${TARGET_PEERS}; do
        EW_ID="@${ew}:${MATRIX_DOMAIN}"
        # Ensure worker is invited into shared room for interaction
        ensure_room_member "${ROOM_ID}" "${EW_ID}" "${MANAGER_MATRIX_TOKEN}" || true

        ALREADY=$(jq -r --arg w "${EW_ID}" \
            '.channels.matrix.groupAllowFrom // [] | map(select(. == $w)) | length' \
            "${NEW_WORKER_CONFIG}" 2>/dev/null || echo "0")
        if [ "${ALREADY}" = "0" ]; then
            jq --arg w "${EW_ID}" '.channels.matrix.groupAllowFrom += [$w]' \
                "${NEW_WORKER_CONFIG}" > /tmp/new-worker-oclaw-tmp.json
            mv /tmp/new-worker-oclaw-tmp.json "${NEW_WORKER_CONFIG}"
            log "  Added @${ew} to new worker's groupAllowFrom"
        fi
    done
else
    log "  No existing registry, skipping"
fi

# ============================================================
# Step 7: Update Manager groupAllowFrom
# ============================================================
log "Step 7: Updating Manager groupAllowFrom..."
MANAGER_CONFIG="${HOME}/openclaw.json"
WORKER_MATRIX_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"
if [ -f "${MANAGER_CONFIG}" ]; then
    ALREADY_IN=$(jq -r --arg w "${WORKER_MATRIX_ID}" \
        '.channels.matrix.groupAllowFrom // [] | map(select(. == $w)) | length' \
        "${MANAGER_CONFIG}" 2>/dev/null || echo "0")
    if [ "${ALREADY_IN}" = "0" ]; then
        jq --arg w "${WORKER_MATRIX_ID}" \
            '.channels.matrix.groupAllowFrom += [$w]' \
            "${MANAGER_CONFIG}" > /tmp/manager-config-updated.json
        mv /tmp/manager-config-updated.json "${MANAGER_CONFIG}"
        log "  Added ${WORKER_MATRIX_ID} to groupAllowFrom"
    else
        log "  ${WORKER_MATRIX_ID} already in groupAllowFrom"
    fi
fi

# ============================================================
# Step 8: Sync to MinIO
# ============================================================
log "Step 8: Syncing to MinIO..."
mc mirror "/root/hiclaw-fs/agents/${WORKER_NAME}/" "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" --overwrite 2>&1 | tail -5
mc stat "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/SOUL.md" > /dev/null 2>&1 \
    || _fail "SOUL.md not found in MinIO after sync"
mc stat "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/openclaw.json" > /dev/null 2>&1 \
    || _fail "openclaw.json not found in MinIO after sync"
log "  MinIO sync verified"

# Push Worker agent files from Manager image (AGENTS.md + file-sync skill)
WORKER_AGENT_SRC="/opt/hiclaw/agent/worker-agent"
if [ -d "${WORKER_AGENT_SRC}" ]; then
    log "  Pushing AGENTS.md (with builtin markers) to worker MinIO..."
    mc cp "${WORKER_AGENT_SRC}/AGENTS.md" \
        "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/AGENTS.md" \
        || log "  WARNING: Failed to push AGENTS.md"
    log "  Pushing file-sync skill to worker MinIO..."
    mc mirror "${WORKER_AGENT_SRC}/skills/file-sync/" \
        "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/skills/file-sync/" --overwrite \
        || log "  WARNING: Failed to push file-sync skill"
    log "  Worker agent files pushed"
else
    log "  WARNING: worker-agent directory not found at ${WORKER_AGENT_SRC}"
fi

# ============================================================
# Step 8b: Add new Worker to all existing Workers' groupAllowFrom
# ============================================================
log "Step 8b: Updating existing Workers' groupAllowFrom..."
if [ -f "${REGISTRY_FILE_EARLY}" ]; then
    TARGET_PEERS=$(get_room_peer_workers "${REGISTRY_FILE_EARLY}" "${ROOM_KEY}" "${WORKER_NAME}")
    for ew in ${TARGET_PEERS}; do
        EW_MINIO="hiclaw/hiclaw-storage/agents/${ew}/openclaw.json"
        EW_TMP="/tmp/openclaw-${ew}-update.json"
        EW_TMP_OUT="/tmp/openclaw-${ew}-updated.json"

        if ! mc cp "${EW_MINIO}" "${EW_TMP}" 2>/dev/null; then
            log "  WARNING: Could not pull openclaw.json for ${ew} from MinIO, skipping"
            continue
        fi

        ALREADY=$(jq -r --arg w "${WORKER_MATRIX_ID}" \
            '.channels.matrix.groupAllowFrom // [] | map(select(. == $w)) | length' \
            "${EW_TMP}" 2>/dev/null || echo "0")

        if [ "${ALREADY}" = "0" ]; then
            jq --arg w "${WORKER_MATRIX_ID}" '.channels.matrix.groupAllowFrom += [$w]' \
                "${EW_TMP}" > "${EW_TMP_OUT}"
            if mc cp "${EW_TMP_OUT}" "${EW_MINIO}" 2>/dev/null; then
                log "  Updated ${ew}: added ${WORKER_MATRIX_ID} to groupAllowFrom"
                # Notify peer worker in shared interaction room to run hiclaw-sync
                EVENT_ID=$(send_mentioned_message "${ROOM_ID}" "@${ew}:${MATRIX_DOMAIN}" "Your config has been updated (new worker @${WORKER_NAME}:${MATRIX_DOMAIN} added to groupAllowFrom). Please run: hiclaw-sync" "${MANAGER_MATRIX_TOKEN}" || true)
                if [ -n "${EVENT_ID}" ]; then
                    log "  Notified @${ew} to run hiclaw-sync"
                else
                    log "  WARNING: Failed to notify @${ew}"
                fi
            else
                log "  WARNING: Failed to push updated config for ${ew} to MinIO"
            fi
            rm -f "${EW_TMP}" "${EW_TMP_OUT}"
        else
            log "  ${ew}: already has ${WORKER_MATRIX_ID} in groupAllowFrom"
            rm -f "${EW_TMP}"
        fi
    done
else
    log "  No existing registry, skipping"
fi

# ============================================================
# Step 8.5: Update workers-registry.json and push skills
# ============================================================
log "Step 8.5: Updating workers-registry and pushing skills..."
REGISTRY_FILE="${HOME}/workers-registry.json"

# Ensure registry file exists
if [ ! -f "${REGISTRY_FILE}" ]; then
    log "  Initializing workers-registry.json..."
    echo '{"version":1,"updated_at":"","workers":{}}' > "${REGISTRY_FILE}"
fi

# Build skills JSON array from WORKER_SKILLS (comma-separated)
SKILLS_JSON="["
FIRST_SKILL=true
# Ensure file-sync is always included
SKILLS_WITH_FILESYNC="${WORKER_SKILLS}"
if ! echo "${SKILLS_WITH_FILESYNC}" | grep -q '\bfile-sync\b'; then
    SKILLS_WITH_FILESYNC="file-sync,${SKILLS_WITH_FILESYNC}"
fi
IFS=',' read -ra SKILL_ARR <<< "${SKILLS_WITH_FILESYNC}"
for skill in "${SKILL_ARR[@]}"; do
    skill=$(echo "${skill}" | tr -d ' ')
    [ -z "${skill}" ] && continue
    if [ "${FIRST_SKILL}" = true ]; then FIRST_SKILL=false; else SKILLS_JSON="${SKILLS_JSON},"; fi
    SKILLS_JSON="${SKILLS_JSON}\"${skill}\""
done
SKILLS_JSON="${SKILLS_JSON}]"

# Upsert worker entry into registry
NOW_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
WORKER_MATRIX_USER_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"

jq --arg w "${WORKER_NAME}" \
   --arg uid "${WORKER_MATRIX_USER_ID}" \
   --arg rid "${ROOM_ID}" \
   --arg rk "${ROOM_KEY}" \
   --arg ts "${NOW_TS}" \
   --argjson skills "${SKILLS_JSON}" \
   '.workers[$w] = {
     "matrix_user_id": $uid,
     "room_id": $rid,
     "room_key": $rk,
     "skills": $skills,
     "created_at": (if .workers[$w].created_at? then .workers[$w].created_at else $ts end),
     "skills_updated_at": $ts
   }
   | .rooms = (.rooms // {})
   | .rooms[$rk] = {
       room_id: $rid,
       members: (((.rooms[$rk].members // []) + [$w]) | unique),
       updated_at: $ts
     }
   | .updated_at = $ts' \
   "${REGISTRY_FILE}" > /tmp/workers-registry-updated.json
mv /tmp/workers-registry-updated.json "${REGISTRY_FILE}"

log "  Registry updated for ${WORKER_NAME}: room_key=${ROOM_KEY}, skills=${SKILLS_WITH_FILESYNC}"

# Push skills to worker's MinIO workspace (Worker not yet started, no notification)
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh \
    --worker "${WORKER_NAME}" --no-notify \
    || log "  WARNING: push-worker-skills.sh returned non-zero (non-fatal)"

# ============================================================
# Step 9: Start Worker
# ============================================================
DEPLOY_MODE="remote"
CONTAINER_ID=""
INSTALL_CMD=""
WORKER_STATUS="pending_install"

source /opt/hiclaw/scripts/lib/container-api.sh

_build_install_cmd() {
    local manager_ip
    manager_ip=$(container_get_manager_ip 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    local fs_endpoint="http://${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}:8080"
    local fs_access_key="${WORKER_NAME}"
    local fs_secret_key="${WORKER_MINIO_PASSWORD}"

    local cmd="bash hiclaw-install.sh worker --name ${WORKER_NAME} --fs ${fs_endpoint} --fs-key ${fs_access_key} --fs-secret ${fs_secret_key}"

    # Add find-skills related options if enabled
    if [ "${ENABLE_FIND_SKILLS}" = true ]; then
        cmd="${cmd} --find-skills"
        if [ -n "${SKILLS_API_URL}" ]; then
            cmd="${cmd} --skills-api-url ${SKILLS_API_URL}"
        fi
    fi

    echo "${cmd}"
}

# Build extra environment variables JSON for container creation
_build_extra_env() {
    local extra_env="[]"
    if [ "${ENABLE_FIND_SKILLS}" = true ] && [ -n "${SKILLS_API_URL}" ]; then
        extra_env='["SKILLS_API_URL='"${SKILLS_API_URL}"'"]'
    fi
    echo "${extra_env}"
}

if [ "${REMOTE_MODE}" = true ]; then
    log "Step 9: Remote mode requested"
    INSTALL_CMD=$(_build_install_cmd)
elif container_api_available; then
    log "Step 9: Starting Worker container locally..."
    EXTRA_ENV_JSON=$(_build_extra_env)
    CREATE_OUTPUT=$(container_create_worker "${WORKER_NAME}" "${WORKER_NAME}" "${WORKER_MINIO_PASSWORD}" "${EXTRA_ENV_JSON}" 2>&1) || true
    CONTAINER_ID=$(echo "${CREATE_OUTPUT}" | tail -1)
    if [ -n "${CONTAINER_ID}" ] && [ ${#CONTAINER_ID} -ge 12 ]; then
        DEPLOY_MODE="local"
        log "  Waiting for Worker agent to be ready..."
        if container_wait_worker_ready "${WORKER_NAME}" 120; then
            WORKER_STATUS="ready"
            log "  Worker agent is ready!"
        else
            WORKER_STATUS="starting"
            log "  WARNING: Worker agent not ready within timeout (container may still be initializing)"
        fi
    else
        log "  WARNING: Container creation failed, falling back to remote mode"
        INSTALL_CMD=$(_build_install_cmd)
    fi
else
    log "Step 9: No container runtime socket available"
    INSTALL_CMD=$(_build_install_cmd)
fi

# ============================================================
# Output JSON result
# ============================================================
RESULT=$(jq -n \
    --arg name "${WORKER_NAME}" \
    --arg user_id "${WORKER_USER_ID}" \
    --arg room_id "${ROOM_ID}" \
    --arg room_key "${ROOM_KEY}" \
    --arg consumer "${CONSUMER_NAME}" \
    --arg mode "${DEPLOY_MODE}" \
    --arg container_id "${CONTAINER_ID}" \
    --arg status "${WORKER_STATUS}" \
    --arg install_cmd "${INSTALL_CMD:-}" \
    --argjson skills "${SKILLS_JSON}" \
    '{
        worker_name: $name,
        matrix_user_id: $user_id,
        room_id: $room_id,
        room_key: $room_key,
        consumer: $consumer,
        skills: $skills,
        mode: $mode,
        container_id: $container_id,
        status: $status,
        install_cmd: (if $install_cmd == "" then null else $install_cmd end)
    }')

echo "---RESULT---"
echo "${RESULT}"
