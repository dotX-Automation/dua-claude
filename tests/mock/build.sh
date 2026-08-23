#!/usr/bin/env bash

# Build the mock DUA container used by the bats suite.
#
#   tests/mock/build.sh                     # uid/gid of the caller, pinned template
#   tests/mock/build.sh -u 4321 -g 5678     # deliberately mismatched ids
#   tests/mock/build.sh -s /path/to/dua-template
#   tests/mock/build.sh -r master           # check the template's current state
#
# The template files are staged rather than referenced so that the Docker build
# context stays tiny and the image records exactly which files went in.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_URL="https://github.com/dotX-Automation/dua-template.git"
TEMPLATE_REF="$(cat "${HERE}/TEMPLATE_REF")"
TEMPLATE_DIR=""
TAG="dua-claude-mock:latest"
UID_ARG="$(id -u)"
GID_ARG="$(id -g)"
TARGET="x86-cudev"

usage() {
  cat >&2 <<'EOF'
usage: build.sh [-t TAG] [-u UID] [-g GID] [-T TARGET] [-s TEMPLATE_DIR | -r REF]
  -t  image tag                       (default dua-claude-mock:latest)
  -u  uid of the internal user        (default: yours)
  -g  gid of the internal user        (default: yours)
  -T  value of /etc/dua/target        (default x86-cudev)
  -s  existing dua-template checkout
  -r  dua-template ref to clone       (default: the sha in TEMPLATE_REF)
EOF
}

while getopts ":t:u:g:T:s:r:h" opt; do
  case "${opt}" in
  t) TAG="${OPTARG}" ;;
  u) UID_ARG="${OPTARG}" ;;
  g) GID_ARG="${OPTARG}" ;;
  T) TARGET="${OPTARG}" ;;
  s) TEMPLATE_DIR="${OPTARG}" ;;
  r) TEMPLATE_REF="${OPTARG}" ;;
  h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
  esac
done

CTX="$(mktemp -d)"
trap 'rm -rf "${CTX}"' EXIT
mkdir -p "${CTX}/stubs" "${CTX}/template"
cp "${HERE}/Dockerfile" "${CTX}/"
cp "${HERE}/stubs/"* "${CTX}/stubs/"

if [[ -z "${TEMPLATE_DIR}" ]]; then
  TEMPLATE_DIR="$(mktemp -d)"
  trap 'rm -rf "${CTX}" "${TEMPLATE_DIR}"' EXIT
  echo "cloning dua-template at ${TEMPLATE_REF} ..."
  git clone --quiet "${TEMPLATE_URL}" "${TEMPLATE_DIR}"
  git -C "${TEMPLATE_DIR}" checkout --quiet "${TEMPLATE_REF}"
fi

SRC="${TEMPLATE_DIR}/bin/dua-templates/context"
[[ -d "${SRC}" ]] || {
  echo >&2 "ERROR: ${SRC} not found, is ${TEMPLATE_DIR} a dua-template checkout?"
  exit 1
}
for f in bashrc aliases.sh commands.sh ros2.sh dua_submod.sh dua_subtree.sh; do
  cp "${SRC}/${f}" "${CTX}/template/${f}"
done

echo "template: $(git -C "${TEMPLATE_DIR}" rev-parse --short HEAD 2>/dev/null || echo "${TEMPLATE_DIR}")"
echo "building ${TAG} with uid ${UID_ARG}, gid ${GID_ARG}, target ${TARGET} ..."
docker build \
  --build-arg "USER_UID=${UID_ARG}" \
  --build-arg "USER_GID=${GID_ARG}" \
  --build-arg "TARGET=${TARGET}" \
  -t "${TAG}" "${CTX}"
echo "built ${TAG}"
