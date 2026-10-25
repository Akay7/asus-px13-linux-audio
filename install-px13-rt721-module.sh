#!/bin/bash
# Install the patched rt721-sdca module (built by build-px13-rt721-module.sh) into updates/,
# where it overrides the in-tree one. Rebuild and reinstall after every kernel update.
set -e
KVER=$(uname -r)
SRC="$(dirname "$(readlink -f "$0")")/rt721-patched/snd-soc-rt721-sdca.ko"
[ -f "$SRC" ] || { echo "ERROR: $SRC missing, run ./build-px13-rt721-module.sh first"; exit 1; }
MODVER=$(/usr/sbin/modinfo -F vermagic "$SRC" | cut -d' ' -f1)
[ "$MODVER" = "$KVER" ] || { echo "ERROR: module is built for $MODVER, running $KVER; rebuild it"; exit 1; }
sudo install -Dm644 "$SRC" /lib/modules/$KVER/updates/snd-soc-rt721-sdca.ko
sudo depmod -a
/usr/sbin/modinfo -n snd-soc-rt721-sdca
echo "Reboot to load it"
