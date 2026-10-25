# Internal audio on ASUS ProArt PX13 (HN7306EAC) — openSUSE Tumbleweed

Tested on kernel **7.3.0-1-default** (and earlier 7.2.11-1-default), Secure Boot **on**,
PipeWire/WirePlumber. The scripts use generic paths (`/lib/modules/$(uname -r)/build`), so other
distros should work too as long as the kernel headers/devel package is installed.

## What was wrong

Speakers are two TI TAS2783 amps on SoundWire, the jack/mic is a Realtek RT721.
With a current kernel the card (`amdsoundwire`) is created, but these things are broken:

| Symptom | Kernels | Cause | Fix in this repo |
|---|---|---|---|
| No speaker/headphone sinks, only HDMI | all | `alsa-ucm-conf` 1.2.16.1 has no `sof-soundwire/tas2783.conf`, so WirePlumber keeps the card profile "off" | `tas2783.conf` |
| Only one speaker works, plays mono | 7.2 | `tas2783-sdw` gives both amps the full channel mask, so neither gets its own channel | patch in `tas2783-patched/` (in-tree since 7.3) |
| No speaker sink again, card profiles are only "off" / "pro-audio" | 7.3 | the RT721 fails to resume from runtime suspend: `regcache_sync()` writes back register defaults the codec rejects (`-ENODATA`), and since 7.3 that error fails the resume. Its PCMs then fail to open, so PipeWire drops the whole HiFi profile, speakers included | patch in `rt721-patched/` (or the udev rule as a fallback) |

The tas2783 fix is the upstream patch
["ASoC: tas2783-sdw: split a stereo stream across the two mono amps"](https://ratatoskr.run/lkml/2026/08/17416566/t),
commit [`173cb3147ba2`](https://git.kernel.org/pub/scm/linux/kernel/git/broonie/sound.git/commit/?id=173cb3147ba2),
which is in v7.3.

The RT721 fix drops three entries from the driver's register defaults: PDE23 REQ_POWER_STATE
(`0x41001188`, which the driver never writes and the codec ignores on this laptop) and the volatile
MBQ registers `0x2000046` and `0x6100006` (the cache never tracks them, so the sync only writes stale
values back). It is not upstream yet; it was reported to linux-sound as a regression:
[rt721-sdca: runtime resume fails with -ENODATA since v7.3](https://lore.kernel.org/linux-sound/8a12a2d9-1b56-4e00-8ccc-cf31325f8366@crazyrussian.pro/T/#u).

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

The build scripts look for the key pair in `~/.mok`; set `MOK_DIR=/other/dir` to use another location.
Keep the `.key` file private and out of this repo (`.gitignore` excludes `*.key` / `*.der`).

### 3. Kernel 7.3: patched RT721 module

Needs `kernel-default-devel` (matching your running kernel) and `curl`.

```bash
./build-px13-rt721-module.sh      # fetches the rt721-sdca source for your kernel, patches, builds, signs
./install-px13-rt721-module.sh    # copies it to /lib/modules/$(uname -r)/updates/
sudo reboot
```

`updates/` takes priority over the stock module. Check:

```bash
/usr/sbin/modinfo -n snd-soc-rt721-sdca     # must end in .../updates/snd-soc-rt721-sdca.ko
sudo ./trace-px13-rt721-resume.sh           # forces one suspend/resume and plays 1 s of silence
```

The `aplay:` line must say `Playing raw data`, not `No data available`. If it fails, the codec stays
dead until a reboot; `rt721-trace.txt` then shows the last register written before the failure.

Fallback if you can't build modules: forbid runtime PM for the RT721 instead
(`./install-px13-rt721-rule.sh && sudo reboot`). The codec then stays active; on this laptop the
SoundWire link stays up for the amps anyway, so the cost looks small. Don't use both: the rule
hides whether the module works.

### 4. Kernel 7.2 only: patched tas2783 module

7.3 has this fix in-tree; skip this step there.

```bash
./build-px13-tas2783-module.sh      # fetches tas2783-sdw.c for your kernel, patches, builds, signs
./install-px13-tas2783-module.sh    # copies it to /lib/modules/$(uname -r)/updates/
sudo reboot
```

### 5. Check it works

```bash
speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 1 -l 1   # left speaker only
speaker-test -D hw:CARD=amdsoundwire,DEV=2 -c 2 -t sine -f 500 -s 2 -l 1   # right speaker only
```

Then plug in headphones and play something on the "Headphones" sink.

## After a kernel update

Modules in `updates/` are built for one exact kernel version; after an update the stock driver
loads again. Boot the new kernel and rebuild:

```bash
./build-px13-rt721-module.sh && ./install-px13-rt721-module.sh && sudo reboot
```

If the patch no longer applies, the driver changed upstream: check whether the problem is fixed
there (boot without the override and run `sudo ./trace-px13-rt721-resume.sh`) before forcing anything.

## Remove when fixed upstream

- **RT721 module:** once a kernel fixes the resume, remove the override and check with the trace script:

  ```bash
  sudo rm -f /lib/modules/*/updates/snd-soc-rt721-sdca.ko && sudo depmod -a && sudo reboot
  ```

- **tas2783 module (7.2 leftovers):** `sudo rm -f /lib/modules/*/updates/snd-soc-tas2783-sdw.ko && sudo depmod -a`.

- **UCM file:** upstream alsa-ucm-conf added its own `ucm2/sof-soundwire/tas2783.conf` (commit
  [`182d0122`](https://github.com/alsa-project/alsa-ucm-conf/commit/182d0122), 2026-08-21), after
  1.2.16.1. Once an `alsa-ucm-conf` update lands, check `rpm -ql alsa-ucm-conf | grep tas2783`.
  If it lists the file, remove yours and let the package provide it:

  ```bash
  sudo rm /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
  sudo zypper install -f alsa-ucm-conf     # reinstall the packaged file
  systemctl --user restart wireplumber
  ```

  The upstream version also adds `codecs/tas2783/init.conf`, which at the time of writing uses
  control names that don't exist ([PR #886](https://github.com/alsa-project/alsa-ucm-conf/pull/886),
  still open). That only means a harmless failed boot-time `cset`; speakers still work.

- **MOK key:** delete it once nothing uses it (`sudo mokutil --delete ~/.mok/mok-tas2783.der`,
  then confirm at next boot).

## Files

| File | Purpose |
|---|---|
| `tas2783.conf` | UCM speaker config |
| `install-px13-ucm.sh` | installs it and restarts WirePlumber |
| `rt721-patched/px13-rt721-sync-defaults.patch` | the RT721 register-defaults fix (7.3) |
| `rt721-patched/Makefile` | kbuild file for the out-of-tree RT721 module |
| `build-px13-rt721-module.sh` | fetches the RT721 driver source for your kernel, patches, builds, signs |
| `install-px13-rt721-module.sh` | installs the RT721 module into `updates/` |
| `trace-px13-rt721-resume.sh` | forces one RT721 suspend/resume and traces every register write |
| `90-px13-rt721-no-autosuspend.rules` | fallback: udev rule that keeps the RT721 out of runtime suspend |
| `install-px13-rt721-rule.sh` | installs that rule |
| `tas2783-patched/px13-tas2783-channel-mask.patch` | the tas2783 stereo backport (7.2) |
| `tas2783-patched/Makefile` | kbuild file for the out-of-tree tas2783 module |
| `build-px13-tas2783-module.sh` | fetches the tas2783 source for your kernel, patches, builds, signs |
| `install-px13-tas2783-module.sh` | installs the tas2783 module into `updates/` |
