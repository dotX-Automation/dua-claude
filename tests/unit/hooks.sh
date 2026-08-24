#!/usr/bin/env bash

# Offline tests for the hooks and the slash commands.
#
# Hooks are ordinary programs with a JSON contract on stdin and stdout, so they
# can be tested without Claude: feed a synthetic event, assert on the decision.
#
# Usage: tests/unit/hooks.sh
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "${HERE}/../.." && pwd)"
PLUGIN="${ROOT}/plugins/dua-claude"
GUARD="${PLUGIN}/scripts/guard-host-exec.sh"
SESSION="${PLUGIN}/scripts/session-start.sh"
STUB_DIR="${ROOT}/tests/stub"

# shellcheck source=../fixtures/fixtures.sh
source "${ROOT}/tests/fixtures/fixtures.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [[ -n "${2-}" ]] && printf '       %s\n' "${2}"
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --------------------------------------------------------------------------
section "registration"

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${PLUGIN}/hooks/hooks.json"; then
  ok "hooks.json is valid JSON"
else
  no "hooks.json is valid JSON"
fi

events="$(python3 -c '
import json
d = json.load(open("'"${PLUGIN}"'/hooks/hooks.json"))["hooks"]
print(" ".join(sorted(d)))')"
[[ "${events}" == *"SessionStart"* ]] && ok "registers SessionStart" || no "registers SessionStart"
[[ "${events}" == *"PreToolUse"* ]] && ok "registers PreToolUse" || no "registers PreToolUse"

matcher="$(python3 -c '
import json
d = json.load(open("'"${PLUGIN}"'/hooks/hooks.json"))["hooks"]
print(d["PreToolUse"][0].get("matcher", ""))')"
[[ "${matcher}" == "Bash" ]] && ok "the guard matches Bash only" || no "the guard matches Bash only" "${matcher}"

while read -r cmd; do
  [[ -z "${cmd}" ]] && continue
  if [[ "${cmd}" != '${CLAUDE_PLUGIN_ROOT}'* ]]; then
    no "hook command is plugin relative" "${cmd}"
    continue
  fi
  path="${PLUGIN}${cmd#'${CLAUDE_PLUGIN_ROOT}'}"
  if [[ -x "${path}" ]]; then
    ok "$(basename "${path}") exists and is executable"
  else
    no "$(basename "${path}") exists and is executable" "${path}"
  fi
done < <(python3 -c '
import json
d = json.load(open("'"${PLUGIN}"'/hooks/hooks.json"))["hooks"]
for ev in d.values():
    for group in ev:
        for h in group["hooks"]:
            print(h["command"])')

# --------------------------------------------------------------------------
section "guard: commands that belong in the container"

PROJECT="${TMP}/guarded"
make_repo "${PROJECT}" guarded x86-cudev
OUTSIDE="${TMP}/plain"
mkdir -p "${OUTSIDE}"

# guard <cwd> <command> -> DECISION on stdout
guard() {
  local cwd="${1}" cmd="${2}" out
  out="$(python3 -c '
import json, sys
print(json.dumps({"session_id": "t", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' \
    "${cwd}" "${cmd}" | "${GUARD}" 2>&1)"
  if [[ -z "${out}" ]]; then
    printf 'allow'
    return
  fi
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw)["hookSpecificOutput"]["permissionDecision"])
except Exception:
    print("unparseable: " + raw[:80])' <<<"${out}"
}

denies() {
  local got
  got="$(guard "${PROJECT}" "${1}")"
  if [[ "${got}" == "deny" ]]; then ok "denies: ${1}"; else no "denies: ${1}" "got ${got}"; fi
}
allows() {
  local got
  got="$(guard "${PROJECT}" "${1}")"
  if [[ "${got}" == "allow" ]]; then ok "allows: ${1}"; else no "allows: ${1}" "got ${got}"; fi
}

denies 'colcon build'
denies 'colcon build --packages-select my_pkg'
denies 'ros2 topic list'
denies 'ros2 launch my_pkg bringup.launch.py'
denies 'ament_uncrustify --reformat src/my_pkg'
denies 'rosdep install --from-paths src'
denies 'cd src && colcon build'
denies 'cd src; colcon test'
denies 'RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ros2 topic list'
denies '/opt/ros/jazzy/bin/ros2 node list'
denies 'ls && ros2 topic list'
denies 'rviz2'

section "guard: commands that must not be blocked"
allows 'dua exec -- colcon build'
allows 'dua build --all'
allows 'dua bg start node -- ros2 launch my_pkg a.launch.py'
allows 'grep -rn colcon .'
allows 'echo "ros2 topic list"'
allows 'cat src/my_pkg/package.xml'
allows 'docker exec -i abc bash -c "colcon build"'
allows 'git status'
allows 'ls -la'
allows 'python3 -c "print(1)"'
allows 'find . -name "*.launch.py"'
allows 'sed -i "s/ros2/ros2/" file.txt'

section "guard: outside a DUA project nothing is blocked"
got="$(guard "${OUTSIDE}" 'colcon build')"
[[ "${got}" == "allow" ]] && ok "allows colcon build outside a DUA project" ||
  no "allows colcon build outside a DUA project" "got ${got}"

section "guard: malformed or empty input fails open"
for bad in '' 'not json at all' '{}' '{"tool_input": {}}'; do
  out="$(printf '%s' "${bad}" | "${GUARD}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 && -z "${out}" ]]; then
    ok "fails open on: ${bad:-<empty>}"
  else
    no "fails open on: ${bad:-<empty>}" "rc=${rc} out=${out}"
  fi
done

section "guard: the denial explains the fix"
reason="$(python3 -c '
import json
print(json.dumps({"cwd": "'"${PROJECT}"'", "tool_name": "Bash",
                  "tool_input": {"command": "colcon build --packages-select my_pkg"}}))' |
  "${GUARD}" | python3 -c '
import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')"
[[ "${reason}" == *"dua exec -- colcon build --packages-select my_pkg"* ]] &&
  ok "quotes the corrected command" || no "quotes the corrected command" "${reason:0:120}"
[[ "${reason}" == *"dua build"* ]] && ok "points at the dedicated command" || no "points at the dedicated command"

# --------------------------------------------------------------------------
section "session start"

fix="${TMP}/fixture"
mkdir -p "${fix}/containers"
printf '1000\n1000\n' >"${fix}/ids"
printf 'x86-cudev' >"${fix}/dua_target"
cat >"${fix}/containers/abcabcabcabc.rec" <<EOF
DUA_REC_BEGIN
ID	abcabcabcabc
NAME	/devcontainer-guarded-x86-cudev-1
IMAGE	guarded:x86-cudev
STATE	running
STARTED	2026-08-23T10:00:00Z
SERVICE	guarded-x86-cudev
PROJECT	devcontainer
DCFOLDER	<no value>
WSSRC	${PROJECT}
DUA_REC_END
EOF

session() {
  python3 -c '
import json, sys
print(json.dumps({"session_id": "t", "cwd": sys.argv[1],
                  "hook_event_name": "SessionStart", "source": "startup"}))' "${1}" |
    env PATH="${STUB_DIR}:${PATH}" DUA_STUB_FIXTURE="${fix}" \
      DUA_STUB_LOG="${fix}/calls.log" NO_COLOR=1 \
      CLAUDE_PLUGIN_DATA="${fix}/state" "${SESSION}" 2>&1
}

out="$(session "${PROJECT}")"
if python3 -c 'import json,sys; json.load(sys.stdin)' <<<"${out}"; then
  ok "emits valid JSON inside a project"
else
  no "emits valid JSON inside a project" "${out:0:160}"
fi
ctxt="$(python3 -c '
import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' <<<"${out}" 2>/dev/null || true)"
[[ "${ctxt}" == *"${PROJECT}"* ]] && ok "names the repository root" || no "names the repository root"
[[ "${ctxt}" == *"container      running"* ]] && ok "reports the container state" || no "reports the container state"
[[ "${ctxt}" == *"Edit files on the host"* ]] && ok "states the rules of engagement" || no "states the rules of engagement"
[[ "${ctxt}" == *"Ask before building an image"* ]] && ok "says to ask before a rebuild" || no "says to ask before a rebuild"
[[ ${#ctxt} -le 10000 ]] && ok "context is within the 10000 character cap (${#ctxt})" ||
  no "context is within the cap" "${#ctxt}"

out="$(session "${OUTSIDE}")"
if python3 -c 'import json,sys; json.load(sys.stdin)' <<<"${out}"; then
  ok "emits valid JSON outside a project too"
else
  no "emits valid JSON outside a project too" "${out:0:160}"
fi
ctxt="$(python3 -c '
import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' <<<"${out}" 2>/dev/null || true)"
[[ -z "${ctxt}" ]] && ok "says nothing outside a project" || no "says nothing outside a project" "${ctxt:0:80}"

# --------------------------------------------------------------------------
section "slash commands"

for f in "${PLUGIN}"/commands/*.md; do
  n="$(basename "${f}" .md)"
  if [[ "$(head -1 "${f}")" != "---" ]]; then
    no "${n}: has frontmatter"
    continue
  fi
  end="$(awk 'NR>1 && /^---$/ {print NR; exit}' "${f}")"
  if [[ -z "${end}" ]]; then
    no "${n}: frontmatter is closed"
    continue
  fi
  fm="$(sed -n "2,$((end - 1))p" "${f}")"
  if grep -q '^description:' <<<"${fm}"; then
    ok "${n}: has a description"
  else
    no "${n}: has a description"
  fi
  while read -r line; do
    [[ -z "${line}" ]] && continue
    key="${line%%:*}"
    case "${key}" in
    description | argument-hint | allowed-tools | disable-model-invocation | model | name) ;;
    *) no "${n}: unexpected frontmatter field '${key}'" ;;
    esac
  done <<<"${fm}"
  if [[ "$(wc -l <"${f}")" -gt "${end}" ]]; then
    ok "${n}: has a body"
  else
    no "${n}: has a body"
  fi
done

if [[ -f "${PLUGIN}/templates/CLAUDE.md.tmpl" ]]; then
  ok "the CLAUDE.md template exists"
else
  no "the CLAUDE.md template exists"
fi
if grep -q 'templates/CLAUDE.md.tmpl' "${PLUGIN}/commands/claude-md.md"; then
  ok "the claude-md command points at it"
else
  no "the claude-md command points at it"
fi

printf '\n\033[1m%s passed, %s failed\033[0m\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
