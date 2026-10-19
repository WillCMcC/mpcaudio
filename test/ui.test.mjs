// End-to-end UI test with a mock WebUSB fastboot MPC (needs `playwright` + its Chromium; site served with the real
// nginx.conf so /akai/ proxies to Akai): node test/ui.test.mjs http://127.0.0.1:8088/ [install|restore]

import { chromium } from 'playwright';
const base = process.argv[2] || 'http://127.0.0.1:8088/';
const mode = process.argv[3] || 'install';
const browser = await chromium.launch();
const page = await browser.newPage();
const errors = []; page.on('pageerror', (e) => errors.push(String(e))); page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
await page.addInitScript(() => {
  // Mock WebUSB fastboot MPC (One+ in Update Mode): records the bytes it is sent and their SHA-256.
  const enc = (s) => new TextEncoder().encode(s);
  const log = (window.__fb = { cmds: [], bytes: 0, chunks: [] });
  let pending = [], expect = 0;
  const reply = (s) => pending.push(s);
  const dev = {
    vendorId: 0x09e8, productId: 0x4056, productName: 'MPC One Mk 2', serialNumber: 'TEST', configuration: null,
    async open() {}, async close() {}, async releaseInterface() {},
    async selectConfiguration() { this.configuration = { interfaces: [{ interfaceNumber: 0, alternates: [{ alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x03, endpoints: [{ direction: 'in', type: 'bulk', endpointNumber: 1 }, { direction: 'out', type: 'bulk', endpointNumber: 1 }] }] }] }; },
    async claimInterface() {},
    async transferOut(ep, data) {
      if (expect > 0) { log.bytes += data.byteLength; log.chunks.push(new Uint8Array(data)); expect -= data.byteLength; if (expect === 0) reply('OKAY'); return { status: 'ok', bytesWritten: data.byteLength }; }
      const cmd = new TextDecoder().decode(data); log.cmds.push(cmd);
      if (cmd === 'getvar:serialno') reply('OKAYTEST');
      else if (cmd === 'getvar:max-download-size') reply('OKAY0x70000000');
      else if (cmd.startsWith('download:')) { expect = parseInt(cmd.slice(9), 16); reply('DATA' + cmd.slice(9)); }
      else if (cmd === 'flash:rootfs') { reply('INFOwriting'); reply('OKAY'); }
      else reply('OKAY');
      return { status: 'ok', bytesWritten: data.byteLength };
    },
    async transferIn() { while (!pending.length) await new Promise((r) => setTimeout(r, 5)); return { status: 'ok', data: new DataView(enc(pending.shift()).buffer) }; },
  };
  Object.defineProperty(navigator, 'usb', { value: { requestDevice: async (o) => { window.__filters = o.filters; return dev; }, getDevices: async () => [] } });
});
await page.goto(base);
const t0 = Date.now();
await page.click(mode === 'restore' ? '#restore' : '#install');
const steps = new Set();
for (;;) {
  const t = await page.textContent('#status-text').catch(() => '');
  if (t) steps.add(t.replace(/\d+%/, ''));
  const cls = await page.getAttribute('#status', 'class');
  if (/done|error/.test(cls || '')) break;
  if (Date.now() - t0 > 300000) { console.log('TIMEOUT'); break; }
  await page.waitForTimeout(250);
}
const res = await page.evaluate(async () => {
  const all = new Uint8Array(window.__fb.bytes); let o = 0; for (const c of window.__fb.chunks) { all.set(c, o); o += c.length; }
  const h = [...new Uint8Array(await crypto.subtle.digest('SHA-256', all))].map((b) => b.toString(16).padStart(2, '0')).join('');
  return { cmds: window.__fb.cmds, bytes: window.__fb.bytes, sha: h, filters: window.__filters.map((f) => f.productId.toString(16)) };
});
console.log('steps:', [...steps].join(' | '));
console.log('final:', await page.textContent('#status-text'), `(${((Date.now() - t0) / 1000).toFixed(1)}s)`);
console.log('commands:', res.cmds.join(', '));
console.log('bytes sent:', res.bytes, 'sha256:', res.sha.slice(0, 16), '| usb filters:', res.filters.join(','));
console.log('errors:', errors.length ? errors : 'none');
await page.screenshot({ path: `/tmp/pwtest/ui-${mode}.png` });
await browser.close();
