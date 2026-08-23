# dua-claude

A [Claude Code](https://code.claude.com) plugin that lets Claude develop inside [DUA](https://github.com/dotX-Automation/dua-template) projects the way a human developer does: editing files on the host, executing builds, tests and ROS 2 nodes inside the project's container.

**Work in progress.**

## Trying it out during development

```txt
claude --plugin-dir ./plugins/dua-claude   # load without installing
tests/run-all.sh                           # everything: lint, offline suite, container suite
tests/run-all.sh -q                        # lint and offline suite only, no Docker needed
tests/run-all.sh -r master                 # build the mock against the template's master
```

The offline suite (`tests/unit/run.sh`) replays container records captured from real hosts through `tests/stub/docker`, so it needs no daemon. The container suite (`tests/bats/`) drives the real CLI against a mock DUA container built by `tests/mock/build.sh` from the genuine `dua-template` shell configuration, with `/opt/ros` and the venv stubbed and `colcon` and `ros2` replaced by recording stubs. `tests/smoke/on-host.sh` is the acceptance test against a real DUA container, and `tests/probe/` holds the host probes used to validate the design.

---

Copyright 2026 dotX Automation s.r.l. Licensed under the Apache License, Version 2.0.
