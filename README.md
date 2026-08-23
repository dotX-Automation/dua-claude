# dua-claude

A [Claude Code](https://code.claude.com) plugin that lets Claude develop inside [DUA](https://github.com/dotX-Automation/dua-template) projects the way a human developer does: editing files on the host, executing builds, tests and ROS 2 nodes inside the project's container.

**Work in progress.**

## Trying it out during development

```txt
claude --plugin-dir ./plugins/dua-claude     # load without installing
tests/unit/run.sh                            # offline suite, no Docker needed
tests/smoke/on-host.sh                       # acceptance test, needs a running DUA container
tests/probe/                                 # host probes used to validate the design
```

---

Copyright 2026 dotX Automation s.r.l. Licensed under the Apache License, Version 2.0.
