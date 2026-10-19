import { AKAI_IMAGE, ROOTFS, sha256 } from './core.js';

// XZ with CRC32 and stored LZMA2 chunks. This trades disk space (~421 MiB) for a
// quick browser build without another WASM dependency. It is a normal XZ stream:
// https://tukaani.org/xz/xz-file-format.txt
// https://github.com/tukaani-project/xz-embedded/blob/master/linux/lib/xz/xz_dec_lzma2.c
const crcTable = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let i = 0; i < 8; i++) n = (n >>> 1) ^ ((n & 1) ? 0xedb88320 : 0);
  return n >>> 0;
});
function crc32(bytes, crc = 0xffffffff) {
  for (const b of bytes) crc = (crc >>> 8) ^ crcTable[(crc ^ b) & 255];
  return crc >>> 0;
}
function putCrc(bytes, start, end) {
  new DataView(bytes.buffer).setUint32(end, (crc32(bytes.subarray(start, end)) ^ 0xffffffff) >>> 0, true);
}
function vli(n) {
  const bytes = [];
  while (n >= 128) { bytes.push((n % 128) | 128); n = Math.floor(n / 128); }
  bytes.push(n);
  return bytes;
}
const align4 = (n) => Math.ceil(n / 4) * 4;

export async function storeXz(rootfs, onProgress = () => {}) {
  const chunkSize = 65536;
  const dataSize = rootfs.length + 3 * Math.ceil(rootfs.length / chunkSize) + 1;
  const unpaddedSize = 12 + dataSize + 4; // block header + data + CRC32
  const records = [0, 1, ...vli(unpaddedSize), ...vli(rootfs.length)];
  const indexSize = align4(records.length) + 4;
  const out = new Uint8Array(12 + align4(unpaddedSize) + indexSize + 12);
  const dv = new DataView(out.buffer);
  out.set([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0, 0, 1]); // XZ magic, CRC32
  putCrc(out, 6, 8);
  out.set([2, 0, 0x21, 1, 0], 12); // 12-byte block header, LZMA2, 4 KiB dictionary
  putCrc(out, 12, 20);
  let pos = 24, crc = 0xffffffff;
  for (let offset = 0; offset < rootfs.length; offset += chunkSize) {
    const chunk = rootfs.subarray(offset, offset + chunkSize), size = chunk.length - 1;
    out.set([offset === 0 ? 1 : 2, size >>> 8, size & 255], pos); pos += 3;
    out.set(chunk, pos); pos += chunk.length;
    crc = crc32(chunk, crc);
    if (offset % (8 * 1024 * 1024) === 0) {
      onProgress(offset / rootfs.length);
      await new Promise((resolve) => setTimeout(resolve, 0)); // let the page paint
    }
  }
  out[pos++] = 0; // LZMA2 end marker
  pos = align4(pos);
  dv.setUint32(pos, (crc ^ 0xffffffff) >>> 0, true); pos += 4;
  out.set(records, pos);
  putCrc(out, pos, pos + indexSize - 4); pos += indexSize;
  dv.setUint32(pos + 4, indexSize / 4 - 1, true);
  out.set([0, 1, 0x59, 0x5a], pos + 8); // matching stream flags, YZ
  dv.setUint32(pos, (crc32(out.subarray(pos + 4, pos + 10)) ^ 0xffffffff) >>> 0, true);
  onProgress(1);
  return out;
}

/** Repack the verified official image with the exact rootfs used by Install. */
export async function buildUsbImage(image, rootfs, onProgress = () => {}) {
  if (rootfs.length !== ROOTFS.size || await sha256(rootfs) !== ROOTFS.patchedSha256) {
    throw new Error('Build check failed — reload the page');
  }
  const header = new Uint8Array(await image.slice(0, AKAI_IMAGE.xzOffset).arrayBuffer());
  // mpcimg2 PartInfo_t: 76 bytes immediately before the XZ payload.
  const part = AKAI_IMAGE.xzOffset - 76;
  if (new TextDecoder().decode(header.subarray(part, part + 5)) !== 'PARTL') throw new Error('Bad firmware header');
  const payload = await storeXz(rootfs, onProgress);
  const dv = new DataView(header.buffer);
  dv.setBigUint64(part + 8, BigInt(payload.length), true);
  header.set(new Uint8Array(await crypto.subtle.digest('SHA-1', payload)), part + 56);
  const padding = new Uint8Array((8 - (header.length + payload.length) % 8) % 8);
  return new Blob([header, payload, padding, image.slice(-16)], { type: 'application/octet-stream' });
}
