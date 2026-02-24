#!/bin/bash
# test-helpers.sh - Common test utilities: assertions, lifecycle, logging
# Source this file in each test script.

# NOTE: Do NOT use "set -e" here. Tests use assertions (log_pass/log_fail)
# for results, not exit codes. set -e would abort the test script on the
# first failing curl or command, hiding remaining test results.

# ============================================================
# Configuration
# ============================================================

export TEST_MANAGER_HOST="${TEST_MANAGER_HOST:-127.0.0.1}"
export TEST_MATRIX_PORT="${TEST_MATRIX_PORT:-6167}"
export TEST_GATEWAY_PORT="${TEST_GATEWAY_PORT:-8080}"
export TEST_CONSOLE_PORT="${TEST_CONSOLE_PORT:-8001}"
export TEST_MINIO_PORT="${TEST_MINIO_PORT:-9000}"
export TEST_MINIO_CONSOLE_PORT="${TEST_MINIO_CONSOLE_PORT:-9001}"
export TEST_ELEMENT_PORT="${TEST_ELEMENT_PORT:-8088}"

export TEST_MATRIX_URL="http://${TEST_MANAGER_HOST}:${TEST_GATEWAY_PORT}"
export TEST_MATRIX_DIRECT_URL="${TEST_MATRIX_DIRECT_URL:-http://${TEST_MANAGER_HOST}:${TEST_MATRIX_PORT}}"
export TEST_CONSOLE_URL="http://${TEST_MANAGER_HOST}:${TEST_CONSOLE_PORT}"
export TEST_MINIO_URL="http://${TEST_MANAGER_HOST}:${TEST_MINIO_PORT}"

# Extra headers for gateway routing (set when Matrix is accessed through gateway)
# Example: TEST_MATRIX_EXTRA_HEADERS="Host: matrix-local.hiclaw.io:9080"
export TEST_MATRIX_EXTRA_HEADERS="${TEST_MATRIX_EXTRA_HEADERS:-}"

# Test state
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0
TEST_FAILURES=()

# ============================================================
# Logging
# ============================================================

log_info() {
    echo -e "\033[36m[TEST INFO]\033[0m $1"
}

log_pass() {
    echo -e "\033[32m[TEST PASS]\033[0m $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

log_fail() {
    echo -e "\033[31m[TEST FAIL]\033[0m $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TEST_FAILURES+=("$1")
}

log_section() {
    echo ""
    echo -e "\033[35m=== $1 ===\033[0m"
}

# ============================================================
# Assertions
# ============================================================

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-assert_eq}"

    if [ "${expected}" = "${actual}" ]; then
        log_pass "${message}"
    else
        log_fail "${message} (expected: '${expected}', got: '${actual}')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assert_contains}"

    if echo "${haystack}" | grep -q "${needle}"; then
        log_pass "${message}"
    else
        log_fail "${message} (expected to contain: '${needle}')"
    fi
}

assert_contains_i() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-assert_contains_i}"

    if echo "${haystack}" | grep -qi "${needle}"; then
        log_pass "${message}"
    else
        log_fail "${message} (expected to contain (case-insensitive): '${needle}')"
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-assert_not_empty}"

    if [ -n "${value}" ] && [ "${value}" != "null" ]; then
        log_pass "${message}"
    else
        log_fail "${message} (value is empty or null)"
    fi
}

assert_http_code() {
    local url="$1"
    local expected_code="$2"
    local message="${3:-assert_http_code}"
    local extra_args="${4:-}"

    local actual_code
    # Use -s (silent) without -f (fail) so curl always outputs the HTTP code.
    # With -f, curl exits non-zero on 4xx/5xx, and || echo "000" would concatenate.
    actual_code=$(curl -s -o /dev/null -w '%{http_code}' ${extra_args} "${url}" 2>/dev/null)

    assert_eq "${expected_code}" "${actual_code}" "${message}"
}

# ============================================================
# Wait / Poll utilities
# ============================================================

# Wait until a condition function returns 0, or timeout
# Usage: wait_until "description" timeout_seconds check_function [args...]
wait_until() {
    local description="$1"
    local timeout="$2"
    shift 2
    local check_fn="$@"

    local elapsed=0
    log_info "Waiting for: ${description} (timeout: ${timeout}s)"

    while ! eval "${check_fn}" 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [ "${elapsed}" -ge "${timeout}" ]; then
            log_fail "Timeout waiting for: ${description}"
            return 1
        fi
    done

    log_info "${description} ready (took ${elapsed}s)"
    return 0
}

# Wait for Manager container to be healthy
wait_for_manager() {
    local timeout="${1:-300}"
    wait_until "Manager container healthy" "${timeout}" \
        "curl -sf http://${TEST_MANAGER_HOST}:${TEST_GATEWAY_PORT}/ > /dev/null 2>&1"
}

# ============================================================
# Test Lifecycle
# ============================================================

test_setup() {
    local test_name="$1"
    log_section "Starting: ${test_name}"
}

test_teardown() {
    local test_name="$1"
    log_section "Finished: ${test_name}"
}

# Print summary and exit with appropriate code
test_summary() {
    echo ""
    echo "========================================"
    echo "  Test Summary"
    echo "========================================"
    echo "  Total:  ${TESTS_TOTAL}"
    echo -e "  \033[32mPassed: ${TESTS_PASSED}\033[0m"
    echo -e "  \033[31mFailed: ${TESTS_FAILED}\033[0m"
    echo "========================================"

    if [ ${TESTS_FAILED} -gt 0 ]; then
        echo ""
        echo "Failures:"
        for failure in "${TEST_FAILURES[@]}"; do
            echo "  - ${failure}"
        done
        echo ""
        return 1
    fi

    return 0
}

# ============================================================
# LLM / Agent helpers
# ============================================================

# Check if LLM API key is configured (required for tests that need Manager Agent responses)
require_llm_key() {
    if [ -z "${HICLAW_LLM_API_KEY}" ]; then
        log_info "SKIP: No LLM API key configured (set HICLAW_LLM_API_KEY). This test requires Manager Agent LLM responses."
        return 1
    fi
    return 0
}

# ============================================================
# Docker helpers
# ============================================================

start_worker_container() {
    local worker_name="$1"
    local container_name="hiclaw-test-worker-${worker_name}"

    docker run -d \
        --name "${container_name}" \
        --network host \
        -e "HICLAW_WORKER_NAME=${worker_name}" \
        -e "HICLAW_MATRIX_SERVER=http://${TEST_MANAGER_HOST}:${TEST_GATEWAY_PORT}" \
        -e "HICLAW_AI_GATEWAY=http://${TEST_MANAGER_HOST}:${TEST_GATEWAY_PORT}" \
        -e "HICLAW_FS_ENDPOINT=http://${TEST_MANAGER_HOST}:${TEST_MINIO_PORT}" \
        -e "HICLAW_FS_ACCESS_KEY=${TEST_MINIO_USER}" \
        -e "HICLAW_FS_SECRET_KEY=${TEST_MINIO_PASSWORD}" \
        "hiclaw/worker-agent:${HICLAW_VERSION:-latest}" 2>/dev/null

    echo "${container_name}"
}

stop_worker_container() {
    local container_name="$1"
    docker stop "${container_name}" 2>/dev/null || true
    docker rm "${container_name}" 2>/dev/null || true
}
