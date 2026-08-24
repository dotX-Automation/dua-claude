---
name: dua-workspace
description: How to work in a DUA project (Distributed Unified Architecture, dotX Automation). Read this before doing anything in a repository that has a docker/container-*/ directory and bin/dua_setup.sh, or whenever a task involves ROS 2 packages, colcon, a DUA unit or a DUA container. Explains the split between editing on the host and executing in the container, the repository layout, and the dua command.
---

# Working in a DUA project

DUA is dotX Automation's project framework: a repository layout plus a Docker container that carries the toolchain, ROS 2, and the project's dependencies. You are running on the host, outside that container.

## The one rule

**Edit on the host. Execute in the container.**

The repository root is bind-mounted inside the container at `/home/neo/workspace`, so both views are the same filesystem. A file you edit with Edit or Write is immediately visible to a build running in the container, and a file a build writes is immediately visible to you.

| Do this on the host | Do this in the container, through `dua` |
| --- | --- |
| Read, Grep, Glob, Edit, Write | `colcon build`, `colcon test` |
| `git`, including submodules and subtrees | `ros2` anything, running nodes, launch files |
| Reading build logs and `compile_commands.json` | `ament_*` linters, gdb, valgrind |
| `dua_setup.sh`, container lifecycle | anything that needs ROS or the project's dependencies |

Never run `colcon` or `ros2` directly on the host. `colcon` may even be on the host's `PATH` without any ROS environment, in which case it runs and fails in confusing ways instead of failing cleanly.

Never edit files inside the container with `docker exec`. The container's copy of the workspace is the host's copy, so there is nothing to gain and the edit bypasses your own tooling.

Never hand-write `docker exec`. Use `dua exec`, which resolves the right container, maps the working directory and reproduces the environment a human developer gets.

## The dua command

`dua` is on your PATH. Run `dua --help` for the full surface. Run it from anywhere inside the repository; it walks up to find the project root.

```bash
dua ctx                                  # what is resolved: repo, target, container, snapshot
dua doctor                               # check the host, the repository and the container
dua exec -- <command>                    # run a command in the container
dua build [PKG...]                       # colcon build, at the workspace root
dua test [PKG...]                        # colcon test, then the results
dua run --for 20s -- <command>           # run under a deadline
dua bg start NAME -- <command>           # run detached, logged
dua up | dua down | dua restart          # container lifecycle
```

Start with `dua ctx` when you arrive in a project you have not seen this session. If anything looks wrong, `dua doctor` explains it.

If `dua` reports that the container is not running, run `dua up`. If it reports that no image is built, **stop and ask the user**: building an image can take tens of minutes and is their decision, never yours.

## Repository layout

```
<repo root>/
├── bin/dua_setup.sh          creates and modifies targets (see the dua-targets skill)
├── config/                   project-wide configuration
├── docker/container-<TARGET>/
│   ├── Dockerfile            the image for this target
│   ├── aliases.sh commands.sh ros2.sh bashrc zshrc   live-mounted into the container
│   └── .devcontainer/docker-compose.yaml
├── logs/                     experiment data and dua's own logs; entirely gitignored
├── src/                      the ROS 2 workspace: packages, and nested DUA units
└── tools/                    third-party code, ignored by colcon
```

A **unit** is a repository holding one package or a small set of them. A **macro-project** is a repository that contains other units under `src/`, integrating them into one control architecture. A **target** is one Docker image, named after the platform it is built for, such as `x86-dev`, `x86-cudev` or `armv8-dev`.

If the session started inside a unit that is nested in a macro-project, `dua ctx` says so. In that case the container belongs to the macro-project, and builds cover the whole workspace unless packages are selected.

The shell configuration files under `docker/container-<TARGET>/` are mounted live into the container. Editing `commands.sh` to add a project command takes effect in the next command you run, with no rebuild. Editing the `Dockerfile` does not: that needs an image rebuild, which is the user's decision.

## Files and ownership

Build artifacts land in `build/`, `install/` and `log/` at the workspace root, written by the container but visible on the host. They are gitignored. Read them freely: `log/latest_build/<pkg>/stdout_stderr.log` is usually the fastest way to understand a build failure.

`dua` writes its own logs to `logs/cc/`, which is gitignored too. Long commands are tee'd there, so when output is truncated the full text is still on disk.

`dua ctx` and `dua doctor` report the host's uid and gid alongside the container's. A difference is informational, not a problem to fix: files written in the container simply carry those ids on the host. Do not treat it as an error, and do not try to chown things.

## When something looks broken

Run `dua doctor` first and read what it says. Most surprises come from one of: the container is stopped, the image was never built on this host, the workspace looks empty because the build has not run yet, or a command was run on the host instead of in the container.

For details on any of this, other skills go deeper: `dua-containers` for resolution and lifecycle, `dua-build-test` for building and testing, `dua-runtime` for running nodes, `dua-targets` for creating and changing targets, `dua-integration` for submodules and subtrees.
