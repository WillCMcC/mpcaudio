// Full browser download with the real official image fixture and the site's CSP.
// Needs Playwright + Chromium. node test/download.test.mjs <official .img> <output dir>
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { readFile, mkdir } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { AKAI_IMAGE } from '../site/core.js';

const site = fileURLToPath(new URL('../site/', import.meta.url));
const output = process.argv[3];
assert.ok(process.argv[2] && output, 'Pass the official image and an output directory');
await mkdir(output, { recursive: true });
const nginx = await readFile(new URL('../nginx.conf', import.meta.url), 'utf8');
const csp = nginx.match(/Content-Security-Policy "([^"]+)"/)[1];
const requests = [];
let broken = '';
const server = createServer(async (req, res) => {
  requests.push(req.url);
  res.setHeader('Content-Security-Policy', csp);
  res.setHeader('Permissions-Policy', 'usb=(self)');
  if (req.url === AKAI_IMAGE.proxyPath) {
    if (broken === 'firmware') { res.end('damaged'); return; }
    createReadStream(process.argv[2]).pipe(res); return;
  }
  try {
    const path = req.url === '/' ? 'index.html' : req.url.slice(1);
    const bytes = await readFile(join(site, path));
    if (path === 'patch.bin' && broken === 'patch') bytes[100] ^= 1;
    res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' })[extname(path)] || 'application/octet-stream');
    res.end(bytes);
  } catch { res.writeHead(404).end(); }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ acceptDownloads: true });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.addInitScript(() => Object.defineProperty(navigator, 'usb', { value: undefined }));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.click('#install');
  assert.match(await page.textContent('#status-text'), /Chrome or Edge/);
  let downloads = 0;
  page.on('download', () => downloads++);
  for (const failure of ['firmware', 'patch']) {
    broken = failure;
    await page.click('#download');
    await page.waitForFunction(() => !document.getElementById('download').disabled);
    assert.match(await page.getAttribute('#status', 'class'), /error/);
    assert.equal(downloads, 0, 'Damaged inputs must never be downloadable');
    assert.equal(await page.isDisabled('#install'), false);
  }
  broken = '';
  const pending = page.waitForEvent('download', { timeout: 180000 });
  await page.click('#download');
  assert.equal(await page.isDisabled('#install'), true);
  assert.equal(await page.isDisabled('#restore'), true);
  const download = await pending;
  assert.equal(download.suggestedFilename(), AKAI_IMAGE.name);
  await download.saveAs(join(output, 'browser.img'));
  assert.equal(await download.failure(), null);
  await page.waitForFunction(() => !document.getElementById('download').disabled);
  assert.match(await page.getAttribute('#status', 'class'), /done/);
  assert.equal(downloads, 1);
  assert.deepEqual(errors, []);
  assert.equal(requests.filter((r) => r === AKAI_IMAGE.proxyPath).length, 3);
  await page.screenshot({ path: join(output, 'download-desktop.png') });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: join(output, 'download-mobile.png') });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  console.log('PASS: download without WebUSB; damaged firmware/patch rejected; retry, locking, filename, CSP, desktop/mobile layout');
  console.log(`Downloaded file: ${join(output, 'browser.img')}`);
} finally {
  await browser.close();
  server.close();
}
