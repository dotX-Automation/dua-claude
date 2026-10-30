---
description: Create a new DUA target for this project
argument-hint: "[TARGET] [-a unit1,unit2]"
---

Help the user create a new target with `dua setup create`.

First run `dua ctx` to see which targets already exist. Ask for anything you need that was not given: the project name as it should appear in the image tag, the target platform, and which units under `src/` should be integrated.

Valid targets are the base image names: x86-base, x86-dev, x86-cudev, armv8-base, armv8-dev, jetson6, jetson5, jetsonnano, jetsontx2.

Before running anything, state what will change and what will follow. Unit inclusion is not recursive, so every dependency must be listed explicitly and in dependency order. After the command succeeds, remind the user that the image has to be built before the target can be used, and that the changes should be committed. Do not build the image yourself.

Reference skills: dua-containers, dua-integration, dua-targets
