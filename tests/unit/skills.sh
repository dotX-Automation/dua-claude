#!/usr/bin/env bash

# Static checks for the plugin's skills.
#
# Frontmatter shape, naming rules, size, referenced files, and the one that
# matters most: every `dua <subcommand>` mentioned in a skill must exist in the
# CLI, so a skill can never teach a command that was renamed or never written.
#
# Usage: tests/unit/skills.sh
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "${HERE}/../.." && pwd)"
SKILLS="${ROOT}/plugins/dua-claude/skills"
DUA="${ROOT}/plugins/dua-claude/bin/dua"

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

# Subcommands the CLI actually dispatches, read from the source of truth.
mapfile -t SUBCOMMANDS < <(
  sed -n 's/^  case "${CMD}" in$//p; s/^  ctx | doctor | exec.*$/&/p' "${DUA}" |
    head -1 | tr -d ' ' | tr '|' '\n' | sed 's/).*//' | grep -v '^$'
)
if [[ ${#SUBCOMMANDS[@]} -eq 0 ]]; then
  # Fall back to the dispatch case labels.
  mapfile -t SUBCOMMANDS < <(
    sed -n '/^  case "${CMD}" in$/,/^  esac$/p' "${DUA}" |
      grep -oE '^  [a-z]+\)' | tr -d ' )' | sort -u
  )
fi
printf 'CLI subcommands: %s\n\n' "${SUBCOMMANDS[*]}"

is_subcommand() {
  local c
  for c in "${SUBCOMMANDS[@]}"; do [[ "${c}" == "${1}" ]] && return 0; done
  return 1
}

[[ -d "${SKILLS}" ]] || {
  echo "no skills directory at ${SKILLS}"
  exit 1
}

for dir in "${SKILLS}"/*/; do
  dir="${dir%/}"
  name="$(basename "${dir}")"
  file="${dir}/SKILL.md"
  printf '\033[1m%s\033[0m\n' "${name}"

  if [[ ! -f "${file}" ]]; then
    no "${name}: has a SKILL.md"
    continue
  fi

  # Frontmatter: first line ---, closed by a later ---
  if [[ "$(head -1 "${file}")" != "---" ]]; then
    no "${name}: starts with frontmatter"
    continue
  fi
  fm_end="$(awk 'NR>1 && /^---$/ {print NR; exit}' "${file}")"
  if [[ -z "${fm_end}" ]]; then
    no "${name}: frontmatter is closed"
    continue
  fi
  ok "frontmatter parses"

  fm="$(sed -n "2,$((fm_end - 1))p" "${file}")"

  # Only the portable Agent Skills fields, to stay usable outside Claude Code
  # and to avoid the approval prompt that allowed-tools triggers.
  while read -r line; do
    [[ -z "${line}" ]] && continue
    key="${line%%:*}"
    case "${key}" in
    name | description | license | compatibility | metadata) ;;
    *) no "${name}: unexpected frontmatter field '${key}'" ;;
    esac
  done <<<"${fm}"

  fm_name="$(sed -n 's/^name:[[:space:]]*//p' <<<"${fm}")"
  if [[ "${fm_name}" == "${name}" ]]; then
    ok "name matches the directory"
  else
    no "${name}: name matches the directory" "frontmatter says '${fm_name}'"
  fi
  if [[ "${fm_name}" =~ ^[a-z0-9-]{1,64}$ ]]; then
    ok "name is kebab-case within 64 characters"
  else
    no "${name}: name is kebab-case within 64 characters"
  fi

  desc="$(sed -n 's/^description:[[:space:]]*//p' <<<"${fm}")"
  if [[ -n "${desc}" ]]; then
    ok "has a description"
  else
    no "${name}: has a description"
  fi
  if [[ ${#desc} -le 1024 ]]; then
    ok "description is within 1024 characters (${#desc})"
  else
    no "${name}: description is within 1024 characters" "${#desc}"
  fi
  # A description spanning lines would not be caught by the sed above, so make
  # sure the field is a single line.
  if [[ "$(grep -c '^description:' <<<"${fm}")" -eq 1 ]]; then
    ok "description is a single line"
  else
    no "${name}: description is a single line"
  fi

  body_lines=$(($(wc -l <"${file}") - fm_end))
  if [[ ${body_lines} -gt 0 ]]; then
    ok "has a body (${body_lines} lines)"
  else
    no "${name}: has a body"
  fi
  bytes="$(wc -c <"${file}")"
  if [[ ${bytes} -le 20000 ]]; then
    ok "SKILL.md is under 20 kB (${bytes})"
  else
    no "${name}: SKILL.md is over 20 kB" "${bytes}; move detail into reference.md"
  fi

  # Referenced companion files must exist.
  missing=""
  while read -r ref; do
    [[ -z "${ref}" ]] && continue
    [[ -f "${dir}/${ref}" ]] || missing+=" ${ref}"
  done < <(grep -oE '\b[a-z0-9_-]+\.md\b' "${file}" | grep -v '^SKILL\.md$' | sort -u)
  if [[ -z "${missing}" ]]; then
    ok "referenced files exist"
  else
    no "${name}: referenced files exist" "missing:${missing}"
  fi

  # Every dua subcommand mentioned must be real.
  unknown=""
  while read -r sub; do
    [[ -z "${sub}" ]] && continue
    is_subcommand "${sub}" || unknown+=" ${sub}"
  done < <(grep -ohE '(^|`)dua [a-z-]+' "${dir}"/*.md |
    sed 's/.*dua //' | grep -v '^-' | sort -u)
  if [[ -z "${unknown}" ]]; then
    ok "every dua subcommand mentioned exists"
  else
    no "${name}: every dua subcommand mentioned exists" "unknown:${unknown}"
  fi

  # No absolute home paths other than the container's own: that is the shape
  # private information takes when it is pasted in from a terminal session.
  stray="$(grep -hoE '/home/[A-Za-z0-9_.-]+/' "${dir}"/*.md 2>/dev/null |
    grep -v '^/home/neo/$' | sort -u | tr '\n' ' ')"
  if [[ -z "${stray}" ]]; then
    ok "contains no host home paths"
  else
    no "${name}: contains no host home paths" "${stray}"
  fi
done

printf '\n\033[1m%s passed, %s failed\033[0m\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
