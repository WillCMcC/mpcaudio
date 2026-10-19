import { AKAI_IMAGE, ROOTFS, PATCH_SHA256, USB_FILTERS, sha256, fetchAkaiImage, extractRootfs, applyPatch, Fastboot, flashRootfs } from './core.js';
import { buildUsbImage } from './usb-image.js';

const $ = (id) => document.getElementById(id);
const installBtn = $('install'), restoreBtn = $('restore'), downloadBtn = $('download');
const statusBox = $('status'), barFill = $('bar-fill'), statusText = $('status-text');
let busy = false;
let downloadUrl;

function status(text, frac = null, cls = '') {
  statusBox.hidden = false;
  statusBox.className = `status ${cls}`;
  statusText.textContent = text;
  if (frac !== null) barFill.style.width = `${Math.round(frac * 100)}%`;
}
function lock(on) { busy = on; installBtn.disabled = on; restoreBtn.disabled = on; downloadBtn.disabled = on; }

async function buildRootfs(withAddon) {
  // progress budget: download 0–25 %, unpack 25–35 %, send 35–90 %, write 90–97 %
  const image = await fetchAkaiImage((f) => status(`Downloading MPC ${AKAI_IMAGE.version}…`, f * 0.25));
  status('Preparing…', 0.25);
  const rootfs = await extractRootfs(image, window['xz-decompress'].XzReadableStream, (f) => status('Preparing…', 0.25 + f * 0.1));
  if (withAddon) {
    const patch = new Uint8Array(await (await fetch('patch.bin')).arrayBuffer());
    if ((await sha256(patch)) !== PATCH_SHA256) throw new Error('Download damaged — reload the page');
    applyPatch(rootfs, patch);
  }
  if ((await sha256(rootfs)) !== (withAddon ? ROOTFS.patchedSha256 : ROOTFS.stockSha256)) throw new Error('Build check failed — reload the page');
  return { rootfs, image };
}

async function run(withAddon) {
  if (busy) return;
  if (!navigator.usb) { status('Use Chrome or Edge on a computer.', 0, 'error'); return; }
  let device;
  try {
    device = await navigator.usb.requestDevice({ filters: USB_FILTERS });   // first await: needs the click gesture
  } catch {
    status('No MPC found. Is it in Update Mode and connected by USB?', 0, 'error'); return;
  }
  lock(true);
  const fb = new Fastboot(device);
  try {
    const { rootfs } = await buildRootfs(withAddon);
    await fb.open();
    await flashRootfs(fb, rootfs, {
      onStep: (s) => {
        if (s === 'writing') status('Writing… don’t unplug', 0.9);
        if (s === 'rebooting') status('Restarting…', 0.97);
      },
      onProgress: (f) => status('Installing… don’t unplug', 0.35 + f * 0.55),
    });
    status(withAddon
      ? 'Done. When the MPC is back, choose “MPC One+ Audio” (or “MPC One Audio”) as an input on this computer.'
      : 'Done. Stock MPC 3.9.1 restored.', 1, 'done');
  } catch (e) {
    status(e.message || String(e), null, 'error');
    await fb.close();
  } finally {
    lock(false);
  }
}

async function download() {
  if (busy) return;
  lock(true);
  try {
    const { rootfs, image } = await buildRootfs(true);
    status('Preparing USB update…', 0.35);
    const file = await buildUsbImage(image, rootfs, (f) => status('Preparing USB update…', 0.35 + f * 0.6));
    if (downloadUrl) URL.revokeObjectURL(downloadUrl);
    downloadUrl = URL.createObjectURL(file);
    const link = document.createElement('a');
    link.href = downloadUrl;
    link.download = AKAI_IMAGE.name; // Akai's normal filename, also recognized by older updaters
    document.body.append(link);
    link.click();
    link.remove();
    status('Download ready. Copy to a FAT32 stick, then USB Drive Update.', 1, 'done');
  } catch (e) {
    status(e.message || String(e), null, 'error');
  } finally {
    lock(false);
  }
}

installBtn.addEventListener('click', () => run(true));
restoreBtn.addEventListener('click', () => run(false));
downloadBtn.addEventListener('click', download);
