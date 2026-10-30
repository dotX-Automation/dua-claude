# Building and testing: reference

## What dua actually runs

Build, at `/home/neo/workspace`:

```txt
colcon build --symlink-install --event-handlers status- desktop_notification- \
  [--continue-on-error] \
  [--packages-select PKG... | --packages-up-to PKG...] \
  [--cmake-force-configure] \
  --ament-cmake-args '-DCMAKE_EXPORT_COMPILE_COMMANDS=On'
```

with `-DCMAKE_BUILD_TYPE=Debug` added for `--debug`. No build type is forced otherwise: the packages decide. This mirrors the `cbuild` alias minus `--continue-on-error`, which `--keep-going` puts back.

`-v` swaps the event handlers for `console_direct+ status- desktop_notification-`, the full stream a developer sees in a terminal.

Test:

```bash
colcon test --return-code-on-test-failure --event-handlers status- desktop_notification- [selection]
colcon test-result [--test-result-base build/<pkg>] --all --verbose
```

`colcon test-result` takes no package selection, unlike every other colcon verb; narrowing happens through the result base. Passing `--packages-select` to it is an error.

## Clean

`dua build --clean PKG` removes `build/<pkg>` and `install/<pkg>`. `dua build --clean --all` removes `build/`, `install/` and `log/` entirely and runs `py3clean`. Neither touches `logs/`, which is DUA's own directory for experiment data.

## Creating a package

```bash
dua pkg new my_pkg --deps "rclcpp std_msgs" --node my_node        # ament_cmake by default
dua pkg new my_pkg --python --deps "rclpy std_msgs"               # ament_python
dua pkg new my_pkg --library my_library --deps "rclcpp std_msgs"  # ament_cmake library-only package
```

It runs `ros2 pkg create` with `--package-format 3` into `src/`, taking the maintainer name and email from the host's git configuration. The result is on the host immediately.

Dependencies must be listed in alphabetical order.

## The build tree

| Path | Contents |
| --- | --- |
| `build/<pkg>/` | intermediate objects, `compile_commands.json`, CMake cache |
| `build/<pkg>/Testing/Temporary/LastTest.log` | ctest output for the last run |
| `install/<pkg>/` | installed artifacts; `install/setup.bash` sources the whole workspace |
| `log/latest_build/<pkg>/stdout_stderr.log` | the complete output of the last build of that package |
| `log/latest_test/` | the same for tests |
| `logs/cc/` | the logs dua writes for builds, tests, runs and background processes |

All of these are readable from the host with your normal tools. Prefer that over `dua exec -- cat`.
