#!/usr/bin/env bash

# Release consistency checks.
#
# The failure this prevents: shipping a version whose changelog says nothing,
# or install instructions naming the wrong marketplace, both of which are
# invisible until a colleague tries to install the plugin. The marketplace
# lives in another repository, so only what this one says about it is checked.
#
# Usage: tests/unit/release.sh
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "${HERE}/../.." && pwd)"
MANIFEST="${ROOT}/.claude-plugin/plugin.json"
MARKET_REPO="dotX-Automation/dotxautomation-claude-open"
MARKET_NAME="dotxautomation-claude-open"
CHANGELOG="${ROOT}/CHANGELOG.md"

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

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k] if isinstance(d, dict) else d[int(k)]
print(d)' "$@" 2>/dev/null; }

printf '\033[1mmanifests\033[0m\n'

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${MANIFEST}"; then
  ok ".claude-plugin/plugin.json is valid JSON"
else
  no "${MANIFEST} is valid JSON"
fi

owner="$(jget "${MANIFEST}" author.name)"
if [[ "${owner}" == "dotX Automation s.r.l." ]]; then
  ok "author is spelled correctly"
else
  no "author is spelled correctly" "found '${owner}'"
fi

printf '\033[1mversion\033[0m\n'

version="$(jget "${MANIFEST}" version)"
if [[ -z "${version}" ]]; then
  no "the plugin declares a version" "add \"version\" to plugin.json before releasing"
elif [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  ok "version ${version} is semver"
else
  no "version is semver" "found '${version}'"
fi

if [[ -f "${CHANGELOG}" ]]; then
  ok "there is a changelog"
  top="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "${CHANGELOG}" | tr -d '#[] ')"
  if [[ -n "${version}" && "${top}" == "${version}" ]]; then
    ok "the changelog's newest entry is ${version}"
  else
    no "the changelog's newest entry matches the manifest" "changelog ${top:-none}, manifest ${version:-none}"
  fi
  if grep -q '^## \[Unreleased\]' "${CHANGELOG}"; then
    ok "the changelog has an Unreleased section"
  else
    no "the changelog has an Unreleased section"
  fi
else
  no "there is a changelog"
fi

printf '\033[1mfiles a user expects\033[0m\n'
for f in README.md LICENSE; do
  if [[ -f "${ROOT}/${f}" ]]; then
    ok "${f} exists"
  else
    no "${f} exists"
  fi
done
if grep -qi 'apache' "${ROOT}/LICENSE" 2>/dev/null; then
  ok "LICENSE looks like Apache 2.0"
else
  no "LICENSE looks like Apache 2.0"
fi
license_field="$(jget "${MANIFEST}" license)"
if [[ "${license_field}" == "Apache-2.0" ]]; then
  ok "the manifest declares Apache-2.0"
else
  no "the manifest declares Apache-2.0" "found '${license_field}'"
fi

printf '\033[1minstall instructions\033[0m\n'
if grep -qF "plugin marketplace add ${MARKET_REPO}" "${ROOT}/README.md" 2>/dev/null; then
  ok "the README documents adding the marketplace"
else
  no "the README documents adding the marketplace"
fi
if grep -qF "plugin install dua-claude@${MARKET_NAME}" "${ROOT}/README.md" 2>/dev/null; then
  ok "the README documents installing the plugin"
else
  no "the README documents installing the plugin" "the marketplace name must match ${MARKET_REPO}'s marketplace.json"
fi

printf '\n\033[1m%s passed, %s failed\033[0m\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
