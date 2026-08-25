# dua-claude: context bootstrap

This document exists so that a new conversation, or a new Claude Code instance, can pick up work on this plugin without rediscovering how it works or why it is built the way it is. It describes the state of the repository at version 0.1.2.

Repository: `github.com/dotX-Automation/dua-claude`, public. Marketplace name `dotxautomation`, plugin name `dua-claude`.

---

## Why this exists

DUA, the Distributed Unified Architecture, is an open framework to develop robotics software: a repository layout (`dua-template`), a set of base container images (`dua-foundation`) and a collection of shared ROS 2 libraries (other public repos from the same organization). Development happens in a container: a developer opens a shell inside it, and ROS 2, the toolchain and every dependency live there rather than on the host.

Claude Code could not work with this effectively. Running it *inside* a DUA container works, but confines it to one container instance, and every image rebuild destroys everything, including the Claude Code installation itself. Running it on the host leaves it without a toolchain: `colcon` and `ros2` either do not exist or, worse, exist without a ROS environment and fail in confusing ways.

The plugin resolves this by making Claude a DUA developer rather than a container inhabitant. It runs on the host, in a project root, and drives the project's container the way a person does.

The consequence that matters: no Claude state lives inside a container, so rebuilding an image, recreating a container or switching targets costs nothing, and the user is free to customize their Claude Code installation as they please.

---

## The design

### The invariant

**Claude edits on the host. Claude executes in the container.**

DUA's compose files bind-mount the repository root into the container at `/home/neo/workspace`. The host view and the container view are therefore the same filesystem. Claude's own Read, Grep, Glob, Edit and Write tools work natively on the host; anything needing ROS or the toolchain is executed inside the container. Git also stays on the host, where the credentials and the SSH agent are.

Everything else in the plugin follows from this.

### Container resolution keyed on bind mounts

Given a working directory, the plugin walks up collecting ancestor directories, inspects every container on the host (running or not), and selects the one whose bind mount destination is `/home/neo/workspace` and whose source is one of those ancestors. The innermost match wins.

This was chosen over name and image matching after measuring the alternatives on real hosts. Names are unreliable: VS Code Dev Containers renames images to `vsc-container-<target>-<hash>-uid`, and every container started with `docker compose up -d` from a `.devcontainer` directory joins a Compose project literally named `devcontainer`, so several unrelated projects share one project name. Mount matching was correct in every case tested, including hosts running two DUA containers at once, and costs about 15 ms.

It also solves the nested-unit case for free: a unit living under a macro-project's `src/` resolves to the macro-project's container, which is the one that actually owns the workspace.

Compose service labels, devcontainer labels and name substring matching remain as fallbacks, each revalidated against the mount before use. Two containers bound to one repository is treated as a host anomaly: reported, never guessed at.

### The environment snapshot

This is the least obvious part of the design and the most important to understand before changing anything in `lib/exec.sh`.

The container's `~/.bashrc` returns immediately for non-interactive shells. So `docker exec ... bash -c '...'` has no ROS environment at all, while `bash -lc` is no better because the interactive guard still fires. An interactive `bash -ic` does produce the full environment, identical to what a developer gets, but costs about 400 ms per command and prints Ubuntu's three-line sudo hint on standard output, which corrupts anything parsing the output.

So the first command in a container captures `export -p`, `declare -f` and `alias -p` from one interactive shell into `/tmp/dua-cc/env.sh`, and every later command sources that from a non-interactive shell. Measured on a real host: about 30 ms against about 400 ms, with the environment identical variable for variable (86 of 86) and function for function (25 of 25), and no output noise, because a non-interactive shell never reads `/etc/bash.bashrc`.

Three details of this are load-bearing and were each found by a real failure:

- `declare -p` cannot be used to capture variables. It emits readonly internals such as `BASHOPTS` and `EUID`, which fail on source, and `PWD` assignments that would make the working directory lie. `export -p` is correct.
- The command being run is passed in through the environment as `DUA_CMD`. An early version let the snapshot capture that variable, so every subsequent command re-ran the first one forever. The variable is now scrubbed from the capturing shell, excluded from the snapshot, and restored after sourcing. The same applies to `DUA_DOMAIN`, since `ros2init` sets `ROS_DOMAIN_ID` itself and any injected value has to be applied afterwards.
- Invalidation is keyed on the *contents* of the mounted configuration files, not their timestamps. `stat` has one-second granularity, so an edit made in the same second as the snapshot was built went unnoticed, which on a fast machine or a CI runner happens often. A `cksum` digest over all configured targets' config files costs about 3 ms and has no such window.

The full invalidation key is: snapshot recipe version (currently 4), container id, container start time, the configuration digest, and a generation counter bumped by `dua build` and `dua setup`. Bumping `DUA_SNAPSHOT_VERSION` in `lib/exec.sh` invalidates every existing snapshot, which is what makes a plugin update safe.

### Deliberate non-goals

**Remote Docker is unsupported.** `DOCKER_HOST=ssh://host` would make `dua exec` work while Claude's file tools silently edited a different copy of the repository, breaking the invariant the whole design rests on. Claude Code runs on development machines; deployment to embedded hosts stays a human, SSH-based activity.

**No MCP server.** Everything needed is filesystem and subprocess work, already covered by the built-in tools. An MCP server would add a process and a protocol for nothing.

**No image builds without asking.** Rebuilding takes tens of minutes. Claude may start, stop and restart containers freely; building is always the user's decision.

**No `dua lint`.** The `ament_*` linters remain reachable through `dua exec` and are documented, but there is no subcommand for them.

---

## The components

### `plugins/dua-claude/bin/dua` and `lib/`

A Bash CLI, put on the Bash tool's `PATH` whenever the plugin is enabled. Strict mode throughout, shellcheck clean at `-S warning`, and no dependencies beyond `docker`, `git` and coreutils. Deliberately no `jq`: all parsing is done with `docker inspect` Go templates.

| File | Responsibility |
| --- | --- |
| `lib/common.sh` | logging, the docker wrapper, per-repository state under `CLAUDE_PLUGIN_DATA`, small helpers |
| `lib/resolve.sh` | repository discovery, container resolution and its fallbacks, target inference, working directory mapping, the revalidated resolution cache |
| `lib/exec.sh` | the environment snapshot, its invalidation key, and the construction of every `docker exec` |
| `lib/compose.sh` | `up`, `down`, `restart` |
| `lib/workflows.sh` | `build`, `test`, `run`, `bg`, `setup`, `pkg`, and host-side logging to `logs/cc/` |

Subcommands: `ctx`, `doctor`, `exec`, `up`, `down`, `restart`, `build`, `test`, `run`, `bg`, `setup`, `pkg`.

Common options: `--target`, `--timeout` (`--for` on `run`), `--mode snap|ic|raw`, `--domain`, `--json`, `--trace`, `--time`. They may appear before or after the subcommand.

Behaviours worth knowing before editing:

- `down` and `restart` act on the container directly, never through Compose, because of the shared `devcontainer` project name. `up` starts an existing container when there is one and only falls back to Compose when none exists.
- Resolution must use `docker ps -a`, not `docker ps`, or stopped containers are invisible and `up` recreates instead of starting.
- `build` and `test` always run at the workspace root, but *select* packages by inference: run from inside `src/`, the packages at or below the current directory are chosen, and `--all` overrides. The build command mirrors the team's `cbuild` alias minus `--continue-on-error`, forces no build type, and always exports `compile_commands.json`.
- `colcon test-result` accepts no package selection, unlike every other colcon verb; narrowing happens through `--test-result-base`.
- `bg` stages its script into the container over stdin, runs it under `setsid` so it leads a process group, records its own pid, and logs to `logs/cc/bg-<name>.log` on the host. `stop` sends SIGINT to the group first, which is what ROS 2 expects, and escalates only if ignored.
- Every `docker exec` used inside a loop must redirect stdin from `/dev/null`. Without it, `docker exec -i` consumes the loop's own input and the loop silently processes only its first item; this was a real bug in `bg list`.
- Exit codes propagate. A command stopped by its deadline exits 124, and `run` treats that as success.

### Skills

Six skills under `plugins/dua-claude/skills/`, three with a `reference.md` that is read only when needed. Their descriptions sit in context permanently, at roughly 500 tokens for all six, so they are kept short and sharply scoped.

`dua-workspace` is the always-on one: the invariant, the layout, the terminology, the rules of engagement. `dua-containers` covers resolution, lifecycle, execution modes and troubleshooting. `dua-build-test` covers building, package selection, reading failures and `compile_commands.json`. `dua-runtime` covers running nodes without hanging a session, domain hygiene and hardware caution. `dua-targets` covers `dua_setup.sh`, the `IMAGE SETUP` markers and the fact that unit inclusion is not recursive. `dua-integration` covers submodules versus subtrees.

These have been reviewed and edited by the team; treat their current wording as authoritative over anything a general description of DUA might suggest.

### Hooks

`hooks/hooks.json` registers two, both addressed through `${CLAUDE_PLUGIN_ROOT}`.

`scripts/session-start.sh` runs on `SessionStart`, emits the resolved context as `additionalContext` (about 275 tokens), and emits an empty context outside a DUA project rather than nothing, so no hook error notice appears.

`scripts/guard-host-exec.sh` runs on `PreToolUse` matching `Bash`. It denies `colcon`, `ros2`, `rosdep`, `rviz`, `gz`, `gazebo`, `ament_*` and `rqt*` when they are the first word of a shell segment, and quotes the corrected `dua` form in the denial reason. It exists because `colcon` is sometimes present on a host without a ROS environment, so the mistake does not fail cleanly.

Three properties of the guard are deliberate and should not be "improved" away: it inspects only the first word of each segment, after stripping environment assignments and directory prefixes, so `grep colcon` and `echo "ros2 topic list"` pass; it never fires outside a DUA project; and it **fails open** on unparseable or empty input. A guard that blocks when confused is worse than no guard, because it gets disabled.

### Slash commands and the CLAUDE.md template

`commands/` holds `doctor`, `build`, `test`, `new-target`, `add-unit` and `claude-md`, invoked as `/dua-claude:<name>`. `templates/CLAUDE.md.tmpl` is the structure the `claude-md` command fills in from what is actually in a repository; per-project facts belong there, generic DUA facts belong in the skills.

### Test harness

Four layers. Everything up to the container suite runs with no Docker and no DUA installation.

| Suite | What it is |
| --- | --- |
| `tests/unit/run.sh` | 152 checks. Drives the CLI with a fake `docker` client (`tests/stub/docker`) replaying container records: VS Code containers, Compose containers, label-less containers, stopped, absent, ambiguous, foreign checkouts. Asserts on resolution, on the exact `colcon` and `ros2` command lines, on snapshot stamps, on exit codes |
| `tests/unit/skills.sh` | 66 checks. Frontmatter shape, naming, size, referenced files, no host home paths, and that every `dua` subcommand a skill mentions exists in the CLI |
| `tests/unit/hooks.sh` | 59 checks. Feeds synthetic hook events to both hook scripts; tables of commands that must be denied and must not be |
| `tests/unit/release.sh` | 15 checks. Version, changelog, manifests and install instructions agree |
| `tests/bats/` | 52 tests against a mock DUA container: output cleanliness, snapshot parity against an interactive shell, working directory mapping, lifecycle, workflows, background processes |
| `tests/smoke/on-host.sh` | acceptance test against a real DUA container on a development machine |
| `tests/probe/` | the scripts that established the design empirically; also useful as diagnostics on real development machines |

The mock container (`tests/mock/`) is built from the *genuine* `bashrc`, `aliases.sh`, `commands.sh` and `ros2.sh` of a `dua-template` checkout, with `/opt/ros` and the venv stubbed so the real `ros2init` completes, `colcon` and `ros2` replaced by recording stubs, and Ubuntu's sudo hint left in place because suppressing it is something the plugin must actually do. `tests/fixtures/fixtures.sh` builds DUA-shaped fixture repositories and is shared by both suites.

Fixtures and test data must stay generic. This repository is public and dotX projects are not; an early version leaked real project names into test records.

### CI

`.github/workflows/ci.yaml` on push and pull request: shellcheck and manifest validation, the four offline suites, the container suite against `dua-template` pinned at the hash in `tests/mock/TEMPLATE_REF`, and `claude plugin validate --strict`. GitHub-hosted runners.

`.github/workflows/nightly.yaml` rebuilds the mock against the template's current `master` and runs the container suite against it, reporting which files under `bin/dua-templates/context/` changed if it breaks. The plugin depends on details of the template that are not part of any contract, such as the interactive guard in `bashrc` and what `ros2init` sources, so this is an early warning rather than a test.

---

## Housekeeping

### Installing

```txt
/plugin marketplace add dotX-Automation/dua-claude
/plugin install dua-claude@dotxautomation
```

Then, once per user, in `~/.claude/settings.json`, so Claude does not ask for approval on every call (a plugin cannot ship permission rules):

```jsonc
{ "permissions": { "allow": ["Bash(dua:*)"] } }
```

Verify from any DUA project:

```bash
cd ~/path/to/a/dua/project
dua doctor
```

### Updating

```txt
/plugin marketplace update
```

Because the plugin declares an explicit version, an installation stays where it is until updated. Confirm the version in `/plugin`.

### Changing the plugin and cutting a release

Work from a checkout. Load it without installing:

```bash
git clone git@github.com:dotX-Automation/dua-claude.git
cd dua-claude
claude --plugin-dir ./plugins/dua-claude
```

Then:

1. Make the change. If it touches the snapshot recipe in `lib/exec.sh`, bump `DUA_SNAPSHOT_VERSION` so existing snapshots invalidate.
2. Extend the tests. A change to resolution or command construction belongs in `tests/unit/run.sh`; a change to a skill in `tests/unit/skills.sh`; a change to a hook in `tests/unit/hooks.sh`; anything about real shell behaviour in `tests/bats/`.
3. Run the offline stack, which needs nothing installed: `tests/run-all.sh -q`
4. Run everything, including the container suite, which needs Docker and `bats`: `tests/run-all.sh`
5. If the change could affect a real container, run the acceptance test from inside a DUA project with its container up: `tests/smoke/on-host.sh` (add `-n` to skip the stop and start cycle, `-b` to include a real full build)
6. Update `CHANGELOG.md`: move the entry out of `Unreleased` into a new version section.
7. Bump `version` in `plugins/dua-claude/.claude-plugin/plugin.json`. Patch for fixes, minor for new commands or options, and note breaking changes explicitly since the CLI surface may still move before 1.0.0.
8. Re-run `tests/unit/release.sh`, which fails if the version and the changelog disagree.
9. Commit, tag and push:

    ```bash
    git add -A
    git commit -m "Release 0.1.3"
    git tag v0.1.3
    git push
    git push --tags
    ```

10. Watch CI. Four jobs: lint, offline, container, plugin-validate.
11. Create the GitHub release from the tag.
12. Run `/plugin marketplace update`.

### Running individual suites

```bash
tests/run-all.sh -q            # lint, manifests, and the four offline suites
tests/run-all.sh               # the above plus the mock container and bats
tests/run-all.sh -r master     # build the mock against dua-template's master
tests/unit/run.sh -v           # the offline CLI suite with failure context
tests/unit/skills.sh
tests/unit/hooks.sh
tests/unit/release.sh
bats tests/bats                        # all container tests
bats --print-output-on-failure tests/bats/exec.bats
tests/mock/build.sh -s /path/to/dua-template   # rebuild the mock from a local checkout
tests/smoke/on-host.sh -n      # real container, no lifecycle cycle
```

Diagnostics when something behaves unexpectedly on a machine:

```bash
DUA_TIME=1 dua exec -- true    # resolution and execution timings
dua --trace ctx                # trace resolution
DUA_NO_CACHE=1 dua ctx         # bypass the resolution cache
dua exec --mode ic -- <cmd>    # bypass the environment snapshot
tests/probe/dua-cc-probe.sh -r # full host and container probe, redacted
```

### Moving the pinned template

`tests/mock/TEMPLATE_REF` holds the `dua-template` commit CI builds the mock from. Move it when the template changes something the plugin depends on and the nightly job goes red: verify locally with `tests/run-all.sh -r master`, then write the new SHA into that file so CI becomes deterministic again.

---

## Known limitations and open threads

- Linux is the only supported host OS.
- `dua build --debug` passes `-DCMAKE_BUILD_TYPE=Debug`, which any package setting `CMAKE_BUILD_TYPE` unconditionally in its `CMakeLists.txt` silently overrides. The CLI warns; the fix is in the packages, converting the assignment to `if(NOT CMAKE_BUILD_TYPE)`.
- The `test` invocation is provisional, and may be improved depending on the form of test suites that are implemented.
- `USER_GID` is not a build argument in `dua-template`, so the internal user's gid is whatever `useradd` picked. `dua doctor` reports it as information only, never as a warning, by explicit decision.
- Behavioural evaluation is not built. Nothing yet verifies automatically that Claude *uses* the skills and respects the guard, so take care and check its output.

---

## Working on this productively

Two habits produced most of the value here and are worth keeping.

**Measure before deciding.** Every significant choice in this plugin, from mount-based resolution to the snapshot to the digest, came from probe scripts run on real hosts rather than from reasoning about what Docker and bash probably do. Several turned out to contradict the obvious guess.

**Distrust suites that pass first time.** The bugs that mattered — the poisoned snapshot, the stdin theft in `bg list`, `test-result` rejecting package selection, the one-second timestamp window — were all found by running against something real after the offline tests were green, and each one is now pinned by a test that would have caught it offline.
