# Kodi with FreeBSD on UGREEN DXP2800

A recipe for turning a UGREEN DXP2800 NAS (Intel N100 / Alder Lake-N) into
a silent, host-native FreeBSD HTPC running **Kodi 22** on the iGPU over
HDMI, with **TVHeadend** as the PVR backend and **working HDMI audio**.

Everything here is what I actually run; the audio part required a small
drm-kmod patch because FreeBSD's i915 driver currently never enables the
display-audio codec on this SoC.

```
UGREEN DXP2800 (Intel N100)
  └─ FreeBSD 15.1-RELEASE (ZFS root)
       ├─ i915kms (drm-612-kmod, patched) -> HDMI -> LG TV
       ├─ Xorg :0 (modesetting) -> Kodi 22 (native, no VM)
       ├─ pvr.hts -> TVHeadend (HTSP)
       └─ rc.d: kodidisplay (X+Kodi), kodiwatchdog (TV hotplug)
```

## Why not a VM?

The obvious design - run LibreELEC/Kodi in a bhyve VM with the iGPU passed
through (GVT-d) - **does not work reliably** on this SoC: the passed-through
display engine faults on Kodi's 10-bit GUI plane and the screen stays black
(FreeBSD bug 300031). The bhyve workarounds that were tried (DSB disabled,
DPT disabled, no compression, clearing the GTT, EPT PAT, MFCing upstream
passthrough commits) did not fix it.

Running Kodi **natively on the host** with the iGPU owned by `i915kms` gives
correct colours and a stable picture. The cost: HDMI audio needed a
drm-kmod fix (below), and the TV hotplug handling needed a small watchdog.

## What you need

* UGREEN DXP2800 (or any Intel N100/Alder Lake-N box with HDMI)
* FreeBSD 15.1-RELEASE (ZFS-on-root recommended; the recipe assumes `/zroot`)
* Packages: `xorg`, `kodi`, `libva-intel-media-driver`, `libcec`,
  `drm-612-kmod` (GPU), `gpu-firmware-intel-kmod-alderlake`
* A TVHeadend server somewhere on the LAN (this recipe assumes HTSP on
  `<TVH_HOST>:9982`)

## 1. Keep the iGPU on the host

If you also run bhyve VMs, do **not** pass the GPU/HDA through. In
`/boot/loader.conf` keep only what the VMs need, e.g. a USB controller:

```
pptdevs="0/20/0"          # example: one xHCI passed to a VM, GPU+HDA stay on host
```

and load the display driver at boot (`/etc/rc.conf`):

```
kld_list="coretemp i915kms"
```

Check after reboot:

```
pciconf -lv | grep -E '^(vgapci|hdac)'
kldstat -m i915kms
ls /dev/dri
```

## 2. Packages

```sh
pkg install -y xorg kodi libva-intel-media-driver libcec \
    drm-612-kmod gpu-firmware-intel-kmod-alderlake
```

Optional extras: `sox` (audio tests), `git` (for the audio-fix build).

## 3. Xorg + Kodi autostart

`/usr/local/etc/rc.d/kodidisplay` - see [files/kodidisplay](files/kodidisplay).
It starts Xorg on `vt7`, waits for an active `HDMI-1` mode, re-probes the
HDMI audio codec (see section 4), then starts Kodi with `HOME=/root`.

Enable both services:

```sh
sysrc kodidisplay_enable=YES
sysrc kodiwatchdog_enable=YES
```

Kodi stores its data in `/root/.kodi` (it runs as root, `DISPLAY=:0`).

## 4. Working HDMI audio (the missing piece)

**Symptom:** `/dev/sndstat` is empty, dmesg says
`hdac0: CODEC at address 2 not responding!`, Kodi has no audio device.

**Root cause** (see the bug report and diff in
[patches/](patches/)): the audio-enable decision is actually correct
(instrumented build: `has_hdmi_sink=1`, `display_info.has_audio=1`,
`force_audio=AUTO`, so `hsw_audio_codec_enable()` runs). What is missing is
the **HDA link clock**: FreeBSD's i915 port has no audio component, so the
power-up and `AUD_FREQ_CNTRL` programming inside
`i915_audio_component_get_power()` / `i915_audio_component_init()` are
`#ifdef __linux__` no-ops. `AUD_FREQ_CNTRL` is never written, so the HDA
codec at address 2 stays silent. The patch is one file
(`intel_audio.c`) and programs `AUD_FREQ_CNTRL` with the existing
`AUD_FREQ_GEN12` macro (with the TGL/RKL BIOS-value quirk) by calling the
existing `i915_audio_component_init()` on FreeBSD, plus the power/pin-buffer
writes in `hsw_audio_codec_enable()`; no `intel_hdmi.c` change is needed.

**Fix:** build drm-kmod 6.12-lts with the patch in this repo:

```sh
pkg install -y git
git clone --depth 1 --branch 6.12-lts \
    https://github.com/freebsd/drm-kmod /root/drm-kmod-612
cd /root/drm-kmod-612
patch -p1 < /path/to/patches/drm-kmod-612-hdmi-audio-fix.patch

# build the whole module set: the packaged drm.ko lacks gpu_buddy_*
env KMODS="dmabuf ttm drm i915" make -j4 SYSDIR=/usr/src/sys

# keep the stock modules as backups, then install
for m in dmabuf ttm drm i915kms; do
    cp -p /boot/modules/$m.ko /boot/modules/$m.ko.stock-pkg
done
cp /root/drm-kmod-612/dmabuf/dmabuf.ko /boot/modules/
cp /root/drm-kmod-612/ttm/ttm.ko /boot/modules/
cp /root/drm-kmod-612/drm/drm.ko /boot/modules/
cp /root/drm-kmod-612/i915/i915kms.ko /boot/modules/
reboot
```

**Second piece - re-probe the codec:** `hdac` probes HDA codecs at boot,
before i915 has enabled display audio, so the codec is missed on the first
pass. After Xorg/Kodi has set a mode, force an audio-enable cycle and
re-probe:

```sh
xrandr --output HDMI-1 --mode 1920x1080 --rate 60
devctl detach -f hdac0
devctl attach pci0:0:31:3
```

(if a plain mode re-apply does not trigger a fresh audio-enable commit, an
`xrandr --output HDMI-1 --off` first, then the `--mode` line, also works)

This is automated by [files/hdmi-audio-reprobe](files/hdmi-audio-reprobe),
called from `kodidisplay` (before Kodi starts) and from the watchdog (after
the TV is powered back on). Expected result:

```
hdacc0: <Intel (0x281c) HDA CODEC> at cad 2
pcm0: <Intel (0x281c) (HDMI/DP 8ch)> (play) default
```

and Kodi uses `OSS:/dev/dsp0|pcm0`.

> Upgrades of `drm-612-kmod` overwrite the patched modules - re-apply the
> patch and rebuild. Upstream bug: FreeBSD 285156, drm-kmod issue #296.

## 5. TV hotplug watchdog and TV-off suspension

`files/kodiwatchdog.sh` runs from `rc.d/kodiwatchdog` and keeps the display
alive. It also makes Kodi follow the TV without CEC:

* when the TV is switched off the HDMI sink disconnects; after ~30 s
  (`OFFLINE_STOP_TICKS`) Kodi is quit gracefully via JSON-RPC
  (`Application.Quit`, fallback TERM/KILL), Xorg stays up;
* when the TV comes back the output is re-enabled
  (`xrandr --mode 1920x1080 --rate 60 --primary`), the HDMI audio codec is
  re-probed and Kodi is started after the link has been stable for ~20 s
  (`CONNECT_STABLE_TICKS`), which tolerates the link flapping of a waking TV;
* at boot `rc.d/kodidisplay` only starts Kodi when HDMI is already active,
  otherwise the watchdog starts it when the TV is switched on;
* `files/newsyslog-kodi.conf` rotates the Kodi/watchdog logs, and the
  watchdog truncates `/var/log/messages` above 64 MiB (a drm vblank WARN
  loop once produced 145 GB of kernel log during TV transitions).

## 6. PVR with TVHeadend (optional)

Install the PVR addon and point it at your TVHeadend server:

```sh
pkg install -y kodi-addon-pvr.hts
```

In Kodi: *Add-ons -> PVR clients -> Tvheadend*, set host `<TVH_HOST>`,
HTSP port 9982 and your credentials; enable the addon. Live TV and
recordings then appear in Kodi's TV section.

## 7. Verify

```sh
kldstat -m i915kms                        # GPU driver loaded
pciconf -lv | grep -E '^(vgapci|hdac)'    # GPU + HDA on host
cat /dev/sndstat                          # pcm0 ... (HDMI/DP 8ch)
DISPLAY=:0 xrandr | grep '^HDMI-1'        # connected primary 1920x1080
doas tail /var/log/kodiwatchdog.log
doas grep -iE 'GUI format|OSS:' /root/.kodi/temp/kodi.log
doas tail /var/log/hdmi-audio-reprobe.log
```

Audio test without Kodi (Kodi holds `/dev/dsp0`; stop it first or use Kodi
JSON-RPC on TCP 9090): `play -q tones.wav` via SoX.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `symbol gpu_buddy_init undefined` on module load | you built only `i915kms` - rebuild the full `dmabuf ttm drm i915` set |
| Kodi `Unable to create GUI` | Xorg not running or no output; check `kodidisplay`, `xrandr`, `pptdevs` |
| Black screen after TV off/on | watchdog should fix within ~10 s; else restart display stack (section 5) |
| `/dev/sndstat` empty after applying the patch | the codec re-probe did not run (or TV was off when it ran) - run `hdmi-audio-reprobe` |
| Sound gone after `pkg upgrade` | the drm-kmod upgrade replaced the patched modules - rebuild as in section 4 |
| Kodi GUI black but Kodi logs `GUI format 1920x1080` | plane/CRTC state issue after hotplug - watchdog restart |

## 9. Known upstream issues

* FreeBSD bug 285156 - "No HDMI audio on AlderLake N100" (root-caused and
  fixed by the patch in this repo)
* freebsd/drm-kmod issue #296 - HDMI audio regression in drm-kmod
* FreeBSD bug 300031 - bhyve GVT-d iGPU passthrough display faults on this
  SoC (why this recipe does not use a VM)

## 10. Files

```
files/hdmi-audio-reprobe     # force i915 audio enable + HDA codec re-probe
files/kodidisplay            # rc.d: Xorg + Kodi autostart (with re-probe)
files/kodiwatchdog.sh        # TV hotplug / crash watchdog
patches/drm-kmod-612-hdmi-audio-fix.patch
```

Tested on FreeBSD 15.1-RELEASE-p4, Kodi 22.0, drm-612-kmod 6.12.85,
UGREEN DXP2800 (Intel N100, 16 GB), LG TV.

No warranty; adapt paths/IPs to your setup. Contributions and corrections
welcome.
