---
name: dua-build-test
description: Building and testing a DUA ROS 2 workspace with colcon through the dua command, selecting packages, reading build failures, and using compile_commands.json. Use whenever code in a DUA project needs to be compiled, a build fails, tests need running, or a change to a package should be verified.
---

# Building and testing

```bash
dua build                    # inside src/, the packages found here; at the root, everything
dua build --all              # the whole workspace, wherever you are
dua build my_pkg other_pkg   # named packages
dua build --up-to my_pkg     # that package and its dependencies
dua build --debug my_pkg     # Debug build type
dua build --clean my_pkg     # remove its build/ and install/ first
dua test my_pkg              # colcon test, then the results
```

Builds always run at the workspace root, whatever directory you are in, because that is where colcon must run.

**Which packages get built is inferred from where you are.** Run from inside `src/some_unit/`, `dua build` selects the packages defined at or below that directory and says which ones it picked; run from the workspace root, it selects nothing and builds everything. Use `--all` when a change crosses multiple packages, when dependencies were touched, or when the workspace has never been built.

## Reading a failure

The default output is deliberately compact: a start and end line per package, compiler errors as they happen, and a summary. Do not pass `-v` reflexively; it adds the full compiler stream, which is thousands of lines on a real workspace and rarely tells you more.

When a build fails:

1. Read the error in the output. It is already there, on standard error.
2. If truncated, the whole run is in the log path `dua build` prints, under `logs/cc/`.
3. For per-package detail, read `log/latest_build/<pkg>/stdout_stderr.log` on the host with Read or Grep. No container access needed.

The build stops at the first failing package. `--keep-going` continues with the packages that do not depend on it, which is useful for surveying how much is broken.

## compile_commands.json

Every build exports it, so `build/<pkg>/compile_commands.json` gives you the exact include paths, defines and flags for each translation unit. When you need to resolve where a symbol or header comes from in a C++ package, read that file rather than guessing at include paths. It covers the ROS 2 installation, included libraries, and system headers.

## Tests

`dua test` runs `colcon test` and then prints the results. Package selection applies to the test run; the results report covers the selected package when there is exactly one.

## Linters

No linter is currently configured. Standard ones are available

```bash
dua exec -- ament_uncrustify --reformat src/my_pkg
dua exec -- ament_cpplint src/my_pkg
dua exec -- ament_cppcheck src/my_pkg
dua exec -- ament_flake8 src/my_pkg
dua exec -- ament_lint_cmake src/my_pkg
dua exec -- ament_xmllint src/my_pkg
dua exec -- ament_copyright src/my_pkg
```

**You should never run any of these unless explicitly asked to do so.**

## Things that are easy to get wrong

`--debug` passes `-DCMAKE_BUILD_TYPE=Debug`, but many packages in these repositories set `CMAKE_BUILD_TYPE` unconditionally in `CMakeLists.txt`, which silently overrides it. If a debug build does not behave like one, look at the package's `CMakeLists.txt` before looking anywhere else; you may convert the unconditional assignment to `if(NOT CMAKE_BUILD_TYPE)`.

A successful build changes the environment, since new packages join `AMENT_PREFIX_PATH`. `dua` handles that automatically; you do not need to restart anything.

`tools/` is ignored by colcon on purpose. A package that lives there will never be built by these commands but it may have its own build tooling, e.g. with `make`; if needed, you have to inspect it.

See `reference.md` in this skill directory for the exact commands and the layout of the build tree.
