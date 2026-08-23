#!/usr/bin/env bash

# Phase 0 environment probe for the dua-claude Claude Code plugin.
#
# Collects, read-only, everything needed to pin down container resolution,
# exec semantics and UID mapping on a real DUA development host.
#
# Usage:
#   ./dua-cc-probe.sh            # run from the root of a DUA project/unit
#   ./dua-cc-probe.sh -d DIR     # or point it at one
#   ./dua-cc-probe.sh -r         # redact $HOME, hostname and user name
#
# Writes a report to stdout and to /tmp/dua-cc-probe-<timestamp>.txt
#
# Safe by design: the only write is a temporary file under <repo>/logs/,
# used to verify UID mapping, removed immediately afterwards.

# Copyright 2026 dotX Automation s.r.l.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# NOTE: no errexit on purpose, most probes are expected to fail sometimes.
set -uo pipefail

VERSION="0.1.0"
START_DIR="${PWD}"
REDACT=0
WORKSPACE_MOUNT="/home/neo/workspace"
REPORT="/tmp/dua-cc-probe-$(date +%Y%m%d-%H%M%S).txt"

usage() {
  echo >&2 "Usage: dua-cc-probe.sh [-d DIR] [-r] [-h]"
  echo >&2 "  -d DIR  directory to probe from (default: current directory)"
  echo >&2 "  -r      redact home path, hostname and user name"
}

while getopts ":d:rh" opt; do
  case "${opt}" in
  d) START_DIR="${OPTARG}" ;;
  r) REDACT=1 ;;
  h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

section() { printf '\n===== %s =====\n' "$1"; }
kv() { printf '%-28s %s\n' "$1:" "${2:-}"; }
note() { printf '  # %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Monotonic-ish millisecond clock, with a fallback for hosts without date +%N.
now_ms() {
  local n
  n="$(date +%s%N 2>/dev/null)"
  if [[ "${n}" == *N* || -z "${n}" ]]; then
    echo $(($(date +%s) * 1000))
  else
    echo $((n / 1000000))
  fi
}

# run LABEL -- CMD...  : run a command, report exit code, stdout and stderr
run() {
  local label="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  local out err rc t0 t1
  out="$(mktemp)"
  err="$(mktemp)"
  t0="$(now_ms)"
  "$@" >"${out}" 2>"${err}"
  rc=$?
  t1="$(now_ms)"
  printf -- '--- %s\n' "${label}"
  printf '    cmd : %s\n' "$*"
  printf '    rc  : %s   (%s ms)\n' "${rc}" "$((t1 - t0))"
  if [[ -s "${out}" ]]; then
    sed 's/^/    out | /' "${out}" | head -40
  else
    printf '    out | <empty>\n'
  fi
  if [[ -s "${err}" ]]; then
    sed 's/^/    err | /' "${err}" | head -20
  else
    printf '    err | <empty>\n'
  fi
  rm -f "${out}" "${err}"
  return "${rc}"
}

# ----------------------------------------------------------------------------
# Report body
# ----------------------------------------------------------------------------

main_report() {

  section "0. PROBE"
  kv "probe version" "${VERSION}"
  kv "date" "$(date -Is 2>/dev/null || date)"
  kv "start dir" "${START_DIR}"

  # --------------------------------------------------------------------------
  section "1. HOST"
  kv "uname" "$(uname -srmo 2>/dev/null || uname -a)"
  kv "os-release" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  kv "bash" "${BASH_VERSION:-unknown}"
  kv "shell (\$SHELL)" "${SHELL:-unset}"
  kv "host uid" "$(id -u)"
  kv "host gid" "$(id -g)"
  kv "host user" "$(id -un)"
  kv "host groups" "$(id -Gn | tr ' ' ',')"
  kv "in docker group" "$(id -Gn | tr ' ' '\n' | grep -qx docker && echo yes || echo no)"
  kv "locale" "${LANG:-unset}"
  kv "realpath available" "$(have realpath && echo yes || echo no)"
  kv "getent available" "$(have getent && echo yes || echo no)"

  # --------------------------------------------------------------------------
  section "2. DOCKER"
  if ! have docker; then
    kv "docker" "NOT FOUND -- everything below is moot"
    return 0
  fi
  kv "docker client" "$(docker version --format '{{.Client.Version}}' 2>/dev/null)"
  kv "docker server" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  kv "rootless" "$(docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && echo yes || echo no)"
  kv "context" "$(docker context show 2>/dev/null)"
  kv "DOCKER_HOST" "${DOCKER_HOST:-unset}"
  kv "compose v2 plugin" "$(docker compose version --short 2>/dev/null || echo none)"
  kv "docker-compose v1" "$(docker-compose version --short 2>/dev/null || echo none)"
  kv "running containers" "$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"

  # --------------------------------------------------------------------------
  section "3. REPO DETECTION (walking up from start dir)"
  local d roots=()
  d="$(cd "${START_DIR}" 2>/dev/null && pwd -P)" || d=""
  if [[ -z "${d}" ]]; then
    kv "start dir" "UNREADABLE"
    return 0
  fi
  while :; do
    local marks=""
    [[ -d "${d}/docker" ]] && marks+="docker/ "
    [[ -f "${d}/bin/dua_setup.sh" ]] && marks+="dua_setup.sh "
    [[ -d "${d}/.git" || -f "${d}/.git" ]] && marks+=".git "
    [[ -d "${d}/src" ]] && marks+="src/ "
    if [[ -n "${marks}" ]]; then
      printf '  %-60s %s\n' "${d}" "[${marks% }]"
    fi
    if [[ -d "${d}/docker" && -f "${d}/bin/dua_setup.sh" ]]; then
      roots+=("${d}")
    fi
    [[ "${d}" == "/" ]] && break
    d="$(dirname "${d}")"
  done
  kv "DUA roots found" "${#roots[@]}"
  local i=0
  for r in "${roots[@]:-}"; do
    kv "  root[${i}]" "${r}"
    i=$((i + 1))
  done
  REPO_ROOT="${roots[0]:-}"
  kv "innermost root" "${REPO_ROOT:-NONE}"
  if [[ -z "${REPO_ROOT}" ]]; then
    note "not inside a DUA project: skipping sections 4-8"
    return 0
  fi
  kv "git branch" "$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  kv "git dirty files" "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  kv "has submodules" "$([[ -f "${REPO_ROOT}/.gitmodules" ]] && echo yes || echo no)"
  kv "units under src/" "$(find "${REPO_ROOT}/src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  find "${REPO_ROOT}/src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    while read -r u; do
      printf '    %-40s %s\n' "$(basename "${u}")" \
        "$([[ -d "${u}/docker" ]] && echo "DUA unit" || echo "plain package")"
    done

  # --------------------------------------------------------------------------
  section "4. TARGETS CONFIGURED IN THIS REPO"
  local tdir tname compose
  for tdir in "${REPO_ROOT}"/docker/container-*; do
    [[ -d "${tdir}" ]] || continue
    tname="$(basename "${tdir}")"
    tname="${tname#container-}"
    compose="${tdir}/.devcontainer/docker-compose.yaml"
    printf -- '--- target %s\n' "${tname}"
    if [[ -f "${compose}" ]]; then
      printf '    service      : %s\n' "$(grep -m1 -E '^  [A-Za-z0-9_.-]+:' "${compose}" | tr -d ' :')"
      printf '    image        : %s\n' "$(grep -m1 -E '^\s*image:' "${compose}" | sed 's/.*image:[[:space:]]*//')"
      printf '    USER_UID arg : %s\n' "$(grep -m1 -E 'USER_UID=' "${compose}" | sed 's/.*USER_UID=//')"
      printf '    network_mode : %s\n' "$(grep -m1 -E '^\s*network_mode:' "${compose}" | sed 's/.*network_mode:[[:space:]]*//')"
      printf '    restart      : %s\n' "$(grep -m1 -E '^\s*restart:' "${compose}" | sed 's/.*restart:[[:space:]]*//' || echo none)"
      printf '    ws volume    : %s\n' \
        "$(grep -m1 -E "^[[:space:]]*-[[:space:]].*:${WORKSPACE_MOUNT}[[:space:]]*$" "${compose}" |
          sed 's/^[[:space:]]*-[[:space:]]*//' || echo MISSING)"
    else
      printf '    NO COMPOSE FILE at %s\n' "${compose}"
    fi
    printf '    image present: %s\n' \
      "$(docker image inspect "$(grep -m1 -E '^\s*image:' "${compose}" 2>/dev/null | sed 's/.*image:[[:space:]]*//')" \
        --format '{{.Id}}' 2>/dev/null || echo no)"
    printf '    dockerfile   : %s\n' "$([[ -f "${tdir}/Dockerfile" ]] && echo yes || echo MISSING)"
    printf '    units in it  : %s\n' \
      "$(grep -oE '^# [A-Za-z0-9_.-]+ START #$' "${tdir}/Dockerfile" 2>/dev/null |
        sed 's/^# //; s/ START #$//' | grep -v '^IMAGE$' | tr '\n' ',' | sed 's/,$//')"
  done

  # --------------------------------------------------------------------------
  section "5. RUNNING CONTAINERS (full resolution material)"
  local t0 t1 ids
  t0="$(now_ms)"
  ids="$(docker ps -q 2>/dev/null)"
  t1="$(now_ms)"
  kv "docker ps -q" "$((t1 - t0)) ms"
  if [[ -z "${ids}" ]]; then
    note "no running containers"
  else
    t0="$(now_ms)"
    # shellcheck disable=SC2086
    docker inspect ${ids} --format '
--- container {{.Name}}
    id           : {{slice .Id 0 12}}
    image        : {{.Config.Image}}
    state        : {{.State.Status}}
    config user  : {{.Config.User}}
    labels       : compose.project={{index .Config.Labels "com.docker.compose.project"}} compose.service={{index .Config.Labels "com.docker.compose.service"}}
    dc labels    : local_folder={{index .Config.Labels "devcontainer.local_folder"}} config_file={{index .Config.Labels "devcontainer.config_file"}}
    workdir      : {{.Config.WorkingDir}}
    mounts       :{{range .Mounts}}
                   {{.Type}} {{.Source}} => {{.Destination}} ({{.Mode}}){{end}}' 2>&1
    t1="$(now_ms)"
    kv "docker inspect (all)" "$((t1 - t0)) ms"
  fi

  # --------------------------------------------------------------------------
  section "6. RESOLUTION EXPERIMENT"
  # Strategy A: bind-mount match against repo root
  local cid=""
  for id in ${ids}; do
    local src
    src="$(docker inspect "${id}" \
      --format "{{range .Mounts}}{{if eq .Destination \"${WORKSPACE_MOUNT}\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)"
    if [[ -n "${src}" ]]; then
      printf '    candidate %-14s ws-source=%s\n' "$(docker inspect "${id}" --format '{{slice .Id 0 12}}')" "${src}"
      if [[ "${src}" == "${REPO_ROOT}" ]]; then
        cid="${id}"
      fi
    fi
  done
  kv "A: mount match" "${cid:+FOUND }${cid:-NOT FOUND}"
  # Strategy B: image tag match
  local imgs=""
  for tdir in "${REPO_ROOT}"/docker/container-*; do
    [[ -d "${tdir}" ]] || continue
    imgs+="$(grep -m1 -E '^\s*image:' "${tdir}/.devcontainer/docker-compose.yaml" 2>/dev/null |
      sed 's/.*image:[[:space:]]*//') "
  done
  for im in ${imgs}; do
    printf '    image %-30s running: %s\n' "${im}" \
      "$(docker ps -q --filter "ancestor=${im}" 2>/dev/null | tr '\n' ' ')"
  done
  # Strategy C: name substring (the dexecn strategy)
  local hint
  hint="$(basename "${REPO_ROOT}")"
  kv "C: name hint" "${hint}"
  kv "C: docker ps -f name" "$(docker ps -q -f "name=${hint}" 2>/dev/null | tr '\n' ' ')"
  kv "C: match count" "$(docker ps -q -f "name=${hint}" 2>/dev/null | wc -l | tr -d ' ')"

  if [[ -z "${cid}" ]]; then
    note "no container bound to this repo root: skipping sections 7-8"
    note "start one (VS Code, or docker compose up -d) and re-run to complete the probe"
    return 0
  fi
  CID="${cid}"
  kv "resolved container" "$(docker inspect "${CID}" --format '{{.Name}} ({{slice .Id 0 12}})')"

  # --------------------------------------------------------------------------
  section "7. UID / OWNERSHIP MAPPING"
  run "container: id neo" -- docker exec -i -u neo "${CID}" id
  run "container: /etc/dua/target" -- docker exec -i -u neo "${CID}" cat /etc/dua/target
  run "container: default exec user" -- docker exec -i "${CID}" id -un
  kv "host uid" "$(id -u)"
  local cuid
  cuid="$(docker exec -i -u neo "${CID}" id -u 2>/dev/null)"
  kv "container neo uid" "${cuid:-unknown}"
  if [[ "${cuid}" == "$(id -u)" ]]; then
    kv "UID MATCH" "yes"
  else
    kv "UID MATCH" "NO -- files written in-container will be owned by ${cuid} on the host"
  fi
  # Practical write test, inside logs/ which is gitignored in every DUA repo.
  local probe_rel="logs/.dua-cc-probe-$$"
  if [[ -d "${REPO_ROOT}/logs" ]]; then
    docker exec -i -u neo "${CID}" \
      sh -c "echo probe > ${WORKSPACE_MOUNT}/${probe_rel}" 2>/dev/null
    if [[ -f "${REPO_ROOT}/${probe_rel}" ]]; then
      kv "write test" "OK, visible on host"
      kv "  host stat" "$(stat -c '%u:%g %A' "${REPO_ROOT}/${probe_rel}" 2>/dev/null)"
      kv "  host writable" "$([[ -w "${REPO_ROOT}/${probe_rel}" ]] && echo yes || echo NO)"
      rm -f "${REPO_ROOT}/${probe_rel}" 2>/dev/null ||
        docker exec -i -u neo "${CID}" rm -f "${WORKSPACE_MOUNT}/${probe_rel}" 2>/dev/null
      kv "  cleaned up" "$([[ -f "${REPO_ROOT}/${probe_rel}" ]] && echo NO || echo yes)"
    else
      kv "write test" "FAILED (not visible on host -- mount mismatch?)"
    fi
  else
    kv "write test" "skipped, no logs/ dir"
  fi

  # --------------------------------------------------------------------------
  section "8. SHELL SEMANTICS INSIDE THE CONTAINER"
  local payload
  payload='
printf "ROS_DISTRO=%s\n"        "${ROS_DISTRO:-<unset>}"
printf "RMW=%s\n"               "${RMW_IMPLEMENTATION:-<unset>}"
printf "ROS_DOMAIN_ID=%s\n"     "${ROS_DOMAIN_ID:-<unset>}"
printf "VIRTUAL_ENV=%s\n"       "${VIRTUAL_ENV:-<unset>}"
printf "AMENT_PREFIX_PATH=%s\n" "${AMENT_PREFIX_PATH:0:70}"
printf "which_colcon=%s\n"      "$(command -v colcon || echo none)"
printf "which_ros2=%s\n"        "$(command -v ros2 || echo none)"
printf "which_python=%s\n"      "$(command -v python3 || echo none)"
printf "alias_cbuild=%s\n"      "$(alias cbuild 2>/dev/null | head -c 30 || echo none)"
printf "func_ros2init=%s\n"     "$(type -t ros2init 2>/dev/null || echo none)"
printf "func_dua_subtree=%s\n"  "$(type -t dua-subtree 2>/dev/null || echo none)"
printf "func_ros2bag=%s\n"      "$(type -t ros2bag 2>/dev/null || echo none)"
printf "pwd=%s\n"               "$(pwd)"
'
  run "bash -c   (plain)" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}" "${CID}" bash -c "${payload}"
  run "bash -lc  (login)" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}" "${CID}" bash -lc "${payload}"
  run "bash -ic  (interactive)" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}" "${CID}" bash -ic "${payload}"
  run "zsh -ic   (human baseline)" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}" "${CID}" zsh -ic "${payload}"

  section "8b. EXEC BEHAVIOUR DETAILS"
  run "exit code propagation" -- docker exec -i -u neo "${CID}" bash -ic 'exit 42'
  run "stderr noise, isolated" -- docker exec -i -u neo "${CID}" bash -ic 'true'
  run "history expansion hazard" -- docker exec -i -u neo "${CID}" bash -ic 'echo "a!b" ; echo c !d'
  run "quoting / substitution" -- docker exec -i -u neo "${CID}" bash -ic 'x=$(echo ok); echo "[$x]"; echo "spaces are fine"'
  run "TERM / colour check" -- docker exec -i -u neo -e TERM=dumb "${CID}" bash -ic 'echo "TERM=$TERM"; colcon --help 2>&1 | head -3 | cat -v'
  run "cwd mapping (subdir)" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}/src" "${CID}" bash -ic 'pwd; ls -1 | head -5'
  run "timeout wrapper" -- docker exec -i -u neo "${CID}" bash -ic 'timeout 2s sleep 10; echo "rc=$?"'
  run "colcon visible" -- docker exec -i -u neo -w "${WORKSPACE_MOUNT}" "${CID}" bash -ic 'colcon --version 2>&1 | head -2'
  run "ros2 daemon status" -- docker exec -i -u neo "${CID}" bash -ic 'ros2 daemon status 2>&1 | head -3'

  section "8c. LATENCY (3 runs each)"
  local mode
  for mode in "-c" "-ic"; do
    local total=0 k
    # shellcheck disable=SC2034
    for k in 1 2 3; do
      t0="$(now_ms)"
      docker exec -i -u neo "${CID}" bash "${mode}" 'true' >/dev/null 2>&1
      t1="$(now_ms)"
      total=$((total + t1 - t0))
    done
    kv "bash ${mode} avg" "$((total / 3)) ms"
  done

  section "9. WORKSPACE STATE"
  run "build artifacts" -- bash -c "ls -ld '${REPO_ROOT}'/{build,install,log} 2>&1 | head -5"
  run "compile_commands" -- bash -c "ls -l '${REPO_ROOT}/build/compile_commands.json' 2>&1"
}

# ----------------------------------------------------------------------------

{
  echo "dua-claude Phase 0 probe report"
  main_report
  echo
  echo "===== END OF REPORT ====="
} 2>&1 | {
  if [[ "${REDACT}" == "1" ]]; then
    sed -e "s#${HOME}#~#g" \
      -e "s/$(id -un)/USER/g" \
      -e "s/$(hostname)/HOST/g"
  else
    cat
  fi
} | tee "${REPORT}"

echo
echo "Report saved to: ${REPORT}"
