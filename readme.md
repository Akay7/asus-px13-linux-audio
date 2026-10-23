# Internal audio on ASUS ProArt PX13 (HN7306EAC) — openSUSE Tumbleweed

Tested on kernel **7.2.11-1-default**, Secure Boot **on**, PipeWire/WirePlumber.
The scripts use generic paths (`/lib/modules/$(uname -r)/build`), so other distros should
work too as long as the kernel headers/devel package is installed.

## What was wrong

Speakers are two TI TAS2783 amps on SoundWire, the jack/mic is a Realtek RT721.
With a current kernel the card (`amdsoundwire`) is created, but two things stay broken:

| Symptom | Cause | Fix in this repo |
|---|---|---|
| No speaker/headphone sinks, only HDMI | `alsa-ucm-conf` 1.2.16.1 has no `sof-soundwire/tas2783.conf`, so WirePlumber keeps the card profile "off" | `tas2783.conf` |
| Only one speaker works, plays mono | `tas2783-sdw` gives both amps the full channel mask, so neither gets its own channel | patch in `tas2783-patched/` |

The module fix is the upstream patch
["ASoC: tas2783-sdw: split a stereo stream across the two mono amps"](https://ratatoskr.run/lkml/2026/08/17416566/t),
applied by Mark Brown to `sound.git` (`for-7.3`, commit
[`173cb3147ba2`](https://git.kernel.org/pub/scm/linux/kernel/git/broonie/sound.git/commit/?id=173cb3147ba2)).
It is backported here until a 7.3 kernel is released.

The TAS2783 firmware (`ti/audio/tas2783/1714-1-0x8/0xB.bin`) already ships in
`kernel-firmware-sound`; nothing needs to be extracted.

## Install

All steps ask for `sudo`.

### 1. UCM speaker profile

```bash
./install-px13-ucm.sh
```

Copies `tas2783.conf` to `/usr/share/alsa/ucm2/sof-soundwire/` and restarts WirePlumber.
A "Speaker" sink should appear in `wpctl status`.

### 2. Signing key (Secure Boot only, once)

With Secure Boot on, the kernel only loads modules signed with a key you enrolled via `mokutil`.
Check with `mokutil --sb-state`. If it is enabled and you don't have a key yet:

```bash
mkdir -p ~/.mok && chmod 700 ~/.mok && cd ~/.mok
openssl req -new -x509 -newkey rsa:2048 -keyout mok-tas2783.key \
  -out mok-tas2783.der -outform DER -days 3650 -nodes -subj "/CN=local kernel module MOK/"
sudo mokutil --import mok-tas2783.der   # set a one-time password
sudo reboot                             # blue MOK screen: Enroll MOK -> enter password
```

The build script looks for the key pair in `~/.mok`; set `MOK_DIR=/other/dir` to use another location.
Keep the `.key` file private and out of this repo (`.gitignore` excludes `*.key` / `*.der`).

### 3. Build and install the patched module

Needs `kernel-default-devel` (matching your running kernel) and `curl`.

```bash
./build-px13-tas2783-module.sh      # fetches tas2783-sdw.c for your kernel, patches, builds, signs
./install-px13-tas2783-module.sh    # copies it to /lib/modules/$(uname -r)/updates/
sudo reboot
```

`updates/` takes priority over the stock module.

### 4. Check it works

```bash
/usr/sbin/modinfo -n snd-soc-tas2783-sdw      # must end in .../updates/snd-soc-tas2783-sdw.ko
speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 1 -l 1   # left speaker only
speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 2 -l 1   # right speaker only
```

## After a kernel update (until 7.3)

The module in `updates/` is built for one exact kernel version. After an update to a new
kernel, the stock driver loads again and the right speaker goes silent (mono).
If a *7.3* kernel is not installed yet, boot the new kernel and repeat step 3:

```bash
./build-px13-tas2783-module.sh && ./install-px13-tas2783-module.sh && sudo reboot
```

If the patch no longer applies, the driver changed upstream: check upstream before forcing anything.

## Remove after kernel 7.3 is released

Kernel 7.3 contains the fix, so the patched module is no longer needed.

1. Boot into a **7.3** kernel (`uname -r` shows `7.3...`).
2. Confirm the fix is in your kernel by removing the override and testing (steps below).
   If you want to check the source first: `tas_sdw_hw_params()` in
   `sound/soc/codecs/tas2783-sdw.c` for v7.3 should contain the `name_prefix` / `ch_mask` block.
3. Remove the override module (all kernel versions):

   ```bash
   sudo rm -f /lib/modules/*/updates/snd-soc-tas2783-sdw.ko
   sudo depmod -a
   sudo reboot
   ```

4. Verify the stock module is now used and stereo works:

   ```bash
   /usr/sbin/modinfo -n snd-soc-tas2783-sdw   # path now under .../kernel/sound/soc/codecs/
   speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 1 -l 1
   speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 2 -l 1
   ```

   If one side is still silent, rebuild and reinstall the override (step 3)
   and check upstream for a follow-up fix.

5. The UCM file (`tas2783.conf`) is separate. Upstream alsa-ucm-conf added its own
   (`ucm2/sof-soundwire/tas2783.conf`, commit
   [`182d0122`](https://github.com/alsa-project/alsa-ucm-conf/commit/182d0122), 2026-08-21), but
   1.2.16.1 predates it, so it will arrive with the first release after 1.2.16.1.
   Once an `alsa-ucm-conf` update lands, check `rpm -ql alsa-ucm-conf | grep tas2783`.
   If it lists the file, remove yours and let the package provide it:

   ```bash
   sudo rm /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
   sudo zypper install -f alsa-ucm-conf     # reinstall the packaged file
   systemctl --user restart wireplumber
   ```

   The upstream version also adds `codecs/tas2783/init.conf`, which at the time of writing uses
   control names that don't exist ([PR #886](https://github.com/alsa-project/alsa-ucm-conf/pull/886),
   still open). That only means a harmless failed boot-time `cset`; speakers still work.

6. Optional cleanup: delete the MOK key if nothing else uses it
   (`sudo mokutil --delete ~/.mok/mok-tas2783.der`, then confirm at next boot).

## Files

| File | Purpose |
|---|---|
| `tas2783.conf` | UCM speaker config |
| `install-px13-ucm.sh` | installs it and restarts WirePlumber |
| `tas2783-patched/px13-tas2783-channel-mask.patch` | the backported driver fix |
| `tas2783-patched/Makefile` | kbuild file for the out-of-tree module |
| `build-px13-tas2783-module.sh` | fetches the driver source for your kernel, patches, builds, signs |
| `install-px13-tas2783-module.sh` | installs the module into `updates/` |
