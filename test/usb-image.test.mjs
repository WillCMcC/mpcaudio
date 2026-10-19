// Requires native xz and TheKikGen's mpcimg2, never contacts or writes an MPC.
// MPCIMG2=/path/to/mpcimg2 node test/usb-image.test.mjs <official Akai .img> [output directory]
import assert from 'node:assert/strict';
import { openAsBlob } from 'node:fs';
import { readFile, writeFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { AKAI_IMAGE, ROOTFS, PATCH_SHA256, checkAkaiImage, extractRootfs, applyPatch, sha256 } from '../site/core.js';
import { storeXz, buildUsbImage } from '../site/usb-image.js';
const require = createRequire(import.meta.url);
const { XzReadableStream } = require('../site/xz-decompress.min.js');
const mpcimg2 = process.env.MPCIMG2;
assert.ok(mpcimg2, 'Set MPCIMG2 to TheKikGen’s compiled mpcimg2');
for (const size of [0, 1, 65535, 65536, 65537, 1048577]) {
  const bytes = Uint8Array.from({ length: size }, (_, i) => i % 251);
  const xz = await storeXz(bytes);
  assert.deepEqual(execFileSync('xz', ['-dc'], { input: xz, maxBuffer: 2 ** 21 }), Buffer.from(bytes));
}
console.log('XZ chunk boundaries + CRC32 verified with native xz');

const dir = process.argv[3] || await mkdtemp(join(tmpdir(), 'mpcaudio-usb-'));
const image = await openAsBlob(process.argv[2]);
await checkAkaiImage(image);
const rootfs = await extractRootfs(image, XzReadableStream);
assert.equal(await sha256(rootfs), ROOTFS.stockSha256);
const patch = await readFile(new URL('../site/patch.bin', import.meta.url));
assert.equal(await sha256(patch), PATCH_SHA256);
applyPatch(rootfs, patch);
assert.equal(await sha256(rootfs), ROOTFS.patchedSha256);
await assert.rejects(buildUsbImage(image, new Uint8Array(1)), /Build check failed/);
const result = await buildUsbImage(image, rootfs);
const output = join(dir, AKAI_IMAGE.name), expected = join(dir, 'expected.ext4'), roundtrip = join(dir, 'roundtrip.ext4');
await writeFile(output, new Uint8Array(await result.arrayBuffer()));
await writeFile(expected, rootfs);
const header = new Uint8Array(await result.slice(0, AKAI_IMAGE.xzOffset).arrayBuffer());
const original = new Uint8Array(await image.slice(0, AKAI_IMAGE.xzOffset).arrayBuffer());
const part = AKAI_IMAGE.xzOffset - 76;
const payloadSize = Number(new DataView(header.buffer).getBigUint64(part + 8, true));
const payload = await result.slice(AKAI_IMAGE.xzOffset, AKAI_IMAGE.xzOffset + payloadSize).arrayBuffer();
assert.deepEqual(header.slice(part + 56, part + 76), new Uint8Array(await crypto.subtle.digest('SHA-1', payload)));
header.set(original.slice(part + 8, part + 16), part + 8);
header.set(original.slice(part + 56, part + 76), part + 56);
assert.deepEqual(header, original, 'Only PARTL size and SHA-1 may change');
assert.deepEqual(await result.slice(-16).arrayBuffer(), await image.slice(-16).arrayBuffer());
assert.equal((result.size - 16) % 8, 0, 'Akai trailer alignment');
await writeFile(join(dir, 'rootfs.xz'), new Uint8Array(payload));
execFileSync('xz', ['-t', join(dir, 'rootfs.xz')]);
console.log(execFileSync(mpcimg2, ['-i', output], { encoding: 'utf8' }));
console.log(execFileSync(mpcimg2, ['-r', output, roundtrip], { encoding: 'utf8' }));
execFileSync('cmp', [expected, roundtrip]);
console.log(`PASS: ${result.size} bytes; mpcimg2 round-trip is byte-identical to Install rootfs ${ROOTFS.patchedSha256}`);
console.log(`Output: ${output}`);
