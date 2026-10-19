#!/bin/bash
# Run INSIDE a Linux VM (e.g. Lima): bake the mpc-uac2 add-on into an Akai MPC Gen1 rootfs and repack an update .img.
# usage: build-image.sh <base rootfs.ext4> <stock akai .img (for header)> <out .img>
# needs: ~/work/mpcimg2 (TheKikGen/MPC-LiveXplore imgmaker/mpcimg2.c) and addon/tee/mpc_uac2_tee.so built first.
set -euo pipefail
BASE=$1; STOCK=$2; OUT=$3
A=$(cd "$(dirname "$0")/.." && pwd)   # addon/
W=$(mktemp -d); cp "$BASE" $W/rootfs.ext4; mkdir $W/m
sudo mount -o loop,rw $W/rootfs.ext4 $W/m
R=$W/m
sudo install -d -m 755 $R/usr/libexec/mpc-uac2 $R/usr/lib/systemd/system/acvs.service.d
for f in mpc-uac2.sh mpc-uac2d.sh mpc-uac2-prestart.sh; do sudo install -m 755 $A/$f $R/usr/libexec/mpc-uac2/$f; done
sudo install -m 755 $A/tee/mpc_uac2_tee.so $R/usr/libexec/mpc-uac2/mpc_uac2_tee.so
sudo install -m 644 $A/image/README $A/image/VERSION $R/usr/libexec/mpc-uac2/
sudo install -m 644 $A/image/mpc-uac2d.service $R/usr/lib/systemd/system/mpc-uac2d.service
sudo install -m 644 $A/image/50-mpc-uac2-tee.conf $R/usr/lib/systemd/system/acvs.service.d/50-mpc-uac2-tee.conf
sudo ln -sf ../mpc-uac2d.service $R/usr/lib/systemd/system/multi-user.target.wants/mpc-uac2d.service
sudo chown -R 0:0 $R/usr/libexec/mpc-uac2 $R/usr/lib/systemd/system/acvs.service.d $R/usr/lib/systemd/system/mpc-uac2d.service
ls -la $R/usr/libexec/mpc-uac2 $R/usr/lib/systemd/system/multi-user.target.wants/mpc-uac2d.service $R/usr/lib/systemd/system/acvs.service.d
df -k $R | tail -1
sudo umount $R
sudo e2fsck -fn $W/rootfs.ext4 | tail -1
cd ~/work && ./mpcimg2 -m "$STOCK" $W/rootfs.ext4 "$OUT" | tail -2
rm -f $W/rt.ext4; ./mpcimg2 -r "$OUT" $W/rt.ext4 >/dev/null && cmp $W/rt.ext4 $W/rootfs.ext4 && echo ROUNDTRIP_OK
sha256sum "$OUT"
rm -rf $W
