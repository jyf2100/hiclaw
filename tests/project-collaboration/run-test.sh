#!/bin/bash
# run-test.sh - End-to-end test: Project Collaboration via Git
#
# Tests the project management skill by running a multi-worker git project:
#   - developer: writes Flask Hello World app and commits code
#   - reviewer:  reviews code, commits review.md, may request changes
#   - tester:    runs tests, commits test results
#
# Multi-round validation:
#   Round 1: developer writes code → reviewer reviews → reviewer requests changes
#   Round 2: developer fixes → reviewer approves → tester runs tests
#
# Usage:
#   ./tests/project-collaboration/run-test.sh [options]
#
# Options:
#   --skip-worker-creation   Assume workers already exist (reuse existing)
#   --timeout <seconds>      Project completion timeout (default: 3600)
#   --matrix-host <host>     Matrix server host (default: 127.0.0.1)
#   --matrix-port <port>     Matrix direct port (default: 6167)
#   --minio-port <port>      MinIO port (default: 9000)
#
# Required env:
#   HICLAW_ADMIN_USER        Admin username
#   HICLAW_ADMIN_PASSWORD    Admin password
#   HICLAW_MATRIX_DOMAIN     Matrix domain
#   HICLAW_LLM_API_KEY       LLM API key (must be set for agents to work)
#   TEST_GITHUB_REPO         GitHub repo for git operations (e.g. "org/test-repo")
#   TEST_GITHUB_TOKEN        GitHub PAT for git operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

source "${TESTS_DIR}/lib/test-helpers.sh"
source "${TESTS_DIR}/lib/matrix-client.sh"
source "${TESTS_DIR}/lib/minio-client.sh"

# ============================================================
# Configuration
# ============================================================

SKIP_WORKER_CREATION="${SKIP_WORKER_CREATION:-false}"
PROJECT_TIMEOUT="${PROJECT_TIMEOUT:-3600}"
ADMIN_USER="${HICLAW_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${HICLAW_ADMIN_PASSWORD:-}"
MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
MATRIX_DIRECT_URL="${TEST_MATRIX_DIRECT_URL:-http://127.0.0.1:6167}"
MANAGER_CONTAINER="${MANAGER_CONTAINER:-hiclaw-manager}"

WORKER_NAMES=("developer" "reviewer" "tester")
GITHUB_REPO="${TEST_GITHUB_REPO:-}"
GITHUB_TOKEN="${TEST_GITHUB_TOKEN:-${HICLAW_GITHUB_TOKEN:-}}"

LOG_DIR="${PROJECT_ROOT}/logs/project-collaboration"
mkdir -p "${LOG_DIR}"
LOG_TS=$(date '+%Y%m%d-%H%M%S')
RUN_LOG="${LOG_DIR}/run-${LOG_TS}.log"

log_tee() {
    echo "$1" | tee -a "${RUN_LOG}"
}

# ============================================================
# Arg parsing
# ============================================================

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-worker-creation) SKIP_WORKER_CREATION=true; shift ;;
        --timeout) PROJECT_TIMEOUT="$2"; shift 2 ;;
        --matrix-host) export TEST_MANAGER_HOST="$2"; shift 2 ;;
        --matrix-port) export TEST_MATRIX_PORT="$2"; shift 2 ;;
        --minio-port) export TEST_MINIO_PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================
# Pre-flight checks
# ============================================================

test_setup "project-collaboration"

log_tee "Log file: ${RUN_LOG}"
log_tee ""

if [ -z "${ADMIN_PASSWORD}" ]; then
    log_fail "HICLAW_ADMIN_PASSWORD is required"
    exit 1
fi

if [ -z "${HICLAW_LLM_API_KEY:-}" ]; then
    log_info "WARNING: HICLAW_LLM_API_KEY not set — agents may not function"
fi

if [ -z "${GITHUB_TOKEN}" ]; then
    log_info "WARNING: No GitHub token — git operations will be simulated locally"
fi

# ============================================================
# Step 0: Login as admin
# ============================================================

log_section "Step 0: Login"

ADMIN_LOGIN=$(matrix_login "${ADMIN_USER}" "${ADMIN_PASSWORD}")
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | jq -r '.access_token // empty')
assert_not_empty "${ADMIN_TOKEN}" "Admin login successful"

MANAGER_USER="@manager:${MATRIX_DOMAIN}"

# Find DM room with Manager
DM_ROOM=$(matrix_find_dm_room "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null || true)
if [ -z "${DM_ROOM}" ]; then
    log_info "Creating DM room with Manager..."
    DM_ROOM=$(matrix_create_dm "${ADMIN_TOKEN}" "${MANAGER_USER}" 2>/dev/null | jq -r '.room_id // empty')
fi
assert_not_empty "${DM_ROOM}" "DM room with Manager exists"
log_tee "DM Room: ${DM_ROOM}"

# Helper to run mc commands inside the manager container
mc_exec() {
    docker exec "${MANAGER_CONTAINER}" mc "$@"
}
assert_not_empty "${DM_ROOM}" "DM room with Manager exists"
log_tee "DM Room: ${DM_ROOM}"

# ============================================================
# Step 1: Create Workers (developer, reviewer, tester)
# ============================================================

log_section "Step 1: Create Workers"

if [ "${SKIP_WORKER_CREATION}" = "true" ]; then
    log_info "Skipping worker creation (--skip-worker-creation)"
else
    # Request Manager to create each worker
    for worker in "${WORKER_NAMES[@]}"; do
        log_info "Requesting creation of worker: ${worker}"

        case "${worker}" in
            developer)
                SOUL_DESC="一名全栈开发工程师，擅长 Python/Flask web 开发，负责写代码并提交到 git"
                ;;
            reviewer)
                SOUL_DESC="一名代码审查工程师，负责审查代码质量，提交 review.md 记录审查意见，并根据修复情况给出最终审批"
                ;;
            tester)
                SOUL_DESC="一名 QA 测试工程师，负责编写测试用例、运行测试并将测试结果提交到 git"
                ;;
        esac

        matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" \
            "请创建一个新的 Worker，名字是 ${worker}，角色：${SOUL_DESC}。需要 github-operations MCP 访问权限。"

        log_info "Waiting for Manager to create ${worker}..."
        REPLY=$(matrix_wait_for_reply "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 120)
        assert_not_empty "${REPLY}" "Manager acknowledged ${worker} creation"
        log_tee "[Manager reply for ${worker}]: ${REPLY:0:200}"

        # Wait for worker MinIO files to appear
        log_info "Waiting for ${worker} config in MinIO..."
        MINIO_WAIT=0
        until mc_exec stat "hiclaw/hiclaw-storage/agents/${worker}/SOUL.md" > /dev/null 2>&1; do
            sleep 5
            MINIO_WAIT=$((MINIO_WAIT + 5))
            if [ "${MINIO_WAIT}" -ge 120 ]; then
                log_fail "Worker ${worker} SOUL.md not found in MinIO after 120s"
                break
            fi
        done
        if mc_exec stat "hiclaw/hiclaw-storage/agents/${worker}/SOUL.md" > /dev/null 2>&1; then
            log_pass "Worker ${worker} SOUL.md in MinIO"
        fi

        sleep 5
    done
fi

# ============================================================
# Step 2: Initiate the project
# ============================================================

log_section "Step 2: Initiate Project"

PROJECT_MSG="请启动一个项目：用 Python Flask 实现一个 Hello World web app，需要经过以下完整流程：
1. developer 开发代码，创建 app.py 和 requirements.txt，提交到 git（branch: feature/hello-world）
2. reviewer 对代码进行 code review，提交 review.md 到 git（branch: feature/hello-world），review.md 必须包含审查意见
3. 如果 reviewer 提出了修改意见，developer 需要修复并再次提交，然后 reviewer 再次 review 并更新 review.md（第二轮 review）
4. 最终 reviewer 批准后，tester 编写测试用例 test_app.py，运行测试，并将测试结果提交到 git

项目代码仓库：${GITHUB_REPO:-local-test-repo}

请先拆解任务、制定 plan，与我确认后再开始执行。每个角色（developer/reviewer/tester）都必须有各自的 git commit。"

log_info "Sending project initiation message..."
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "${PROJECT_MSG}"

# Wait for Manager to propose a plan
log_info "Waiting for Manager to propose project plan (up to 5 min)..."
PLAN_REPLY=$(matrix_wait_for_reply "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 300)
assert_not_empty "${PLAN_REPLY}" "Manager proposed project plan"
log_tee "[Manager plan proposal]: ${PLAN_REPLY:0:500}"

# ============================================================
# Step 3: Human confirms the plan
# ============================================================

log_section "Step 3: Confirm Plan"

sleep 3
matrix_send_message "${ADMIN_TOKEN}" "${DM_ROOM}" "确认项目计划，开始执行。"

log_info "Waiting for Manager to acknowledge confirmation and start project..."
CONFIRM_REPLY=$(matrix_wait_for_reply "${ADMIN_TOKEN}" "${DM_ROOM}" "@manager" 180)
assert_not_empty "${CONFIRM_REPLY}" "Manager acknowledged plan confirmation"
log_tee "[Manager confirmation reply]: ${CONFIRM_REPLY:0:300}"

# ============================================================
# Step 4: Monitor project progress
# ============================================================

log_section "Step 4: Monitor Project Progress"

log_info "Project is running. Monitoring for completion (timeout: ${PROJECT_TIMEOUT}s)..."
log_info "Press Ctrl+C to stop monitoring (results will be incomplete)"

ELAPSED=0
PROJECT_DONE=false
PROJECT_ROOM_ID=""
PROJECT_ID=""

while [ "${ELAPSED}" -lt "${PROJECT_TIMEOUT}" ]; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))

    # Check if project room was created
    if [ -z "${PROJECT_ROOM_ID}" ]; then
        # Look for a room named "Project: ..."
        ALL_ROOMS=$(matrix_joined_rooms "${ADMIN_TOKEN}" 2>/dev/null | jq -r '.joined_rooms[]' 2>/dev/null || true)
        for room_id in ${ALL_ROOMS}; do
            ROOM_NAME=$(matrix_get_room_name "${ADMIN_TOKEN}" "${room_id}" 2>/dev/null || true)
            if echo "${ROOM_NAME}" | grep -qi "^Project:"; then
                PROJECT_ROOM_ID="${room_id}"
                log_info "Found project room: ${ROOM_NAME} (${PROJECT_ROOM_ID})"
                log_tee "Project Room ID: ${PROJECT_ROOM_ID}"
                break
            fi
        done
    fi

    # Check if project meta.json exists in MinIO
    if [ -z "${PROJECT_ID}" ]; then
        PROJECT_META_LIST=$(mc_exec ls "hiclaw/hiclaw-storage/shared/projects/" 2>/dev/null | awk '{print $NF}' | tr -d '/' || true)
        if [ -n "${PROJECT_META_LIST}" ]; then
            PROJECT_ID=$(echo "${PROJECT_META_LIST}" | head -1)
            log_info "Found project: ${PROJECT_ID}"
            log_tee "Project ID: ${PROJECT_ID}"
        fi
    fi

    # Check plan.md for completion
    if [ -n "${PROJECT_ID}" ]; then
        PLAN_CONTENT=$(mc_exec cat "hiclaw/hiclaw-storage/shared/projects/${PROJECT_ID}/plan.md" 2>/dev/null || true)
        if [ -n "${PLAN_CONTENT}" ]; then
            # Check if all tasks are [x]
            PENDING_COUNT=$(echo "${PLAN_CONTENT}" | grep -c '^\- \[ \]' 2>/dev/null || echo "0")
            INPROG_COUNT=$(echo "${PLAN_CONTENT}" | grep -c '^\- \[~\]' 2>/dev/null || echo "0")
            DONE_COUNT=$(echo "${PLAN_CONTENT}" | grep -c '^\- \[x\]' 2>/dev/null || echo "0")
            log_info "[${ELAPSED}s] Plan status: ${DONE_COUNT} done, ${INPROG_COUNT} in-progress, ${PENDING_COUNT} pending"

            if [ "${PENDING_COUNT}" = "0" ] && [ "${INPROG_COUNT}" = "0" ] && [ "${DONE_COUNT}" -gt 0 ]; then
                log_info "All tasks completed!"
                PROJECT_DONE=true
                break
            fi
        fi
    fi

    # Check for completion message in DM
    RECENT_DM=$(matrix_read_messages "${ADMIN_TOKEN}" "${DM_ROOM}" 5 2>/dev/null | \
        jq -r '[.chunk[] | select(.sender | startswith("@manager")) | .content.body] | first // empty' 2>/dev/null || true)
    if echo "${RECENT_DM}" | grep -qi "项目.*完成\|project.*completed\|所有任务.*完成\|all tasks.*done"; then
        log_info "Manager reported project completion!"
        PROJECT_DONE=true
        break
    fi

    if [ $((ELAPSED % 300)) -eq 0 ]; then
        log_info "Still waiting... (${ELAPSED}/${PROJECT_TIMEOUT}s)"
    fi
done

if [ "${PROJECT_DONE}" = "true" ]; then
    log_pass "Project completed within timeout"
else
    log_info "Project timed out or status unclear — running verification anyway"
fi

# ============================================================
# Step 5: Collect chat logs
# ============================================================

log_section "Step 5: Collect Chat Logs"

CHAT_LOG="${LOG_DIR}/chat-${LOG_TS}.log"

dump_room_messages() {
    local token="$1"
    local room_id="$2"
    local room_label="$3"
    local limit="${4:-200}"

    if [ -n "${TEST_MATRIX_EXTRA_HEADERS}" ]; then
        curl -sf "${MATRIX_DIRECT_URL}/_matrix/client/v3/rooms/${room_id}/messages?dir=b&limit=${limit}" \
            -H "Authorization: Bearer ${token}" \
            -H "${TEST_MATRIX_EXTRA_HEADERS}" 2>/dev/null | \
            jq -r --arg label "${room_label}" '
                .chunk | reverse | .[] |
                select(.content.body != null and .content.body != "") |
                "[\(.origin_server_ts / 1000 | strftime("%H:%M:%S"))] \(.sender | split(":")[0] | ltrimstr("@")): \(.content.body)"
            ' 2>/dev/null >> "${CHAT_LOG}" || true
    else
        curl -sf "${MATRIX_DIRECT_URL}/_matrix/client/v3/rooms/${room_id}/messages?dir=b&limit=${limit}" \
            -H "Authorization: Bearer ${token}" 2>/dev/null | \
            jq -r --arg label "${room_label}" '
                .chunk | reverse | .[] |
                select(.content.body != null and .content.body != "") |
                "[\(.origin_server_ts / 1000 | strftime("%H:%M:%S"))] \(.sender | split(":")[0] | ltrimstr("@")): \(.content.body)"
            ' 2>/dev/null >> "${CHAT_LOG}" || true
    fi
}

echo "# Chat Log — Project Collaboration Test" > "${CHAT_LOG}"
echo "# Generated: $(date)" >> "${CHAT_LOG}"
echo "" >> "${CHAT_LOG}"

echo "## DM (admin <-> manager)" >> "${CHAT_LOG}"
dump_room_messages "${ADMIN_TOKEN}" "${DM_ROOM}" "DM" 200

if [ -n "${PROJECT_ROOM_ID}" ]; then
    echo "" >> "${CHAT_LOG}"
    echo "## Project Room" >> "${CHAT_LOG}"
    dump_room_messages "${ADMIN_TOKEN}" "${PROJECT_ROOM_ID}" "Project" 500
fi

# Dump worker rooms too
ALL_ROOMS=$(matrix_joined_rooms "${ADMIN_TOKEN}" 2>/dev/null | jq -r '.joined_rooms[]' 2>/dev/null || true)
for room_id in ${ALL_ROOMS}; do
    [ "${room_id}" = "${DM_ROOM}" ] && continue
    [ "${room_id}" = "${PROJECT_ROOM_ID}" ] && continue
    ROOM_NAME=$(matrix_get_room_name "${ADMIN_TOKEN}" "${room_id}" 2>/dev/null || true)
    if echo "${ROOM_NAME}" | grep -qi "Worker:"; then
        echo "" >> "${CHAT_LOG}"
        echo "## ${ROOM_NAME}" >> "${CHAT_LOG}"
        dump_room_messages "${ADMIN_TOKEN}" "${room_id}" "${ROOM_NAME}" 100
    fi
done

log_pass "Chat logs saved to: ${CHAT_LOG}"

# ============================================================
# Step 6: Save state for verify.sh
# ============================================================

STATE_FILE="${LOG_DIR}/state-${LOG_TS}.env"
cat > "${STATE_FILE}" << EOF
PROJECT_ID="${PROJECT_ID}"
PROJECT_ROOM_ID="${PROJECT_ROOM_ID}"
DM_ROOM="${DM_ROOM}"
ADMIN_TOKEN="${ADMIN_TOKEN}"
MATRIX_DOMAIN="${MATRIX_DOMAIN}"
MATRIX_DIRECT_URL="${MATRIX_DIRECT_URL}"
CHAT_LOG="${CHAT_LOG}"
GITHUB_REPO="${GITHUB_REPO}"
LOG_TS="${LOG_TS}"
EOF
log_info "State saved to: ${STATE_FILE}"

# ============================================================
# Step 7: Run verification
# ============================================================

log_section "Step 7: Run Verification"

VERIFY_SCRIPT="${SCRIPT_DIR}/verify.sh"
if [ -f "${VERIFY_SCRIPT}" ]; then
    bash "${VERIFY_SCRIPT}" \
        --state-file "${STATE_FILE}" \
        --chat-log "${CHAT_LOG}" \
        --project-id "${PROJECT_ID}" \
        --project-room "${PROJECT_ROOM_ID}" \
        --github-repo "${GITHUB_REPO}" \
        --github-token "${GITHUB_TOKEN}" \
        2>&1 | tee -a "${RUN_LOG}"
    VERIFY_EXIT=${PIPESTATUS[0]}
else
    log_fail "verify.sh not found at ${VERIFY_SCRIPT}"
    VERIFY_EXIT=1
fi

# ============================================================
# Summary
# ============================================================

test_teardown "project-collaboration"

echo "" | tee -a "${RUN_LOG}"
echo "Run log: ${RUN_LOG}" | tee -a "${RUN_LOG}"
echo "Chat log: ${CHAT_LOG}" | tee -a "${RUN_LOG}"

test_summary
SUMMARY_EXIT=$?

exit $((VERIFY_EXIT > SUMMARY_EXIT ? VERIFY_EXIT : SUMMARY_EXIT))
