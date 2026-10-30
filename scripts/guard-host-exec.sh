#!/usr/bin/env bash

# PreToolUse hook: stop ROS 2 and colcon commands from running on the host.
#
# colcon is sometimes installed on a development host without any ROS
# environment, so a stray `colcon build` does not fail cleanly: it runs, does
# the wrong thing, and wastes a debugging cycle. This hook turns that into a
# deny with the corrected command in the reason.
#
# It is deliberately narrow. Only the first word of each shell segment is
# considered, so `grep colcon`, `echo "ros2 topic list"` and `dua exec --
# colcon build` all pass. Outside a DUA project nothing is blocked at all.
# A guard that cries wolf gets switched off, and then it protects nothing.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

# Commands that only make sense inside the container.
CONTAINER_ONLY_RE='^(colcon|ros2|rosdep|rviz|rviz2|gz|ign|gazebo|ament_[a-z_]+|rqt[a-z_]*)$'

allow() { exit 0; } # defer to the normal permission flow

deny() {
  local reason="${1}"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${reason}" | python3 -c 'import json,sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "deny",
                                         "permissionDecisionReason": sys.stdin.read()}}))'
    exit 0
  fi
  # Without python3, exit 2 blocks and feeds stderr back to Claude.
  printf '%s\n' "${reason}" >&2
  exit 2
}

payload="$(cat 2>/dev/null || true)"
[[ -n "${payload}" ]] || allow

# Fail open: a guard that cannot parse its input must not block work.
command -v python3 >/dev/null 2>&1 || allow

read -r -d '' PARSE <<'PY' || true
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(d.get("cwd", ""))
print((ti.get("command") or "").replace("\n", " "))
PY

parsed="$(printf '%s' "${payload}" | python3 -c "${PARSE}" 2>/dev/null || true)"
[[ -n "${parsed}" ]] || allow
cwd="$(sed -n '1p' <<<"${parsed}")"
command_line="$(sed -n '2,$p' <<<"${parsed}")"
[[ -n "${command_line}" ]] || allow

# Only guard inside DUA projects: elsewhere these commands are the user's business.
d="${cwd:-${PWD}}"
in_project=0
while :; do
  if [[ -d "${d}/docker" && -f "${d}/bin/dua_setup.sh" ]]; then
    in_project=1
    break
  fi
  [[ "${d}" == "/" || -z "${d}" ]] && break
  d="$(dirname "${d}")"
done
[[ ${in_project} -eq 1 ]] || allow

# Split on shell separators and inspect the first real word of each segment.
segments="$(printf '%s' "${command_line}" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')"
while IFS= read -r segment; do
  # Strip leading whitespace, subshell parentheses and environment assignments.
  segment="${segment#"${segment%%[![:space:]]*}"}"
  while [[ "${segment}" == \(* || "${segment}" == '{ '* ]]; do
    segment="${segment#?}"
    segment="${segment#"${segment%%[![:space:]]*}"}"
  done
  while [[ "${segment}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
    segment="${segment#* }"
    segment="${segment#"${segment%%[![:space:]]*}"}"
  done
  first="${segment%%[[:space:]]*}"
  first="${first##*/}" # /opt/ros/jazzy/bin/ros2 counts as ros2

  [[ -z "${first}" ]] && continue
  if [[ "${first}" =~ ${CONTAINER_ONLY_RE} ]]; then
    deny "This is a DUA project: ${first} runs inside the project's container, not on the host.

Run it through the CLI instead:

    dua exec -- ${segment}

For a build or a test use the dedicated commands, which run at the workspace root and log their output: dua build, dua test. For anything long running use dua run --for <duration> -- ... or dua bg start <name> -- ..., so the session does not hang on a node that never exits.

If you really need a host shell here, say so and the user can disable this hook."
  fi
done <<<"${segments}"

allow
