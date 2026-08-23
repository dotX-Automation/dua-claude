#!/usr/bin/env bash

# Container lifecycle for the dua CLI.
#
# down and restart act on the container directly, never through Compose:
# every container started with `docker compose up -d` from a .devcontainer
# directory joins a project literally named "devcontainer", so `compose down`
# can reach containers belonging to unrelated projects.
#
# up starts an existing container when there is one, and only falls back to
# Compose when none exists, invoking it exactly the way a human would so that
# the resulting container is indistinguishable from a hand-started one.
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

compose_cli() {
  if dk compose version >/dev/null 2>&1; then
    printf 'compose'
  elif have docker-compose; then
    printf 'legacy'
  else
    printf ''
  fi
}

dua_up() {
  local want="${1-}" rc=0 target dir

  resolve_container "${want}" || rc=$?
  case ${rc} in
  0)
    info "already running: ${DUA_CNAME} (${DUA_CID:0:12}), target ${DUA_CTARGET}"
    return 0
    ;;
  3)
    info "starting existing container ${DUA_CNAME} (${DUA_CID:0:12}) ..."
    dk start "${DUA_CID}" >/dev/null || die "docker start failed"
    resolve_container "${want}" >/dev/null 2>&1 || true
    info "started: ${DUA_CNAME}, target ${DUA_CTARGET}"
    return 0
    ;;
  6)
    err "several containers are bound to ${DUA_REPO_ROOT}, refusing to guess"
    print_candidates
    return 1
    ;;
  esac

  if ! target="$(infer_target "${DUA_REPO_ROOT}" "${want}")"; then
    err "cannot tell which target to start"
    info "configured targets:"
    list_targets "${DUA_REPO_ROOT}" | sed 's/^/  /' >&2
    hint "re-run with --target <TARGET>"
    return 1
  fi

  dir="${DUA_REPO_ROOT}/docker/container-${target}/.devcontainer"
  [[ -d "${dir}" ]] || die "target ${target} is not configured in this repository"

  local image
  image="$(target_image "${DUA_REPO_ROOT}" "${target}")"
  if ! image_exists "${image}"; then
    err "image ${image} is not built on this host"
    hint "building it is a human decision: run 'docker compose build' in ${dir}"
    return 1
  fi

  case "$(compose_cli)" in
  compose) (cd "${dir}" && dk compose up -d) || die "docker compose up failed" ;;
  legacy) (cd "${dir}" && docker-compose up -d) || die "docker-compose up failed" ;;
  *) die "no Docker Compose available on this host" ;;
  esac

  state_set "${DUA_REPO_ROOT}" target "${target}"
  if resolve_container "${target}" >/dev/null 2>&1; then
    info "started: ${DUA_CNAME} (${DUA_CID:0:12}), target ${DUA_CTARGET}"
    return 0
  fi
  err "compose reported success but no container is bound to ${DUA_REPO_ROOT}"
  return 1
}

dua_down() {
  local rc=0
  resolve_container "${1-}" || rc=$?
  case ${rc} in
  0)
    info "stopping ${DUA_CNAME} (${DUA_CID:0:12}) ..."
    dk stop "${DUA_CID}" >/dev/null || die "docker stop failed"
    info "stopped"
    return 0
    ;;
  3)
    info "already stopped: ${DUA_CNAME}"
    return 0
    ;;
  6)
    err "several containers are bound to ${DUA_REPO_ROOT}, refusing to guess"
    print_candidates
    return 1
    ;;
  *)
    info "no container to stop for ${DUA_REPO_ROOT}"
    return 0
    ;;
  esac
}

dua_restart() {
  local rc=0
  resolve_container "${1-}" || rc=$?
  if [[ ${rc} -eq 6 ]]; then
    err "several containers are bound to ${DUA_REPO_ROOT}, refusing to guess"
    print_candidates
    return 1
  fi
  if [[ ${rc} -ne 0 && ${rc} -ne 3 ]]; then
    err "no container to restart for ${DUA_REPO_ROOT}"
    hint "dua up"
    return 1
  fi
  info "restarting ${DUA_CNAME} (${DUA_CID:0:12}) ..."
  dk restart "${DUA_CID}" >/dev/null || die "docker restart failed"
  info "restarted (the environment snapshot will be rebuilt on next use)"
  return 0
}

print_candidates() {
  local rec id nm st ws
  for rec in "${DUA_CANDIDATES[@]}"; do
    IFS='|' read -r id nm _ st _ _ _ _ ws <<<"${rec}"
    printf '  %-14s %-50s %-8s %s\n' "${id:0:12}" "${nm#/}" "${st}" "${ws}" >&2
  done
  hint "stop the one you do not want, or pass --target"
}
