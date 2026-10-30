#!/usr/bin/env bash

# Common helpers for the dua CLI.
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

# Container-side constants. These are DUA invariants, not user settings.
# shellcheck disable=SC2034  # consumed by the other library files
readonly DUA_WS="/home/neo/workspace"
readonly DUA_USER="neo"
readonly DUA_CC_DIR="/tmp/dua-cc"

# Docker binary, overridable for testing.
DUA_DOCKER="${DUA_DOCKER:-docker}"

# Colours, only when writing to a terminal.
if [[ -t 1 && -z "${NO_COLOR-}" ]]; then
  C_RED=$'\033[31m'
  C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'
  C_DIM=$'\033[2m'
  C_OFF=$'\033[0m'
else
  # shellcheck disable=SC2034
  C_RED='' C_YEL='' C_GRN='' C_DIM='' C_OFF=''
fi

err() { printf '%sERROR%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }
warn() { printf '%swarning%s %s\n' "${C_YEL}" "${C_OFF}" "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
dbg() { [[ -n "${DUA_DEBUG-}" ]] && printf '%s[dua] %s%s\n' "${C_DIM}" "$*" "${C_OFF}" >&2 || true; }

die() {
  err "$*"
  exit 1
}

# Print a hint line: something the user or Claude should do next.
hint() { printf '%s→ %s%s\n' "${C_DIM}" "$*" "${C_OFF}" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run docker, honouring DUA_DOCKER.
dk() { "${DUA_DOCKER}" "$@"; }

# Normalise the "<no value>" that Go templates emit for missing map keys.
denull() { [[ "${1-}" == "<no value>" ]] && printf '' || printf '%s' "${1-}"; }

# Minimal JSON string escaping (quotes, backslashes, control characters).
json_str() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '"%s"' "${s}"
}

# Per-repository state directory, outside any repository.
# CLAUDE_PLUGIN_DATA survives plugin updates when running as a plugin.
dua_state_dir() {
  local base="${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-${HOME}/.local/state}/dua-claude}"
  printf '%s/repos' "${base}"
}

# Stable short identifier for a repository path.
path_key() {
  local p="${1}" h=""
  if have sha1sum; then
    h="$(printf '%s' "${p}" | sha1sum | cut -c1-16)"
  elif have shasum; then
    h="$(printf '%s' "${p}" | shasum | cut -c1-16)"
  else
    h="$(printf '%s' "${p}" | cksum | tr -d ' ')"
  fi
  printf '%s-%s' "$(basename "${p}")" "${h}"
}

# Read/write a per-repository state value.
state_get() {
  local root="${1}" key="${2}" f
  f="$(dua_state_dir)/$(path_key "${root}").${key}"
  [[ -f "${f}" ]] && cat "${f}" || printf ''
}

state_set() {
  local root="${1}" key="${2}" val="${3}" d f
  d="$(dua_state_dir)"
  mkdir -p "${d}" 2>/dev/null || return 0
  f="${d}/$(path_key "${root}").${key}"
  printf '%s' "${val}" >"${f}" 2>/dev/null || true
}

# Monotonic-ish milliseconds, for timing output.
now_ms() {
  local n
  n="$(date +%s%N 2>/dev/null)"
  if [[ "${n}" == *N* || -z "${n}" ]]; then printf '%s' $(($(date +%s) * 1000)); else printf '%s' $((n / 1000000)); fi
}

# Quote a list of arguments into a single shell command line.
shquote_join() {
  local out="" a
  for a in "$@"; do
    out+="${out:+ }$(printf '%q' "${a}")"
  done
  printf '%s' "${out}"
}
