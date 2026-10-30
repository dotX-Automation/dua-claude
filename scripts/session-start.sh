#!/usr/bin/env bash

# SessionStart hook: put the resolved DUA context in front of Claude.
#
# Reads the hook event on stdin, emits JSON with additionalContext on stdout.
# Outside a DUA project it emits an empty context rather than nothing, so the
# session never shows a hook error notice.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

PLUGIN_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUA="${PLUGIN_ROOT}/bin/dua"

payload="$(cat 2>/dev/null || true)"

# The event carries the working directory; fall back to ours.
cwd="${PWD}"
if command -v python3 >/dev/null 2>&1 && [[ -n "${payload}" ]]; then
  parsed="$(printf '%s' "${payload}" |
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("cwd", ""))
except Exception:
    print("")' 2>/dev/null || true)"
  [[ -n "${parsed}" && -d "${parsed}" ]] && cwd="${parsed}"
fi

emit() {
  # additionalContext is capped at 10000 characters upstream; we are far below.
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${1}" | python3 -c 'import json,sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": sys.stdin.read()}}))'
  else
    # Plain stdout is injected as context for SessionStart, so this still works.
    printf '%s\n' "${1}"
  fi
  exit 0
}

# Is any ancestor a DUA project?
d="${cwd}"
root=""
while :; do
  if [[ -d "${d}/docker" && -f "${d}/bin/dua_setup.sh" ]]; then
    root="${d}"
    break
  fi
  [[ "${d}" == "/" ]] && break
  d="$(dirname "${d}")"
done
[[ -z "${root}" ]] && emit ""

ctx="$(cd "${cwd}" && timeout 15 "${DUA}" ctx 2>&1 || true)"
[[ -z "${ctx}" ]] && ctx="dua ctx produced no output; run dua doctor to find out why"

emit "This is a DUA project (Distributed Unified Architecture, dotX Automation s.r.l.). You are on the host; the toolchain and ROS 2 live in the project's container, which the dua command drives.

${ctx}

Rules of engagement:
- Edit files on the host with your normal tools. The repository root is bind-mounted in the container, so both views are the same filesystem.
- Execute through dua, never by hand: dua exec -- <command>, dua build, dua test, dua run --for <d> -- <command>, dua bg start <name> -- <command>.
- Never run colcon, ros2 or ament_* on the host, and never write your own docker exec.
- You may start, stop and restart the container if strictly necessary, most of the time the user sets this up for you, ask them if unsure. Ask before building an image: it takes long and is the user's decision, usually they do themselves.
- Read build output from logs/cc/ and log/latest_build/<pkg>/stdout_stderr.log on the host.

The dua-workspace skill has the full picture; other dua-* skills cover containers, building, running, targets and unit integration."
