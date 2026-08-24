# DUA containers: reference

## Troubleshooting

| Symptom | Cause | What to do |
| --- | --- | --- |
| `no container is running for <repo>` | the container is down | `dua up` |
| `no container and no image` | never built on this host | ask the user to build it |
| `several containers are bound to` | two containers mount the same repository, usually VS Code plus a manual `docker compose up` | report it unless already know, it might be an edge case the user has to clarify |
| `not inside a DUA project` | the working directory has no ancestor with both `docker/` and `bin/dua_setup.sh` | check where you are, the repository may not be DUA-based, in case either this skill is not needed or you have been started in the wrong folder |
| `colcon: command not found` on the host | the command ran outside the container | prefix it with `dua exec --` |
| `colcon` runs on the host but fails oddly | `colcon` is installed on the host without a ROS environment | prefix it with `dua exec --` |
| a package is not found by a build | the workspace was never built, or the package is under `tools/`, which colcon ignores | `dua build --all` once |
| the environment lacks a function the user says exists | the snapshot predates an edit to `commands.sh` | `dua ctx` shows the snapshot state; the next command rebuilds it |
| a file written in the container is owned by another id on the host | the image was built with a different `USER_UID` than the current user | informational, report it and carry on unless you have to edit that file and lack the necessary permissions |
| `dua` is slow, several seconds per command | the daemon is busy or the host runs many containers | `DUA_TIME=1 dua exec -- true` splits resolution from execution |

## How resolution works

`dua` walks up from the working directory collecting ancestor directories, then inspects every container on the host, running or not, and selects the one with a bind mount whose destination is `/home/neo/workspace` and whose source is one of those ancestors. The innermost match wins, which is what makes a unit nested under a macro-project's `src/` resolve to the macro-project's container.

Names, images and Compose project names are not used for this, because they are unreliable: VS Code renames images to `vsc-container-<target>-<hash>-uid`, and every container started with `docker compose up -d` from a `.devcontainer` directory joins a project literally named `devcontainer`. Compose service labels, devcontainer labels and name matching exist as fallbacks, each revalidated against the mount before use.

Repeated commands reuse the container id remembered for the repository, revalidated with a single inspect. `ctx`, `doctor` and the lifecycle commands always do the full scan, so the two-containers-on-one-repository case is still detected. `DUA_NO_CACHE=1` disables the cache.

## How the environment snapshot works

The container's `~/.bashrc` returns immediately for non-interactive shells, so a plain `bash -c` has no ROS environment. An interactive `bash -ic` has the full environment but costs about 400 ms and prints Ubuntu's sudo hint on standard output.

So the first command in a container captures `export -p`, `declare -f` and `alias -p` from one interactive shell into `/tmp/dua-cc/env.sh`, and every later command sources that from a non-interactive shell. The result is the same environment, measured identical variable for variable and function for function, at about 30 ms and with clean output.

The snapshot is invalidated by: a different container, a container restart, any change to the contents of the mounted configuration files of any configured target, a successful `dua build`, and a new version of the plugin's snapshot recipe. Invalidation is keyed on file contents rather than timestamps, so an edit made in the same second as the snapshot was built is still noticed.

## Environment variables

| Variable | Effect |
| --- | --- |
| `DUA_TIME=1` | print resolution and execution timings to stderr |
| `DUA_DEBUG=1` | trace resolution, same as `--trace` |
| `DUA_NO_CACHE=1` | always do the full container scan |
| `DUA_EXEC_MODE=ic\|snap\|raw` | default execution mode |
| `DUA_DOCKER` | path to the docker client |
