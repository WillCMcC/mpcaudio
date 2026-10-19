#!/bin/bash
# Run INSIDE a Linux VM: apply the SSH enablement to an MPC Gen1 rootfs (in place, ext4 image file).
# Root login with an EMPTY password (sshd "none"/empty-password auth), like TheKikGen's tkgl SSH images.
# authorized_keys is left stock on purpose: never ship anyone's personal key in a public image.
# usage: add-ssh.sh <rootfs.ext4>
set -euo pipefail
F=$1; M=$(mktemp -d)
sudo mount -o loop,rw "$F" "$M"
sudo sed -i 's/^root:\*:/root::/' "$M/etc/shadow"
sudo sed -i 's/^KbdInteractiveAuthentication no/KbdInteractiveAuthentication yes/' "$M/etc/ssh/sshd_config"
printf '\n# --- mpcaudio SSH: root login with empty password ---\nPermitRootLogin yes\nPasswordAuthentication yes\nPermitEmptyPasswords yes\n' | sudo tee -a "$M/etc/ssh/sshd_config" >/dev/null
sudo tee "$M/etc/ssh/sshd_config.d/10-az0x.conf" >/dev/null <<'EOT'
HostKey /etc/ssh/ssh_host_ed25519_key
HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519

# --- mpcaudio SSH (was prohibit-password / no / no) ---
PermitRootLogin yes

PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords yes
EOT
sudo ln -sf /usr/lib/systemd/system/sshd.service "$M/etc/systemd/system/multi-user.target.wants/sshd.service"
sudo grep '^root' "$M/etc/shadow" | cut -d: -f1-2
sudo umount "$M"; rmdir "$M"
sudo e2fsck -fn "$F" | tail -1
