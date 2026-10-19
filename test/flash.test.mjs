// Flash a rootfs file to an MPC in Update Mode with the SAME Fastboot class the web page uses (node `usb` WebUSB).
//   node test/flash.test.mjs <rootfs.ext4>
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { WebUSB } from 'usb';
// node-usb's WebUSB shim gives every bulk transfer a 1000 ms timeout (browsers have none). The MPC takes ~18 s
// to answer "flash:rootfs", so disable the timeout to behave like Chrome (node-usb treats 0 as "no wait", so use 120 s).
const native = createRequire(import.meta.url)('usb/index.js');
for (const m of ['transferIn', 'transferOut']) {
  const orig = native.UsbDevice.prototype[m];
  if (typeof orig !== 'function') throw new Error('cannot patch node-usb ' + m);
  native.UsbDevice.prototype[m] = function (ep, arg) { return orig.call(this, ep, arg, 120000); };
}
import { Fastboot, flashRootfs, USB_FILTER, sha256 } from '../site/core.js';
const rootfs = new Uint8Array(await readFile(process.argv[2]));
console.log('rootfs', rootfs.length, (await sha256(rootfs)).slice(0, 16));
const webusb = new WebUSB({ allowAllDevices: true });
const devs = (await webusb.getDevices()).filter((d) => d.vendorId === USB_FILTER.vendorId);
if (!devs.length) { console.error('no Akai device'); process.exit(1); }
const dev = devs[0];
console.log(`device ${dev.vendorId.toString(16)}:${dev.productId.toString(16)} "${dev.productName}" serial ${dev.serialNumber}`);
const fb = new Fastboot(dev, (m) => console.log('INFO', m));
await fb.open();
const t0 = Date.now(); let last = 0;
const serial = await flashRootfs(fb, rootfs, {
  onStep: (s) => console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s}`),
  onProgress: (f) => { if (f - last >= 0.25 || f === 1) { console.log(`  sent ${(f * 100).toFixed(0)}%`); last = f; } },
});
console.log(`done serial=${serial} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
