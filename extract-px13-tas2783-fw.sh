#!/usr/bin/env bash
set -euo pipefail

# ASUS ProArt PX13 HN7306 TAS2783 firmware extraction
# Downloads official ASUS TI SmartAmp DCH driver, extracts the
# 1714-1-8.bin / 1714-1-B.bin blobs the kernel needs, installs them.

WORK=/tmp/px13-tas2783
URL="https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/Audio/47519/SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe?model=HN7306EAC"

mkdir -p "$WORK"
cd "$WORK"

echo "==> Downloading ASUS TI SmartAmp driver (4.3 MB)..."
curl -fL -A "Mozilla/5.0" -o smartamp.exe "$URL"

echo "==> Initialising wine prefix..."
export WINEPREFIX="$WORK/wineprefix" WINEDEBUG=-all
wineboot -i >/dev/null 2>&1 || true

echo "==> Running installer; snapshotting temp files..."
rm -rf "$WORK/snapshot"
mkdir -p "$WORK/snapshot"
TEMP="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Temp"

# Watch temp dir while installer runs and grab files before they get cleaned up.
(
  while true; do
    for d in "$TEMP"/is-*; do
      [ -d "$d" ] && rsync -a "$d/" "$WORK/snapshot/" 2>/dev/null
    done
    sleep 0.2
  done
) &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT

wine "$WORK/smartamp.exe" /SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=Z:\\tmp\\px13-tas2783\\install.log 2>/dev/null
sleep 5
kill $WATCHER 2>/dev/null || true

# Find the firmware blobs.
SRC=$(find "$WORK/snapshot" -name "1714-1-0x8.bin" | head -1)
[ -n "$SRC" ] || { echo "ERROR: Did not find 1714-1-0x8.bin. Snapshot:"; find "$WORK/snapshot" | head; exit 1; }
SRC_DIR=$(dirname "$SRC")

echo "==> Found firmware in $SRC_DIR"

echo "==> Installing to /lib/firmware/ (will prompt for sudo)..."
sudo install -m 644 "$SRC_DIR/1714-1-0x8.bin" /lib/firmware/1714-1-8.bin
sudo install -m 644 "$SRC_DIR/1714-1-0xB.bin" /lib/firmware/1714-1-B.bin
sudo install -d -m 755 /lib/firmware/ti/audio/tas2783
sudo install -m 644 "$SRC_DIR/1714-1-0x8.bin" /lib/firmware/ti/audio/tas2783/1714-1-8.bin
sudo install -m 644 "$SRC_DIR/1714-1-0xB.bin" /lib/firmware/ti/audio/tas2783/1714-1-B.bin

echo
echo "==> Done. Firmware installed."
echo "    Reboot, then check: dmesg | grep tas2783"
echo "    You should NOT see 'Direct firmware load for 1714-1-* failed'."

