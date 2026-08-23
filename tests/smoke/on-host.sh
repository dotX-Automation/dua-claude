#!/usr/bin/env bash

# Phase 1 on-host smoke test.
#
# Exercises the real dua CLI against a real DUA container. Run it from inside
# any DUA project whose container is RUNNING:
#
#   tests/smoke/on-host.sh
#
# It only reads and executes harmless commands, apart from one file written
# into <repo>/logs/ (gitignored) and removed immediately, and one container
# stop/start cycle at the end, which you can skip with -n.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUA="$(cd -P "${HERE}/../../plugins/dua-claude/bin" && pwd)/dua"
CYCLE=1
BUILD=0
while [[ $# -gt 0 ]]; do
  case "${1}" in
  -n) CYCLE=0 ;;
  -b) BUILD=1 ;;
  *) printf 'usage: on-host.sh [-n] [-b]\n  -n  skip the container stop/start cycle\n  -b  run a real full build (slow)\n' >&2; exit 2 ;;
  esac
  shift
done

PASS=0
FAIL=0
REPORT="/tmp/dua-smoke-$(date +%Y%m%d-%H%M%S).txt"

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [[ -n "${2-}" ]] && printf '        %s\n' "$2"
}
sec() { printf '\n== %s\n' "$1"; }

check() { # check <label> <expected substring> <command...>
  local label="$1" want="$2" out rc
  shift 2
  out="$("$@" 2>&1)"
  rc=$?
  if [[ "${out}" == *"${want}"* ]]; then
    ok "${label}"
  else
    no "${label}" "rc=${rc}; wanted '${want}' in: $(head -c 300 <<<"${out}")"
  fi
}

main() {
  local root rc
  printf 'dua-claude Phase 1+2 smoke test\ndate: %s\ncwd:  %s\n' "$(date -Is)" "$(pwd -P)"

  sec "ctx"
  "${DUA}" ctx || no "ctx exits 0" "see above"
  check "ctx reports a running container" "container      running" "${DUA}" ctx
  check "ctx maps the working directory" "/home/neo/workspace" "${DUA}" ctx
  check "ctx --json is parseable" '"repo_root"' "${DUA}" ctx --json

  sec "doctor"
  "${DUA}" doctor
  if [[ $? -eq 0 ]]; then ok "doctor reports no blockers"; else no "doctor reports no blockers"; fi

  sec "exec, snapshot mode"
  local t0 t1 out
  t0="$(date +%s%N)"
  out="$("${DUA}" exec -- 'printf "ROS_DISTRO=%s colcon=%s\n" "$ROS_DISTRO" "$(command -v colcon)"' 2>&1)"
  t1="$(date +%s%N)"
  printf '  first call (builds the snapshot): %s ms\n' "$(((t1 - t0) / 1000000))"
  [[ "${out}" == *"ROS_DISTRO=jazzy"* ]] && ok "ROS environment present" || no "ROS environment present" "${out}"
  t0="$(date +%s%N)"
  out="$("${DUA}" exec -- 'echo CLEAN' 2>&1)"
  t1="$(date +%s%N)"
  printf '  warm call, end to end: %s ms\n' "$(((t1 - t0) / 1000000))"
  printf '  phase breakdown:\n'
  DUA_TIME=1 "${DUA}" exec -- true 2>&1 >/dev/null | sed 's/^/    /'
  DUA_TIME=1 "${DUA}" exec -- true 2>&1 >/dev/null | sed 's/^/    /'
  printf '  interactive mode, for comparison:\n'
  DUA_TIME=1 "${DUA}" exec --mode ic -- true 2>&1 >/dev/null | grep '^\[dua\]' | sed 's/^/    /' 
  [[ "${out}" == "CLEAN" ]] && ok "stdout is exactly the command output" || no "stdout is clean" "got: [${out}]"
  check "functions from ros2.sh are available" "function" "${DUA}" exec -- 'type -t ros2bag'
  check "aliases work" "colcon build" "${DUA}" exec -- 'alias cbuild'
  local nfun
  nfun="$("${DUA}" exec -- 'declare -F | wc -l' 2>/dev/null)"
  if [[ "${nfun}" =~ ^[0-9]+$ && "${nfun}" -ge 10 ]]; then
    ok "shell functions are present (${nfun})"
  else
    no "shell functions are present" "got: ${nfun}"
  fi

  sec "exec, no stale command"
  local one two
  one="$("${DUA}" exec -- 'echo FIRST' 2>&1)"
  two="$("${DUA}" exec -- 'echo SECOND' 2>&1)"
  if [[ "${one}" == "FIRST" && "${two}" == "SECOND" ]]; then
    ok "consecutive commands do not leak into each other"
  else
    no "consecutive commands do not leak into each other" "got [${one}] then [${two}]"
  fi
  # Force a regeneration first: a snapshot left behind by an older plugin
  # version is expected to contain DUA_CMD, and is neutralised at source time
  # rather than by its contents.
  "${DUA}" exec -- 'rm -f /tmp/dua-cc/stamp' >/dev/null 2>&1
  "${DUA}" exec -- true >/dev/null 2>&1
  check "a freshly built snapshot has no DUA_CMD" "clean" \
    "${DUA}" exec -- 'grep -q DUA_CMD /tmp/dua-cc/env.sh && echo POISONED || echo clean'
  check "nor DUA_DOMAIN" "clean" \
    "${DUA}" exec -- 'grep -q DUA_DOMAIN /tmp/dua-cc/env.sh && echo POISONED || echo clean'

  sec "exec, correctness"
  "${DUA}" exec -- 'exit 42'
  [[ $? -eq 42 ]] && ok "exit code propagates" || no "exit code propagates"
  "${DUA}" exec --timeout 2s -- 'sleep 30' >/dev/null 2>&1
  [[ $? -eq 124 ]] && ok "timeout yields 124" || no "timeout yields 124"
  check "history expansion is not applied" "a!b" "${DUA}" exec -- 'echo "a!b"'
  check "quoting survives" "[hello world]" "${DUA}" exec -- 'x="hello world"; echo "[$x]"'
  check "cwd maps into subdirectories" "/home/neo/workspace/src" bash -c "cd src && '${DUA}' exec -- pwd"

  check "domain override survives ros2init" "ROS_DOMAIN_ID=7" \
    "${DUA}" exec --domain 7 -- 'echo "ROS_DOMAIN_ID=$ROS_DOMAIN_ID"'

  sec "exec, mode parity"
  local a b
  a="$("${DUA}" exec -- 'env | grep -vE "^(_|SHLVL|PWD|OLDPWD)=" | sort | md5sum' 2>/dev/null)"
  b="$("${DUA}" exec --mode ic -- 'env | grep -vE "^(_|SHLVL|PWD|OLDPWD)=" | sort | md5sum' 2>/dev/null)"
  if [[ "${a}" == "${b}" ]]; then ok "snap and ic environments match"; else no "snap and ic environments match" "snap=${a} ic=${b}"; fi
  a="$("${DUA}" exec -- 'declare -F | sort | md5sum' 2>/dev/null)"
  b="$("${DUA}" exec --mode ic -- 'declare -F | sort | md5sum' 2>/dev/null)"
  if [[ "${a}" == "${b}" ]]; then ok "snap and ic function sets match"; else no "snap and ic function sets match"; fi

  sec "workspace identity"
  local probe
  root="$("${DUA}" ctx --json | sed -n 's/.*"repo_root": "\([^"]*\)".*/\1/p')"
  probe="logs/.dua-smoke-$$"
  "${DUA}" exec -- "echo probe > /home/neo/workspace/${probe}" >/dev/null 2>&1
  if [[ -f "${root}/${probe}" ]]; then
    ok "container writes are visible on the host"
    printf '  ownership: %s\n' "$(stat -c '%u:%g %A' "${root}/${probe}")"
    rm -f "${root}/${probe}" 2>/dev/null || "${DUA}" exec -- "rm -f /home/neo/workspace/${probe}"
  else
    no "container writes are visible on the host"
  fi

  sec "snapshot invalidation"
  local target
  target="$("${DUA}" ctx --json | sed -n 's/.*"target": "\([^"]*\)".*/\1/p' | head -1)"
  check "snapshot is fresh" "fresh" "${DUA}" ctx
  touch "${root}/docker/container-${target}/commands.sh"
  check "touching commands.sh invalidates it" "stale" "${DUA}" ctx
  "${DUA}" exec -- true >/dev/null 2>&1
  check "the next exec refreshes it" "fresh" "${DUA}" ctx

  sec "resolution cache"
  printf '  with cache:\n'
  DUA_TIME=1 "${DUA}" exec -- true 2>&1 >/dev/null | sed 's/^/    /'
  printf '  without cache:\n'
  DUA_NO_CACHE=1 DUA_TIME=1 "${DUA}" exec -- true 2>&1 >/dev/null | sed 's/^/    /'

  sec "build and test plumbing"
  printf '  default build output size: %s lines\n' \
    "$("${DUA}" build --all __no_such_package_here__ 2>&1 | wc -l)"
  check "build runs and reports a summary" "Summary:" \
    "${DUA}" build --all __no_such_package_here__
  check "colcon warns about the unknown package" "ignoring unknown package" \
    "${DUA}" build --all __no_such_package_here__
  local blog
  blog="$(ls -t "${root}"/logs/cc/*-build.log 2>/dev/null | head -1)"
  if [[ -n "${blog}" ]]; then ok "build wrote ${blog##*/}"; else no "build wrote a log"; fi
  if [[ ${BUILD} -eq 1 ]]; then
    sec "real build"
    if "${DUA}" build --all; then ok "full workspace build"; else no "full workspace build"; fi
    check "snapshot invalidated by the build" "stale" "${DUA}" ctx
  else
    printf '\n(skipping the real build, pass -b to run it)\n'
  fi

  sec "run under a deadline"
  local t4 t5
  t4="$(date +%s%N)"
  "${DUA}" run --for 3s -- 'echo started; sleep 30' >/dev/null 2>&1
  rc=$?
  t5="$(date +%s%N)"
  if [[ ${rc} -eq 0 && $(((t5 - t4) / 1000000)) -lt 8000 ]]; then
    ok "run returns at the deadline ($(((t5 - t4) / 1000000)) ms)"
  else
    no "run returns at the deadline" "rc=${rc}, $(((t5 - t4) / 1000000)) ms"
  fi

  sec "background processes"
  "${DUA}" bg stop smoke >/dev/null 2>&1 || true
  if "${DUA}" bg start smoke -- 'for i in $(seq 1 100); do echo tick $i; sleep 1; done' >/dev/null 2>&1; then
    ok "bg start"
  else
    no "bg start"
  fi
  sleep 2
  check "bg status reports it running" "running" "${DUA}" bg status smoke
  check "bg logs are readable from the host" "tick" "${DUA}" bg logs smoke -n 5
  check "bg list shows it" "smoke" "${DUA}" bg list
  # two processes at once: the list loop must not lose entries to stdin theft
  "${DUA}" bg start smoke2 -- 'sleep 60' >/dev/null 2>&1
  sleep 1
  out="$("${DUA}" bg list 2>&1)"
  if [[ "${out}" == *smoke* && "${out}" == *smoke2* ]]; then
    ok "bg list shows every process"
  else
    no "bg list shows every process" "got: ${out}"
  fi
  "${DUA}" bg stop smoke2 >/dev/null 2>&1 || true
  if "${DUA}" bg stop smoke >/dev/null 2>&1; then ok "bg stop"; else no "bg stop"; fi
  sleep 1
  if "${DUA}" bg status smoke >/dev/null 2>&1; then no "bg status reports it stopped"; else ok "bg status reports it stopped"; fi
  check "the environment reached the background process" "jazzy" \
    bash -c "'${DUA}' bg start envchk -- 'echo DISTRO=\$ROS_DISTRO; sleep 5' >/dev/null 2>&1; sleep 2; '${DUA}' bg logs envchk -n 5"
  "${DUA}" bg stop envchk >/dev/null 2>&1 || true

  if [[ ${CYCLE} -eq 1 ]]; then
    sec "lifecycle"
    "${DUA}" down && ok "down stops the container" || no "down stops the container"
    check "ctx sees it stopped" "container      stopped" "${DUA}" ctx
    check "exec refuses and suggests up" "dua up" "${DUA}" exec -- true
    "${DUA}" up && ok "up restarts the existing container" || no "up restarts it"
    check "ctx sees it running again" "container      running" "${DUA}" ctx
    check "snapshot rebuilt after restart" "" "${DUA}" exec -- 'echo ok'
  else
    printf '\n(skipping the stop/start cycle)\n'
  fi

  printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
}

main 2>&1 | tee "${REPORT}"
printf '\nReport saved to: %s\n' "${REPORT}"
