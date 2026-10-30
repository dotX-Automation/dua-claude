#!/usr/bin/env bash

# Shared setup for the bats suites.
#
# Each test gets its own fixture repository and its own mock container bound to
# it, so tests are independent and can run in any order. The container name
# carries the bats test number to avoid collisions.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export DUA="${REPO_ROOT}/bin/dua"
export MOCK_IMAGE="${MOCK_IMAGE:-dua-claude-mock:latest}"

# shellcheck source=../fixtures/fixtures.sh
source "${REPO_ROOT}/tests/fixtures/fixtures.sh"

# Unique-ish suffix for container names within a run.
_cname() { printf 'duacc-test-%s-%s' "$$" "${1}"; }

# make_project [name] -> sets PROJECT to a fresh fixture repository
make_project() {
  local name="${1:-fixture}"
  PROJECT="${BATS_TEST_TMPDIR}/${name}"
  make_repo "${PROJECT}" "${name}" x86-cudev
  export PROJECT
}

# start_mock [suffix] [extra docker run args...]
# Runs a mock container bound to $PROJECT and sets CONTAINER.
start_mock() {
  local suffix="${1:-main}"
  shift || true
  CONTAINER="$(_cname "${suffix}")"
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --name "${CONTAINER}" \
    -v "${PROJECT}:/home/neo/workspace" \
    "$@" "${MOCK_IMAGE}" >/dev/null
  export CONTAINER
  # Wait for the container to be up; it starts a sleep, so this is quick.
  local i
  # shellcheck disable=SC2034
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null)" == "running" ]] && return 0
    sleep 0.2
  done
  echo "mock container did not start" >&2
  return 1
}

stop_mocks() {
  local c
  for c in $(docker ps -aq --filter "name=duacc-test-$$-" 2>/dev/null); do
    docker rm -f "${c}" >/dev/null 2>&1 || true
  done
}

# Plugin state must not leak between tests.
setup_state() {
  export CLAUDE_PLUGIN_DATA="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${CLAUDE_PLUGIN_DATA}"
  export NO_COLOR=1
}

# dua_in <dir> <args...> : run the CLI from a directory inside the fixture
dua_in() {
  local dir="${1}"
  shift
  run env -C "${dir}" \
    CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" NO_COLOR=1 \
    "${DUA}" "$@"
}

# What the container recorded for a stubbed tool.
mock_log() {
  docker exec -i "${CONTAINER}" cat "/tmp/mock/${1}.log" </dev/null 2>/dev/null || true
}

standard_setup() {
  setup_state
  make_project "${1:-fixture}"
  start_mock main
}
