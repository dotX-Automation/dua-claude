---
description: Build the DUA workspace, or the packages in the current directory, and triage failures
argument-hint: "[package...] [--all] [--debug] [--clean]"
---

Build the project with `dua build $ARGUMENTS`.

Remember that with no package arguments the packages found at or below the current directory are selected, and `--all` builds the whole workspace.

If the build succeeds, say so briefly with the packages that were built.

If it fails, do not paste the whole log. Read the error, then read `log/latest_build/<pkg>/stdout_stderr.log` for the failing package if you need more, identify the root cause, and propose a fix. Distinguish a compilation error in the project's own code from a missing dependency, which may instead need a unit integrated into the target and an image rebuild.

Reference skill: dua-build-test
