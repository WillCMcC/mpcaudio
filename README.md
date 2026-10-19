# MPC USB Audio Firmware

Firmware source for Akai MPC One / One+: stereo USB audio in both directions and USB MIDI while running in standalone mode. Based on Akai MPC 3.9.1 Gen1, with the mpc-uac2 1.3 add-on and optional SSH.

The computer can record the MPC’s main output and play audio into the MPC’s inputs 1/2. One USB-MIDI port carries notes and clock both ways. The add-on starts automatically after the MPC app boots and steps aside in Controller mode.

## Drag files from Finder

Connect USB in standalone mode: **MPCTransfer** appears as a 1 GiB drive alongside audio/MIDI. Drop files or folders onto it, then **Eject** it in Finder. They appear on the SD card under **USB Imports / Transfer-<date>-<id>**. Reconnect USB for another batch; wait for the import folder to appear before removing the SD card or switching to Controller mode.

The transfer disk reserves 1 GiB of internal `/data` storage on first use (plus 512 MiB must remain free). The SD card itself stays with the MPC. Imports use a new folder and compare every copied file before clearing the transfer disk. A missing/full SD card leaves the batch pending for retry. Unplugging without eject keeps the disk for the next connection; reconnect and eject to import. Filesystem errors are retained for repair on the computer, never automatically formatted. Finder housekeeping and the supplied `START HERE.txt` are skipped.

`mpc-transferd` watches for the USB host's SCSI eject; it never mounts an image still owned by the host. State survives reboot, and interrupted imports resume without overwriting existing projects. Logs: `journalctl -u mpc-transferd`.

## YouTube into MPC, monitored through Ableton

On macOS select MPC One+ as the system audio output. In Live select MPC One+ as the **Audio Input Device**, and explicitly select Mac headphones or another interface as the **Audio Output Device**. Use an audio track with Ext. In 1/2 and Monitor In, and enable input monitoring on the MPC to put those inputs into its main mix. Listen through Live's chosen output. Routing Live's monitored output back to the MPC closes a feedback loop with this stereo routing.

## Source

- `addon/tee/mpc_uac2_tee.c` — audio input/output bridge loaded into the MPC app.
- `addon/mpc-uac2.sh` — USB audio/MIDI gadget configuration.
- `addon/mpc-transfer-watch.c` — remembers disconnects during imports.
- `addon/mpc-transfer.sh` — exclusive USB transfer-disk ownership and verified SD imports.
- `addon/mpc-uac2d.sh` — standalone/Controller-mode supervisor.
- `addon/mpc-uac2-prestart.sh` — startup cleanup and crash-loop failsafe.
- `addon/image/` — systemd units, SSH configuration and firmware image builder.

## Build firmware

Build on Linux with `make`, the ARM hard-float cross-compiler (`arm-linux-gnueabihf-gcc`), `e2fsprogs`, and root access for loop mounts. Use [TheKikGen’s mpcimg2](https://github.com/TheKikGen/MPC-LiveXplore) compiled with liblzma and OpenSSL at `~/work/mpcimg2`.

Download Akai’s official `MPC-3.9.1-Gen1-update.img` separately. Its SHA-256 must be:

```text
4c0f7797a006313fad206f9513eca8b3823e834c9e0941a6b5f088386cb835d6
```

From this repository, using absolute paths for the images:

```sh
make
~/work/mpcimg2 -r /path/to/MPC-3.9.1-Gen1-update.img /tmp/mpc-rootfs.ext4

# Optional: enable SSH as root with an empty password.
./addon/image/add-ssh.sh /tmp/mpc-rootfs.ext4

./addon/image/build-image.sh \
  /tmp/mpc-rootfs.ext4 \
  /path/to/MPC-3.9.1-Gen1-update.img \
  /tmp/MPC-3.9.1-Gen1-usbaudio-update.img
```

The builder repacks the rootfs into Akai’s V2 update format and verifies the extracted result byte-for-byte. Copy the resulting image to a FAT32 USB stick and use Menu › Preferences › Info › Update › USB Drive Update on the MPC.

Akai’s firmware is not distributed here; each image is built locally from the official download. SSH is optional; enabling it lets anyone on the MPC’s network log in as root without a password.

## Device support

Verified on MPC One+. MPC One uses the model’s USB ID but has not been hardware-tested. Audio is stereo at 44.1 kHz; computer audio is mixed with the physical inputs. The add-on stays dormant on other Gen1 models.

To disable the add-on, place an empty `MPC-UAC2-OFF` file at the root of a USB stick or SD card. To remove it, install Akai’s official firmware again.

USB gadget approach inspired by PolyVector; MPC firmware image format documented by TheKikGen/MPC-LiveXplore.
