#!/bin/bash
# Install the patched tas2783 module (built by build-px13-tas2783-module.sh) into updates/,
# where it overrides the in-tree one. Rebuild and reinstall after every kernel update.
set -e
KVER=$(uname -r)
SRC="$(dirname "$(readlink -f "$0")")/tas2783-patched/snd-soc-tas2783-sdw.ko"
[ -f "$SRC" ] || { echo "ERROR: $SRC missing, run ./build-px13-tas2783-module.sh first"; exit 1; }
MODVER=$(/usr/sbin/modinfo -F vermagic "$SRC" | cut -d' ' -f1)
[ "$MODVER" = "$KVER" ] || { echo "ERROR: module is built for $MODVER, running $KVER; rebuild it"; exit 1; }
sudo install -Dm644 "$SRC" /lib/modules/$KVER/updates/snd-soc-tas2783-sdw.ko
sudo depmod -a
/usr/sbin/modinfo -n snd-soc-tas2783-sdw
echo "Reboot to load it, then test: speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -s 1 (and -s 2)"
