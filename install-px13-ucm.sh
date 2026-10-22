#!/bin/bash
# Install the TAS2783 UCM speaker config so WirePlumber gets a HiFi profile for the amd-soundwire card.
set -e
sudo install -Dm644 "$(dirname "$0")/tas2783.conf" /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
systemctl --user restart wireplumber
sleep 2
pactl list short sinks
