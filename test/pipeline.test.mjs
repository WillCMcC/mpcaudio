// Node check of the in-browser pipeline against the real Akai file:
//   node test/pipeline.test.mjs <path to MPC-3.9.1-Gen1-update.img>
import { openAsBlob } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { checkAkaiImage, extractRootfs, applyPatch, sha256, ROOTFS, PATCH_SHA256 } from '../site/core.js';
const require = createRequire(import.meta.url);
const { XzReadableStream } = require('../site/xz-decompress.min.js');
const file = await openAsBlob(process.argv[2]);
let t = Date.now(); await checkAkaiImage(file); console.log(`image ok ${Date.now() - t} ms`);
t = Date.now(); const rootfs = await extractRootfs(file, XzReadableStream); console.log(`xz → rootfs ${Date.now() - t} ms`);
const stock = await sha256(rootfs); console.log(`stock rootfs ${stock === ROOTFS.stockSha256 ? 'OK' : 'MISMATCH ' + stock}`);
const patch = await readFile(new URL('../site/patch.bin', import.meta.url));
console.log(`patch ${(await sha256(patch)) === PATCH_SHA256 ? 'OK' : 'MISMATCH'}`);
applyPatch(rootfs, patch);
const patched = await sha256(rootfs); console.log(`patched rootfs ${patched === ROOTFS.patchedSha256 ? 'OK' : 'MISMATCH ' + patched}`);
if (stock !== ROOTFS.stockSha256 || patched !== ROOTFS.patchedSha256) process.exit(1);
