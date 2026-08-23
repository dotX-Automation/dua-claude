#!/usr/bin/env bats

# Execution semantics: the environment snapshot, output cleanliness, exit codes
# and invalidation. These are the tests the offline stub cannot do, because they
# depend on how a real bash behaves inside a real container.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

load helper

setup() { standard_setup execproj; }
teardown() { stop_mocks; }

@test "the DUA environment reaches the command" {
  dua_in "${PROJECT}" exec -- 'echo "${ROS_DISTRO}|${VIRTUAL_ENV}|$(command -v colcon)"'
  [ "${status}" -eq 0 ]
  [[ "${output}" == "jazzy|/opt/dua-venv|"* ]]
}

@test "stdout carries the command output and nothing else" {
  # Ubuntu's sudo hint prints three lines on every interactive bash; the
  # snapshot path must not let a single one of them through.
  dua_in "${PROJECT}" exec -- 'echo ONLYTHIS'
  [ "${status}" -eq 0 ]
  [ "${output}" = "ONLYTHIS" ]
}

@test "the sudo hint is really present in the image" {
  # Guards the test above: if the hint ever stops being emitted, the cleanliness
  # test would pass for the wrong reason.
  run docker exec -i "${CONTAINER}" bash -ic 'echo X' </dev/null
  [[ "${output}" == *"sudo_root"* ]]
}

@test "snapshot and interactive modes agree on the environment" {
  dua_in "${PROJECT}" exec -- 'env | grep -vE "^(_|SHLVL|PWD|OLDPWD)=" | sort | md5sum'
  local snap="${output}"
  dua_in "${PROJECT}" exec --mode ic -- 'env | grep -vE "^(_|SHLVL|PWD|OLDPWD)=" | sort | md5sum'
  [ "${output}" = "${snap}" ]
}

@test "snapshot and interactive modes agree on the functions" {
  dua_in "${PROJECT}" exec -- 'declare -F | sort | md5sum'
  local snap="${output}"
  dua_in "${PROJECT}" exec --mode ic -- 'declare -F | sort | md5sum'
  [ "${output}" = "${snap}" ]
}

@test "functions and aliases from the DUA files are available" {
  dua_in "${PROJECT}" exec -- 'type -t ros2bag'
  [ "${output}" = "function" ]
  dua_in "${PROJECT}" exec -- 'type -t dua-subtree'
  [ "${output}" = "function" ]
  dua_in "${PROJECT}" exec -- 'alias cbuild'
  [[ "${output}" == *"colcon build"* ]]
}

@test "the snapshot never captures the plugin's own variables" {
  dua_in "${PROJECT}" exec -- 'echo first'
  dua_in "${PROJECT}" exec -- 'grep -c "DUA_CMD\|DUA_DOMAIN" /tmp/dua-cc/env.sh || true'
  [ "${output}" = "0" ]
}

@test "consecutive commands do not leak into each other" {
  dua_in "${PROJECT}" exec -- 'echo FIRST'
  [ "${output}" = "FIRST" ]
  dua_in "${PROJECT}" exec -- 'echo SECOND'
  [ "${output}" = "SECOND" ]
}

@test "exit codes propagate and deadlines yield 124" {
  dua_in "${PROJECT}" exec -- 'exit 42'
  [ "${status}" -eq 42 ]
  dua_in "${PROJECT}" exec --timeout 1s -- 'sleep 20'
  [ "${status}" -eq 124 ]
}

@test "history expansion is not applied to the command" {
  dua_in "${PROJECT}" exec -- 'echo "a!b"'
  [ "${output}" = "a!b" ]
}

@test "quoting and command substitution survive the trip" {
  dua_in "${PROJECT}" exec -- 'x="hello world"; echo "[$x] [$(echo nested)]"'
  [ "${output}" = "[hello world] [nested]" ]
}

@test "the working directory is mapped, not assumed" {
  mkdir -p "${PROJECT}/src/deep/deeper"
  dua_in "${PROJECT}/src/deep/deeper" exec -- pwd
  [ "${output}" = "/home/neo/workspace/src/deep/deeper" ]
}

@test "the ROS domain override wins over ros2init" {
  dua_in "${PROJECT}" exec --domain 7 -- 'echo "${ROS_DOMAIN_ID}"'
  [ "${output}" = "7" ]
  dua_in "${PROJECT}" exec --mode ic --domain 7 -- 'echo "${ROS_DOMAIN_ID}"'
  [ "${output}" = "7" ]
  dua_in "${PROJECT}" exec -- 'echo "${ROS_DOMAIN_ID}"'
  [ "${output}" = "0" ]
}

@test "raw mode deliberately has no DUA environment" {
  dua_in "${PROJECT}" exec --mode raw -- 'echo "[${ROS_DISTRO:-unset}]"'
  [ "${output}" = "[unset]" ]
}

@test "editing a mounted config file invalidates the snapshot" {
  dua_in "${PROJECT}" exec -- true
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       fresh"* ]]
  echo 'export DUA_TEST_MARKER=present' >>"${PROJECT}/docker/container-x86-cudev/commands.sh"
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       stale"* ]]
  dua_in "${PROJECT}" exec -- true
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       fresh"* ]]
}

@test "the host and the container see the same files" {
  echo "written on the host" >"${PROJECT}/host_file"
  dua_in "${PROJECT}" exec -- 'cat host_file'
  [ "${output}" = "written on the host" ]
  dua_in "${PROJECT}" exec -- 'echo "written in the container" > container_file'
  [ "$(cat "${PROJECT}/container_file")" = "written in the container" ]
}

@test "stdin is forwarded to the command" {
  run bash -c "echo piped | env -C '${PROJECT}' CLAUDE_PLUGIN_DATA='${CLAUDE_PLUGIN_DATA}' '${DUA}' exec -- cat"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"piped"* ]]
}
