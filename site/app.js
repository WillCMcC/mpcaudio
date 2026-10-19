import { AKAI_IMAGE, ROOTFS, PATCH_SHA256, USB_FILTER, sha256, checkAkaiImage, extractRootfs, applyPatch, Fastboot, flashRootfs } from './core.js';

const $ = (id) => document.getElementById(id);
const drop = $('drop'), fileInput = $('file'), fileLabel = $('file-label');
const installBtn = $('install'), restoreBtn = $('restore');
const statusBox = $('status'), barFill = $('bar-fill'), statusText = $('status-text');
$('akai-link').href = AKAI_IMAGE.url;

let akaiFile = null;
let busy = false;

function status(text, frac = null, cls = '') {
  statusBox.hidden = false;
  statusBox.className = `status ${cls}`;
  statusText.textContent = text;
  if (frac !== null) barFill.style.width = `${Math.round(frac * 100)}%`;
}
function setReady(on) { installBtn.disabled = !on || busy; restoreBtn.disabled = !on || busy; }

async function takeFile(file) {
  if (!file || busy) return;
  drop.className = 'drop'; fileLabel.textContent = 'Checking…'; setReady(false); akaiFile = null;
  try {
    await checkAkaiImage(file);
    akaiFile = file;
    drop.className = 'drop ok'; fileLabel.textContent = `✓ ${file.name}`;
    setReady(true);
  } catch (e) {
    drop.className = 'drop bad'; fileLabel.textContent = `Wrong file. Use ${AKAI_IMAGE.name}.`;
  }
}

fileInput.addEventListener('change', () => takeFile(fileInput.files[0]));
drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
drop.addEventListener('dragleave', () => drop.classList.remove('over'));
drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); takeFile(e.dataTransfer.files[0]); });

async function buildRootfs(withAddon) {
  const { XzReadableStream } = window['xz-decompress'];
  status('Preparing…', 0);
  const rootfs = await extractRootfs(akaiFile, XzReadableStream, (f) => status('Preparing…', f * 0.3));
  if (withAddon) {
    const patch = new Uint8Array(await (await fetch('patch.bin')).arrayBuffer());
    if ((await sha256(patch)) !== PATCH_SHA256) throw new Error('Download damaged, reload the page');
    applyPatch(rootfs, patch);
  }
  if ((await sha256(rootfs)) !== (withAddon ? ROOTFS.patchedSha256 : ROOTFS.stockSha256)) throw new Error('Build check failed, reload the page');
  return rootfs;
}

async function run(withAddon) {
  if (!navigator.usb) { status('Use Chrome or Edge.', 0, 'error'); return; }
  let device;
  try {
    device = await navigator.usb.requestDevice({ filters: [USB_FILTER] });   // must run in the click handler
  } catch {
    status('No MPC selected. Is it in Update Mode and connected?', 0, 'error'); return;
  }
  busy = true; setReady(false);
  const fb = new Fastboot(device);
  try {
    const rootfs = await buildRootfs(withAddon);
    await fb.open();
    await flashRootfs(fb, rootfs, {
      onStep: (s) => ({ sending: () => status('Installing…', 0.3), writing: () => status('Writing… don’t unplug', 0.9), rebooting: () => status('Restarting…', 0.97) }[s] || (() => {}))(),
      onProgress: (f) => status('Installing… don’t unplug', 0.3 + f * 0.6),
    });
    status(withAddon ? 'Done. The MPC restarts. In standalone, pick “MPC One+ Audio” as an input on this computer.' : 'Done. Stock firmware restored.', 1, 'done');
  } catch (e) {
    status(`${e.message}`, null, 'error');
    await fb.close();
  } finally {
    busy = false; setReady(!!akaiFile);
  }
}

installBtn.addEventListener('click', () => run(true));
restoreBtn.addEventListener('click', () => run(false));
