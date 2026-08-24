---
name: dua-containers
description: Resolving, starting, stopping and executing inside a DUA project's container. Use when a dua command reports no container, a stopped container or several containers, when a command needs to run inside the container, when the environment inside a command looks wrong, or when deciding whether a change needs a container restart or an image rebuild.
---

# DUA containers

Every DUA project has one container per target, and one target is active per project on a given host (except rare special cases, e.g. the need for hardware emulation, of which the user will inform you). `dua` finds it by looking for a container that bind-mounts the repository root at `/home/neo/workspace`, which works whether the container was started by VS Code or by Compose.

## Running commands

```bash
dua exec -- colcon list                       # arguments are quoted for you
dua exec "ros2 topic list | grep camera"      # a single argument is a shell command string
dua exec --timeout 30s -- <command>           # exit 124 when the deadline passes
dua exec --domain 7 -- ros2 topic list        # override ROS_DOMAIN_ID for this command
```

The working directory is mapped: run `dua exec -- pwd` from `src/my_unit` and you get `/home/neo/workspace/src/my_unit`. Relative paths behave as you expect.

The environment is the one a developer gets in an interactive shell: ROS 2 sourced, the workspace's `install/local_setup.*` sourced when it exists, a Python venv active, and every function and alias from the project's `commands.sh`, `aliases.sh` and `ros2.sh`. That includes project-specific commands, so if a repository defines a `takeoff` function you can call it.

The Python venv, named `dua-venv`, is usable and freely extendable with `pip` and similar tools. It is created in the base images using the same Python version as the ROS 2 installation and including many common packages and dependencies; it extends the system environment, to maintain compatibility with distro-installed Python packages that are either part of the base image (e.g. of JetPack) or part of large automated installations which require specific version (e.g. ROS 2). Compatibility errors caused by this should be reported to the user, which will suggest further actions.

Exit codes propagate. Standard input is forwarded, so `echo data | dua exec -- some-tool` works.

## When there is no container

`dua exec` refuses and tells you which case you are in.

- Stopped: run `dua up`, which starts the existing container rather than creating a second one.
- Absent but the image exists: `dua up` creates it with Compose.
- Absent and no image: **stop and ask the user.** Building takes long and is their call.
- Several containers bound to one repository: a host misconfiguration or a specific edge case the user should inform you about. `dua` lists them and refuses to guess. Tell the user; do not stop containers on your own initiative.

## Lifecycle

```bash
dua up          # start: an existing container if there is one, otherwise Compose
dua down        # stop, keeping the container
dua restart     # stop and start
```

In general, relevant containers are already active when you are called into action. You may start, stop and restart when needed. You may not build images without asking.

`dua down` stops the container directly rather than going through Compose, because containers started from a `.devcontainer` directory all share the Compose project name `devcontainer`, so a Compose-level teardown can reach unrelated projects. Do not work around this with `docker compose down`.

## What a change requires

| Changed | What to do |
| --- | --- |
| Anything under `src/` | `dua build` |
| `docker/container-<T>/{aliases,commands,ros2}.sh`, `bashrc` | nothing, they are live-mounted and take effect next command |
| `docker/container-<T>/.devcontainer/docker-compose.yaml` | `dua down && dua up` |
| `docker/container-<T>/Dockerfile`, or adding units with `dua setup` | image rebuild: ask the user |

## Execution modes

The default mode caches the interactive environment inside the container and reuses it, which costs about 30 ms per command instead of 400 ms. `dua ctx` reports whether that snapshot is `fresh`, `stale` or `absent`; a stale one is rebuilt automatically on the next command.

Two other modes exist for when the default is in question. `--mode ic` runs a genuine interactive shell, slower but the reference behaviour; if a command works under `--mode ic` and not by default, say so, because that is a plugin bug worth reporting. `--mode raw` runs a bare shell with no DUA environment at all.

See `reference.md` in this skill directory for the troubleshooting matrix and the details of how resolution and the snapshot work.
