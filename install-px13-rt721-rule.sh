#!/bin/bash
# Install the udev rule that keeps the RT721 jack codec from runtime-suspending (kernel 7.3 resume bug).
# Takes effect on the next boot: once the codec is stuck in suspend, only a reboot brings it back.
set -e
sudo install -Dm644 "$(dirname "$0")/90-px13-rt721-no-autosuspend.rules" /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules
sudo udevadm control --reload
echo "Reboot, then check: cat /sys/bus/soundwire/devices/sdw:0:1:025d:0721:01/power/runtime_status   # active"
