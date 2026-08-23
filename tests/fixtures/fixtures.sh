#!/usr/bin/env bash

# DUA project fixtures, shared by the offline suite and the bats suite.
#
# Source it to get make_repo and make_pkg, or run it to build one repository:
#   tests/fixtures/fixtures.sh DIR NAME TARGET [TARGET...]
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash

# make_repo <path> <project name> <target>...
#
# Produces the parts of the dua-template layout the plugin actually reads: the
# root markers, one docker/container-<target>/ per target with a compose file
# declaring the service, image and workspace mount, a Dockerfile carrying unit
# markers, and the mounted shell configuration files.
make_repo() {
  local path="${1}" name="${2}"
  shift 2
  mkdir -p "${path}"/{src,logs,config,tools,bin}
  touch "${path}/bin/dua_setup.sh"
  cat >"${path}/logs/.gitignore" <<'EOF'
*
!.gitignore
!COLCON_IGNORE
!ros/
EOF
  local t d f
  for t in "$@"; do
    d="${path}/docker/container-${t}"
    mkdir -p "${d}/.devcontainer"
    cat >"${d}/.devcontainer/docker-compose.yaml" <<EOF
services:
  ${name}-${t}:
    build:
      context: ../
      dockerfile: Dockerfile
      args:
        - USER_UID=1000
    image: ${name}:${t}
    user: neo
    network_mode: "host"
    privileged: true
    ipc: host
    working_dir: /home/neo/workspace
    volumes:
      - ../../../:/home/neo/workspace
EOF
    cat >"${d}/Dockerfile" <<EOF
FROM dotxautomation/dua-foundation:${t}
ARG USER_UID=1000
# IMAGE SETUP START #
# dep_one START #
RUN echo dep_one
# dep_one END #
# ${name} START #
RUN echo ${name}
# ${name} END #
# IMAGE SETUP END #
EOF
    for f in aliases.sh commands.sh ros2.sh bashrc dua_submod.sh dua_subtree.sh; do
      echo "# ${f} for ${name}-${t}" >"${d}/${f}"
    done
  done
}

# make_pkg <repo> <relative path> <package name>
make_pkg() {
  mkdir -p "${1}/${2}"
  cat >"${1}/${2}/package.xml" <<EOF
<?xml version="1.0"?>
<package format="3">
  <name>${3}</name>
  <version>0.1.0</version>
  <description>${3}</description>
  <maintainer email="info@dotxautomation.com">dotX Automation s.r.l.</maintainer>
  <license>Apache-2.0</license>
</package>
EOF
  cat >"${1}/${2}/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.8)
project(${3})
find_package(ament_cmake REQUIRED)
ament_package()
EOF
}

# Allow direct invocation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  if [[ $# -lt 3 ]]; then
    echo >&2 "usage: fixtures.sh DIR NAME TARGET [TARGET...]"
    exit 2
  fi
  make_repo "$@"
  echo "${1}"
fi
