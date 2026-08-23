# Mock DUA container for the integration test suite.
#
# It is not a small dua-foundation: it reproduces only what the plugin actually
# depends on, so the suite runs on a GitHub-hosted runner in seconds.
#
#   - internal user neo, with UID and GID as build arguments, in the sudo group
#   - Ubuntu's /etc/bash.bashrc sudo hint, which is real output pollution
#   - /etc/dua/target
#   - the genuine bashrc, aliases.sh, commands.sh, ros2.sh, dua_submod.sh and
#     dua_subtree.sh from a dua-template checkout, unmodified
#   - stubs for /opt/dua-venv and /opt/ros/jazzy, so the real ros2init succeeds
#   - recording stubs for colcon and ros2
#   - the workspace mount point and the sleeping command DUA containers run
#
# Build it with tests/mock/build.sh, which stages the template files.
#
# Copyright 2026 dotX Automation s.r.l.
# SPDX-License-Identifier: Apache-2.0

FROM ubuntu:24.04

ARG USER_UID=1000
ARG USER_GID=1000
ARG TARGET=x86-cudev

ENV DEBIAN_FRONTEND=noninteractive

# procps for the `ps -p $$` in ros2.sh, sudo because the hint only prints when
# sudo exists and the user is in the sudo group.
RUN apt-get update && \
  apt-get install -y --no-install-recommends bash sudo procps ca-certificates && \
  rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a user at UID 1000; remove whoever holds the requested ids.
RUN if getent passwd ${USER_UID} >/dev/null; then \
  userdel -r "$(getent passwd ${USER_UID} | cut -d: -f1)" 2>/dev/null || true; \
  fi; \
  if ! getent group ${USER_GID} >/dev/null; then groupadd -g ${USER_GID} neo; fi; \
  if ! getent group internal >/dev/null; then groupadd -g 999 internal || groupadd internal; fi; \
  useradd -m -s /bin/bash -u ${USER_UID} -g ${USER_GID} -G sudo,internal neo && \
  printf 'Defaults !fqdn\nneo ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/neo && \
  chmod 0440 /etc/sudoers.d/neo

RUN mkdir -p /etc/dua /opt/dua-venv/bin /opt/ros/jazzy \
  /usr/share/colcon_argcomplete/hook /home/neo/workspace /mnt/remote && \
  echo "${TARGET}" > /etc/dua/target

COPY stubs/activate /opt/dua-venv/bin/activate
COPY stubs/ros-setup.bash /opt/ros/jazzy/setup.bash
COPY stubs/colcon-argcomplete.bash /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash
COPY stubs/colcon /usr/local/bin/colcon
COPY stubs/ros2 /usr/local/bin/ros2

# Unmodified from dua-template, staged by build.sh.
COPY template/bashrc /home/neo/.bashrc
COPY template/aliases.sh /home/neo/.aliases.sh
COPY template/commands.sh /home/neo/.commands.sh
COPY template/ros2.sh /home/neo/.ros2.sh
COPY template/dua_submod.sh /home/neo/.dua_submod.sh
COPY template/dua_subtree.sh /home/neo/.dua_subtree.sh

RUN chmod +x /usr/local/bin/colcon /usr/local/bin/ros2 && \
  chown -R ${USER_UID}:${USER_GID} /home/neo /mnt/remote && \
  chmod -R g+rw /opt/dua-venv

USER neo
ENV HOME=/home/neo
WORKDIR /home/neo/workspace

CMD ["/bin/bash", "-c", "trap 'exit 0' TERM; sleep infinity & wait"]
