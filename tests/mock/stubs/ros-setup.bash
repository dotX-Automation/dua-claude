# Stub of /opt/ros/jazzy/setup.bash: exports what a real ROS 2 setup would, so
# the genuine ros2.sh from dua-template runs to completion without a real ROS.
export AMENT_PREFIX_PATH="/opt/ros/jazzy${AMENT_PREFIX_PATH:+:${AMENT_PREFIX_PATH}}"
export COLCON_PREFIX_PATH="/opt/ros/jazzy"
export PATH="/opt/ros/jazzy/bin:${PATH}"
export PYTHONPATH="/opt/ros/jazzy/lib/python3.12/site-packages${PYTHONPATH:+:${PYTHONPATH}}"
export ROS_VERSION=2
export ROS_PYTHON_VERSION=3
