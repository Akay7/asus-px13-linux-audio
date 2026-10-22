# Fixing internal audio on ASUS ProArt PX13 GoPro Edition (HN7306, Strix Halo) — openSUSE Tumbleweed

## Symptom

No sound from internal speakers or headphone jack. Only an HDMI audio
device shows up; PipeWire falls back to a null sink.

## Hardware background

This laptop routes audio over **SoundWire**, not a classic HD-Audio codec:

- **Realtek RT721** SDCA codec → headphone jack
- **2x Texas Instruments TAS2783** SmartAmp amplifiers → internal speakers
- Both sit behind the AMD Audio Coprocessor (`AMD/ATI Audio Coprocessor`,
  PCI id `1022:15e2`), driven by `snd_pci_ps`.

---

## Step 1 — Confirm there's no analog sound card at all

```bash
aplay -l
cat /proc/asound/cards
```

Expect to see only `HDA-Intel — HD-Audio Generic` (HDMI). No entry for
speakers/headphones means the ASoC machine driver never assembled a card.

```bash
pactl info | grep 'Default Sink'
```

`auto_null` confirms PipeWire has nothing real to fall back to.

## Step 2 — Check the PCI audio hardware is detected

```bash
lspci -nn | grep -iE 'audio|multimedia'
```

Expect two AMD entries: the HD-Audio controller (HDMI) and the
`Audio Coprocessor [1022:15e2]`.

## Step 3 — Check the relevant kernel modules are loaded

```bash
lsmod | grep -E 'snd_sof|snd_acp|snd_pci_ps|snd_amd|soundwire|sdw'
```

You should see `snd_pci_ps`, `snd_amd_sdw_acpi`, `snd_acp_sdw_legacy_mach`,
`snd_soc_rt721_sdca`, etc. already loaded — the controller and jack codec
drivers are fine; the problem is downstream.

## Step 4 — Check the SoundWire bus and which devices are attached

```bash
ls /sys/bus/soundwire/devices/
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "$d status=$(cat $d/status 2>/dev/null) driver=$(readlink $d/driver 2>/dev/null | xargs -r basename)"
done
```

Expected on this laptop:

```
sdw:0:1:0102:0000:01:8  status=Attached  driver=            <- TAS2783 amp #1, unclaimed
sdw:0:1:0102:0000:01:b  status=Attached  driver=            <- TAS2783 amp #2, unclaimed
sdw:0:1:025d:0721:01    status=Attached  driver=rt721-sdca  <- RT721 jack codec, OK
```

Both amps are seen by the bus (`Attached`) but have **no driver** bound.
That's the smoking gun: the kernel has no driver for the TAS2783 SoundWire
peripheral, so the ASoC machine driver can never build a complete card and
gives up silently (no error, just nothing).

## Step 5 — Confirm CONFIG_SND_SOC_TAS2783_SDW is disabled

Four independent checks, all against the **currently running** kernel
(`uname -r`):

```bash
# 1. Config baked into the running kernel binary itself
zcat /proc/config.gz | grep TAS2783

# 2. The config file openSUSE ships next to the kernel package (should match #1)
grep TAS2783 /usr/lib/modules/$(uname -r)/config

# 3. Is there a module file anywhere?
find /usr/lib/modules/$(uname -r) -iname '*tas2783*'
# empty output = not built as a module

# 4. Is it compiled directly into the kernel image instead?
grep -i tas2783 /usr/lib/modules/$(uname -r)/modules.builtin
# empty output = not built-in either
```

Expected result: `# CONFIG_SND_SOC_TAS2783_SDW is not set`, and both find/grep
checks come back empty. That confirms the driver is fully absent — not
failing to bind, not missing firmware, just never compiled.

*(Firmware itself is already present and NOT the issue: check
`ls /lib/firmware/ti/audio/tas2783/` — the blobs matching this board's ACPI
HID, e.g. `1714-1-0x8.bin.xz` / `1714-1-0xB.bin.xz`, ship in the
`kernel-firmware-sound` package.)*

## Step 6 — Check whether the driver source is available locally

openSUSE's `kernel-devel`/`kernel-default-devel` packages ship only the
build scaffolding (Makefiles, Kconfig, headers) needed to build *external*
modules — not the kernel's own full `.c` sources.

```bash
find /usr/src -iname 'tas2783*'
grep tas2783 /usr/src/linux-$(uname -r | sed 's/-default//')/sound/soc/codecs/Makefile
```

The Makefile references `tas2783-sdw.o`, but the `.c`/`.h` files are not
present — confirmed by checking the codecs dir only has 1 `.c` file total
(everything else is likewise absent, so this isn't tas2783-specific, it's
normal for this package). Source has to be fetched separately.

## Step 7 — Build the module manually against the running kernel

```bash
mkdir -p ~/scratch/tas2783 && cd ~/scratch/tas2783

KVER=$(uname -r)               # e.g. 7.1.6-1-default
KTAG="v${KVER%%-*}"            # e.g. v7.1.6  (matches upstream stable tag)
                                # NOTE: must be %%-* (strip from FIRST '-'),
                                # not %-default — the latter leaves "v7.1.6-1",
                                # which 404s and silently produces no .c file,
                                # causing "No rule to make target ...o" later.

curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs/tas2783-sdw.c?h=${KTAG}" -o tas2783-sdw.c
curl -sfL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs/tas2783.h?h=${KTAG}"     -o tas2783.h

# verify the download actually worked before building — curl -f fails
# silently on a bad tag/404 and leaves no usable file, which later shows
# up as a confusing "No rule to make target ...o" from kbuild
wc -l tas2783-sdw.c tas2783.h   # expect ~1378 and ~111 lines; 0 lines = bad tag, check $KTAG

cat > Makefile <<'EOF'
obj-m := snd-soc-tas2783-sdw.o
snd-soc-tas2783-sdw-y := tas2783-sdw.o
EOF

make -C /usr/src/linux-${KVER%-default}-obj/x86_64/default M=$PWD modules
```

Verify the result matches your kernel exactly before going any further:

```bash
/usr/sbin/modinfo snd-soc-tas2783-sdw.ko | grep -E 'vermagic|depends|alias'
```

Expect:
- `vermagic:` matches `uname -r` exactly
- `alias: sdw:m0102p*v*c*` (matches the TAS2783 SoundWire device IDs seen in step 4)
- `depends:` only on modules already loaded (`regmap-sdw-mbq`, `soundwire-bus`,
  `snd-soc-core`, `snd-soc-sdca`, `snd-pcm`)

## Step 8 — Sign the module for Secure Boot

Check Secure Boot is on (it was, on this machine):

```bash
mokutil --sb-state
```

If enabled, an unsigned out-of-tree module will be refused by the kernel at
load time. Generate a Machine Owner Key (MOK), sign the module, enroll the
key:

```bash
cd ~/scratch/tas2783

openssl req -new -x509 -newkey rsa:2048 \
  -keyout mok-tas2783.key -out mok-tas2783.der -outform DER \
  -days 3650 -nodes -subj "/CN=local kernel module MOK/"

/usr/src/linux-$(uname -r | sed 's/-default//')-obj/x86_64/default/scripts/sign-file \
  sha256 mok-tas2783.key mok-tas2783.der snd-soc-tas2783-sdw.ko

sudo mokutil --import mok-tas2783.der
# you'll be asked to set a one-time enrollment password
sudo reboot
```

On reboot, the **MOK Manager** blue screen appears automatically before
GRUB — choose *Enroll MOK* → *Continue* → enter the password you set →
reboot again. This step needs to happen at the physical console; it can't
be scripted.

## Step 9 — Load the module and test

```bash
sudo insmod ~/scratch/tas2783/snd-soc-tas2783-sdw.ko
dmesg | tail -40
aplay -l
wpctl status
```

Expect a new sound card / new sink to appear for the speakers. Play a test
tone:

```bash
speaker-test -c 2 -t wav -l 1
```

If it works, make it persistent:

```bash
sudo cp ~/scratch/tas2783/snd-soc-tas2783-sdw.ko \
  /usr/lib/modules/$(uname -r)/kernel/sound/soc/codecs/
sudo depmod -a
echo snd-soc-tas2783-sdw | sudo tee /etc/modules-load.d/tas2783.conf
```

(Note: this manual copy will be wiped out by the next kernel update — it's
a stopgap until the fix lands upstream in openSUSE's kernel config, at
which point this whole workaround should be removed.)

## Step 10 — Report upstream so the config gets fixed properly

File against **openSUSE Bugzilla** (`bugzilla.opensuse.org`), product
*openSUSE Tumbleweed*, component *Kernel*:

> **Summary:** Enable CONFIG_SND_SOC_TAS2783_SDW — no speaker/jack audio on
> ASUS ProArt PX13 (HN7306, Strix Halo)
>
> Internal audio is non-functional out of the box. The SoundWire bus
> enumerates both TAS2783 speaker amps (`sdw:0:1:0102:0000:01:8/:b`) but
> `CONFIG_SND_SOC_TAS2783_SDW` is disabled in the shipped kernel config, so
> no driver claims them and the ASoC machine driver never assembles a
> sound card. RT721 (headphone jack codec) binds fine. Firmware
> (`/lib/firmware/ti/audio/tas2783/1714-1-*.bin`) is already present via
> `kernel-firmware-sound`. Building `snd-soc-tas2783-sdw.ko` manually from
> the same kernel version and loading it produces a working speaker sink,
> confirming this is purely a config option, not missing driver/firmware
> support in this kernel.

Attach `dmesg`, `aplay -l`, and `/sys/bus/soundwire/devices/*/status`
output from before/after loading the module.

Related upstream discussion (same laptop family):
- https://github.com/CachyOS/linux-cachyos/issues/737
- https://github.com/CachyOS/linux-cachyos/issues/853
- https://patchew.org/linux/20260308151654.29059-1-hasunpark@gmail.com/

---

## Status of this investigation (as of writing)

- [x] Root cause identified: `CONFIG_SND_SOC_TAS2783_SDW` disabled (Step 5)
- [x] Confirmed on both kernel 7.1.5 and 7.1.6 — not fixed by the point update
- [x] Module built and matched to running kernel (Step 7), vermagic/alias verified
- [ ] MOK signing / enrollment (Step 8) — not yet done
- [ ] Module loaded and speaker output verified live (Step 9) — not yet done
- [ ] Bug filed upstream (Step 10) — not yet done
