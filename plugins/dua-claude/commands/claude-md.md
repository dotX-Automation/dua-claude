---
description: Write or update this project's CLAUDE.md from what is actually in the repository
---

Create or update `CLAUDE.md` at the root of this DUA project, using `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.tmpl` as the structure.

Gather the facts from the repository rather than guessing:

- `dua ctx --json` for the role, the configured targets and which image is built
- `src/*/package.xml` for the packages, their dependencies and their descriptions
- launch files, parameter files under `config/`, and the node source for the interfaces the project exposes
- `README.md`, if it says anything a reader would need
- `docker/container-<TARGET>/commands.sh` for project-specific commands worth knowing

Keep it to what is true and durable. Do not restate what the dua-* skills already cover: generic DUA facts belong there, and this file is for what makes *this* project different.

If `CLAUDE.md` already exists, merge rather than overwrite: keep what is still accurate, correct what is stale, and show the user a diff of what you changed before writing.

Reference skills: dua-workspace, dua-targets, dua-containers
