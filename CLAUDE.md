# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A Claude Code plugin marketplace, not a DUA project. `.claude-plugin/marketplace.json` declares the marketplace `dotxautomation` with `pluginRoot: ./plugins`; the single plugin lives in `plugins/dua-claude/`. Everything is Bash plus JSON manifests and Markdown skills: there is no compile step and no runtime dependency beyond Docker, Git and coreutils.

Important distinction: the `dua-*` skills and `/dua-claude:*` commands you may see loaded in a session are *the product this repository builds*, not instructions for developing it. This repository has no DUA container of its own, and `dua ctx` run here will fail (no `docker/` and `bin/dua_setup.sh` at the root). Do not use the plugin's own workflows to work on the plugin.

## Commands

```bash
tests/run-all.sh                    # lint + offline suites + container suite (needs Docker and bats)
tests/run-all.sh -q                 # everything that needs no Docker
tests/run-all.sh -r master          # rebuild the mock against dua-template's master instead of the pinned ref
tests/unit/run.sh                   # offline CLI suite alone
tests/unit/skills.sh                # static skill validation alone
tests/unit/hooks.sh                 # hook and slash-command suite alone
tests/unit/release.sh               # version/changelog/manifest consistency alone
bats tests/bats/exec.bats           # one container suite file
bats -f 'pattern' tests/bats        # one test by name
tests/mock/build.sh                 # build the mock DUA container (prerequisite of tests/bats)
tests/smoke/on-host.sh              # acceptance test against a real DUA container on this machine
claude --plugin-dir ./plugins/dua-claude   # load the plugin without installing it
```

`shellcheck -S warning` is the linter. Its file list is written out explicitly in **two** places, `tests/run-all.sh` and `.github/workflows/ci.yaml`: a new script must be added to both or it goes unlinted.

## Architecture

### The CLI

`plugins/dua-claude/bin/dua` is a single dispatch script (option parsing, one `cmd_*` function per subcommand, `main`) that sources five libraries in order, all of which communicate through globals rather than return values:

- `lib/common.sh` — constants that are DUA invariants (`DUA_WS=/home/neo/workspace`, `DUA_USER=neo`), logging helpers, `dk()` wrapping `${DUA_DOCKER}` (the seam the test stub uses), per-repository state under `CLAUDE_PLUGIN_DATA`.
- `lib/resolve.sh` — `resolve_repo()` walks up for a directory holding both `docker/` and `bin/dua_setup.sh`; `resolve_container()` finds the container that bind-mounts an ancestor of `$PWD` at the workspace path. Resolution is keyed on **bind mounts, never on names, images or Compose project names**, because VS Code renames images and every container started from a `.devcontainer` directory joins a Compose project literally called `devcontainer`. Its return codes are the CLI's error vocabulary: 0 running, 3 stopped, 4 no container but image built, 5 neither, 6 ambiguous. Every caller switches on them.
- `lib/exec.sh` — the three exec modes (`snap` default, `ic`, `raw`) and the environment snapshot that makes `snap` cost ~30 ms instead of ~400 ms. The snapshot is produced by an interactive shell (`export -p`, `declare -f`, `alias -p`; deliberately not `declare -p`) and cached per container per invalidation key. The key combines `DUA_SNAPSHOT_VERSION`, container identity and boot time, a digest of the *contents* of every mounted config file across every target, and a generation counter bumped by commands that change the workspace environment. **Bump `DUA_SNAPSHOT_VERSION` whenever the snapshot recipe changes**, or an updated plugin will reuse snapshots built by the old one.
- `lib/compose.sh` — lifecycle. `down` and `restart` act on the container directly and never through Compose, for the `devcontainer` project-name reason above; `up` starts an existing container and only falls back to Compose when none exists.
- `lib/workflows.sh` — `build`, `test`, `run`, `bg`, `setup`, `pkg new`. Everything runs at the workspace root because colcon requires it, and long output is tee'd to `logs/cc/` in the repository (the template gitignores it). The colcon invocations are `readonly` constants at the top of the file, including the `-DCMAKE_EXPORT_COMPILE_COMMANDS=On` that exists purely so Claude can resolve symbols.

Adding a subcommand means touching four places in `bin/dua`: `usage()`, the dispatch allow-list, the `OPT_PASSTHROUGH` list if it owns its own flags, and the final `case`.

### Hooks

`hooks/hooks.json` registers two programs in `scripts/`. `session-start.sh` injects the resolved project context at session start. `guard-host-exec.sh` is a `PreToolUse` matcher on Bash that denies `colcon`, `ros2`, `ament_*` and friends run on the host and answers with the `dua` equivalent. Three properties are load-bearing and are asserted by the tests: it inspects only the first word of each shell segment (so `grep colcon` passes), it never fires outside a DUA project, and it fails open on unparseable input.

### Skills and commands

`skills/*/SKILL.md` (six, some with a `reference.md`) and `commands/*.md`. `templates/CLAUDE.md.tmpl` is the template the `/dua-claude:claude-md` command uses to write a `CLAUDE.md` for a *user's* DUA project — it has nothing to do with this file.

### Test layers

Four, in increasing cost, all of which except the last two run with no DUA installation:

- `tests/unit/` — offline. `run.sh` drives the real CLI against the fake Docker client in `tests/stub/docker`, fed container records reproducing real-world shapes (renamed VS Code images, unlabelled containers, two containers on one repo, another checkout's container), asserting on resolution, on the exact `colcon`/`ros2` command lines built, on snapshot invalidation and on exit codes. `skills.sh` validates skills statically, and critically **cross-checks every `dua <subcommand>` mentioned in a skill against the dispatch list in `bin/dua`** — renaming a subcommand without updating the skills fails CI. `hooks.sh` feeds synthetic hook events and asserts on the decisions. `release.sh` checks that version, changelog, manifests and install instructions agree.
- `tests/bats/` — the real CLI against a mock DUA container built by `tests/mock/build.sh` from a genuine `dua-template` checkout, with `/opt/ros` and the venv stubbed so the real `ros2init` completes, `colcon` and `ros2` replaced by recording stubs, and Ubuntu's sudo hint left in place because suppressing it is part of the plugin's job. Covers what a stub cannot: stdout purity, snapshot-versus-interactive-shell equivalence variable by variable and function by function, working-directory mapping, background processes, uid/gid mismatch reporting.
- `tests/smoke/on-host.sh` — against a real container: command cost, host-visible file ownership, snapshot invalidation on a real edit, stop/start cycle.
- `tests/probe/` — the scripts that established the design empirically; they double as diagnostics on unfamiliar machines.

The template ref the container suite pins is `tests/mock/TEMPLATE_REF`. `.github/workflows/nightly.yaml` rebuilds the mock against the template's current `master` and reports which files under `bin/dua-templates/context/` changed when it breaks — the plugin depends on template details that are not a contract (the interactive guard in `bashrc`, what `ros2init` sources), so that job is an early warning, not a gate. `ci.yaml` is the gate.

## Conventions and boundaries

Bash: `set -o errexit -o nounset -o pipefail`, `TRACE=1` enabling `xtrace`, Apache-2.0 header on every file (`SPDX-License-Identifier: Apache-2.0` short form in `tests/`), `# shellcheck shell=bash` on sourced libraries, and explicit `# shellcheck disable=` with a reason where a global is consumed elsewhere. Comments explain *why a plausible alternative was rejected* rather than what the code does; match that register.

The plugin's own design boundaries, which the skills state and the code enforces, are worth preserving when changing behaviour: Claude may start, stop and restart containers, may not build images (long, and a human decision), proposes Git operations rather than performing them, and asks before commanding hardware, since DUA containers are privileged.

Remote Docker is deliberately unsupported: `dua exec` would work while Claude's file tools edited a different copy of the repository. `dua doctor` notes a set `DOCKER_HOST` for that reason.

## Releasing

Semantic versioning. Update `CHANGELOG.md`, bump `version` in `plugins/dua-claude/.claude-plugin/plugin.json`, run `tests/run-all.sh`, commit, tag `vX.Y.Z`, push the tag. `tests/unit/release.sh` fails when the version and the changelog disagree.
