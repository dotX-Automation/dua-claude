#!/usr/bin/env bats

# Resolution, doctor and lifecycle against a real container.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

load helper

setup() { standard_setup resolveproj; }
teardown() { stop_mocks; }

@test "ctx resolves the container by bind mount" {
  dua_in "${PROJECT}" ctx
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"container      running"* ]]
  [[ "${output}" == *"resolved by    mount"* ]]
  [[ "${output}" == *"${CONTAINER}"* ]]
}

@test "ctx maps the working directory from a subdirectory" {
  mkdir -p "${PROJECT}/src/some_pkg/include"
  dua_in "${PROJECT}/src/some_pkg/include" ctx
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/home/neo/workspace/src/some_pkg/include"* ]]
}

@test "ctx --json is well formed and reports the mount source" {
  dua_in "${PROJECT}" ctx --json
  [ "${status}" -eq 0 ]
  echo "${output}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["container"]["state"])'
  [[ "${output}" == *"\"workspace_source\": \"${PROJECT}\""* ]]
}

@test "a nested unit resolves to the owning container" {
  make_repo "${PROJECT}/src/nested_unit" nested_unit x86-cudev
  dua_in "${PROJECT}/src/nested_unit" ctx
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"container      running"* ]]
  [[ "${output}" == *"/home/neo/workspace/src/nested_unit"* ]]
  [[ "${output}" == *"unit nested in ${PROJECT}"* ]]
}

@test "a container bound to another checkout is ignored" {
  local other="${BATS_TEST_TMPDIR}/other"
  make_repo "${other}" resolveproj x86-cudev
  dua_in "${other}" ctx
  [[ "${output}" == *"absent"* ]]
}

@test "two containers bound to one repository are reported, not guessed" {
  start_mock second
  dua_in "${PROJECT}" ctx
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing to guess"* ]] || [[ "${output}" == *"ambiguous"* ]]
  dua_in "${PROJECT}" exec -- true
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing to guess"* ]]
}

@test "doctor passes and cross-checks /etc/dua/target" {
  dua_in "${PROJECT}" doctor
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no blockers"* ]]
  [[ "${output}" == *"workspace mounted"* ]]
  # The mock is started with docker run, so it carries no compose labels: the
  # target comes from the single configured one and must agree with the file.
  [[ "${output}" == *"/etc/dua/target agrees: x86-cudev"* ]] ||
    [[ "${output}" == *"from /etc/dua/target"* ]]
}

@test "the target is inferred without compose labels" {
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"target         x86-cudev"* ]]
  [[ "${output}" != *"target         latest"* ]]
}

@test "doctor reports uid and gid differences as notes, never as warnings" {
  # A second image built with deliberately unrelated ids.
  if ! docker image inspect dua-claude-mock:mismatch >/dev/null 2>&1; then
    skip "dua-claude-mock:mismatch not built"
  fi
  docker rm -f "$(_cname mism)" >/dev/null 2>&1 || true
  CONTAINER="$(_cname mism)"
  docker run -d --name "${CONTAINER}" -v "${PROJECT}:/home/neo/workspace" \
    dua-claude-mock:mismatch >/dev/null
  docker rm -f "$(_cname main)" >/dev/null 2>&1 || true
  dua_in "${PROJECT}" doctor
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"uid host"* ]]
  [[ "${output}" == *"[note]"* ]]
  [[ "${output}" != *"warning"* ]]
  [[ "${output}" == *"no blockers"* ]]
}

@test "a stopped container is found and started again, not recreated" {
  docker stop "${CONTAINER}" >/dev/null
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"container      stopped"* ]]
  dua_in "${PROJECT}" exec -- true
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"dua up"* ]]
  dua_in "${PROJECT}" up
  [ "${status}" -eq 0 ]
  [ "$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")" = "running" ]
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"container      running"* ]]
}

@test "down stops the container and leaves it in place" {
  dua_in "${PROJECT}" down
  [ "${status}" -eq 0 ]
  [ "$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")" = "exited" ]
  dua_in "${PROJECT}" up
  [ "${status}" -eq 0 ]
  [ "$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")" = "running" ]
}

@test "restart invalidates the environment snapshot" {
  dua_in "${PROJECT}" exec -- true
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       fresh"* ]]
  dua_in "${PROJECT}" restart
  [ "${status}" -eq 0 ]
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       stale"* ]]
}

@test "outside a DUA project the CLI explains itself" {
  dua_in "${BATS_TEST_TMPDIR}" ctx
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not inside a DUA project"* ]]
}
