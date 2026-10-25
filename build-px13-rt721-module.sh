#!/bin/bash
# Fetch rt721-sdca source for the running kernel, drop the register defaults that make
# runtime resume fail on 7.3 (PDE23 REQ_POWER_STATE and the volatile MBQ 0x2000046/0x6100006),
# build it and (if Secure Boot is on) sign it with your MOK.
# Needs the kernel devel package (kernel-default-devel on openSUSE) and curl.
#
#   MOK_DIR=/path/to/keys ./build-px13-rt721-module.sh
#
# MOK_DIR must hold mok-tas2783.key and mok-tas2783.der (default: ~/.mok, see readme.md).
set -euo pipefail

KVER=${KVER:-$(uname -r)}
KTAG="v${KVER%%-*}"               # 7.3.0-1-default -> v7.3.0
KTAG=${KTAG%.0}                   # kernel.org tags x.y.0 as vx.y
KDIR=/lib/modules/$KVER/build
MOK_DIR=${MOK_DIR:-$HOME/.mok}
DIR="$(dirname "$(readlink -f "$0")")/rt721-patched"
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs"

[ -d "$KDIR" ] || { echo "ERROR: $KDIR missing, install the kernel devel package for $KVER"; exit 1; }

cd "$DIR"
echo "==> Fetching rt721-sdca source for $KTAG"
for f in rt721-sdca.c rt721-sdca.h rt721-sdca-sdw.c rt721-sdca-sdw.h rt-sdw-common.h; do
	curl -sfL "$BASE/$f?h=$KTAG" -o "$f" || { echo "ERROR: no $f for tag $KTAG"; exit 1; }
done

echo "==> Applying px13-rt721-sync-defaults.patch"
patch -p0 -s --forward --no-backup-if-mismatch -r - < px13-rt721-sync-defaults.patch || {
	echo "ERROR: patch does not apply to $KTAG: the driver changed upstream, check whether it is fixed there"
	exit 1
}

echo "==> Building against $KDIR"
make -C "$KDIR" M="$PWD" modules

if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	[ -f "$MOK_DIR/mok-tas2783.key" ] && [ -f "$MOK_DIR/mok-tas2783.der" ] ||
		{ echo "ERROR: Secure Boot is on but no key pair in $MOK_DIR (see readme.md)"; exit 1; }
	echo "==> Signing with $MOK_DIR/mok-tas2783.der"
	"$KDIR/scripts/sign-file" sha256 "$MOK_DIR/mok-tas2783.key" "$MOK_DIR/mok-tas2783.der" snd-soc-rt721-sdca.ko
fi

echo "==> Built $DIR/snd-soc-rt721-sdca.ko for $KVER"
echo "    Next: ./install-px13-rt721-module.sh && sudo reboot"
