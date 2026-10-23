#!/bin/bash
# Fetch tas2783-sdw source for the running kernel, apply the stereo channel-mask backport,
# build it and (if Secure Boot is on) sign it with your MOK.
# Needs the kernel devel package (kernel-default-devel on openSUSE) and curl.
#
#   MOK_DIR=/path/to/keys ./build-px13-tas2783-module.sh
#
# MOK_DIR must hold mok-tas2783.key and mok-tas2783.der (default: ~/.mok, see readme.md).
set -euo pipefail

KVER=${KVER:-$(uname -r)}
KTAG="v${KVER%%-*}"               # 7.2.12-1-default -> v7.2.12
KDIR=/lib/modules/$KVER/build
MOK_DIR=${MOK_DIR:-$HOME/.mok}
DIR="$(dirname "$(readlink -f "$0")")/tas2783-patched"
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs"

[ -d "$KDIR" ] || { echo "ERROR: $KDIR missing, install the kernel devel package for $KVER"; exit 1; }

cd "$DIR"
echo "==> Fetching tas2783 source for $KTAG"
curl -sfL "$BASE/tas2783-sdw.c?h=$KTAG" -o tas2783-sdw.c || { echo "ERROR: no source for tag $KTAG"; exit 1; }
curl -sfL "$BASE/tas2783.h?h=$KTAG"     -o tas2783.h     || { echo "ERROR: no source for tag $KTAG"; exit 1; }

echo "==> Applying px13-tas2783-channel-mask.patch"
patch -p0 -s --forward --no-backup-if-mismatch -r - tas2783-sdw.c < px13-tas2783-channel-mask.patch || {
	echo "ERROR: patch does not apply to $KTAG. If $KTAG already has the fix (7.3+), you don't need this module;"
	echo "       otherwise the driver changed upstream and the patch needs updating."
	exit 1
}

echo "==> Building against $KDIR"
make -C "$KDIR" M="$PWD" modules

if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	[ -f "$MOK_DIR/mok-tas2783.key" ] && [ -f "$MOK_DIR/mok-tas2783.der" ] ||
		{ echo "ERROR: Secure Boot is on but no key pair in $MOK_DIR (see readme.md)"; exit 1; }
	echo "==> Signing with $MOK_DIR/mok-tas2783.der"
	"$KDIR/scripts/sign-file" sha256 "$MOK_DIR/mok-tas2783.key" "$MOK_DIR/mok-tas2783.der" snd-soc-tas2783-sdw.ko
fi

echo "==> Built $DIR/snd-soc-tas2783-sdw.ko for $KVER"
echo "    Next: ./install-px13-tas2783-module.sh && sudo reboot"
