# dua-claude

A [Claude Code](https://code.claude.com) plugin that lets Claude develop inside [DUA](https://github.com/dotX-Automation/dua-template) projects the way a human developer does: editing files on the host, executing builds, tests and ROS 2 nodes inside the project's container.

## How it works

Claude Code runs on the host, in the root of a DUA unit or macro-project. The toolchain, ROS 2 and the project's dependencies live in the project's container, and the repository root is bind-mounted there at `/home/neo/workspace`, so the host view and the container view are the same filesystem. The plugin builds on that: Claude reads, greps and edits with its own tools on the host, and executes everything else in the container through a command line tool the plugin puts on its `PATH`.

The consequence that matters is that nothing about Claude's state lives inside the container. Rebuilding an image, recreating a container or switching targets costs nothing, which is what running Claude Code inside a DUA container never allowed.

The container is found by looking for one that bind-mounts an ancestor of the current directory at the workspace path, walking upwards, so the same lookup works whether the container was started by VS Code Dev Containers or by Compose, and a unit nested under a macro-project's `src/` resolves to the container that owns it. Names, images and Compose project names are not used for this: VS Code renames images, and every container started from a `.devcontainer` directory joins a Compose project literally named `devcontainer`.

Commands run in the same environment a developer gets in an interactive shell, including every function and alias the project defines in its own `commands.sh`, `aliases.sh` and `ros2.sh`. That environment is captured once per container and reused, which costs about 30 ms per command instead of about 400 ms for a fresh interactive shell, and produces no shell startup noise on standard output.

## Requirements

Docker and Git on the host, Claude Code, and a DUA project whose image has been built. Linux is the supported platform. Remote Docker is deliberately unsupported, because `dua exec` would work while Claude's file tools silently edited a different copy of the repository.

## Install

```
/plugin marketplace add dotX-Automation/dua-claude
/plugin install dua-claude@dotxautomation
```

Then add this to your own `~/.claude/settings.json`, so that Claude does not ask for approval on every call. A plugin cannot ship permission rules, so this step is per user.

```jsonc
{ "permissions": { "allow": ["Bash(dua:*)"] } }
```

Check the installation from any DUA project on your machine:

```bash
cd ~/path/to/a/dua/project
dua doctor
```

Updates are pulled with `/plugin marketplace update`. Since the plugin declares a version, an installation stays on the version it has until it is updated.

## The `dua` command

`dua` is on the `PATH` of Claude's Bash tool whenever the plugin is enabled, and you can put it on yours by adding `plugins/dua-claude/bin` to `PATH` from a checkout. Run it from anywhere inside a project; it walks up to find the root.

| Command | What it does |
| --- | --- |
| `dua ctx [--json]` | the resolved context: root, role, targets, container, ids, snapshot state |
| `dua doctor` | preflight checks on the host, the repository and the container |
| `dua exec [OPTS] -- CMD` | run a command in the container, in the mapped working directory |
| `dua up`, `down`, `restart` | container lifecycle; `up` starts an existing container rather than creating a second one |
| `dua build [PKG...]` | colcon build at the workspace root, with `--all`, `--up-to`, `--debug`, `--clean`, `--keep-going`, `-v` |
| `dua test [PKG...]` | colcon test followed by the results |
| `dua run --for D -- CMD` | run under a deadline, streamed and logged |
| `dua bg start\|list\|status\|logs\|stop NAME` | detached processes, logged where the host can read them |
| `dua setup ...` | guarded passthrough to the project's own `bin/dua_setup.sh` |
| `dua pkg new NAME` | `ros2 pkg create` with the project's conventions |

Options common to most commands: `--target T`, `--timeout D` (`--for` reads better on `run`), `--mode snap|ic|raw`, `--domain N`, `--json`, `--trace`, `--time`. Exit codes are those of the command that ran; a command stopped by its deadline exits 124.

Long output is tee'd to `logs/cc/`, which the DUA template already gitignores, so a truncated console never means a lost build log.

## What the plugin adds to Claude

**Six skills**, loaded on demand. `dua-workspace` carries the mental model and the rules of engagement, `dua-containers` covers resolution, lifecycle and execution, `dua-build-test` covers building and reading failures, `dua-runtime` covers running nodes without hanging a session, `dua-targets` covers targets and unit integration, `dua-integration` covers submodules and subtrees. Only their descriptions sit in context permanently, at roughly 500 tokens for all six.

**Two hooks.** A `SessionStart` hook injects the resolved project context, so Claude opens a session already knowing the root, the target, whether the container is up and how host and container ids relate. A `PreToolUse` hook on the Bash tool denies `colcon`, `ros2`, `ament_*` and similar commands run on the host, answering with the corrected `dua` form. The guard inspects only the first word of each shell segment, so `grep colcon` and `echo "ros2 topic list"` pass untouched, it never fires outside a DUA project, and it fails open when it cannot parse its input.

**Six slash commands**: `/dua-claude:doctor`, `:build`, `:test`, `:new-target`, `:add-unit` and `:claude-md`, the last of which writes or updates a project's `CLAUDE.md` from what is actually in the repository.

## Boundaries

Claude may start, stop and restart containers on its own. It may not build images: that takes a long time and is a decision for the person, so the plugin tells it to ask and wait. Git operations are the user's by default; Claude proposes them and waits for approval. The skills also tell it to ask before running anything that commands hardware, since DUA containers are privileged and see the host's devices.

## Testing suite

Four layers, in increasing order of cost and fidelity. Everything up to the container suite runs without a DUA installation of any kind.

**Offline suites**, in `tests/unit/`, need neither Docker nor a container. `run.sh` exercises the CLI end to end by putting a fake `docker` client from `tests/stub/` at the front of `PATH` and feeding it container records that reproduce the shapes seen on real hosts: a VS Code container with a renamed image, a Compose container, a container with no labels at all, stopped containers, two containers on one repository, a container belonging to another checkout. It asserts on resolution, on the exact command lines built for `colcon` and `ros2`, on snapshot invalidation, and on exit codes. `skills.sh` validates every skill statically, including that each `dua` subcommand a skill mentions actually exists in the CLI, so documentation cannot drift from the tool. `hooks.sh` feeds synthetic hook events to the two hook scripts and asserts on the decisions, with a table of commands that must be denied and a table that must not. `release.sh` checks that the version, the changelog, the manifests and the install instructions agree.

**The container suite**, in `tests/bats/`, drives the real CLI against a mock DUA container. The mock is built by `tests/mock/build.sh` from the genuine `bashrc`, `aliases.sh`, `commands.sh` and `ros2.sh` of a `dua-template` checkout, with `/opt/ros` and the virtual environment stubbed so that the real `ros2init` runs to completion, `colcon` and `ros2` replaced by recording stubs, and Ubuntu's sudo hint left in place because it is real output pollution the plugin has to suppress. It covers what a stub cannot: that a command's standard output contains the command's output and nothing else, that the cached environment matches an interactive shell variable for variable and function for function, that the working directory maps correctly, that background processes start, log and stop, and that uid and gid differences are reported without being treated as faults.

**The on-host acceptance test**, `tests/smoke/on-host.sh`, runs against a real DUA container on a development machine. It measures the cost of a command, checks that files written in the container appear on the host with the expected ownership, verifies snapshot invalidation against a real edit, and exercises the stop and start cycle.

**The probes**, in `tests/probe/`, are the scripts that established the design empirically before any of it was written: how containers can be identified, what a non-interactive shell does and does not inherit, what the environment snapshot costs. They double as diagnostics when a colleague's machine behaves unexpectedly.

Run the lot locally with `tests/run-all.sh`, or `tests/run-all.sh -q` for everything that does not need Docker.

Two GitHub Actions workflows: `ci.yaml` runs shellcheck and manifest validation, the offline suites, the container suite against a pinned `dua-template` commit, and `claude plugin validate --strict`; it is what gates merges. `nightly.yaml` rebuilds the mock against the template's current `master` and runs the container suite against it, reporting which files under `bin/dua-templates/context/` changed when something breaks. The plugin depends on details of the template that are not part of any contract, such as the interactive guard in `bashrc` and what `ros2init` sources, so that job is an early warning rather than a test.

## Development

```bash
claude --plugin-dir ./plugins/dua-claude   # load without installing
tests/run-all.sh                           # everything, including the container suite
tests/run-all.sh -q                        # only what needs no Docker
tests/run-all.sh -r master                 # build the mock against the template's master
bats tests/bats/exec.bats                  # one suite
```

```txt
plugins/dua-claude/
├── bin/dua                  entry point
├── lib/                     resolution, execution, lifecycle, workflows
├── skills/                  six skills, some with a reference.md
├── commands/                slash commands
├── hooks/  scripts/         hook registration and the hook programs
└── templates/               the CLAUDE.md template
tests/
├── unit/                    offline suites, no Docker required
├── stub/                    the fake docker client they run against
├── fixtures/                DUA project fixtures shared by both suites
├── mock/                    the mock DUA container
├── bats/                    the container suite
├── smoke/                   on-host acceptance test
└── probe/                   the design probes
```

## Releasing

The plugin uses semantic versioning. To cut a release: update `CHANGELOG.md`, bump `version` in `plugins/dua-claude/.claude-plugin/plugin.json`, run `tests/run-all.sh`, commit, tag `vX.Y.Z` and push the tag. `tests/unit/release.sh` fails if the version and the changelog disagree.

Update installed instances with `/plugin marketplace update`.

---

## Copyright and License

Copyright 2026 dotX Automation s.r.l.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.

You may obtain a copy of the License at <http://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

See the License for the specific language governing permissions and limitations under the License.
