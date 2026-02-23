#!/bin/bash
# Runs in Hetzner rescue Linux: writes the FreeBSD UFS image to disk,
# mounts the UFS root, and configures SSHD + SSH keys before first boot.
# Note: bash required — runs in Hetzner Linux rescue (not FreeBSD), uses pipefail.
#
# Environment variables:
#   SSH_PUBKEY — user's SSH public key (optional; saved for later steps)
set -euo pipefail

echo '==> Writing FreeBSD image to disk...'

# Find the downloaded image (safer than ls | grep)
IMAGE=$(echo FreeBSD*.raw.xz)
if [ ! -f "$IMAGE" ]; then
  echo "ERROR: FreeBSD image not found"
  ls -la
  exit 1
fi

# Create temp partition at end of disk for the uncompressed image
echo '==> Creating temp partition for decompression...'
DISK_SECTORS=$(blockdev --getsz /dev/sda)
PART_SECTORS=16777216  # 8GB
PART_START=$((DISK_SECTORS - PART_SECTORS - 34))
if [ "$PART_START" -lt 2048 ]; then
  echo "ERROR: Disk too small (${DISK_SECTORS} sectors) for 8GB temp partition"
  exit 1
fi
echo "start=$PART_START, size=$PART_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4" | sfdisk /dev/sda --force
partprobe /dev/sda
udevadm settle || sleep 3

# Find the new temp partition
TEMP_PART=$(ls /dev/sda* | grep -E '^/dev/sda[0-9]+$' | sort -V | tail -1)
if [ -z "$TEMP_PART" ]; then
  echo "ERROR: Could not find temp partition after sfdisk"
  ls -la /dev/sda*
  exit 1
fi
echo "    Using temp partition: $TEMP_PART"

echo '==> Decompressing image...'
xz -dc "$IMAGE" > "$TEMP_PART"

echo '==> Writing image to disk...'
dd if="$TEMP_PART" of=/dev/sda bs=4M status=progress
sync

echo '==> Configuring FreeBSD...'
partprobe /dev/sda
udevadm settle || sleep 3

# Load UFS kernel module (built into most rescue kernels)
modprobe ufs || true

# Mount the FreeBSD UFS root partition
# FreeBSD VM image layout: sda1=EFI, sda2=freebsd-boot, sda3=freebsd-swap, sda4=freebsd-ufs
MOUNTED=false
for part in /dev/sda4 /dev/sda3 /dev/sda2; do
  echo "    Trying to mount $part..."
  if mount -t ufs -o ufstype=ufs2,rw "$part" /mnt 2>/dev/null; then
    echo "    Mounted $part as FreeBSD UFS root"
    MOUNTED=true
    break
  fi
done

if [ "$MOUNTED" = false ]; then
  echo "ERROR: Could not mount any FreeBSD UFS root partition"
  fdisk -l /dev/sda
  exit 1
fi

# --- rc.conf ---

# Disable growfs so the UFS partition stays small (leaves free space for ZFS)
if grep -q 'growfs_enable' /mnt/etc/rc.conf; then
  sed -i 's/growfs_enable=.*/growfs_enable="NO"/' /mnt/etc/rc.conf
else
  echo 'growfs_enable="NO"' >> /mnt/etc/rc.conf
fi

# Enable SSHD
if grep -q 'sshd_enable' /mnt/etc/rc.conf; then
  sed -i 's/sshd_enable=.*/sshd_enable="YES"/' /mnt/etc/rc.conf
else
  echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
fi

# --- SSH hardening ---

set_sshd_option() {
  local key="$1" value="$2" file="/mnt/etc/ssh/sshd_config"
  if grep -qE "^#?${key}" "$file"; then
    sed -i "s/^#*${key}.*/${key} ${value}/" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

set_sshd_option "PermitRootLogin" "prohibit-password"
set_sshd_option "PasswordAuthentication" "no"
set_sshd_option "KbdInteractiveAuthentication" "no"
set_sshd_option "ChallengeResponseAuthentication" "no"
set_sshd_option "X11Forwarding" "no"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "AllowTcpForwarding" "no"
set_sshd_option "AllowAgentForwarding" "no"
set_sshd_option "PermitEmptyPasswords" "no"
set_sshd_option "ClientAliveInterval" "300"
set_sshd_option "ClientAliveCountMax" "2"
set_sshd_option "LoginGraceTime" "30"
set_sshd_option "MaxSessions" "3"
set_sshd_option "MaxStartups" "10:30:60"
set_sshd_option "PermitUserEnvironment" "no"
set_sshd_option "UseDNS" "no"

# --- SSH keys ---

mkdir -p /mnt/root/.ssh
chmod 700 /mnt/root/.ssh

# Copy Packer's key for reconnection after reboots
if [ -f /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys
fi

# Save user's SSH key separately (clean-up-zfs.sh will remove Packer's key)
if [ -n "${SSH_PUBKEY:-}" ]; then
  echo "$SSH_PUBKEY" >> /mnt/root/.ssh/authorized_keys
  echo "$SSH_PUBKEY" > /mnt/root/.ssh/user_key.pub
fi
chmod 600 /mnt/root/.ssh/authorized_keys 2>/dev/null || true

# Unmount cleanly before reboot
sync
umount /mnt

echo '==> FreeBSD image written and configured. Rebooting into FreeBSD...'
sleep 1 && udevadm settle && reboot
