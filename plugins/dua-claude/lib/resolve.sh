#!/usr/bin/env bash

# Repository and container resolution for the dua CLI.
#
# Resolution is keyed on bind mounts, not on names: a DUA container is the one
# that mounts an ancestor of the current directory at /home/neo/workspace.
# Names and images are unreliable because VS Code Dev Containers and plain
# Compose produce different naming and image schemes for the same project.
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

# One inspect template for every container query. The test stub depends on the
# record markers, so keep DUA_REC_BEGIN/END and the field names stable.
DUA_INSPECT_FMT='DUA_REC_BEGIN
ID{{"\t"}}{{.Id}}
NAME{{"\t"}}{{.Name}}
IMAGE{{"\t"}}{{.Config.Image}}
STATE{{"\t"}}{{.State.Status}}
STARTED{{"\t"}}{{.State.StartedAt}}
SERVICE{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}
PROJECT{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}
DCFOLDER{{"\t"}}{{index .Config.Labels "devcontainer.local_folder"}}
WSSRC{{"\t"}}{{range .Mounts}}{{if eq .Destination "/home/neo/workspace"}}{{.Source}}{{end}}{{end}}
DUA_REC_END'

# Outputs of resolve_repo() and resolve_container(), consumed by bin/dua,
# lib/exec.sh and lib/compose.sh.
# shellcheck disable=SC2034

DUA_REPO_ROOT=""
DUA_ANCESTORS=()

# Outputs of resolve_container(), set as globals.
DUA_CID=""
DUA_CNAME=""
DUA_CIMAGE=""
DUA_CSTATE=""
DUA_CSTARTED=""
DUA_CSERVICE=""
DUA_CPROJECT=""
DUA_CTARGET=""
DUA_WSSRC=""
DUA_STRATEGY=""
DUA_CANDIDATES=()

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------

# A directory is a DUA root when it holds both docker/ and bin/dua_setup.sh.
is_dua_root() { [[ -d "${1}/docker" && -f "${1}/bin/dua_setup.sh" ]]; }

# Walk up from a directory, filling DUA_ANCESTORS (innermost first) and
# selecting the innermost DUA root as DUA_REPO_ROOT.
resolve_repo() {
  local start="${1:-$PWD}" d roots=()
  d="$(cd "${start}" 2>/dev/null && pwd -P)" || return 1
  DUA_ANCESTORS=()
  while :; do
    DUA_ANCESTORS+=("${d}")
    if is_dua_root "${d}"; then roots+=("${d}"); fi
    [[ "${d}" == "/" ]] && break
    d="$(dirname "${d}")"
  done
  [[ ${#roots[@]} -eq 0 ]] && return 1
  DUA_REPO_ROOT="${roots[0]}"
  dbg "repo root ${DUA_REPO_ROOT} (${#roots[@]} DUA roots on the path)"
  return 0
}

# Targets configured in a repository, one per line.
list_targets() {
  local root="${1}" d t
  for d in "${root}"/docker/container-*; do
    [[ -d "${d}" ]] || continue
    t="$(basename "${d}")"
    printf '%s\n' "${t#container-}"
  done
}

compose_file() { printf '%s/docker/container-%s/.devcontainer/docker-compose.yaml' "${1}" "${2}"; }

# Service name declared in a target's compose file: <NAME>-<TARGET>.
target_service() {
  local f
  f="$(compose_file "${1}" "${2}")"
  [[ -f "${f}" ]] || return 1
  sed -n 's/^  \([A-Za-z0-9_.-]\+\):[[:space:]]*$/\1/p' "${f}" | head -1
}

# Image tag declared in a target's compose file: <NAME>:<TARGET>.
target_image() {
  local f
  f="$(compose_file "${1}" "${2}")"
  [[ -f "${f}" ]] || return 1
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${f}" | head -1
}

# USER_UID build argument declared in a target's compose file.
target_user_uid() {
  local f
  f="$(compose_file "${1}" "${2}")"
  [[ -f "${f}" ]] || return 1
  sed -n 's/.*USER_UID=\([0-9]\+\).*/\1/p' "${f}" | head -1
}

# Units integrated into a target's Dockerfile, comma separated.
target_units() {
  local f="${1}/docker/container-${2}/Dockerfile"
  [[ -f "${f}" ]] || return 0
  grep -oE '^# [A-Za-z0-9_.-]+ START #$' "${f}" 2>/dev/null |
    sed 's/^# //; s/ START #$//' | grep -v '^IMAGE$' | paste -sd, -
}

image_exists() { dk image inspect "${1}" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

# Turn the inspect output on stdin into one
# "<id>|<name>|<image>|<state>|<started>|<service>|<project>|<dcfolder>|<wssrc>"
# line per container.
parse_records() {
  awk -F'\t' '
      /^DUA_REC_BEGIN$/ { id=nm=im=st=sa=sv=pj=dc=ws=""; next }
      /^DUA_REC_END$/   { print id"|"nm"|"im"|"st"|"sa"|"sv"|"pj"|"dc"|"ws; next }
      $1=="ID"       { id=$2 }
      $1=="NAME"     { nm=$2 }
      $1=="IMAGE"    { im=$2 }
      $1=="STATE"    { st=$2 }
      $1=="STARTED"  { sa=$2 }
      $1=="SERVICE"  { sv=$2 }
      $1=="PROJECT"  { pj=$2 }
      $1=="DCFOLDER" { dc=$2 }
      $1=="WSSRC"    { ws=$2 }
    '
}

# Emit a record line per existing container, running or not.
list_containers() {
  local ids
  ids="$(dk ps -aq 2>/dev/null)" || return 0
  [[ -z "${ids}" ]] && return 0
  # shellcheck disable=SC2086
  dk inspect ${ids} --format "${DUA_INSPECT_FMT}" 2>/dev/null | parse_records
}

# Emit the record for a single container, or nothing.
inspect_one() {
  dk inspect "${1}" --format "${DUA_INSPECT_FMT}" 2>/dev/null | parse_records
}

_set_container_from_record() {
  local rec="${1}" IFS='|'
  # shellcheck disable=SC2034
  read -r DUA_CID DUA_CNAME DUA_CIMAGE DUA_CSTATE DUA_CSTARTED \
    DUA_CSERVICE DUA_CPROJECT _dcfolder DUA_WSSRC <<<"${rec}"
  DUA_CNAME="${DUA_CNAME#/}"
  DUA_CSERVICE="$(denull "${DUA_CSERVICE}")"
  DUA_CPROJECT="$(denull "${DUA_CPROJECT}")"
  DUA_WSSRC="$(denull "${DUA_WSSRC}")"
  # Target: prefer the compose service suffix, fall back to the image tag.
  DUA_CTARGET=""
  local t
  while read -r t; do
    [[ -z "${t}" ]] && continue
    if [[ "${DUA_CSERVICE}" == *"-${t}" ]]; then
      DUA_CTARGET="${t}"
      break
    fi
  done < <(list_targets "${DUA_REPO_ROOT}")
  if [[ -z "${DUA_CTARGET}" && "${DUA_CIMAGE}" == *:* ]]; then
    DUA_CTARGET="${DUA_CIMAGE##*:}"
  fi
  return 0
}

# Resolve the container bound to the current repository.
#
# Return codes:
#   0  running container found            (DUA_* set)
#   3  only a stopped container found     (DUA_* set)
#   4  no container, but the image exists
#   5  no container and no image
#   6  ambiguous: several containers bound to the same root
resolve_container() {
  local want_target="${1-}"
  local recs=() rec ws state
  local running=() stopped=()

  mapfile -t recs < <(list_containers)
  DUA_CANDIDATES=()

  # Strategy A: bind-mount match, innermost ancestor first.
  local anc
  for anc in "${DUA_ANCESTORS[@]}"; do
    running=()
    stopped=()
    for rec in "${recs[@]}"; do
      ws="$(denull "$(cut -d'|' -f9 <<<"${rec}")")"
      [[ "${ws}" != "${anc}" ]] && continue
      state="$(cut -d'|' -f4 <<<"${rec}")"
      if [[ "${state}" == "running" ]]; then running+=("${rec}"); else stopped+=("${rec}"); fi
    done
    if [[ -n "${want_target}" ]]; then
      local filtered=() r svc
      for r in "${running[@]}"; do
        svc="$(denull "$(cut -d'|' -f6 <<<"${r}")")"
        [[ "${svc}" == *"-${want_target}" ]] && filtered+=("${r}")
      done
      if [[ ${#filtered[@]} -gt 0 ]]; then running=("${filtered[@]}"); fi
    fi
    if [[ ${#running[@]} -gt 1 ]]; then
      # shellcheck disable=SC2034
      DUA_CANDIDATES=("${running[@]}")
      DUA_STRATEGY="mount"
      return 6
    fi
    if [[ ${#running[@]} -eq 1 ]]; then
      _set_container_from_record "${running[0]}"
      DUA_STRATEGY="mount"
      dbg "resolved by mount: ${DUA_CNAME}"
      return 0
    fi
    if [[ ${#stopped[@]} -ge 1 ]]; then
      _set_container_from_record "${stopped[0]}"
      DUA_STRATEGY="mount"
      dbg "resolved by mount, stopped: ${DUA_CNAME}"
      return 3
    fi
  done

  # Strategies B and C only make sense for containers that exist. They are
  # re-validated against the mount, so they can only recover cases where the
  # mount scan missed something, never override it.
  local t svc dcf
  while read -r t; do
    [[ -z "${t}" ]] && continue
    svc="$(target_service "${DUA_REPO_ROOT}" "${t}" 2>/dev/null)" || continue
    [[ -z "${svc}" ]] && continue
    for rec in "${recs[@]}"; do
      [[ "$(denull "$(cut -d'|' -f6 <<<"${rec}")")" != "${svc}" ]] && continue
      ws="$(denull "$(cut -d'|' -f9 <<<"${rec}")")"
      [[ -n "${ws}" && "${ws}" != "${DUA_REPO_ROOT}" ]] && continue
      _set_container_from_record "${rec}"
      DUA_STRATEGY="service-label"
      dbg "resolved by compose service label: ${DUA_CNAME}"
      if [[ "${DUA_CSTATE}" == "running" ]]; then return 0; else return 3; fi
    done
    dcf="${DUA_REPO_ROOT}/docker/container-${t}"
    for rec in "${recs[@]}"; do
      [[ "$(denull "$(cut -d'|' -f8 <<<"${rec}")")" != "${dcf}" ]] && continue
      _set_container_from_record "${rec}"
      # shellcheck disable=SC2034
      DUA_STRATEGY="devcontainer-label"
      dbg "resolved by devcontainer label: ${DUA_CNAME}"
      if [[ "${DUA_CSTATE}" == "running" ]]; then return 0; else return 3; fi
    done
  done < <(list_targets "${DUA_REPO_ROOT}")

  # Nothing bound. Report whether an image is at least available.
  while read -r t; do
    [[ -z "${t}" ]] && continue
    if image_exists "$(target_image "${DUA_REPO_ROOT}" "${t}")"; then return 4; fi
  done < <(list_targets "${DUA_REPO_ROOT}")
  return 5
}

# Map the current host directory to its path inside the container.
container_cwd() {
  local pwd_p src="${DUA_WSSRC:-$DUA_REPO_ROOT}"
  pwd_p="$(pwd -P)"
  if [[ "${pwd_p}" == "${src}" ]]; then
    printf '%s' "${DUA_WS}"
  elif [[ "${pwd_p}" == "${src}/"* ]]; then
    printf '%s/%s' "${DUA_WS}" "${pwd_p#"${src}"/}"
  else
    printf '%s' "${DUA_WS}"
  fi
}

# Target to use when starting a container, printed on stdout.
# Order: explicit request, remembered choice, the only target whose image is
# built, the only configured target. Otherwise fail and let the caller ask.
infer_target() {
  local root="${1}" want="${2-}" t remembered built=() all=()
  if [[ -n "${want}" ]]; then
    printf '%s' "${want}"
    return 0
  fi
  remembered="$(state_get "${root}" target)"
  if [[ -n "${remembered}" && -d "${root}/docker/container-${remembered}" ]]; then
    printf '%s' "${remembered}"
    return 0
  fi
  while read -r t; do
    [[ -z "${t}" ]] && continue
    all+=("${t}")
    if image_exists "$(target_image "${root}" "${t}")"; then built+=("${t}"); fi
  done < <(list_targets "${root}")
  if [[ ${#built[@]} -eq 1 ]]; then
    printf '%s' "${built[0]}"
    return 0
  fi
  if [[ ${#all[@]} -eq 1 ]]; then
    printf '%s' "${all[0]}"
    return 0
  fi
  return 1
}

# Hot-path resolution.
#
# A full scan costs about 35 ms and grows with the number of containers on the
# host, so commands that run often reuse the container id remembered for this
# repository, revalidated with a single inspect: it must still exist, still be
# running, and still mount one of the current ancestors at the workspace path.
# Anything else falls back to the full scan.
#
# Only exec-like commands use this. ctx, doctor and the lifecycle commands
# always scan, so that two containers bound to one repository are still caught.
resolve_container_cached() {
  local want="${1-}" cid rec ws state anc
  if [[ -z "${DUA_NO_CACHE-}" && -z "${want}" ]]; then
    cid="$(state_get "${DUA_REPO_ROOT}" cid)"
    if [[ -n "${cid}" ]]; then
      rec="$(inspect_one "${cid}")"
      if [[ -n "${rec}" ]]; then
        state="$(cut -d'|' -f4 <<<"${rec}")"
        ws="$(denull "$(cut -d'|' -f9 <<<"${rec}")")"
        if [[ "${state}" == "running" && -n "${ws}" ]]; then
          for anc in "${DUA_ANCESTORS[@]}"; do
            if [[ "${ws}" == "${anc}" ]]; then
              _set_container_from_record "${rec}"
              # shellcheck disable=SC2034
              DUA_STRATEGY="cache"
              dbg "resolved from cache: ${DUA_CNAME}"
              return 0
            fi
          done
        fi
      fi
      dbg "cache miss for ${cid}"
    fi
  fi
  local rc=0
  resolve_container "${want}" || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    state_set "${DUA_REPO_ROOT}" cid "${DUA_CID}"
  fi
  return ${rc}
}
