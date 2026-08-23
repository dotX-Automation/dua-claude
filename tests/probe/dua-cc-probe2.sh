#!/usr/bin/env bash

# dua-claude micro-probe #2: sudo-hint suppression and env-snapshot viability.
#
# Run from inside any DUA project/unit directory whose container is RUNNING.
#   ./dua-cc-probe2.sh            # resolve container from the current repo
#   ./dua-cc-probe2.sh -c CID     # or force a container id/name
#
# Side effects, all inside the container only, all reverted or benign:
#   - removes and re-creates /home/neo/.sudo_as_admin_successful
#   - writes /tmp/dua-snap*.sh inside the container
# Nothing is written to the host repo.

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

set -uo pipefail

WS="/home/neo/workspace"
CID=""
REPORT="/tmp/dua-cc-probe2-$(date +%Y%m%d-%H%M%S).txt"

while getopts ":c:h" opt; do
  case "${opt}" in
  c) CID="${OPTARG}" ;;
  h)
    echo >&2 "Usage: dua-cc-probe2.sh [-c CONTAINER]"
    exit 0
    ;;
  *)
    echo >&2 "Usage: dua-cc-probe2.sh [-c CONTAINER]"
    exit 1
    ;;
  esac
done

section() { printf '\n===== %s =====\n' "$1"; }
kv() { printf '%-30s %s\n' "$1:" "${2:-}"; }

now_ms() {
  local n
  n="$(date +%s%N 2>/dev/null)"
  if [[ "${n}" == *N* || -z "${n}" ]]; then echo $(($(date +%s) * 1000)); else echo $((n / 1000000)); fi
}

dex() { docker exec -i -u neo "${CID}" "$@"; }

main() {
  section "0. CONTEXT"
  if [[ -z "${CID}" ]]; then
    local d root=""
    d="$(pwd -P)"
    while :; do
      [[ -d "${d}/docker" && -f "${d}/bin/dua_setup.sh" ]] && {
        root="${d}"
        break
      }
      [[ "${d}" == "/" ]] && break
      d="$(dirname "${d}")"
    done
    if [[ -z "${root}" ]]; then
      echo "ERROR: not inside a DUA repo, use -c CONTAINER"
      return 1
    fi
    kv "repo root" "${root}"
    local id src
    for id in $(docker ps -q); do
      src="$(docker inspect "${id}" \
        --format "{{range .Mounts}}{{if eq .Destination \"${WS}\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)"
      [[ "${src}" == "${root}" ]] && CID="${id}"
    done
  fi
  if [[ -z "${CID}" ]]; then
    echo "ERROR: no running container bound to this repo"
    return 1
  fi
  kv "container" "$(docker inspect "${CID}" --format '{{.Name}} ({{slice .Id 0 12}})')"
  kv "target" "$(dex cat /etc/dua/target 2>/dev/null)"
  kv "host uid/gid" "$(id -u)/$(id -g)"
  kv "neo uid/gid" "$(dex id -u 2>/dev/null)/$(dex id -g 2>/dev/null)"

  # ---------------------------------------------------------------------------
  section "1. SUDO HINT: BEFORE / AFTER"
  dex rm -f /home/neo/.sudo_as_admin_successful /home/neo/.hushlogin
  printf -- '--- without the marker file (stdout only)\n'
  dex bash -ic 'echo MARKER' 2>/dev/null | sed 's/^/    | /'
  dex touch /home/neo/.sudo_as_admin_successful
  printf -- '--- with the marker file (stdout only)\n'
  dex bash -ic 'echo MARKER' 2>/dev/null | sed 's/^/    | /'
  printf -- '--- stderr of one -ic call\n'
  dex bash -ic 'echo MARKER' 2>&1 >/dev/null | sed 's/^/    | /'
  printf -- '--- other stdout noise sources in the image\n'
  dex bash -c 'grep -rlsE "(echo|cat|printf) " /etc/bash.bashrc /etc/profile.d/ 2>/dev/null | head -10' |
    sed 's/^/    | /'

  # ---------------------------------------------------------------------------
  section "2. ENV SNAPSHOT (export -p + declare -f + alias -p)"
  dex bash -c \
    'bash -ic "export -p; declare -f; alias -p" 2>/dev/null > /tmp/dua-snap-raw.sh; wc -lc < /tmp/dua-snap-raw.sh' |
    sed 's/^/    raw lines,bytes | /'
  dex bash -c \
    'grep -vE "^declare -x (PWD|OLDPWD|SHLVL|_)(=|$)" /tmp/dua-snap-raw.sh > /tmp/dua-snap.sh; wc -lc < /tmp/dua-snap.sh' |
    sed 's/^/    filtered      | /'

  printf -- '--- errors raised while sourcing the snapshot (empty is the goal)\n'
  dex bash -c 'source /tmp/dua-snap.sh 2>&1 >/dev/null | sort | uniq -c | head -20' | sed 's/^/    | /'

  printf -- '--- environment restored by the snapshot\n'
  dex bash -c 'shopt -s expand_aliases; source /tmp/dua-snap.sh 2>/dev/null
    printf "ROS_DISTRO=%s\n" "${ROS_DISTRO:-<unset>}"
    printf "AMENT=%s\n" "${AMENT_PREFIX_PATH:0:60}"
    printf "VIRTUAL_ENV=%s\n" "${VIRTUAL_ENV:-<unset>}"
    printf "which_ros2=%s\n" "$(command -v ros2 || echo none)"
    printf "which_colcon=%s\n" "$(command -v colcon || echo none)"
    printf "fn_ros2bag=%s\n" "$(type -t ros2bag || echo none)"
    printf "fn_dua_subtree=%s\n" "$(type -t dua-subtree || echo none)"
    printf "alias_cbuild=%s\n" "$(alias cbuild 2>/dev/null | head -c 25 || echo none)"
    printf "pwd=%s\n" "$(pwd)"' | sed 's/^/    | /'

  printf -- '--- env parity: interactive vs snapshot (differences only)\n'
  local a b
  a="$(mktemp)"
  b="$(mktemp)"
  dex bash -ic 'env' 2>/dev/null | grep -vE '^(_|SHLVL|PWD|OLDPWD|BASH_EXECUTION_STRING)=' | sort >"${a}"
  dex bash -c 'source /tmp/dua-snap.sh 2>/dev/null; env' | grep -vE '^(_|SHLVL|PWD|OLDPWD|BASH_EXECUTION_STRING)=' | sort >"${b}"
  if diff -q "${a}" "${b}" >/dev/null; then
    printf '    | IDENTICAL (%s vars)\n' "$(wc -l <"${a}")"
  else
    diff "${a}" "${b}" | cut -c1-160 | head -30 | sed 's/^/    | /'
  fi
  rm -f "${a}" "${b}"

  printf -- '--- function parity: interactive vs snapshot\n'
  dex bash -ic 'declare -F | awk "{print \$3}" | sort' 2>/dev/null >"${a:=$(mktemp)}"
  dex bash -c 'source /tmp/dua-snap.sh 2>/dev/null; declare -F | awk "{print \$3}" | sort' >"${b:=$(mktemp)}"
  if diff -q "${a}" "${b}" >/dev/null; then
    printf '    | IDENTICAL (%s functions)\n' "$(wc -l <"${a}")"
  else
    diff "${a}" "${b}" | head -20 | sed 's/^/    | /'
  fi
  rm -f "${a}" "${b}"

  # ---------------------------------------------------------------------------
  section "3. LATENCY (5 runs each)"
  local mode total k t0 t1
  for mode in ic snap plain; do
    total=0
    # shellcheck disable=SC2034
    for k in 1 2 3 4 5; do
      t0="$(now_ms)"
      case "${mode}" in
      ic) dex bash -ic 'true' >/dev/null 2>&1 ;;
      snap) dex bash -c 'source /tmp/dua-snap.sh 2>/dev/null; true' >/dev/null 2>&1 ;;
      plain) dex bash -c 'true' >/dev/null 2>&1 ;;
      esac
      t1="$(now_ms)"
      total=$((total + t1 - t0))
    done
    kv "bash ${mode} avg" "$((total / 5)) ms"
  done

  # ---------------------------------------------------------------------------
  section "4. SNAPSHOT INVALIDATION INPUTS"
  kv "container id" "$(docker inspect "${CID}" --format '{{slice .Id 0 12}}')"
  kv "container started at" "$(docker inspect "${CID}" --format '{{.State.StartedAt}}')"
  printf -- '--- mtimes of the mounted config files (host side)\n'
  docker inspect "${CID}" --format '{{range .Mounts}}{{.Source}}
{{end}}' |
    grep -E '/(aliases|commands|ros2|bashrc|dua_submod|dua_subtree)\.?(sh)?$' |
    while read -r f; do
      [[ -f "${f}" ]] && printf '    | %s  %s\n' "$(stat -c '%Y' "${f}")" "${f##*/}"
    done
}

{
  echo "dua-claude micro-probe #2"
  main
  echo
  echo "===== END ====="
} 2>&1 | tee "${REPORT}"

echo
echo "Report saved to: ${REPORT}"
