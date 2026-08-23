#!/usr/bin/env bash

# Command execution inside a DUA container.
#
# Three modes:
#   snap (default)  non-interactive bash sourcing a cached environment snapshot.
#                   ~32 ms, no stdout or stderr pollution.
#   ic              interactive bash, the reference environment. ~385 ms, plus
#                   Ubuntu's sudo hint on stdout and job-control lines on stderr,
#                   both filtered here.
#   raw             plain non-interactive bash, no DUA environment at all.
#
# The snapshot is produced once per container per invalidation key by an
# interactive shell, so it is the same environment a human gets in zsh:
#   export -p     exported variables
#   declare -f    functions, including per-unit commands.sh definitions
#   alias -p      aliases, usable with expand_aliases
# declare -p is deliberately not used: it emits readonly internals that fail on
# source, and PWD/OLDPWD assignments that would make $PWD lie.
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

DUA_EXEC_MODE="${DUA_EXEC_MODE:-snap}"

# Recipe version, part of the invalidation key: bumping it discards every
# snapshot produced by an older version of this file, which is what makes a
# plugin update safe.
readonly DUA_SNAPSHOT_VERSION=4

# Config files bind-mounted into the container whose contents end up in the
# snapshot. A change to any of them invalidates it.
DUA_SNAPSHOT_INPUTS=(aliases.sh commands.sh ros2.sh bashrc dua_submod.sh dua_subtree.sh)

# Digest of every mounted configuration file, across every configured target.
#
# Contents rather than timestamps: stat has one-second granularity, so an edit
# made in the same second as the snapshot was built would go unnoticed, which
# on a fast machine is a real possibility rather than a theoretical one. Using
# the contents also means reverting an edit restores the previous snapshot
# instead of forcing a pointless rebuild.
#
# All targets are covered, not just the resolved one, so invalidation keeps
# working when the target cannot be determined: a container started outside
# Compose carries neither the service label nor a meaningful image tag.
config_digest() {
  local root="${1}" d f
  local -a files=()
  for d in "${root}"/docker/container-*; do
    [[ -d "${d}" ]] || continue
    for f in "${DUA_SNAPSHOT_INPUTS[@]}"; do
      [[ -f "${d}/${f}" ]] && files+=("${d}/${f}")
    done
  done
  # cksum with no arguments would read stdin and hang.
  if [[ ${#files[@]} -eq 0 ]]; then
    printf '0'
    return 0
  fi
  # One fork for all of them: cat-per-file and stat-per-file both cost about
  # 20 ms, which is a fifth of a whole command.
  local out sum=0 c sz rest
  out="$(cksum "${files[@]}")"
  while read -r c sz rest; do
    [[ -n "${c}" ]] || continue
    sum=$(((sum * 31 + c + sz) % 4294967296))
  done <<<"${out}"
  printf '%s' "${sum}"
}

# Invalidation key: the snapshot recipe version, container identity, container
# boot, the configuration digest, and a generation counter bumped by commands
# that change the workspace environment (a build adds packages to
# AMENT_PREFIX_PATH).
snapshot_stamp() {
  local root="${1}" gen
  gen="$(state_get "${root}" gen)"
  printf 'v%s:%s:%s:%s:%s' \
    "${DUA_SNAPSHOT_VERSION}" "${DUA_CID:0:12}" "${DUA_CSTARTED}" \
    "$(config_digest "${root}")" "${gen:-0}"
}

# Invalidate the snapshot by bumping the generation counter.
snapshot_bump() {
  local root="${1}" gen
  gen="$(state_get "${root}" gen)"
  state_set "${root}" gen "$(((${gen:-0} + 1)))"
}

# Shell fragment that regenerates the snapshot when the stamp does not match.
# Kept inline in the exec payload so the common path is a single round trip.
#
# The command and the ROS domain travel in private variables, are scrubbed from
# the shell that produces the snapshot, are excluded from the snapshot itself,
# and are re-applied after sourcing it. Without all three, an early snapshot
# captures DUA_CMD and every later exec replays that first command; ros2init
# likewise resets ROS_DOMAIN_ID, so the domain has to be applied last.
_snapshot_prelude() {
  local stamp="${1}"
  cat <<PRELUDE
__dua_cmd="\$DUA_CMD"
__dua_stamp='${stamp}'
if [ ! -r ${DUA_CC_DIR}/stamp ] || [ "\$(cat ${DUA_CC_DIR}/stamp)" != "\$__dua_stamp" ]; then
  mkdir -p ${DUA_CC_DIR} || exit 97
  touch "\$HOME/.sudo_as_admin_successful" 2>/dev/null
  env -u DUA_CMD -u DUA_DOMAIN bash -ic 'export -p; declare -f; alias -p' 2>/dev/null \\
    | grep -vE '^declare -x (PWD|OLDPWD|SHLVL|_|DUA_CMD|DUA_DOMAIN)(=|\$)' > ${DUA_CC_DIR}/env.sh.tmp
  if [ ! -s ${DUA_CC_DIR}/env.sh.tmp ]; then exit 98; fi
  mv ${DUA_CC_DIR}/env.sh.tmp ${DUA_CC_DIR}/env.sh
  printf '%s' "\$__dua_stamp" > ${DUA_CC_DIR}/stamp
fi
shopt -s expand_aliases
. ${DUA_CC_DIR}/env.sh
DUA_CMD="\$__dua_cmd"
export DUA_CMD
$(_domain_fragment)
PRELUDE
}

# Applied after the environment is in place, in every mode: ros2init sets
# ROS_DOMAIN_ID itself, so an injected value has to win afterwards.
_domain_fragment() {
  printf 'if [ -n "${DUA_DOMAIN:-}" ]; then export ROS_DOMAIN_ID="$DUA_DOMAIN"; fi'
}

# Drop the three-line sudo hint when it appears at the head of stdout, and
# nowhere else.
_strip_sudo_hint() {
  awk '
    NR<=3 && !done {
      if (NR==1 && $0 ~ /^To run a command as administrator \(user "root"\)/) { skip=1; next }
      if (skip && NR==2 && $0 ~ /^See "man sudo_root" for details\./) { next }
      if (skip && NR==3 && $0 == "") { done=1; next }
    }
    { done=1; print }
  '
}

_strip_jobcontrol() {
  grep -vE '^bash: (cannot set terminal process group|no job control in this shell)' || true
}

# dua_exec_in <container-cwd> <timeout|""> <command string>
#
# Runs the command in the resolved container. Exit status is the command's own.
dua_exec_in() {
  local ccwd="${1}" tmo="${2}" cmd="${3}"
  [[ -n "${DUA_CID}" ]] || die "no container resolved"

  local -a args=(exec -i -u "${DUA_USER}" -w "${ccwd}" -e "TERM=dumb" -e "DUA_CMD=${cmd}")
  if [[ -n "${DUA_DOMAIN_ID-}" ]]; then args+=(-e "DUA_DOMAIN=${DUA_DOMAIN_ID}"); fi
  args+=("${DUA_CID}")

  local payload rc=0
  case "${DUA_EXEC_MODE}" in
  snap)
    payload="$(_snapshot_prelude "$(snapshot_stamp "${DUA_REPO_ROOT}")")"
    if [[ -n "${tmo}" ]]; then
      # Re-source inside the subshell so functions and aliases survive.
      payload+=$'\n'"timeout ${tmo} bash -c '__c=\"\$DUA_CMD\"; shopt -s expand_aliases; . ${DUA_CC_DIR}/env.sh; DUA_CMD=\"\$__c\"; eval \"\$DUA_CMD\"'"
    else
      payload+=$'\n''eval "$DUA_CMD"'
    fi
    dk "${args[@]}" bash -c "${payload}"
    rc=$?
    if [[ ${rc} -eq 97 || ${rc} -eq 98 ]]; then
      warn "environment snapshot failed (code ${rc}), falling back to interactive mode"
      DUA_EXEC_MODE=ic dua_exec_in "${ccwd}" "${tmo}" "${cmd}"
      return $?
    fi
    ;;
  ic)
    payload="$(_domain_fragment)"$'\n'
    if [[ -n "${tmo}" ]]; then
      payload+="timeout ${tmo} bash -c 'eval \"\$DUA_CMD\"'"
    else
      payload+='eval "$DUA_CMD"'
    fi
    dk "${args[@]}" bash -ic "${payload}" \
      2> >(_strip_jobcontrol >&2) | _strip_sudo_hint
    rc="${PIPESTATUS[0]}"
    ;;
  raw)
    payload="$(_domain_fragment)"$'\n'
    if [[ -n "${tmo}" ]]; then
      payload+="timeout ${tmo} bash -c 'eval \"\$DUA_CMD\"'"
    else
      payload+='eval "$DUA_CMD"'
    fi
    dk "${args[@]}" bash -c "${payload}"
    rc=$?
    ;;
  *)
    die "unknown exec mode: ${DUA_EXEC_MODE}"
    ;;
  esac
  return "${rc}"
}

# Container-side uid/gid of the internal user, "uid gid" on stdout.
container_ids() {
  dk exec -i -u "${DUA_USER}" "${DUA_CID}" sh -c 'id -u; id -g' 2>/dev/null | paste -sd' ' -
}

# Value of /etc/dua/target inside the container.
container_target_file() {
  dk exec -i -u "${DUA_USER}" "${DUA_CID}" cat /etc/dua/target 2>/dev/null | tr -d '\r\n'
}

# Whether the snapshot inside the container is current.
snapshot_state() {
  local want stored
  want="$(snapshot_stamp "${DUA_REPO_ROOT}")"
  stored="$(dk exec -i -u "${DUA_USER}" "${DUA_CID}" cat "${DUA_CC_DIR}/stamp" 2>/dev/null || true)"
  if [[ -z "${stored}" ]]; then
    printf 'absent'
  elif [[ "${stored}" == "${want}" ]]; then
    printf 'fresh'
  else
    printf 'stale'
  fi
}
