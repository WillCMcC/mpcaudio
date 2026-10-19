# MPC USB Audio Firmware

Firmware source for Akai MPC One / One+: stereo USB audio in both directions and USB MIDI while running in standalone mode. Based on Akai MPC 3.9.1 Gen1, with the mpc-uac2 1.2 add-on and optional SSH.

The computer can record the MPC’s main output and play audio into the MPC’s inputs 1/2. One USB-MIDI port carries notes and clock both ways. The add-on starts automatically after the MPC app boots and steps aside in Controller mode.

## Source

- `addon/tee/mpc_uac2_tee.c` — audio input/output bridge loaded into the MPC app.
- `addon/mpc-uac2.sh` — USB audio/MIDI gadget configuration.
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
