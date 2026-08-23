#!/usr/bin/env bash

# Offline unit tests for the dua CLI.
#
# No Docker daemon is involved: tests/stub/docker replays container records
# captured from real DUA hosts (flight_stack under VS Code, marco-polo under
# Compose, go2_stack on a uid 10001 host).
#
# Usage: tests/unit/run.sh [-v]
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "${HERE}/../.." && pwd)"
DUA="${ROOT}/plugins/dua-claude/bin/dua"
STUB_DIR="${ROOT}/tests/stub"
VERBOSE=0
[[ "${1-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
CURRENT=""

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------

scenario() {
  CURRENT="${1}"
  printf '\n\033[1m%s\033[0m\n' "${CURRENT}"
}

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mok\033[0m   %s\n' "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2-}" ]] && printf '       %s\n' "${2}"
}

assert_contains() {
  local hay="${1}" needle="${2}" label="${3}"
  if [[ "${hay}" == *"${needle}"* ]]; then
    ok "${label}"
  else
    no "${label}" "expected to find: ${needle}"
    [[ ${VERBOSE} -eq 1 ]] && printf '%s\n' "${hay}" | sed 's/^/       | /'
  fi
}

assert_not_contains() {
  local hay="${1}" needle="${2}" label="${3}"
  if [[ "${hay}" != *"${needle}"* ]]; then
    ok "${label}"
  else
    no "${label}" "did not expect: ${needle}"
  fi
}

assert_rc() {
  local got="${1}" want="${2}" label="${3}"
  if [[ "${got}" == "${want}" ]]; then ok "${label}"; else no "${label}" "exit ${got}, expected ${want}"; fi
}

# --------------------------------------------------------------------------
# Fixture construction
# --------------------------------------------------------------------------

# make_repo <path> <name> <target>...
# Builds a DUA project tree with the given targets configured.
make_repo() {
  local path="${1}" name="${2}"
  shift 2
  mkdir -p "${path}"/{src,logs,config,tools,bin}
  touch "${path}/bin/dua_setup.sh"
  local t d
  for t in "$@"; do
    d="${path}/docker/container-${t}"
    mkdir -p "${d}/.devcontainer"
    cat >"${d}/.devcontainer/docker-compose.yaml" <<EOF
services:
  ${name}-${t}:
    build:
      context: ../
      dockerfile: Dockerfile
      args:
        - USER_UID=1000
    image: ${name}:${t}
    user: neo
    network_mode: "host"
    volumes:
      - ../../../:/home/neo/workspace
EOF
    cat >"${d}/Dockerfile" <<EOF
FROM dotxautomation/dua-foundation:${t}
# IMAGE SETUP START #
# dep_one START #
RUN echo dep_one
# dep_one END #
# ${name} START #
RUN echo ${name}
# ${name} END #
# IMAGE SETUP END #
EOF
    local f
    for f in aliases.sh commands.sh ros2.sh bashrc dua_submod.sh dua_subtree.sh; do
      echo "# ${f}" >"${d}/${f}"
    done
  done
}

# make_pkg <repo> <relative path> <package name>
make_pkg() {
  mkdir -p "${1}/${2}"
  cat >"${1}/${2}/package.xml" <<EOF
<?xml version="1.0"?>
<package format="3">
  <name>${3}</name>
  <description>${3}</description>
</package>
EOF
}

# new_fixture -> prints a fresh fixture dir
new_fixture() {
  local d
  d="$(mktemp -d "${TMP}/fix.XXXXXX")"
  mkdir -p "${d}/containers" "${d}/pending"
  printf '1000\n1000\n' >"${d}/ids"
  printf '%s' "" >"${d}/dua_target"
  printf '%s' "${d}"
}

# add_container <fixture> <id> <name> <image> <state> <service> <project> <dcfolder> <wssrc>
add_container() {
  local fix="${1}" id="${2}"
  cat >"${fix}/containers/${id}.rec" <<EOF
DUA_REC_BEGIN
ID	${id}
NAME	/${3}
IMAGE	${4}
STATE	${5}
STARTED	2026-08-22T16:31:18.924911441Z
SERVICE	${6}
PROJECT	${7}
DCFOLDER	${8}
WSSRC	${9}
DUA_REC_END
EOF
}

add_image() { printf '%s\n' "${2}" >>"${1}/images"; }

# run_dua <fixture> <cwd> <args...>
OUT=""
RC=0
run_dua() {
  local fix="${1}" cwd="${2}"
  shift 2
  OUT="$(
    cd "${cwd}" || exit 99
    PATH="${STUB_DIR}:${PATH}" \
      DUA_STUB_FIXTURE="${fix}" \
      DUA_STUB_LOG="${fix}/calls.log" \
      CLAUDE_PLUGIN_DATA="${fix}/state" \
      NO_COLOR=1 \
      "${DUA}" "$@" 2>&1
  )"
  RC=$?
}

calls() { cat "${1}/calls.log" 2>/dev/null || true; }

# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------

scenario "outside a DUA project"
fix="$(new_fixture)"
mkdir -p "${TMP}/plain"
run_dua "${fix}" "${TMP}/plain" ctx
assert_rc "${RC}" 1 "ctx exits 1"
assert_contains "${OUT}" "not inside a DUA project" "explains why"

scenario "single unit, container running, from the repo root"
fix="$(new_fixture)"
repo="${TMP}/flight_stack"
make_repo "${repo}" flight_stack x86-cudev x86-dev
add_image "${fix}" "flight_stack:x86-cudev"
add_container "${fix}" 816eb445df3b \
  "container-x86-cudev_devcontainer-flight_stack-x86-cudev-1" \
  "vsc-container-x86-cudev-dc6c14dd-uid" running \
  "flight_stack-x86-cudev" "container-x86-cudev_devcontainer" \
  "${repo}/docker/container-x86-cudev" "${repo}"
run_dua "${fix}" "${repo}" ctx
assert_rc "${RC}" 0 "ctx succeeds"
assert_contains "${OUT}" "container      running" "reports running"
assert_contains "${OUT}" "resolved by    mount" "resolved by mount, not by name"
assert_contains "${OUT}" "target         x86-cudev" "target from the compose service label"
assert_contains "${OUT}" "->  /home/neo/workspace" "cwd maps to the workspace root"
assert_contains "${OUT}" "x86-cudev (built)" "marks the built image"
run_dua "${fix}" "${repo}" ctx --json
assert_contains "${OUT}" '"strategy": "mount"' "json carries the strategy"
assert_contains "${OUT}" '"units": "dep_one,flight_stack"' "parses units from the Dockerfile"
assert_not_contains "${OUT}" '"units": "IMAGE' "drops the IMAGE SETUP marker"

scenario "same project, from a subdirectory"
mkdir -p "${repo}/src/px4_msgs/include"
run_dua "${fix}" "${repo}/src/px4_msgs/include" ctx
assert_contains "${OUT}" "->  /home/neo/workspace/src/px4_msgs/include" "cwd maps through the mount"

scenario "nested unit inside a macro-project"
fix="$(new_fixture)"
macro="${TMP}/marco-polo"
make_repo "${macro}" marco-polo x86-cudev
mkdir -p "${macro}/src"
make_repo "${macro}/src/go2_stack" go2_stack x86-cudev
add_image "${fix}" "marco-polo:x86-cudev"
add_container "${fix}" 7d2d43a72b5c "devcontainer-marco-polo-x86-cudev-1" \
  "marco-polo:x86-cudev" running "marco-polo-x86-cudev" "devcontainer" "" "${macro}"
run_dua "${fix}" "${macro}/src/go2_stack" ctx
assert_rc "${RC}" 0 "ctx succeeds inside the nested unit"
assert_contains "${OUT}" "container      running" "resolves the macro-project container"
assert_contains "${OUT}" "devcontainer-marco-polo-x86-cudev-1" "picks the owning container"
assert_contains "${OUT}" "->  /home/neo/workspace/src/go2_stack" "maps the nested path"
assert_contains "${OUT}" "role           unit nested in ${macro}" "reports the nested role"

scenario "two DUA containers on one host"
fix="$(new_fixture)"
r1="${TMP}/h2_flight"
r2="${TMP}/h2_marco"
make_repo "${r1}" flight_stack x86-cudev
make_repo "${r2}" marco-polo x86-cudev
add_container "${fix}" aaaaaaaaaaaa "vsc-flight" "vsc-x-uid" running \
  "flight_stack-x86-cudev" "container-x86-cudev_devcontainer" "" "${r1}"
add_container "${fix}" bbbbbbbbbbbb "devcontainer-marco-polo-x86-cudev-1" \
  "marco-polo:x86-cudev" running "marco-polo-x86-cudev" "devcontainer" "" "${r2}"
run_dua "${fix}" "${r1}" ctx
assert_contains "${OUT}" "aaaaaaaaaaaa" "picks the flight_stack container"
run_dua "${fix}" "${r2}" ctx
assert_contains "${OUT}" "bbbbbbbbbbbb" "picks the marco-polo container"

scenario "two containers bound to the same root"
fix="$(new_fixture)"
repo="${TMP}/dupes"
make_repo "${repo}" dupes x86-cudev
add_container "${fix}" cccccccccccc "vsc-dupes" "vsc-x-uid" running \
  "dupes-x86-cudev" "container-x86-cudev_devcontainer" "" "${repo}"
add_container "${fix}" dddddddddddd "devcontainer-dupes-x86-cudev-1" \
  "dupes:x86-cudev" running "dupes-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}" ctx
assert_rc "${RC}" 1 "ctx refuses to guess"
assert_contains "${OUT}" "cccccccccccc" "lists the first candidate"
assert_contains "${OUT}" "dddddddddddd" "lists the second candidate"
run_dua "${fix}" "${repo}" exec -- true
assert_rc "${RC}" 1 "exec refuses too"
assert_contains "${OUT}" "refusing to guess" "says why"

scenario "container stopped"
fix="$(new_fixture)"
repo="${TMP}/stopped"
make_repo "${repo}" stopped x86-cudev
add_image "${fix}" "stopped:x86-cudev"
add_container "${fix}" eeeeeeeeeeee "devcontainer-stopped-x86-cudev-1" \
  "stopped:x86-cudev" exited "stopped-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}" ctx
assert_contains "${OUT}" "container      stopped" "ctx reports stopped"
run_dua "${fix}" "${repo}" exec -- colcon build
assert_rc "${RC}" 1 "exec fails cleanly"
assert_contains "${OUT}" "dua up" "suggests starting it"
run_dua "${fix}" "${repo}" up
assert_rc "${RC}" 0 "up succeeds"
assert_contains "$(calls "${fix}")" "start eeeeeeeeeeee" "starts the existing container"
assert_not_contains "$(calls "${fix}")" "compose up" "does not create a second one"

scenario "no container, image built vs not built"
fix="$(new_fixture)"
repo="${TMP}/nocont"
make_repo "${repo}" nocont x86-cudev
run_dua "${fix}" "${repo}" ctx
assert_contains "${OUT}" "absent (image not built)" "distinguishes a missing image"
add_image "${fix}" "nocont:x86-cudev"
run_dua "${fix}" "${repo}" ctx
assert_contains "${OUT}" "absent (image built)" "distinguishes a built image"
run_dua "${fix}" "${repo}" exec -- true
assert_contains "${OUT}" "no container is running" "exec explains the situation"

scenario "compose service label fallback"
fix="$(new_fixture)"
repo="${TMP}/labelonly"
make_repo "${repo}" labelonly x86-cudev
add_container "${fix}" ffffffffffff "devcontainer-labelonly-x86-cudev-1" \
  "labelonly:x86-cudev" running "labelonly-x86-cudev" "devcontainer" "" ""
run_dua "${fix}" "${repo}" ctx
assert_contains "${OUT}" "resolved by    service-label" "falls back to the service label"
assert_contains "${OUT}" "ffffffffffff" "finds the container"

scenario "a container mounting another checkout is not stolen"
fix="$(new_fixture)"
repo="${TMP}/mine"
other="${TMP}/theirs"
make_repo "${repo}" twin x86-cudev
make_repo "${other}" twin x86-cudev
add_container "${fix}" 111111111111 "devcontainer-twin-x86-cudev-1" \
  "twin:x86-cudev" running "twin-x86-cudev" "devcontainer" "" "${other}"
run_dua "${fix}" "${repo}" ctx
assert_contains "${OUT}" "absent" "ignores the other checkout's container"

scenario "exec command construction"
fix="$(new_fixture)"
repo="${TMP}/execs"
make_repo "${repo}" execs x86-cudev
mkdir -p "${repo}/src/pkg_a"
add_container "${fix}" 222222222222 "devcontainer-execs-x86-cudev-1" \
  "execs:x86-cudev" running "execs-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}/src/pkg_a" exec -- colcon build --packages-select pkg_a
assert_rc "${RC}" 0 "exec succeeds"
log="$(calls "${fix}")"
assert_contains "${log}" "exec -i -u neo -w /home/neo/workspace/src/pkg_a" "maps the working directory"
assert_contains "${log}" "TERM=dumb" "sets TERM"
assert_contains "${log}" "DUA_CMD=colcon build --packages-select pkg_a" "passes the command by environment"
assert_contains "${log}" "/tmp/dua-cc/env.sh" "uses the environment snapshot"
assert_contains "${log}" "expand_aliases" "enables aliases"
assert_not_contains "${log}" "bash -ic eval" "does not use an interactive shell in snap mode"

scenario "exec modes and timeout"
run_dua "${fix}" "${repo}" exec --mode ic -- true
assert_contains "$(calls "${fix}")" "bash -ic" "ic mode uses an interactive shell"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec --mode raw -- true
assert_not_contains "$(calls "${fix}")" "dua-cc/env.sh" "raw mode skips the snapshot"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec --timeout 30s -- ros2 launch pkg a.launch.py
assert_contains "$(calls "${fix}")" "timeout 30s" "applies the deadline"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec "ros2 topic list | head -3"
assert_contains "$(calls "${fix}")" "DUA_CMD=ros2 topic list | head -3" "single argument stays a shell string"

scenario "the snapshot cannot capture our own variables"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec -- 'echo one'
log="$(calls "${fix}")"
assert_contains "${log}" "env -u DUA_CMD -u DUA_DOMAIN bash -ic" "scrubs them before capture"
assert_contains "${log}" "PWD|OLDPWD|SHLVL|_|DUA_CMD|DUA_DOMAIN" "excludes them from the snapshot"
assert_contains "${log}" '__dua_cmd="$DUA_CMD"' "saves the command before sourcing"
assert_contains "${log}" 'DUA_CMD="$__dua_cmd"' "restores it afterwards"

scenario "snapshot recipe version"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec -- true
assert_contains "$(calls "${fix}")" "__dua_stamp='v2:" "the stamp carries the recipe version"
run_dua "${fix}" "${repo}" --time exec -- true
assert_contains "${OUT}" "[dua] resolve" "--time reports per-phase timings"

scenario "ROS domain override"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec --domain 7 -- 'ros2 topic list'
log="$(calls "${fix}")"
assert_contains "${log}" "DUA_DOMAIN=7" "passes the domain under a private name"
assert_not_contains "${log}" "-e ROS_DOMAIN_ID=7" "never injects ROS_DOMAIN_ID directly"
assert_contains "${log}" 'export ROS_DOMAIN_ID="$DUA_DOMAIN"' "applies it after the environment"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec --mode ic --domain 7 -- 'ros2 topic list'
assert_contains "$(calls "${fix}")" 'export ROS_DOMAIN_ID="$DUA_DOMAIN"' "also in interactive mode, after ros2init"

scenario "exit codes and flag placement"
: >"${fix}/calls.log"
DUA_STUB_EXEC_RC=42 run_dua "${fix}" "${repo}" exec -- false
assert_rc "${RC}" 42 "propagates the command's exit code"
DUA_STUB_EXEC_RC=124 run_dua "${fix}" "${repo}" exec --timeout 5s -- sleep 99
assert_rc "${RC}" 124 "reports a deadline as 124"
assert_contains "${OUT}" "hit its 5s deadline" "explains the deadline"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" --mode ic exec -- true
assert_contains "$(calls "${fix}")" "bash -ic" "accepts global flags before the subcommand"

scenario "down never uses compose"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" down
assert_rc "${RC}" 0 "down succeeds"
assert_contains "$(calls "${fix}")" "stop 222222222222" "stops the container directly"
assert_not_contains "$(calls "${fix}")" "compose down" "never calls compose down"

scenario "target inference for up"
fix="$(new_fixture)"
repo="${TMP}/infer"
make_repo "${repo}" infer x86-dev x86-cudev jetson6
add_image "${fix}" "infer:x86-cudev"
cp "${TMP}/execs/docker/container-x86-cudev/.devcontainer/docker-compose.yaml" /dev/null 2>/dev/null || true
run_dua "${fix}" "${repo}" up
assert_contains "$(calls "${fix}")" "compose up -d" "brings up the only built target"
run_dua "${fix}" "${repo}" ctx --json
assert_contains "${OUT}" '"name": "jetson6"' "lists every configured target"

scenario "build: workspace-wide"
fix="$(new_fixture)"
repo="${TMP}/bld"
make_repo "${repo}" bld x86-cudev
make_pkg "${repo}" src/unit_a/pkg_a1 pkg_a1
make_pkg "${repo}" src/unit_a/pkg_a2 pkg_a2
make_pkg "${repo}" src/pkg_b pkg_b
add_container "${fix}" 444444444444 "devcontainer-bld-x86-cudev-1" \
  "bld:x86-cudev" running "bld-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}" build
assert_rc "${RC}" 0 "build succeeds"
log="$(calls "${fix}")"
assert_contains "${log}" "colcon build --symlink-install" "builds with symlink install"
assert_not_contains "${log}" "--continue-on-error" "stops at the first failure by default"
assert_contains "${log}" "--event-handlers status- desktop_notification-" "quiet by default"
assert_not_contains "${log}" "console_direct+" "no full stream unless asked"
assert_contains "${log}" "'-DCMAKE_EXPORT_COMPILE_COMMANDS=On'" "exports compile_commands.json"
assert_not_contains "${log}" "RelWithDebInfo" "does not force a build type"
assert_contains "${log}" "-w /home/neo/workspace " "runs at the workspace root"
assert_not_contains "${log}" "--packages-select" "no selection at the workspace root"
assert_not_contains "${log}" "install/setup.sh" "no extra underlay sourcing"
if compgen -G "${repo}/logs/cc/*-build.log" >/dev/null; then ok "writes a log under logs/cc"; else no "writes a log under logs/cc"; fi

scenario "build: package inference and selection"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}/src/unit_a" build
log="$(calls "${fix}")"
assert_contains "${log}" "--packages-select pkg_a1 pkg_a2" "infers both packages of the unit"
assert_not_contains "${log}" "install/setup.sh" "no extra sourcing: ros2init already did it"
assert_contains "${OUT}" "building the packages found here" "says what it inferred"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}/src/unit_a/pkg_a2" build
assert_contains "$(calls "${fix}")" "--packages-select pkg_a2" "infers a single package"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}/src/unit_a" build --all
assert_not_contains "$(calls "${fix}")" "--packages-select" "--all overrides inference"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build pkg_b
assert_contains "$(calls "${fix}")" "--packages-select pkg_b" "explicit packages win"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --debug
log="$(calls "${fix}")"
assert_contains "${log}" "'-DCMAKE_BUILD_TYPE=Debug'" "--debug forces the Debug build type"
assert_contains "${log}" "--cmake-force-configure" "and forces a reconfigure so it takes effect"
assert_contains "${OUT}" "unconditionally" "and warns that CMakeLists can override it"
assert_contains "${log}" "'-DCMAKE_EXPORT_COMPILE_COMMANDS=On'" "and still exports compile commands"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build -v
assert_contains "$(calls "${fix}")" "console_direct+" "-v streams everything"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --keep-going
assert_contains "$(calls "${fix}")" "--continue-on-error" "--keep-going opts out of stopping"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --up-to pkg_b
assert_contains "$(calls "${fix}")" "--packages-up-to pkg_b" "--up-to switches the selection mode"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --no-compile-commands
assert_not_contains "$(calls "${fix}")" "ament-cmake-args" "--no-compile-commands drops the cmake args entirely"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --clean pkg_b
log="$(calls "${fix}")"
assert_contains "${log}" "rm -rf build/pkg_b install/pkg_b" "--clean with packages removes only theirs"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" build --clean --all
assert_contains "$(calls "${fix}")" "rm -rf build install log" "--clean --all purges the workspace"

scenario "build: snapshot invalidation"
gen_before="$(cat "${fix}/state/repos/"*.gen 2>/dev/null || echo 0)"
run_dua "${fix}" "${repo}" build
gen_after="$(cat "${fix}/state/repos/"*.gen 2>/dev/null || echo 0)"
if [[ "${gen_after}" -gt "${gen_before}" ]]; then ok "a successful build invalidates the snapshot"; else no "a successful build invalidates the snapshot" "gen ${gen_before} -> ${gen_after}"; fi
DUA_STUB_EXEC_RC=1 run_dua "${fix}" "${repo}" build
assert_rc "${RC}" 1 "a failed build returns non-zero"
assert_contains "${OUT}" "latest_build" "and points at the per-package logs"

scenario "test"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" test
log="$(calls "${fix}")"
assert_contains "${log}" "colcon test --return-code-on-test-failure" "runs colcon test"
assert_contains "${log}" "colcon test-result --all --verbose" "always prints results"
assert_not_contains "${log}" "test-result --all --verbose --packages-select" "never selects packages on test-result"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}/src/pkg_b" test
log="$(calls "${fix}")"
assert_contains "${log}" "colcon test --return-code-on-test-failure --event-handlers status- desktop_notification- --packages-select pkg_b" "selects on colcon test only"
assert_contains "${log}" "test-result --test-result-base build/pkg_b" "narrows results by result base instead"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" test --up-to pkg_b
assert_contains "$(calls "${fix}")" "--packages-up-to pkg_b" "test supports --up-to too"

scenario "run under a deadline"
: >"${fix}/calls.log"
DUA_STUB_EXEC_RC=124 run_dua "${fix}" "${repo}" run --for 5s -- ros2 launch pkg a.launch.py
assert_rc "${RC}" 0 "a reached deadline is not a failure"
assert_contains "${OUT}" "deadline reached" "and says so"
assert_contains "$(calls "${fix}")" "timeout 5s" "applies the deadline"
run_dua "${fix}" "${repo}" run -- something
assert_rc "${RC}" 2 "run without a deadline is refused"

scenario "background processes"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" bg start talker -- ros2 run demo_nodes_cpp talker
assert_rc "${RC}" 0 "bg start succeeds"
log="$(calls "${fix}")"
assert_contains "${log}" "cat > /tmp/dua-cc/bg/talker.sh" "stages the script in the container"
assert_contains "${log}" "setsid bash /tmp/dua-cc/bg/talker.sh" "runs it under setsid"
assert_contains "${log}" "/home/neo/workspace/logs/cc/bg-talker.log" "logs where the host can read it"
assert_contains "${log}" "exec -d" "detaches"
staged="$(cat "${fix}/bg/talker.sh" 2>/dev/null)"
assert_contains "${staged}" 'echo $$ > /tmp/dua-cc/bg/talker.pid' "the script records its own pid"
assert_contains "${staged}" "ros2 run demo_nodes_cpp talker" "and carries the command"
assert_contains "${staged}" "dua-cc/env.sh" "with the DUA environment"
run_dua "${fix}" "${repo}" bg status talker
assert_contains "${OUT}" "running" "status reports it running"
run_dua "${fix}" "${repo}" bg list
assert_contains "${OUT}" "talker" "list shows it"
run_dua "${fix}" "${repo}" bg start talker -- something
assert_rc "${RC}" 1 "starting it twice is refused"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" bg stop talker
assert_contains "$(calls "${fix}")" "kill -INT" "stop sends SIGINT first"
assert_not_contains "$(calls "${fix}")" "kill -KILL" "and does not escalate when it works"

scenario "setup passthrough"
fix="$(new_fixture)"
repo="${TMP}/setup"
make_repo "${repo}" setup x86-cudev
cat >"${repo}/bin/dua_setup.sh" <<'EOS'
#!/usr/bin/env bash
echo "dua_setup.sh called with: $*"
echo "cwd: $(pwd)"
EOS
chmod +x "${repo}/bin/dua_setup.sh"
add_container "${fix}" 555555555555 "devcontainer-setup-x86-cudev-1" \
  "setup:x86-cudev" running "setup-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}/src" setup modify -a some_unit x86-cudev
assert_rc "${RC}" 0 "setup succeeds"
assert_contains "${OUT}" "called with: modify -a some_unit x86-cudev" "passes the arguments through"
assert_contains "${OUT}" "cwd: ${repo}" "runs from the repository root"
assert_contains "${OUT}" "must be rebuilt" "warns about the rebuild"
assert_contains "${OUT}" "not recursive" "reminds about unit inclusion"
run_dua "${fix}" "${repo}" setup
assert_rc "${RC}" 2 "setup with no arguments is refused"

scenario "pkg new"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" pkg new my_node --deps "rclcpp std_msgs" --node my_node_exec
log="$(calls "${fix}")"
assert_contains "${log}" "ros2 pkg create --package-format 3" "uses the template invocation"
assert_contains "${log}" "--destination-directory src --build-type ament_cmake" "defaults to a cmake package"
assert_contains "${log}" "--dependencies rclcpp std_msgs" "passes dependencies"
assert_contains "${log}" "--node-name my_node_exec" "passes the node name"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" pkg new py_pkg --python
assert_contains "$(calls "${fix}")" "--build-type ament_python" "--python switches the build type"

scenario "resolution cache"
fix="$(new_fixture)"
repo="${TMP}/cache"
make_repo "${repo}" cache x86-cudev
add_container "${fix}" 666666666666 "devcontainer-cache-x86-cudev-1" \
  "cache:x86-cudev" running "cache-x86-cudev" "devcontainer" "" "${repo}"
run_dua "${fix}" "${repo}" exec -- true
if compgen -G "${fix}/state/repos/*.cid" >/dev/null; then ok "remembers the container id"; else no "remembers the container id"; fi
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec -- true
log="$(calls "${fix}")"
assert_not_contains "${log}" "ps -aq" "a cache hit skips the full scan"
assert_contains "${log}" "inspect 666666666666" "and revalidates the cached id"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" --trace exec -- true
assert_contains "${OUT}" "resolved from cache" "--trace says so"
# a stopped container must not be served from the cache
sed -i 's/^STATE\trunning/STATE\texited/' "${fix}/containers/666666666666.rec"
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" exec -- true
assert_contains "$(calls "${fix}")" "ps -aq" "a stopped cached container falls back to a scan"
assert_contains "${OUT}" "dua up" "and reports it correctly"
sed -i 's/^STATE\texited/STATE\trunning/' "${fix}/containers/666666666666.rec"
# ctx must never use the cache, so anomalies stay visible
: >"${fix}/calls.log"
run_dua "${fix}" "${repo}" ctx
assert_contains "$(calls "${fix}")" "ps -aq" "ctx always scans"

scenario "doctor"
fix="$(new_fixture)"
repo="${TMP}/doc"
make_repo "${repo}" doc x86-cudev
add_image "${fix}" "doc:x86-cudev"
add_container "${fix}" 333333333333 "devcontainer-doc-x86-cudev-1" \
  "doc:x86-cudev" running "doc-x86-cudev" "devcontainer" "" "${repo}"
printf 'x86-cudev' >"${fix}/dua_target"
printf '10001\n60001\n' >"${fix}/ids"   # uid and gid deliberately unrelated
run_dua "${fix}" "${repo}" doctor
assert_rc "${RC}" 0 "doctor passes with no blockers"
assert_contains "${OUT}" "uid host" "uid difference is reported"
assert_contains "${OUT}" "[note]" "uid and gid differences are notes"
assert_not_contains "${OUT}" "warning" "gid mismatch is never a warning"
assert_contains "${OUT}" "/etc/dua/target agrees" "cross-checks the target file"
assert_contains "${OUT}" "no blockers" "summarises"

scenario "doctor without a daemon"
DUA_STUB_NO_DAEMON=1 run_dua "${fix}" "${repo}" doctor
assert_rc "${RC}" 1 "doctor fails when the daemon is unreachable"

# --------------------------------------------------------------------------

printf '\n\033[1m%s passed, %s failed\033[0m\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
