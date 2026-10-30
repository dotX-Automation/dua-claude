---
description: Add another DUA unit to this project as a dependency
argument-hint: "[unit name or repository URL]"
---

Help the user integrate another DUA unit into this project: $ARGUMENTS

Work through it in order, checking with the user at each step that needs a decision.

1. Determine how this repository includes units already: a `.gitmodules` file at the root means submodules, its absence with units under `src/` means subtrees. Follow the existing convention unless told otherwise.
2. Bring the code in under `src/` with the appropriate git command, on the host; ask the user for approval before running git commands.
3. Check whether the unit has build steps of its own, in `docker/container-<TARGET>/Dockerfile` inside the unit. If it does, it must be integrated into this project's target with `dua setup modify -a`, listing its own dependencies explicitly.
4. If step 3 applied, tell the user the image needs rebuilding, and stop there. Otherwise run `dua build` to check the workspace still builds.
5. Remind the user to commit, including the submodule reference if one was added.

Reference skills: dua-targets, dua-integration
