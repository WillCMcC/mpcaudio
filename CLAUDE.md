# mpcaudio

Static web installer at **mpcaudio.boy.dev** (CapRover app `mpcaudio`): gives an Akai MPC One / One+ USB-B audio
(UAC2) in **standalone**, both ways — a computer/Ableton can record the MPC's main out, and audio the computer
plays to the device lands on the MPC's inputs 1/2 (mixed with the physical line inputs). Built in Todoboy task 2541;
computer→MPC direction added in task 2548.
Full device history, backups and the SSH firmware for Will's unit: `~/Desktop/MPC-SSH/NOTES.md` (on the Mac mini).

## How it works (one click: put the MPC in Update Mode, plug in, Install)
1. The page downloads Akai's official `MPC-3.9.1-Gen1-update.img` through a same-origin nginx pass-through
   (`/akai/MPC-3.9.1-Gen1-update.img` → cdn.inmusicbrands.com; Akai's CDN sends no CORS headers). Nothing is stored
   here; `core.js` pins its size + SHA-256. 3.9.1 is the latest Gen1 release (2026-10); the bootloader can't report the
   MPC software version, so the page just states that Install brings the unit to 3.9.1.
2. The browser xz-decompresses the rootfs (`xz-decompress.min.js`, MIT, xz-embedded → WASM; needs CSP
   `'wasm-unsafe-eval'`), applies `patch.bin` (78 × 1 KiB ext4 blocks = add-on + SSH) and checks the result's SHA-256.
   SSH (Will's request, 2026-10-19): root with an EMPTY password (`addon/image/add-ssh.sh`, same as TheKikGen's tkgl
   images); `authorized_keys` stays stock — never put a personal key in this public image. Anyone on the MPC's network
   can log in as root; the page says "SSH (root, no password)".
3. WebUSB fastboot (`Fastboot` in `core.js`): MPC in Update Mode (= `reboot loader`) enumerates as `09e8:4056`
   "MPC One Mk 2" (One+), fastboot 0.4 in U-Boot. The device picker only offers the 8 Gen1 product IDs from the Akai
   image header (`GEN1_UPDATE_PIDS`), so Gen2 MPCs can't be selected. Sequence: `getvar:serialno`,
   `getvar:max-download-size`, `oem inmusic-unlock-magic-7de5fbc22b8c524e`, `download` (441,279,488 bytes raw ext4),
   `flash:rootfs` (~18 s, no reply meanwhile), `reboot`. Only the rootfs partition is written — never U-Boot — so a
   failed flash is retryable. Akai's own USB-stick updater writes the same raw ext4 to the same partition
   (verified byte-for-byte).
4. "Restore stock" flashes Akai's unmodified rootfs the same way.
5. "Download for USB stick" runs the same verified download, extraction and patch, then `usb-image.js` wraps the
   identical patched rootfs in an Akai V2 `.img`. It preserves the official AZ01 header/device table and 16-byte EOF
   trailer, replaces PARTL's payload size and SHA-1, and pads to the same 8-byte alignment as `mpcimg2 -m`.
   XZ uses CRC32 and stored LZMA2 chunks (standard XZ, ~421 MiB saved file), avoiding another WASM dependency and a
   lengthy browser compression step. Only the official ~155 MiB image crosses the network. No firmware is hosted or
   generated on the server; the browser saves `MPC-3.9.1-Gen1-update.img` for FAT32 / USB Drive Update.
   This path needs no WebUSB support or connected MPC. Generated images remain local; never commit or host them.

The add-on (`addon/`): `mpc-uac2d` supervisor starts a configfs UAC2 gadget 30 s after the MPC app starts in standalone,
steps aside in Controller mode; `mpc_uac2_tee.so` (LD_PRELOAD into the MPC app via an acvs.service drop-in) copies the
main out into the gadget (MPC→computer) **and** mixes the gadget's capture (computer→MPC) into the app's own input reads,
so the computer's audio shows on the MPC's inputs 1/2 alongside the line inputs. Both directions use one lock-free SPSC
ring each, drained/filled by a normal-priority worker (never blocks or spins in the app's audio thread) and corrected for
the USB↔codec clock difference by slipping one frame at a time. Lives in the rootfs: `/usr/libexec/mpc-uac2/`,
`/usr/lib/systemd/system/`. Units in the `/etc` overlay do NOT start at boot (etc.mount is too late) — keep boot hooks in the rootfs.

## Constraints
- No external resources; strict CSP (`script-src 'self' 'wasm-unsafe-eval'`); `Permissions-Policy: usb=(self)`.
- WebUSB: Chrome/Edge. `requestDevice` must be the first await in the click handler (user gesture).
- `core.js` hashes are the contract: change the add-on → rebuild `.so`, image, `patch.bin`, then update
  `ROOTFS.patchedSha256` / `PATCH_SHA256`.
- Never test with node-usb's WebUSB shim without overriding its 1000 ms bulk-transfer timeout (see
  `test/flash.test.mjs`): a cancelled read during `flash:rootfs` wedges the MPC's fastboot session until a USB reset.

## Commands
```bash
npm test                                   # pipeline check against the real Akai image (needs the file)
node test/ui.test.mjs <url> [install|restore]   # full page flow with a mock WebUSB MPC (playwright)
MPCIMG2=/path/to/mpcimg2 node test/usb-image.test.mjs <official .img> [output-dir] # native xz + mpcimg2 round-trip + cmp
node test/download.test.mjs <official .img> <output-dir> # Playwright: actual download without WebUSB, damaged inputs, retry
node test/flash.test.mjs <rootfs.ext4>     # flash via the same Fastboot class from Node (MPC in Update Mode)
./bin/release.sh                           # deploy (reconciler-driven via deploy.yaml — don't run by hand)
```
Test helpers (run on the MPC from /run): `addon/tee/uac2_rec.c` (capture levels, computer → MPC direction),
`~/Desktop/MPC-SSH/gadget/tee/uac2_tone.c` (test tone into the gadget).
Rebuild the image: `addon/tee/mpc_uac2_tee.so` is committed (the exact verified build). In a Linux VM: stock rootfs copy →
`addon/image/add-ssh.sh` → `addon/image/build-image.sh` (adds the add-on, repacks) → `mpcimg2 -r` →
`tools/make-patch.py`. To rebuild the .so itself, in a Linux VM, `arm-linux-gnueabihf-gcc -O2 -fPIC -shared -march=armv7-a -mfpu=neon-vfpv4
-mfloat-abi=hard -o addon/tee/mpc_uac2_tee.so addon/tee/mpc_uac2_tee.c -ldl -lpthread`, then
`addon/image/build-image.sh <stock rootfs.ext4> <stock .img> <out .img>`, extract its rootfs with `mpcimg2 -r`, and
`tools/make-patch.py <stock rootfs> <new rootfs> site/patch.bin tools/patch-manifest.json`.

## Routing
`mpcaudio.boy.dev` via `~/brain/bin/configure-boy-dev.sh` route `mpcaudio.boy.dev|mpcaudio|<title>MPC USB Audio</title>`.
