# Targets: reference

## What a target directory contains

```txt
docker/container-<TARGET>/
├── Dockerfile                FROM dotxautomation/dua-foundation:<TARGET>, plus the units
├── aliases.sh                general aliases and functions          [mounted live]
├── commands.sh               project commands and functions         [mounted live]
├── ros2.sh                   ros2init and the ROS 2 environment     [mounted live]
├── bashrc                    the bash startup file                  [mounted live]
├── zshrc  p10k.zsh           the interactive shell humans use       [mounted live]
├── dua_submod.sh dua_subtree.sh   git helpers                       [mounted live]
├── colcon-defaults.yaml      packages-ignore for build and test     [mounted live]
├── nanorc  vimrc             editor configuration
├── zsh_history/              persisted shell history
└── .devcontainer/
    ├── docker-compose.yaml   service, image, mounts, devices, network
    └── devcontainer.json     VS Code configuration
```

Files marked as mounted live are bind-mounted into the container: editing them on the host affects the next command entered or the next shell created, with no rebuild. Everything else is baked into the image at build time.

## Adding a command

Shell commands are useful to the human user, and to scripts that run inside the container, to control running software (e.g., calling ROS 2 services or actions with specific inputs).

Append a function to `docker/container-<TARGET>/commands.sh`. It appears in the environment of the next `dua exec`, and in the next shell a human opens. This is the right place for unit- or project-specific helpers, and it needs no rebuild.

## colcon-defaults.yaml

`colcon-defaults.yaml` holds `packages-ignore` lists for build and test, which is how a target excludes packages that cannot be built for that platform.

It is useful on multi-target units/projects, where some packages cannot be built on specific targets (e.g., a package that depends on CUDA cannot build on `x86-dev`).

## What the base image provides

Ubuntu 24.04, ROS 2 Jazzy, Fast DDS, Cyclone DDS and Zenoh, C and C++ toolchains and debuggers, Python 3 in a venv at `/opt/dua-venv`, OpenCV, Eigen, and `dua-utils` under `/opt/ros/dua-utils`. `/etc/dua/target` records which target the image is. Specific hardware SDKs and libraries, e.g. CUDA and Nvidia libraries, on `x86-cudev` and `jetson*`.

The internal user is `neo`, in the `internal` group, with passwordless sudo inside the container. Containers run privileged with the host network and `/dev` and `/sys` mounted, which is deliberate: robotics needs hardware and multicast, not isolation.

## Rebuilding

The user does this, from the target's `.devcontainer` directory or from Visual Studio Code's Remote-Containers extension.

```bash
docker compose build          # after Dockerfile changes
docker compose build --no-cache
docker compose pull           # to refresh the base image first
```

Your part is to say precisely what changed and therefore what needs rebuilding, and to wait for the user to do so.

## Upstream

`dua-template` provides the layout and the setup script, `dua-foundation` the base images. A repository stays in sync with the template through a workflow that opens a pull request when template files change; it deliberately does not touch already-configured target directories, so improvements to the template's shell files do not reach existing targets by themselves: a manual edit, either by your or a human, is necessary.
