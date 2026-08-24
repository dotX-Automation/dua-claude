---
name: dua-targets
description: Creating, modifying and deleting DUA targets with dua_setup.sh, integrating units into a target's Dockerfile through the IMAGE SETUP markers, and knowing when an image rebuild is required. Use when a project needs a new target, when a unit must be added to or removed from a target, or when the Dockerfile or compose file of a target has to change.
---

# Targets

A target is one Docker image for one platform, living in `docker/container-<TARGET>/`. The valid names come from the base images in `dua-foundation`: `x86-base`, `x86-dev`, `x86-cudev`, `armv8-base`, `armv8-dev`, `jetson6`, `jetson5`, `jetsonnano`, `jetsontx2` (up to `jetson5` they are in active use, the latter ones are legacy targets which are no longer maintained). Development machines use `x86-dev`, `x86-cudev` (Nvidia GPU present) and `armv8-dev` (Mac with Apple Silicon). The others are for deployment on the target hardware.

A repository may have several targets configured while only one is built and running on a given host. That is normal.

## Operating on targets

```bash
dua setup create [-a UNIT1,UNIT2] NAME TARGET
dua setup modify [-a UNIT1,UNIT2] [-r UNIT1,UNIT2] TARGET
dua setup clear TARGET
dua setup delete TARGET
```

`dua setup` is a thin guard around the project's own `bin/dua_setup.sh`: it forces the repository root as the working directory and reminds you what follows. The script itself belongs to the project, is committed, and is the same one the team runs by hand.

**Everything here changes the Dockerfile, which means the image must be rebuilt before the change has any effect.** Rebuilding takes tens of minutes. Never start one on your own initiative: tell the user what needs rebuilding and let them decide when; they usually want to do it in person in a separate terminal, so you should wait for them to perform this step.

After any `dua setup` run, the changes must be committed. Say so; do not commit on the user's behalf unless asked.

## Creating units

If you are working within a unit (i.e. not a macro-project), you can create targets for it: use `dua setup create <UNIT NAME> <TARGET>` to create a target for the unit.

The rationale for units is that they contain software, usually in the form of ROS 2 packages, that performs a specific function and can be reused in a multiplicity of contexts. To be self-contained, a unit must include everything it needs to build and run, in the form of

* dependencies, hence the Dockerfiles in the target folders, explained below;
* code, usually in `src/` as ROS 2 packages;
* configuration: "system-wide" files go in `config/`, each target may get a different set of environment variable (from the default and/or the other targets) given by the contents of its shell configuration files in `docker/container-<TARGET>/`, ROS 2 nodes have launch and parameter files in their directories under `src/`;
* tooling, as executables in `bin/` and thirdparty/extra stuff in `tools/`;
* commands available inside containers to operate the software, in each `docker/container-<TARGET>/commands.sh` and `aliases.sh`.

To configure dependencies for a unit, if need be given the extensive set of software already available in DUA base units, you can modify each target's Dockerfile

```dockerfile
# IMAGE SETUP START #
# my_unit START #
# Example of a unit's own build steps
RUN wget -O [...] && \
  cmake [...] && \
  make [...] && \
  make install [...]
# my_unit END #
# IMAGE SETUP END #
```

**You must always follow these guidelines when editing Dockerfiles:**

* Keep the `# IMAGE SETUP START #` and `# IMAGE SETUP END #` markers intact. They are used by `dua_setup.sh` to locate the section of the Dockerfile that is rewritten when units are added or removed.
* Always add the unit's own build steps between the `# my_unit START #` and `# my_unit END #` markers, and do not edit the rest of the Dockerfile unless a very specific, nonstandard technical edit is required to make things work.
* Respect the indentation of multiple commands over multiple lines, using `\` at the end of each line except the last; you may also split commands with many options (e.g. `cmake`) over multiple lines and different, two-spaces tabs indentation levels.
* Keep the build steps as compact as possible, try to condense operations into a single `RUN` command, and avoid creating unnecessary intermediate files or layers. This helps reduce the final image size and build time.

## Integrating units

When working on a macro-project, you may need to integrate several units into a target; units are found under `src/` as submodules or subtrees and must already be present (see the `dua-integration` skill).

A unit is added to a macro-project's target by copying the unit's own build steps into the target's Dockerfile, between markers. This is done by `dua setup modify -a my_unit_one,my_unit_two,my_unit_three <TARGET>` to add a unit, or even by `dua setup create -a my_unit_one,my_unit_two,my_unit_three <TARGET>` to create a new target with several units at once. The script edits the target's Dockerfile, the resulting section looks like this.

```dockerfile
# IMAGE SETUP START #
# my_unit_one START #
RUN echo my_unit_one
# my_unit_one END #
# my_unit_two START #
RUN echo my_unit_two
# my_unit_two END #
# my_unit_three START #
RUN echo my_unit_three
# my_unit_three END #
# IMAGE SETUP END #
```

It is also possible to remove a unit from a target with `dua setup modify -r my_unit <TARGET>`, which deletes the unit's block from the Dockerfile.

If a macro-project requires specific build steps for itself, it is possible to manually edit target's Dockerfiles, resulting in the following.

```dockerfile
# IMAGE SETUP START #
# my_unit_one START #
RUN echo my_unit_one
# my_unit_one END #
# my_unit_two START #
RUN echo my_unit_two
# my_unit_two END #
# my_project START #
RUN echo my_project
# my_project END #
# IMAGE SETUP END #
```

Dockerfile editing rules must be followed for projects as well as for units.

Two aspects to keep in mind.

**Inclusion is not recursive.** Adding `my_unit` brings in only the block marked `my_unit`, not the dependencies that unit itself integrates. If `my_unit` needs `dep_one` and `dep_two`, all three must be listed explicitly, in dependency order (never needed in practice because units are self-contained and projects do not go beyond one level of nesting).

**Order is the order you give.** With several units in one `-a`, the section is rewritten containing exactly those units in that sequence. With a single unit, it is appended or replaced in place. So `-a dep_one,dep_two,my_unit` is not the same as three separate calls.

If a unit's block already exists in this target's Dockerfile and you list it among several, the existing version is kept rather than re-copied from the unit's own Dockerfile. That is deliberate: it preserves local adjustments. To pull the unit's current version instead, add it alone.

## Editing a target by hand

Adding a dependency to an existing target usually means editing `docker/container-<TARGET>/Dockerfile` directly, inside that target's own marked block. Keep the markers intact; `dua_setup.sh` relies on them.

The compose file at `docker/container-<TARGET>/.devcontainer/docker-compose.yaml` is where devices, environment variables and mounts are declared. A change there needs `dua down && dua up` or a container rebuild in case of breaking changes like new mounts.

`USER_UID` in the compose build arguments controls the uid of the internal user, and `dua_setup.sh` writes `1000` by default. On a host whose user is not 1000, files written by the container carry the wrong owner until it is corrected and the image rebuilt. Report the mismatch, propose the edit, leave the rebuild to the user, and note that **the change should not be pushed since it is host-specific**.

See `reference.md` in this skill directory for what a target directory contains and what each file does.
