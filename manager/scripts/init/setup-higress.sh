#!/bin/bash
# setup-higress.sh - Configure Higress routes, consumers, and MCP servers
# Called by start-manager-agent.sh after Higress Console is ready.
# Requires HIGRESS_COOKIE_FILE env var to be set.
#
# All API calls use "|| true" to tolerate "already exists" errors on restart.

source /opt/hiclaw/scripts/lib/base.sh

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
MATRIX_CLIENT_DOMAIN="${HICLAW_MATRIX_CLIENT_DOMAIN:-matrix-client-local.hiclaw.io}"
AI_GATEWAY_DOMAIN="${HICLAW_AI_GATEWAY_DOMAIN:-aigw-local.hiclaw.io}"
FS_DOMAIN="${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}"

# Resolve LLM provider type and API URL for Higress AI Gateway.
# TODO: Higress Console API currently requires extra params for "qwen" provider
#   type (e.g. apiUrl), so we use "openai" type + rawConfigs as a workaround.
#   Once Higress Console optimizes the AI provider API to support default values
#   for built-in providers like qwen, this mapping can be removed and we can
#   pass type="qwen" directly.
LLM_PROVIDER="${HICLAW_LLM_PROVIDER:-qwen}"
LLM_API_URL="${HICLAW_LLM_API_URL:-}"
if [ -z "${LLM_API_URL}" ]; then
    case "${LLM_PROVIDER}" in
        qwen)  LLM_API_URL="https://dashscope.aliyuncs.com/compatible-mode/v1" ;;
        *)     LLM_API_URL="" ;;
    esac
fi

# Helper: call Higress Console API, log result, never fail.
# Uses HTTP status code + JSON content-type to validate responses.
higress_api() {
    local method="$1"
    local path="$2"
    local desc="$3"
    shift 3
    local body="$*"

    local tmpfile
    tmpfile=$(mktemp)
    local http_code
    http_code=$(curl -s -o "${tmpfile}" -w '%{http_code}' -X "${method}" "http://127.0.0.1:8001${path}" \
        -b "${HIGRESS_COOKIE_FILE}" \
        -H 'Content-Type: application/json' \
        -d "${body}" 2>/dev/null) || true
    local response
    response=$(cat "${tmpfile}" 2>/dev/null)
    rm -f "${tmpfile}"

    # Guard: if we got an HTML page, the session is invalid
    if echo "${response}" | grep -q '<!DOCTYPE html>' 2>/dev/null; then
        log "ERROR: ${desc} ... got HTML page (session expired?). Re-login needed."
        return 1
    fi

    if [ "${http_code}" = "401" ] || [ "${http_code}" = "403" ]; then
        log "ERROR: ${desc} ... HTTP ${http_code} auth failed"
        return 1
    fi

    if echo "${response}" | grep -q '"success":true' 2>/dev/null; then
        log "${desc} ... OK"
    elif echo "${response}" | grep -q '"success":false' 2>/dev/null; then
        if echo "${response}" | grep -qi 'already\|conflict\|exist' 2>/dev/null; then
            log "${desc} ... already exists, skipping"
        else
            log "WARNING: ${desc} ... FAILED (HTTP ${http_code}): ${response}"
        fi
    elif [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ] || [ "${http_code}" = "204" ]; then
        log "${desc} ... OK (HTTP ${http_code})"
    else
        log "WARNING: ${desc} ... unexpected (HTTP ${http_code}): ${response}"
    fi
}

log "Configuring Higress routes and consumers..."

# ============================================================
# 0. Register local service sources (all on 127.0.0.1 in all-in-one container)
#    Higress requires explicit service-source registration even for local services.
# ============================================================
higress_api POST /v1/service-sources "Registering Tuwunel service source" \
    '{"name":"tuwunel","type":"static","domain":"127.0.0.1:6167","port":6167,"properties":{},"authN":{"enabled":false}}'

higress_api POST /v1/service-sources "Registering Element Web service source" \
    '{"name":"element-web","type":"static","domain":"127.0.0.1:8088","port":8088,"properties":{},"authN":{"enabled":false}}'

higress_api POST /v1/service-sources "Registering MinIO service source" \
    '{"name":"minio","type":"static","domain":"127.0.0.1:9000","port":9000,"properties":{},"authN":{"enabled":false}}'

# ============================================================
# 1. Create Manager Consumer (key-auth BEARER)
# ============================================================
higress_api POST /v1/consumers "Creating Manager consumer" \
    '{"name":"manager","credentials":[{"type":"key-auth","source":"BEARER","values":["'"${HICLAW_MANAGER_GATEWAY_KEY}"'"]}]}'

# ============================================================
# 2. Matrix Homeserver Route (no auth - public access)
# ============================================================
higress_api POST /v1/routes "Creating Matrix Homeserver route" \
    '{"name":"matrix-homeserver","domains":[],"path":{"matchType":"PRE","matchValue":"/_matrix"},"services":[{"name":"tuwunel.static","port":6167,"weight":100}]}'

# ============================================================
# 3. Element Web Route (no auth - public access)
# ============================================================
higress_api POST /v1/routes "Creating Element Web route" \
    '{"name":"matrix-web-client","domains":["'"${MATRIX_CLIENT_DOMAIN}"'"],"path":{"matchType":"PRE","matchValue":"/"},"services":[{"name":"element-web.static","port":8088,"weight":100}]}'

# ============================================================
# 4. HTTP File System Route (no auth - protected by MinIO S3 auth)
# ============================================================
higress_api POST /v1/routes "Creating HTTP file system route" \
    '{"name":"http-filesystem","domains":["'"${FS_DOMAIN}"'"],"path":{"matchType":"PRE","matchValue":"/"},"services":[{"name":"minio.static","port":9000,"weight":100}]}'

# ============================================================
# 5. AI Gateway Route (LLM Provider + auth)
# ============================================================
if [ -n "${HICLAW_LLM_API_KEY}" ]; then
    case "${LLM_PROVIDER}" in
        qwen)
            PROVIDER_BODY='{"type":"qwen","name":"qwen","tokens":["'"${HICLAW_LLM_API_KEY}"'"],"protocol":"openai/v1","tokenFailoverConfig":{"enabled":false},"rawConfigs":{"qwenEnableSearch":false,"qwenEnableCompatible":true,"qwenFileIds":[]}}'
            ;;
        *)
            PROVIDER_BODY='{"name":"'"${LLM_PROVIDER}"'","type":"openai","tokens":["'"${HICLAW_LLM_API_KEY}"'"],"modelMapping":{},"protocol":"openai/v1"'
            if [ -n "${LLM_API_URL}" ]; then
                PROVIDER_BODY="${PROVIDER_BODY}"',"rawConfigs":{"apiUrl":"'"${LLM_API_URL}"'"}'
            fi
            PROVIDER_BODY="${PROVIDER_BODY}"'}'
            ;;
    esac

    higress_api POST /v1/ai/providers "Configuring LLM Provider (${LLM_PROVIDER})" \
        "${PROVIDER_BODY}"

    AI_ROUTE_BODY='{"name":"default-ai-route","domains":["'"${AI_GATEWAY_DOMAIN}"'"],"pathPredicate":{"matchType":"PRE","matchValue":"/","caseSensitive":false},"upstreams":[{"provider":"'"${LLM_PROVIDER}"'","weight":100,"modelMapping":{}}],"authConfig":{"enabled":true,"allowedCredentialTypes":["key-auth"],"allowedConsumers":["manager"]}}'

    higress_api POST /v1/ai/routes "Creating AI Gateway route" \
        "${AI_ROUTE_BODY}"
else
    log "Skipping AI Gateway configuration (no HICLAW_LLM_API_KEY)"
fi

# ============================================================
# 6. MCP Server: GitHub (if token provided)
# ============================================================
if [ -n "${HICLAW_GITHUB_TOKEN}" ]; then
    # First, create DNS service source for GitHub API
    higress_api POST /v1/service-sources "Creating GitHub API service source" \
        '{"type":"dns","name":"github-api","domain":"api.github.com","port":443,"protocol":"https"}'
    MCP_YAML_FILE="/opt/hiclaw/agent/skills/mcp-server-management/references/mcp-github.yaml"
    if [ -f "${MCP_YAML_FILE}" ]; then
        # Read YAML template and substitute the GitHub access token
        MCP_YAML=$(sed "s|accessToken: \"\"|accessToken: \"${HICLAW_GITHUB_TOKEN}\"|" "${MCP_YAML_FILE}")
        # Convert YAML to a JSON-escaped string for rawConfigurations
        RAW_CONFIG=$(printf '%s' "${MCP_YAML}" | jq -Rs .)
        # Build the full MCP Server body with rawConfigurations
        MCP_BODY=$(cat <<MCPEOF
{"name":"mcp-github","description":"GitHub MCP Server","type":"OPEN_API","rawConfigurations":${RAW_CONFIG},"mcpServerName":"mcp-github","domains":["${AI_GATEWAY_DOMAIN}"],"services":[{"name":"github-api.dns","port":443,"weight":100}],"consumerAuthInfo":{"type":"key-auth","enable":true,"allowedConsumers":["manager"]}}
MCPEOF
        )
        higress_api PUT /v1/mcpServer "Configuring GitHub MCP Server" \
            "${MCP_BODY}"
    else
        log "WARNING: MCP config not found at ${MCP_YAML_FILE}, skipping GitHub MCP Server"
    fi

    higress_api PUT /v1/mcpServer/consumers "Authorizing Manager for GitHub MCP" \
        '{"mcpServerName":"mcp-github","consumers":["manager"]}'
else
    log "Skipping GitHub MCP Server configuration (no HICLAW_GITHUB_TOKEN)"
fi

# ============================================================
# Wait for AI plugin activation (~40 seconds for first config)
# ============================================================
log "Waiting for AI Gateway plugin activation (40s)..."
sleep 45

log "Higress setup complete"
