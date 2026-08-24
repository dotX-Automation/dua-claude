# Changelog

All notable changes to `dua-claude` are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

Until 1.0.0 the command line surface may still change between minor versions. Breaking changes are called out explicitly.

## [Unreleased]

## [0.1.0] - 2026-08-24

First release. The plugin lets Claude Code develop inside DUA projects from the host: it edits files with its own tools, and executes builds, tests and ROS 2 nodes inside the project's container.

### Added

- **`dua` command line tool**, on the Bash tool's `PATH` when the plugin is enabled.
  - `ctx`, `doctor` for the resolved project context and preflight checks
  - `exec` for arbitrary commands, with `--timeout`, `--domain` and three execution modes
  - `up`, `down`, `restart` for the container lifecycle
  - `build`, `test` wrapping colcon at the workspace root
  - `run --for` for bounded execution and `bg` for detached processes
  - `setup` as a guarded passthrough to the project's `bin/dua_setup.sh`, and `pkg new`
- **Container resolution by bind mount**, so the same container is found whether it was started by VS Code Dev Containers or by Compose, and a unit nested under a macro-project's `src/` resolves to the container that owns it.
- **Environment snapshot**, capturing the interactive DUA environment once per container and reusing it, so a command costs about 30 ms instead of 400 ms while running in the same environment a developer gets in a shell.
- **Six skills**: `dua-workspace`, `dua-containers`, `dua-build-test`, `dua-runtime`, `dua-targets`, `dua-integration`, three of them with a `reference.md` loaded only when needed.
- **Two hooks**: a `SessionStart` hook that injects the resolved project context, and a `PreToolUse` guard that denies ROS 2 and colcon commands run on the host, quoting the corrected `dua` form.
- **Six slash commands**: `/dua-claude:doctor`, `:build`, `:test`, `:new-target`, `:add-unit`, `:claude-md`, the last of which writes a project's `CLAUDE.md` from what is in the repository.
- **Test harness**: an offline suite that replays container records through a docker stub, a static validator for skills, hooks and slash commands, a bats suite against a mock DUA container built from the genuine `dua-template` shell configuration, and an on-host acceptance test.
- **Continuous integration**: lint, the offline suites and the container suite against a pinned `dua-template` commit, plus a nightly job against the template's `master` that reports which context files changed when the plugin stops working against it.

### Known limitations

- Remote Docker is not supported and will not be: with `DOCKER_HOST` pointing elsewhere, `dua exec` would work while file edits silently went to a different copy of the repository.
- `dua build --debug` passes `-DCMAKE_BUILD_TYPE=Debug`, which packages that set `CMAKE_BUILD_TYPE` unconditionally in their `CMakeLists.txt` will override.
- The `test` invocation is provisional: test suites and fixtures are not yet set up in most units.

[Unreleased]: https://github.com/dotX-Automation/dua-claude/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dotX-Automation/dua-claude/releases/tag/v0.1.0
