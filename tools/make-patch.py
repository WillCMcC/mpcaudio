#!/usr/bin/env python3
"""Block-level patch: Akai stock 3.9.1 Gen1 rootfs -> rootfs with the mpc-uac2 add-on.
usage: make-patch.py <stock-rootfs.ext4> <patched-rootfs.ext4> <out patch.bin> <out manifest.json>
patch.bin = b"MPCUAP01" | u32 blockSize | u32 nRuns | runs: (u32 firstBlock, u32 nBlocks, nBlocks*blockSize bytes)"""
import hashlib, json, struct, sys
a_path, b_path, out_bin, out_json = sys.argv[1:5]
BS = 1024   # ext4 block size of the MPC rootfs (441279488 = 430937 x 1 KiB)
a = open(a_path, 'rb').read(); b = open(b_path, 'rb').read()
assert len(a) == len(b) and len(a) % BS == 0, (len(a), len(b))
n = len(a) // BS
changed = [i for i in range(n) if a[i*BS:(i+1)*BS] != b[i*BS:(i+1)*BS]]
runs = []
for i in changed:
    if runs and runs[-1][0] + runs[-1][1] == i: runs[-1][1] += 1
    else: runs.append([i, 1])
out = bytearray(b'MPCUAP01' + struct.pack('<II', BS, len(runs)))
for first, cnt in runs:
    out += struct.pack('<II', first, cnt) + b[first*BS:(first+cnt)*BS]
open(out_bin, 'wb').write(out)
m = {
  "rootfsSize": len(a),
  "stockRootfsSha256": hashlib.sha256(a).hexdigest(),
  "patchedRootfsSha256": hashlib.sha256(b).hexdigest(),
  "patchSha256": hashlib.sha256(out).hexdigest(),
  "changedBlocks": len(changed), "runs": len(runs), "patchBytes": len(out),
}
json.dump(m, open(out_json, 'w'), indent=2); print(json.dumps(m, indent=2))
