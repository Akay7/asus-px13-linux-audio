#!/bin/bash
# Reproduce one RT721 runtime suspend/resume and record every regmap write. regmap_reg_write is
# only logged for writes that succeeded, and cache syncs write runs of registers through the raw
# path, so also record the bus-level regmap_hw_write_* events: the last regmap_hw_write_start
# before a failing regcache_sync is the register the codec ignored (-ENODATA).
#
#   sudo ./trace-px13-rt721-resume.sh [output-file]      (default: ./rt721-trace.txt)
#
# If the resume fails, the codec stays dead until a reboot.
set -u
DEV=sdw:0:1:025d:0721:01
P=/sys/bus/soundwire/devices/$DEV/power
T=/sys/kernel/tracing
OUT=${1:-$PWD/rt721-trace.txt}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -d "$T/events/regmap" ] || mount -t tracefs nodev "$T"

echo 0 > "$T/tracing_on"
echo > "$T/trace"
echo 16384 > "$T/buffer_size_kb"
for e in regmap_reg_write regmap_reg_read regmap_hw_write_start regmap_hw_write_done regcache_sync; do echo 1 > "$T/events/regmap/$e/enable"; done
echo 1 > "$T/events/rpm/enable" 2>/dev/null
echo 1 > "$T/tracing_on"

echo "==> allowing runtime suspend (was: $(cat $P/control))"
echo auto > "$P/control"
for i in $(seq 60); do [ "$(cat $P/runtime_status)" = suspended ] && break; sleep 0.5; done
echo "    runtime_status: $(cat $P/runtime_status)"

# regcache_sync() only touches the hardware if the cache went dirty while suspended,
# which at boot happens when alsactl restores the mixer; do the same with harmless toggles.
# The switch lives in the plain regmap, the volume in the MBQ regmap.
echo "==> dirtying both caches (headset mic switch off/on, headphone volume 0/back)"
amixer -q -c amdsoundwire cset name='rt721 FU0F Capture Switch' off,off
amixer -q -c amdsoundwire cset name='rt721 FU0F Capture Switch' on,on
VOL=$(amixer -c amdsoundwire cget name='rt721 FU05 Playback Volume' | sed -n 's/^ *: values=//p')
amixer -q -c amdsoundwire cset name='rt721 FU05 Playback Volume' 0,0
amixer -q -c amdsoundwire cset name='rt721 FU05 Playback Volume' "$VOL"

echo "==> forcing resume"
echo on > "$P/control"
sleep 1
echo "    runtime_status: $(cat $P/runtime_status)"
APLAY=$(aplay -D hw:CARD=amdsoundwire,DEV=0 -f S16_LE -r 48000 -c 2 -d 1 /dev/zero 2>&1 | tail -1)
echo "    aplay: ${APLAY:-ok}"

echo 0 > "$T/tracing_on"
for e in regmap_reg_write regmap_reg_read regmap_hw_write_start regmap_hw_write_done regcache_sync; do echo 0 > "$T/events/regmap/$e/enable"; done
echo 0 > "$T/events/rpm/enable" 2>/dev/null

{ echo "aplay: ${APLAY:-ok}"; grep -E "$DEV|regcache_sync" "$T/trace"; echo "---- dmesg"; dmesg | tail -40; } > "$OUT"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$OUT"
echo > "$T/trace"
echo "==> wrote $OUT ($(wc -l < "$OUT") lines)"
