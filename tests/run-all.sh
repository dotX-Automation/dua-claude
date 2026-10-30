#!/usr/bin/env bash

# Run every check, in increasing order of cost.
#
#   tests/run-all.sh            lint + offline suite, plus bats if Docker is up
#   tests/run-all.sh -q         lint + offline suite only
#   tests/run-all.sh -r master  build the mock against the template's master
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -o nounset
set -o pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "${HERE}/.." && pwd)"
QUICK=0
REF=""
FAILED=0

while getopts ":qr:h" opt; do
  case "${opt}" in
  q) QUICK=1 ;;
  r) REF="${OPTARG}" ;;
  h)
    echo >&2 "usage: run-all.sh [-q] [-r TEMPLATE_REF]"
    exit 0
    ;;
  *)
    echo >&2 "usage: run-all.sh [-q] [-r TEMPLATE_REF]"
    exit 2
    ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() {
  printf '\033[31mFAILED: %s\033[0m\n' "$1"
  FAILED=$((FAILED + 1))
}

cd "${ROOT}" || exit 1

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  if shellcheck -S warning \
    bin/dua lib/*.sh \
    tests/stub/docker tests/unit/run.sh tests/smoke/on-host.sh \
    tests/fixtures/fixtures.sh tests/mock/build.sh tests/mock/stubs/colcon \
    tests/mock/stubs/ros2 tests/run-all.sh tests/bats/helper.bash tests/unit/skills.sh tests/unit/hooks.sh tests/unit/release.sh \
    scripts/session-start.sh scripts/guard-host-exec.sh; then
    echo "clean"
  else
    fail "shellcheck"
  fi
else
  echo "shellcheck not installed, skipped"
fi

step "manifests"
if python3 - <<'PY'; then
import json, sys
for p in (".claude-plugin/plugin.json", "hooks/hooks.json"):
    with open(p) as f:
        json.load(f)
    print(f"{p}: ok")
PY
  :
else
  fail "manifests"
fi

step "skills"
if tests/unit/skills.sh; then :; else fail "skills"; fi

step "hooks and commands"
if tests/unit/hooks.sh; then :; else fail "hooks and commands"; fi

step "release consistency"
if tests/unit/release.sh; then :; else fail "release consistency"; fi

step "offline suite"
if tests/unit/run.sh; then :; else fail "offline suite"; fi

if [[ ${QUICK} -eq 1 ]]; then
  printf '\n(skipping the container suite)\n'
else
  step "mock container"
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "no usable Docker, skipping the container suite"
  elif ! command -v bats >/dev/null 2>&1; then
    echo "bats not installed, skipping the container suite (apt install bats)"
  else
    if tests/mock/build.sh ${REF:+-r "${REF}"}; then
      tests/mock/build.sh -t dua-claude-mock:mismatch -u 4321 -g 5678 ${REF:+-r "${REF}"} >/dev/null ||
        echo "could not build the mismatched-ids image, that test will skip"
      step "container suite"
      if bats tests/bats; then :; else fail "container suite"; fi
    else
      fail "mock container build"
    fi
  fi
fi

printf '\n'
if [[ ${FAILED} -eq 0 ]]; then
  printf '\033[32meverything passed\033[0m\n'
  exit 0
fi
printf '\033[31m%s stage(s) failed\033[0m\n' "${FAILED}"
exit 1
