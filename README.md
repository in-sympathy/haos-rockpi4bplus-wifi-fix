# haos-rockpi4-wifi-fix

Fixes WiFi on Radxa ROCK Pi 4 boards that carry the **AzureWave AW-NB197SM** module (Broadcom BCM43430/1) when running Home Assistant OS from [citruz/haos-rockpi](https://github.com/citruz/haos-rockpi).

Fixes [citruz/haos-rockpi#50](https://github.com/citruz/haos-rockpi/issues/50).

## Symptoms

- `dmesg` shows a clean firmware attach: `Firmware: BCM43430/1 wl0: ... version 7.45.98`
- `wlan0` exists and NetworkManager reports it as `disconnected`
- Every scan returns nothing: `nmcli device wifi list` is empty, and the UI's "Search networks" finds nothing
- The same board finds networks fine under Armbian, DietPi or Radxa OS

## Do you have this module?

From the HAOS host shell:

```sh
cat /sys/bus/sdio/devices/*/device
```

| Output   | Module                               | This fix          |
|----------|--------------------------------------|-------------------|
| `0xa9a6` | AW-NB197SM (BCM43430/1, 2.4 GHz only) | **needed**        |
| `0x4345` | AP6256 (BCM43456, dual band)         | not applicable    |

Some ROCK Pi 4B+ batches (for example v1.73) ship with the AW-NB197SM instead of the AP6256 listed in Radxa's specs.

## Root cause

The HAOS image has no board-specific nvram for this chip (`brcmfmac43430-sdio.radxa,rockpi4b-plus.txt`), so `brcmfmac` falls back to the generic `brcmfmac43430-sdio.txt`. In the HAOS image that file is the **Raspberry Pi 3B / Zero W** calibration.

| nvram                       | `boardtype` | `boardflags` | `xtalfreq`  |
|-----------------------------|-------------|--------------|-------------|
| HAOS (Raspberry Pi)         | 0x0726      | 0x00404201   | **37400**   |
| Armbian (works on this board) | 0x0726    | 0x00404201   | **26000**   |

The AW-NB197SM runs from a 26 MHz crystal. Told it has the Pi's 37.4 MHz crystal, the chip programs its synthesizer for the wrong reference, so the radio tunes nowhere near 2.4 GHz. Firmware boots, the interface comes up, and the receiver hears nothing.

## Install

You need the **HAOS host root shell**. The *Terminal & SSH* app runs in a container and will not work.

- **Console:** keyboard and HDMI, or UART at 115200 baud. At the `ha >` prompt, type `login`.
- **SSH on port 22222:** put your public key in a file named `authorized_keys` on a USB stick labelled `CONFIG`, plug it in and reboot. Then `ssh root@<ip> -p 22222`. See [Debugging the Home Assistant OS](https://developers.home-assistant.io/docs/operating-system/debugging/).

### Online (Ethernet connected)

```sh
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/haos-rockpi4-wifi-fix/main/install.sh -o /tmp/install.sh
sh /tmp/install.sh
```

If `curl` is missing, use `wget -O /tmp/install.sh <same URL>`.

### Offline

After flashing HAOS, the FAT boot partition (`hassos-boot`) appears on your PC. Copy `install.sh` onto it, boot the board, then run:

```sh
sh /mnt/boot/install.sh
```

Download the raw file; don't paste it through a Windows editor. CRLF line endings break it.

### What a successful run looks like

```
Installing to /mnt/data/brcm-nvram-fix ...
Boot hook: /etc/udev/rules.d/99-brcm-nvram-fix.rules
Applying now ...
brcm-nvram-fix: bound /mnt/data/brcm-nvram-fix/brcmfmac43430-sdio.txt over /usr/lib/firmware/brcm/brcmfmac43430-sdio.txt
brcm-nvram-fix: brcmfmac module loaded
Waiting for the WiFi interface ...
Scanning on wlan0 ...
IN-USE  BSSID              SSID        MODE   CHAN  RATE        SIGNAL  ...
...
OK: wlan0 sees 8 access point(s). This module is 2.4 GHz only.
```

Then connect from **Settings → System → Network → wlan0**, or run `nmcli device wifi connect "<SSID>" password '<password>'`.

## Commands

| Command                       | What it does                                                  |
|-------------------------------|---------------------------------------------------------------|
| `sh install.sh`               | Install and apply now                                         |
| `sh install.sh --status`      | Board, chip, active `xtalfreq`, driver state, boot hook log   |
| `sh install.sh --reapply`     | Re-apply and force a driver reload                            |
| `sh install.sh --uninstall`   | Remove everything and reload the driver with the stock nvram  |
| `--force`                     | Skip the HAOS, board and chip checks                          |

The installer refuses to run on boards without SDIO device `02d0:a9a6`. A 26 MHz nvram on a 37.4 MHz design, such as a real Raspberry Pi, would break WiFi there in exactly the same way.

## How it works

The installer writes two things:

- **`/mnt/data/brcm-nvram-fix/`**
  - `brcmfmac43430-sdio.txt` is the 26 MHz nvram. It is embedded in `install.sh` and checked against its MD5 when written.
  - `apply.sh` is the boot hook.
- **`/etc/udev/rules.d/99-brcm-nvram-fix.rules`** triggers on the SDIO function `02d0:a9a6` and on `wlan*` created by `brcmfmac`. It starts the hook through `systemd-run`, with `RequiresMountsFor=` so the hook waits until `/mnt/data` is mounted.

The hook:

1. Takes a lock in `/run`. If another run holds it, it exits.
2. Compares the nvram that is currently active with the 26 MHz copy. If they already match, it exits. This is what stops the reload from re-triggering itself.
3. Bind-mounts the 26 MHz file over the stock `brcmfmac43430-sdio.txt`. Only that one file is shadowed; the rest of the firmware directory stays untouched.
4. Waits for the first probe to finish, then reloads `brcmfmac` (`rmmod` and `modprobe`, or a sysfs rebind if the driver is built in).

Nothing on the read-only rootfs is modified. HAOS keeps both `/mnt/data` and the `/etc/udev/rules.d` overlay across reboots and across OS updates done with `rauc install`, so the fix survives both. If a future image ships a correct nvram, the hook sees identical content and does nothing.

Hook log for the current boot:

```sh
journalctl -b -t brcm-nvram-fix
```

## Proper fix in the image

The clean upstream fix is to ship the 26 MHz nvram as `brcmfmac43430-sdio.radxa,rockpi4b-plus.txt` (and the matching names for other affected ROCK 4 variants) in the HAOS rootfs. The driver tries the board-specific name before the generic one, so boards with the AP6256 module are unaffected.

## Files

| Path                                 | Purpose                                                                  |
|--------------------------------------|--------------------------------------------------------------------------|
| `install.sh`                         | Installer, boot hook and udev rule. Self-contained, no downloads at runtime. |
| `firmware/brcmfmac43430-sdio.txt`    | The same nvram as a standalone file. MD5 `29030f406aa712ec2cd2c1c578273a46`. |

## Tested on

- Radxa ROCK Pi 4B+ v1.73 with AW-NB197SM
- Home Assistant OS 18.0.dev20260625 (citruz/haos-rockpi), kernel 6.18.35
- Home Assistant Core 2026.10.2

## Credits and licence

- Problem report: [citruz/haos-rockpi#50](https://github.com/citruz/haos-rockpi/issues/50)
- nvram: `brcm/brcmfmac43430-sdio.txt` from [armbian/firmware](https://github.com/armbian/firmware), redistributed unmodified under its original terms
- Scripts: MIT, see [LICENSE](LICENSE)
