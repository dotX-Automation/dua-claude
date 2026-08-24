---
description: Check the DUA project, its container and the host, and explain anything wrong
---

Run `dua doctor` and report what it found.

Explain each finding in plain terms and say what should be done about it. Distinguish clearly between the blockers, which stop work, and the notes, which are informational: a uid or gid difference between the host and the container is a note, not a fault, and needs no action.

If the container is stopped or absent, offer to run `dua up`. If no image is built on this host, say so and stop: building is the user's decision and takes long.
