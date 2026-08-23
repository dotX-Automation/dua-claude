#!/usr/bin/env bats

# Workflows against a real container. colcon and ros2 are recording stubs, so
# the assertions are on the command line that actually arrived, and on the side
# effects visible from the host.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

load helper

setup() {
  standard_setup wfproj
  make_pkg "${PROJECT}" src/unit_a/pkg_a1 pkg_a1
  make_pkg "${PROJECT}" src/unit_a/pkg_a2 pkg_a2
  make_pkg "${PROJECT}" src/pkg_b pkg_b
}
teardown() { stop_mocks; }

@test "build runs colcon at the workspace root with the expected options" {
  dua_in "${PROJECT}" build
  [ "${status}" -eq 0 ]
  local log
  log="$(mock_log colcon)"
  [[ "${log}" == *"build --symlink-install"* ]]
  [[ "${log}" == *"--event-handlers status- desktop_notification-"* ]]
  [[ "${log}" == *"-DCMAKE_EXPORT_COMPILE_COMMANDS=On"* ]]
  [[ "${log}" != *"--continue-on-error"* ]]
  [[ "${log}" != *"--packages-select"* ]]
}

@test "build logs to logs/cc on the host" {
  dua_in "${PROJECT}" build
  run bash -c "ls '${PROJECT}'/logs/cc/*-build.log"
  [ "${status}" -eq 0 ]
  run grep -q "Summary:" "$(ls -t "${PROJECT}"/logs/cc/*-build.log | head -1)"
  [ "${status}" -eq 0 ]
}

@test "build infers the packages of the unit it is run from" {
  dua_in "${PROJECT}/src/unit_a" build
  [ "${status}" -eq 0 ]
  [[ "$(mock_log colcon)" == *"--packages-select pkg_a1 pkg_a2"* ]]
  [[ "${output}" == *"building the packages found here"* ]]
}

@test "build --all overrides inference" {
  dua_in "${PROJECT}/src/unit_a" build --all
  [ "${status}" -eq 0 ]
  [[ "$(mock_log colcon)" != *"--packages-select"* ]]
}

@test "build --up-to switches the selection mode" {
  dua_in "${PROJECT}" build --up-to pkg_b
  [ "${status}" -eq 0 ]
  [[ "$(mock_log colcon)" == *"--packages-up-to pkg_b"* ]]
}

@test "build --debug forces a reconfigure and warns about CMakeLists" {
  dua_in "${PROJECT}" build --debug
  [ "${status}" -eq 0 ]
  local log
  log="$(mock_log colcon)"
  [[ "${log}" == *"--cmake-force-configure"* ]]
  [[ "${log}" == *"-DCMAKE_BUILD_TYPE=Debug"* ]]
  [[ "${output}" == *"unconditionally"* ]]
}

@test "build --clean removes only the selected package trees" {
  mkdir -p "${PROJECT}/build/pkg_b" "${PROJECT}/install/pkg_b" "${PROJECT}/build/pkg_a1"
  dua_in "${PROJECT}" build --clean pkg_b
  [ "${status}" -eq 0 ]
  [ ! -d "${PROJECT}/build/pkg_b" ]
  [ ! -d "${PROJECT}/install/pkg_b" ]
  [ -d "${PROJECT}/build/pkg_a1" ]
}

@test "build --clean --all purges the workspace" {
  mkdir -p "${PROJECT}/build/pkg_b" "${PROJECT}/install" "${PROJECT}/log"
  dua_in "${PROJECT}" build --clean --all
  [ "${status}" -eq 0 ]
  [ ! -d "${PROJECT}/build" ]
  [ ! -d "${PROJECT}/install" ]
  [ ! -d "${PROJECT}/log" ]
  [ -d "${PROJECT}/logs" ]
}

@test "a failing build is reported with the log path" {
  docker exec -i "${CONTAINER}" sh -c 'mkdir -p /tmp/mock; echo 1 > /tmp/mock/colcon.rc' </dev/null
  dua_in "${PROJECT}" build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"build failed"* ]]
  [[ "${output}" == *"latest_build"* ]]
}

@test "a successful build invalidates the environment snapshot" {
  dua_in "${PROJECT}" exec -- true
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       fresh"* ]]
  dua_in "${PROJECT}" build
  dua_in "${PROJECT}" ctx
  [[ "${output}" == *"snapshot       stale"* ]]
}

@test "test selects packages on colcon test but never on test-result" {
  # The stub rejects selection on test-result exactly as the real colcon does,
  # so this test fails loudly if the flag ever comes back.
  dua_in "${PROJECT}" test pkg_b
  [ "${status}" -eq 0 ]
  local log
  log="$(mock_log colcon)"
  [[ "${log}" == *"test --return-code-on-test-failure"* ]]
  [[ "${log}" == *"--packages-select pkg_b"* ]]
  [[ "${log}" == *"test-result --test-result-base build/pkg_b --all --verbose"* ]]
  [[ "${output}" != *"unrecognized arguments"* ]]
}

@test "test over the whole workspace reports every result" {
  dua_in "${PROJECT}" test --all
  [ "${status}" -eq 0 ]
  [[ "$(mock_log colcon)" == *"test-result --all --verbose"* ]]
}

@test "run enforces a deadline and does not call it a failure" {
  dua_in "${PROJECT}" run --for 2s -- 'echo starting; sleep 30'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"deadline reached"* ]]
  run bash -c "grep -l starting '${PROJECT}'/logs/cc/*-run.log"
  [ "${status}" -eq 0 ]
}

@test "run without a deadline is refused" {
  dua_in "${PROJECT}" run -- 'echo hi'
  [ "${status}" -eq 2 ]
}

@test "background processes start, report, log and stop" {
  dua_in "${PROJECT}" bg start ticker -- 'for i in 1 2 3 4 5 6 7 8 9 10; do echo tick $i; sleep 1; done'
  [ "${status}" -eq 0 ]
  sleep 2
  dua_in "${PROJECT}" bg status ticker
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"running"* ]]
  dua_in "${PROJECT}" bg logs ticker
  [[ "${output}" == *"tick"* ]]
  [ -f "${PROJECT}/logs/cc/bg-ticker.log" ]
  dua_in "${PROJECT}" bg stop ticker
  [ "${status}" -eq 0 ]
  sleep 1
  dua_in "${PROJECT}" bg status ticker
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"stopped"* ]]
}

@test "bg list shows every process, not just the first" {
  # Regression: docker exec -i inside the listing loop used to swallow the
  # loop's own stdin, so only the first entry was ever reported.
  dua_in "${PROJECT}" bg start one -- 'sleep 30'
  dua_in "${PROJECT}" bg start two -- 'sleep 30'
  sleep 1
  dua_in "${PROJECT}" bg list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"one"* ]]
  [[ "${output}" == *"two"* ]]
  dua_in "${PROJECT}" bg stop one
  dua_in "${PROJECT}" bg stop two
}

@test "a background process gets the DUA environment" {
  dua_in "${PROJECT}" bg start envchk -- 'echo "DISTRO=${ROS_DISTRO}"; sleep 5'
  sleep 2
  dua_in "${PROJECT}" bg logs envchk
  [[ "${output}" == *"DISTRO=jazzy"* ]]
  dua_in "${PROJECT}" bg stop envchk
}

@test "starting a background process twice is refused" {
  dua_in "${PROJECT}" bg start dupe -- 'sleep 30'
  sleep 1
  dua_in "${PROJECT}" bg start dupe -- 'sleep 30'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already running"* ]]
  dua_in "${PROJECT}" bg stop dupe
}

@test "pkg new creates a package visible on the host" {
  dua_in "${PROJECT}" pkg new my_new_pkg --deps "rclcpp std_msgs"
  [ "${status}" -eq 0 ]
  [ -f "${PROJECT}/src/my_new_pkg/package.xml" ]
  local log
  log="$(mock_log ros2)"
  [[ "${log}" == *"pkg create --package-format 3"* ]]
  [[ "${log}" == *"--dependencies rclcpp std_msgs"* ]]
  [[ "${log}" == *"--build-type ament_cmake"* ]]
}

@test "setup runs the project script from the repository root" {
  cat >"${PROJECT}/bin/dua_setup.sh" <<'EOS'
#!/usr/bin/env bash
echo "args: $*"
echo "cwd: $(pwd)"
EOS
  chmod +x "${PROJECT}/bin/dua_setup.sh"
  dua_in "${PROJECT}/src" setup modify -a some_unit x86-cudev
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"args: modify -a some_unit x86-cudev"* ]]
  [[ "${output}" == *"cwd: ${PROJECT}"* ]]
  [[ "${output}" == *"must be rebuilt"* ]]
  [[ "${output}" == *"not recursive"* ]]
}
