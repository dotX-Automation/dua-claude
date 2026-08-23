#!/usr/bin/env bash

# Development workflows for the dua CLI.
#
# Everything runs from the workspace root, because colcon requires it,
# and every long-running command is logged to logs/cc/ on the host,
# which the template already gitignores.
#
# Copyright 2026 dotX Automation s.r.l.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck shell=bash

# Based on the cbuild alias from the template's ros2.sh, minus its
# --continue-on-error: stopping at the first failure is colcon's default and is
# what a reader of the output usually wants. --keep-going brings it back.
# No build type is forced: each package's CMakeLists.txt decides.
readonly DUA_COLCON_BUILD="colcon build --symlink-install"

# Verbosity. colcon's defaults already print package start/end lines, stream
# stderr directly and print a summary, which is what matters when something
# fails; the full stream is tee'd to logs/cc/ regardless. console_direct+ (what
# a human sees when typing cbuild) is behind -v, because on a large workspace it
# produces thousands of lines nobody reads.
readonly DUA_EH_QUIET="--event-handlers status- desktop_notification-"
readonly DUA_EH_VERBOSE="--event-handlers console_direct+ status- desktop_notification-"

# compile_commands.json is not part of the manual workflow, but Claude reads it
# to resolve includes and symbols, so it is exported unless asked otherwise.
readonly DUA_CMAKE_EXPORT="--ament-cmake-args '-DCMAKE_EXPORT_COMPILE_COMMANDS=On'"
readonly DUA_CMAKE_DEBUG="--ament-cmake-args '-DCMAKE_BUILD_TYPE=Debug' '-DCMAKE_EXPORT_COMPILE_COMMANDS=On'"

# Test integration is still being worked out at dotX, so this invocation is
# provisional and not taken from any existing workflow.
readonly DUA_COLCON_TEST="colcon test --return-code-on-test-failure"

# ---------------------------------------------------------------------------
# Logging on the host
# ---------------------------------------------------------------------------

# Everything under logs/ is gitignored by the template, so nothing here dirties
# a working tree.
cc_log_dir() { printf '%s/logs/cc' "${DUA_WSSRC:-${DUA_REPO_ROOT}}"; }

new_log() {
  local d
  d="$(cc_log_dir)"
  mkdir -p "${d}" 2>/dev/null || true
  printf '%s/%s-%s.log' "${d}" "$(date +%Y%m%d-%H%M%S)" "${1}"
}

# Run a command at the workspace root, streaming and logging it.
# Sets REPLY_LOG to the log path. Returns the command's exit status.
run_logged() {
  local slug="${1}" tmo="${2}" cmd="${3}" log rc=0
  log="$(new_log "${slug}")"
  REPLY_LOG="${log}"
  set +o errexit
  dua_exec_in "${DUA_WS}" "${tmo}" "${cmd}" 2>&1 | tee "${log}"
  rc="${PIPESTATUS[0]}"
  set -o errexit
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Package inference
# ---------------------------------------------------------------------------

# Packages defined at or below the current directory, one per line, when the
# session sits somewhere inside src/. Empty at the workspace root, where the
# intent is the whole workspace.
infer_packages() {
  local ws_root pwd_p f
  ws_root="${DUA_WSSRC:-${DUA_REPO_ROOT}}"
  pwd_p="$(pwd -P)"
  [[ "${pwd_p}" == "${ws_root}/src" || "${pwd_p}" == "${ws_root}/src/"* ]] || return 0
  while read -r f; do
    [[ -n "${f}" ]] || continue
    sed -n 's:.*<name>[[:space:]]*\([^< ]*\)[[:space:]]*</name>.*:\1:p' "${f}" | head -1
  done < <(find "${pwd_p}" -name package.xml \
    -not -path '*/build/*' -not -path '*/install/*' -not -path '*/log/*' 2>/dev/null) |
    sort -u
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

dua_build() {
  local debug=0 clean=0 all=0 upto=0 nocc=0 verbose=0 keepgoing=0
  local -a pkgs=()
  while [[ $# -gt 0 ]]; do
    case "${1}" in
    --debug) debug=1 ;;
    --clean) clean=1 ;;
    --all) all=1 ;;
    --up-to) upto=1 ;;
    --no-compile-commands) nocc=1 ;;
    -v | --verbose) verbose=1 ;;
    --keep-going) keepgoing=1 ;;
    -*)
      err "unknown option for build: ${1}"
      return 2
      ;;
    *) pkgs+=("${1}") ;;
    esac
    shift
  done

  if [[ ${#pkgs[@]} -eq 0 && ${all} -eq 0 ]]; then
    mapfile -t pkgs < <(infer_packages)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      info "building the packages found here: ${pkgs[*]}  (use --all for the whole workspace)"
    fi
  fi

  if [[ ${clean} -eq 1 ]]; then
    local cleancmd
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      cleancmd="cd ${DUA_WS};"
      local p
      for p in "${pkgs[@]}"; do
        cleancmd+=" rm -rf build/${p} install/${p};"
      done
      info "removing build/ and install/ for: ${pkgs[*]}"
    else
      cleancmd="cd ${DUA_WS}; rm -rf build install log; py3clean . 2>/dev/null || true"
      info "removing build/, install/ and log/ from the whole workspace"
    fi
    dua_exec_in "${DUA_WS}" "" "${cleancmd}" || true
  fi

  # No underlay sourcing here: ros2init already sourced /opt/ros and, when it
  # exists, the workspace's install/local_setup, exactly as in a human shell.
  local cmd="${DUA_COLCON_BUILD}"
  if [[ ${verbose} -eq 1 ]]; then cmd+=" ${DUA_EH_VERBOSE}"; else cmd+=" ${DUA_EH_QUIET}"; fi
  if [[ ${keepgoing} -eq 1 ]]; then cmd+=" --continue-on-error"; fi
  # Selection comes before the cmake args, whose value list would otherwise
  # have to be terminated by the parser.
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    if [[ ${upto} -eq 1 ]]; then
      cmd+=" --packages-up-to ${pkgs[*]}"
    else
      cmd+=" --packages-select ${pkgs[*]}"
    fi
  fi
  if [[ ${debug} -eq 1 ]]; then
    # Without forcing a configure, changing only the build type often leaves
    # the existing build tree untouched.
    cmd+=" --cmake-force-configure ${DUA_CMAKE_DEBUG}"
    info "note: -DCMAKE_BUILD_TYPE=Debug only takes effect for packages whose"
    info "CMakeLists.txt does not set CMAKE_BUILD_TYPE unconditionally"
  elif [[ ${nocc} -eq 0 ]]; then
    cmd+=" ${DUA_CMAKE_EXPORT}"
  fi

  local rc=0
  run_logged build "" "${cmd}" || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    # New packages change AMENT_PREFIX_PATH, so the snapshot must be rebuilt.
    snapshot_bump "${DUA_REPO_ROOT}"
    info "build ok, log: ${REPLY_LOG}"
  else
    err "build failed (exit ${rc})"
    hint "full output: ${REPLY_LOG}"
    hint "per-package detail: ${DUA_WSSRC:-${DUA_REPO_ROOT}}/log/latest_build/<pkg>/stdout_stderr.log"
  fi
  return ${rc}
}

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------

dua_test() {
  local all=0 upto=0 verbose=0
  local -a pkgs=()
  while [[ $# -gt 0 ]]; do
    case "${1}" in
    --all) all=1 ;;
    --up-to) upto=1 ;;
    -v | --verbose) verbose=1 ;;
    -*)
      err "unknown option for test: ${1}"
      return 2
      ;;
    *) pkgs+=("${1}") ;;
    esac
    shift
  done

  if [[ ${#pkgs[@]} -eq 0 && ${all} -eq 0 ]]; then
    mapfile -t pkgs < <(infer_packages)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      info "testing the packages found here: ${pkgs[*]}  (use --all for the whole workspace)"
    fi
  fi

  local sel="" eh cmd result
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    if [[ ${upto} -eq 1 ]]; then
      sel=" --packages-up-to ${pkgs[*]}"
    else
      sel=" --packages-select ${pkgs[*]}"
    fi
  fi
  if [[ ${verbose} -eq 1 ]]; then eh="${DUA_EH_VERBOSE}"; else eh="${DUA_EH_QUIET}"; fi

  # colcon test-result takes no package selection: it reads whatever is under
  # the result base. For a single package that base can be narrowed, otherwise
  # the whole workspace is reported.
  result="colcon test-result --all --verbose"
  if [[ ${#pkgs[@]} -eq 1 ]]; then
    result="colcon test-result --test-result-base build/${pkgs[0]} --all --verbose"
  fi

  # Results are printed whatever the outcome, then the test status is returned.
  cmd="${DUA_COLCON_TEST} ${eh}${sel}; __rc=\$?; ${result}; exit \${__rc}"

  local rc=0
  run_logged test "" "${cmd}" || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    info "tests passed, log: ${REPLY_LOG}"
  else
    err "tests failed (exit ${rc})"
    hint "full output: ${REPLY_LOG}"
  fi
  return ${rc}
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

# A node under a deadline, in the mapped working directory rather than the
# workspace root, so relative paths behave as the user expects.
dua_run() {
  local tmo="${1}" cmd="${2}" log rc=0
  [[ -n "${tmo}" ]] || {
    err "run needs a deadline: dua run --for 20s -- COMMAND"
    return 2
  }
  log="$(new_log run)"
  info "running with a ${tmo} deadline, logging to ${log}"
  set +o errexit
  dua_exec_in "$(container_cwd)" "${tmo}" "${cmd}" 2>&1 | tee "${log}"
  rc="${PIPESTATUS[0]}"
  set -o errexit
  if [[ ${rc} -eq 124 ]]; then
    info "deadline reached after ${tmo}, process terminated (this is expected for nodes)"
    return 0
  fi
  return ${rc}
}

# ---------------------------------------------------------------------------
# bg
# ---------------------------------------------------------------------------

readonly DUA_BG_DIR="${DUA_CC_DIR}/bg"

_bg_check_name() {
  [[ "${1}" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name '${1}': use letters, digits, dash and underscore"
}

_bg_hostlog() { printf '%s/bg-%s.log' "$(cc_log_dir)" "${1}"; }
_bg_ctrlog() { printf '%s/logs/cc/bg-%s.log' "${DUA_WS}" "${1}"; }
_bg_pid() { printf '%s/%s.pid' "${DUA_BG_DIR}" "${1}"; }

_bg_pid_of() {
  dk exec -i -u "${DUA_USER}" "${DUA_CID}" cat "$(_bg_pid "${1}")" </dev/null 2>/dev/null |
    tr -d '\r\n' || true
}

_bg_alive() {
  local pid="${1}"
  [[ -n "${pid}" ]] || return 1
  local out
  out="$(dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
    sh -c "kill -0 ${pid} 2>/dev/null && echo yes" </dev/null 2>/dev/null || true)" || true
  [[ "${out}" == "yes" ]]
}

dua_bg_start() {
  local name="${1}" cmd="${2}" ccwd script pid
  _bg_check_name "${name}"
  pid="$(_bg_pid_of "${name}" || true)"
  if _bg_alive "${pid}"; then
    err "'${name}' is already running (pid ${pid})"
    hint "dua bg stop ${name}"
    return 1
  fi
  mkdir -p "$(cc_log_dir)" 2>/dev/null || true
  ccwd="$(container_cwd)"

  # The script records its own pid: under setsid it leads its process group, so
  # stopping it can signal the whole group and take child nodes with it.
  script="$(
    printf 'mkdir -p %s\n' "${DUA_BG_DIR}"
    printf 'echo $$ > %s\n' "$(_bg_pid "${name}")"
    _snapshot_prelude "$(snapshot_stamp "${DUA_REPO_ROOT}")"
    printf 'cd %s\n' "${ccwd}"
    printf '%s\n' "${cmd}"
  )"
  printf '%s' "${script}" |
    dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
      bash -c "mkdir -p ${DUA_BG_DIR} && cat > ${DUA_BG_DIR}/${name}.sh" ||
    die "could not stage the background script"

  dk exec -d -u "${DUA_USER}" -w "${ccwd}" -e "TERM=dumb" "${DUA_CID}" \
    bash -c "setsid bash ${DUA_BG_DIR}/${name}.sh > $(_bg_ctrlog "${name}") 2>&1 < /dev/null &" ||
    die "could not start '${name}'"

  sleep 0.3
  pid="$(_bg_pid_of "${name}" || true)"
  if _bg_alive "${pid}"; then
    info "'${name}' started (pid ${pid})"
  else
    warn "'${name}' exited immediately; see the log"
  fi
  info "log: $(_bg_hostlog "${name}")"
  return 0
}

dua_bg_status() {
  local name="${1-}" pid
  if [[ -z "${name}" ]]; then
    dua_bg_list
    return 0
  fi
  _bg_check_name "${name}"
  pid="$(_bg_pid_of "${name}" || true)"
  if _bg_alive "${pid}"; then
    printf '%-20s running  pid %s  %s\n' "${name}" "${pid}" "$(_bg_hostlog "${name}")"
    return 0
  fi
  printf '%-20s stopped%s  %s\n' "${name}" "${pid:+  (last pid ${pid})}" "$(_bg_hostlog "${name}")"
  return 1
}

dua_bg_list() {
  local names name
  names="$(dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
    sh -c "ls ${DUA_BG_DIR}/*.pid 2>/dev/null" </dev/null 2>/dev/null || true)"
  if [[ -z "${names}" ]]; then
    info "nothing running in the background"
    return 0
  fi
  while read -r name; do
    [[ -n "${name}" ]] || continue
    name="$(basename "${name}" .pid)"
    dua_bg_status "${name}" || true
  done <<<"${names}"
  return 0
}

dua_bg_logs() {
  local name="${1}" n="${2:-40}" f
  _bg_check_name "${name}"
  f="$(_bg_hostlog "${name}")"
  [[ -f "${f}" ]] || {
    err "no log for '${name}' at ${f}"
    return 1
  }
  tail -n "${n}" "${f}"
}

# SIGINT first: that is what ROS 2 nodes and launch files expect for a clean
# shutdown. Escalate only if they ignore it.
dua_bg_stop() {
  local name="${1}" pid i
  _bg_check_name "${name}"
  pid="$(_bg_pid_of "${name}" || true)"
  if ! _bg_alive "${pid}"; then
    info "'${name}' is not running"
    return 0
  fi
  info "stopping '${name}' (pid ${pid}) with SIGINT ..."
  dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
    sh -c "kill -INT -${pid} 2>/dev/null || kill -INT ${pid}" </dev/null || true
  # shellcheck disable=SC2034
  for i in 1 2 3 4 5 6 7 8 9 10; do
    _bg_alive "${pid}" || {
      info "'${name}' stopped"
      return 0
    }
    sleep 0.5
  done
  warn "'${name}' ignored SIGINT, sending SIGTERM"
  dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
    sh -c "kill -TERM -${pid} 2>/dev/null || kill -TERM ${pid}" </dev/null || true
  sleep 1
  if _bg_alive "${pid}"; then
    warn "'${name}' ignored SIGTERM, sending SIGKILL"
    dk exec -i -u "${DUA_USER}" "${DUA_CID}" \
      sh -c "kill -KILL -${pid} 2>/dev/null || kill -KILL ${pid}" </dev/null || true
  fi
  info "'${name}' stopped"
  return 0
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

# Guarded passthrough to the project's own setup script, which runs on the host
# and must run from the repository root.
dua_setup() {
  local script="${DUA_REPO_ROOT}/bin/dua_setup.sh" rc=0
  [[ -f "${script}" ]] || die "no bin/dua_setup.sh in ${DUA_REPO_ROOT}"
  [[ -x "${script}" ]] || die "bin/dua_setup.sh is not executable"
  [[ $# -gt 0 ]] || {
    err "nothing to do: dua setup create|modify|clear|delete ..."
    return 2
  }

  info "running ./bin/dua_setup.sh $* from ${DUA_REPO_ROOT}"
  (cd "${DUA_REPO_ROOT}" && "${script}" "$@") || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    err "dua_setup.sh failed (exit ${rc}); check for leftover artifacts before retrying"
    return ${rc}
  fi

  case "${1}" in
  create | modify | clear)
    info ""
    info "the target's Dockerfile changed, so the image must be rebuilt before the"
    info "change takes effect. Rebuilding is a human decision and can take a long time:"
    hint "cd docker/container-<TARGET>/.devcontainer && docker compose build"
    info "remember that unit inclusion is not recursive: a unit's own dependencies are"
    info "not pulled in, list every unit you need explicitly"
    ;;
  esac
  info "commit the changes"
  return 0
}

# ---------------------------------------------------------------------------
# pkg
# ---------------------------------------------------------------------------

dua_pkg_new() {
  local build_type="ament_cmake" deps="" node="" lib="" desc="" license="Apache-2.0" name=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
    --python) build_type="ament_python" ;;
    --deps)
      deps="${2-}"
      shift
      ;;
    --node)
      node="${2-}"
      shift
      ;;
    --library)
      lib="${2-}"
      shift
      ;;
    --description)
      desc="${2-}"
      shift
      ;;
    --license)
      license="${2-}"
      shift
      ;;
    -*)
      err "unknown option for pkg new: ${1}"
      return 2
      ;;
    *) name="${1}" ;;
    esac
    shift
  done
  [[ -n "${name}" ]] || {
    err "usage: dua pkg new NAME [--python] [--deps \"a b\"] [--node N] [--library L]"
    return 2
  }

  local mname memail
  mname="$(git -C "${DUA_REPO_ROOT}" config user.name 2>/dev/null || true)"
  memail="$(git -C "${DUA_REPO_ROOT}" config user.email 2>/dev/null || true)"
  [[ -n "${mname}" ]] || mname="dotX Automation"
  [[ -n "${memail}" ]] || memail="info@dotxautomation.com"
  [[ -n "${desc}" ]] || desc="${name} package"

  local cmd="ros2 pkg create --package-format 3"
  cmd+=" --description $(printf '%q' "${desc}")"
  cmd+=" --license $(printf '%q' "${license}")"
  cmd+=" --destination-directory src --build-type ${build_type}"
  [[ -n "${deps}" ]] && cmd+=" --dependencies ${deps}"
  cmd+=" --maintainer-name $(printf '%q' "${mname}")"
  cmd+=" --maintainer-email $(printf '%q' "${memail}")"
  [[ -n "${node}" ]] && cmd+=" --node-name ${node}"
  [[ -n "${lib}" ]] && cmd+=" --library-name ${lib}"
  cmd+=" ${name}"

  local rc=0
  dua_exec_in "${DUA_WS}" "" "${cmd}" || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    info "created src/${name} (owned by neo, visible on the host)"
    hint "dua build ${name}"
  fi
  return ${rc}
}
