// mpcaudio core — shared by the web page and the Node test harness. No DOM access here.
// Pipeline: Akai MPC-3.9.1-Gen1-update.img → xz rootfs → (+ add-on patch) → fastboot "flash:rootfs" over WebUSB.

export const AKAI_IMAGE = {
  name: 'MPC-3.9.1-Gen1-update.img',
  url: 'https://cdn.inmusicbrands.com/Software/MPC/MVSU391APC/MPC-3.9.1-Gen1-update.img',
  size: 162220784,
  sha256: '4c0f7797a006313fad206f9513eca8b3823e834c9e0941a6b5f088386cb835d6',
  xzOffset: 340,          // AZ01 header length for this exact file (mpcimg2 -i: "XZ Part. offset 340")
  xzLength: 162220428,
};
export const ROOTFS = {
  size: 441279488,
  stockSha256: '6aafd4384469a76df4c4270aa4f07b3f7e411828a691c75d5471c5fdfe2d69f3',
  patchedSha256: '7eaba72894930a3e533b9f89736689068f1cd4cb8e30e0190215fb9d40094ae6',
};
export const PATCH_SHA256 = '93ce90f5548db0b84ca07e687f831fe79d2787c73fd4589ea0b86729223e9857';
export const FASTBOOT_UNLOCK = 'oem inmusic-unlock-magic-7de5fbc22b8c524e';   // TheKikGen/MPC-LiveXplore usrbin/fastboot-live.sh
export const USB_FILTER = { vendorId: 0x09e8, classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03 };

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
export async function sha256(bytes) { return hex(await crypto.subtle.digest('SHA-256', bytes)); }

/** Verify the user's file is exactly Akai's 3.9.1 Gen1 image. `file` is a Blob/File. */
export async function checkAkaiImage(file) {
  if (file.size !== AKAI_IMAGE.size) throw new Error(`Not ${AKAI_IMAGE.name} (wrong size)`);
  const digest = await sha256(await file.arrayBuffer());
  if (digest !== AKAI_IMAGE.sha256) throw new Error(`Not ${AKAI_IMAGE.name} (checksum mismatch)`);
}

/** Decompress the rootfs out of the Akai image. XzReadableStream comes from xz-decompress. */
export async function extractRootfs(file, XzReadableStream, onProgress = () => {}) {
  const xz = file.slice(AKAI_IMAGE.xzOffset, AKAI_IMAGE.xzOffset + AKAI_IMAGE.xzLength);
  const out = new Uint8Array(ROOTFS.size);
  const reader = new XzReadableStream(xz.stream()).getReader();
  let pos = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (pos + value.length > out.length) throw new Error('Rootfs larger than expected');
    out.set(value, pos); pos += value.length;
    onProgress(pos / out.length);
  }
  if (pos !== out.length) throw new Error('Rootfs smaller than expected');
  return out;
}

/** Apply patch.bin (b"MPCUAP01" | u32 blockSize | u32 nRuns | runs of (u32 first, u32 count, data)). */
export function applyPatch(rootfs, patch) {
  const p = new Uint8Array(patch), dv = new DataView(p.buffer, p.byteOffset, p.byteLength);
  if (new TextDecoder().decode(p.subarray(0, 8)) !== 'MPCUAP01') throw new Error('Bad patch');
  const bs = dv.getUint32(8, true), runs = dv.getUint32(12, true);
  let o = 16;
  for (let r = 0; r < runs; r++) {
    const first = dv.getUint32(o, true), count = dv.getUint32(o + 4, true); o += 8;
    const len = count * bs;
    rootfs.set(p.subarray(o, o + len), first * bs); o += len;
  }
  if (o !== p.length) throw new Error('Bad patch length');
  return rootfs;
}

/** Minimal fastboot client over a WebUSB device (browser navigator.usb or node `usb` WebUSB). */
export class Fastboot {
  constructor(device, log = () => {}) { this.dev = device; this.log = log; }

  async open() {
    const d = this.dev;
    await d.open();
    if (!d.configuration) await d.selectConfiguration(1);
    for (const intf of d.configuration.interfaces) {
      for (const alt of intf.alternates) {
        if (alt.interfaceClass === 0xff && alt.interfaceSubclass === 0x42 && alt.interfaceProtocol === 0x03) {
          await d.claimInterface(intf.interfaceNumber);
          if (intf.alternates.length > 1) await d.selectAlternateInterface(intf.interfaceNumber, alt.alternateSetting);
          this.epIn = alt.endpoints.find((e) => e.direction === 'in' && e.type === 'bulk').endpointNumber;
          this.epOut = alt.endpoints.find((e) => e.direction === 'out' && e.type === 'bulk').endpointNumber;
          this.intf = intf.interfaceNumber;
          return;
        }
      }
    }
    throw new Error('No fastboot interface — is the MPC in Update Mode?');
  }

  async #response() {
    for (;;) {
      const r = await this.dev.transferIn(this.epIn, 64);
      const s = new TextDecoder().decode(r.data);
      const kind = s.slice(0, 4), msg = s.slice(4);
      if (kind === 'INFO') { this.log(msg); continue; }
      if (kind === 'OKAY') return msg;
      if (kind === 'DATA') return msg;
      if (kind === 'FAIL') throw new Error(`MPC refused: ${msg}`);
      throw new Error(`Unexpected fastboot reply: ${s}`);
    }
  }

  async command(cmd) {
    await this.dev.transferOut(this.epOut, new TextEncoder().encode(cmd));
    return this.#response();
  }

  async getvar(name) { return this.command(`getvar:${name}`); }

  async download(data, onProgress = () => {}) {
    const size = data.length.toString(16).padStart(8, '0');
    const reply = await this.command(`download:${size}`);
    if (parseInt(reply, 16) !== data.length) throw new Error(`MPC accepted ${reply}, expected ${size}`);
    const CHUNK = 1 << 20;
    for (let o = 0; o < data.length; o += CHUNK) {
      await this.dev.transferOut(this.epOut, data.subarray(o, Math.min(o + CHUNK, data.length)));
      onProgress(Math.min(o + CHUNK, data.length) / data.length);
    }
    return this.#response();
  }

  async reboot() {
    try { await this.dev.transferOut(this.epOut, new TextEncoder().encode('reboot')); await this.#response(); } catch { /* device resets */ }
    try { await this.dev.close(); } catch { /* gone */ }
  }

  async close() { try { await this.dev.releaseInterface(this.intf); } catch {} try { await this.dev.close(); } catch {} }
}

/** Full install: unlock, send rootfs, write it, reboot. */
export async function flashRootfs(fb, rootfs, { onStep = () => {}, onProgress = () => {} } = {}) {
  onStep('connecting');
  const serial = await fb.getvar('serialno');
  const max = parseInt(await fb.getvar('max-download-size'), 16);
  if (max && max < rootfs.length) throw new Error('MPC download buffer too small');
  await fb.command(FASTBOOT_UNLOCK);
  onStep('sending');
  await fb.download(rootfs, onProgress);
  onStep('writing');
  await fb.command('flash:rootfs');
  onStep('rebooting');
  await fb.reboot();
  return serial;
}
