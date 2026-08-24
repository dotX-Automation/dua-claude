---
name: dua-runtime
description: Running executables, ROS 2 nodes, launch files, and bags inside a DUA container without hanging the session, using deadlines and background processes, and inspecting a running system with ros2 topic, node, service, and action. Use whenever something has to be executed and observed rather than only compiled, or when checking whether a node behaves correctly.
---

# Running things

A ROS 2 node does not exit. Running one in the foreground blocks until a tool timeout, produces nothing useful, and leaves you with no way to inspect it. Never do it.

There are exactly two right ways.

## A bounded run, when you want the output

```bash
dua run --for 20s -- ros2 run my_pkg my_node
dua run --for 20s -- ros2 launch bringup_pkg bringup.launch.py
dua run --for 5s  -- ros2 topic echo /camera/image_raw --once
```

The process is killed at the deadline and that counts as success, not failure. Output is streamed and also written to `logs/cc/`, so nothing is lost to truncation. Use this to see startup output, to check that a node comes up without errors, or to sample a topic.

## A background process, when you want to interact with it

```bash
dua bg start bringup -- ros2 launch bringup_pkg bringup.launch.py
dua bg status bringup
dua bg logs bringup -n 50
dua bg stop bringup
```

The process runs detached with the full DUA environment, logging to `logs/cc/bg-<name>.log` on the host, which you can also Read or Grep directly. `dua bg stop` sends SIGINT to the whole process group first, which is what ROS 2 nodes and launch files expect for a clean shutdown, and escalates only if that is ignored.

**Always stop what you start.** A forgotten node keeps publishing, holds hardware and confuses the next thing you or the user run. Check with `dua bg list` before finishing a task.

Give processes names that say what they are: `bringup`, `camera`, `localization`. Starting a second process under a name already running is refused.

## Inspecting

```bash
dua exec -- ros2 node list
dua exec -- ros2 topic list -t
dua exec --timeout 10s -- ros2 topic hz /odom
dua exec -- ros2 topic info /odom --verbose
dua exec --timeout 5s -- ros2 topic echo /odom --once
dua exec -- ros2 param list /my_node
dua exec -- ros2 service list
dua exec -- ros2 action list
```

Add `--timeout` to anything that might wait forever: `ros2 topic echo` without `--once` never returns, and neither does `ros2 topic hz`.

## Domain and middleware

Containers run with `network_mode: host`, so every DUA container on the machine shares the network. Nodes in different projects on the same `ROS_DOMAIN_ID` will discover each other, which is occasionally what you want unless you are working against software that runs in another container (made possible by DUA, usually clarified by the user).

The default domain is 0. `dua exec --domain N` overrides it for a single command, which is the polite way to avoid colliding with something the user is running. Ask before changing anything globally.

`RMW_IMPLEMENTATION` defaults to `rmw_fastrtps_cpp`. Cyclone DDS and Zenoh are available in the images. `cyclonedds-configure eth0 wlan0` is a function that tells Cyclone which interface to use, required when using it and having to communicate with other hosts. `zenohd` configuration files are usually kept under `config/zenoh`; the `zenohd` executable is in the PATH and should be preferred over `rmw_zenohd` due to its full set of functionalities; one Zenoh router instance per host is enough and should be started as a background process unless one is found to be already active.

Do not change the middleware without being asked, it affects everything else running on the host; infer the current middleware configuration.

## Bags

The images provide a `ros2bag` function that wraps recording and playback with the project's conventions:

```bash
dua bg start recording -- ros2bag record topics.txt my_run 100000000
dua bg start playback -- ros2bag play logs/my_run --clock-rate 10 <any other play option>
```

Bags belong under `logs/`, which is gitignored.

Recording starts immediately and runs until stopped, so a background process is required. `topics.txt` denotes the name of a text file which must contain the list of fully qualified topic names to record, one per line. The second argument is the name of a directory, created in `logs/`, which will contain the bag. The last argument is the max cache size, for which 100 MB is a good default.

Playing with `ros2bag` waits for a keypress before starting: you either provide one or use the following form which is what the command does internally:

```bash
dua bg start playback -- ros2 bag play logs/my_run --clock 10 --wait-for-all-acked 5000 <any other play option>
```

Unless looping is configured, playback stops when the bag ends.

## Hardware

These containers are privileged and see the host's devices. A node that talks to a real camera, radio or vehicle can act on hardware. Before running anything that commands a robot, arms a vehicle or drives an actuator, ask the user. Reading topics is safe; publishing to them may not be, as well as calling services or actions. The user may have a safety interlock, a kill switch, or a remote operator that can override your commands. Always ask before doing anything that could be unsafe. The user may give you permission once and forever in a session to act freely, if clearly stated.
