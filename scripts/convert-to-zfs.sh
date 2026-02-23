#!/bin/sh
# Runs on FreeBSD (booted from UFS): creates a ZFS pool with a proper dataset
# layout in the free disk space, migrates the running system, and configures
# ZFS boot.
set -ex

echo "==> Converting UFS root to ZFS..."

# Load ZFS module (may already be loaded or built into the kernel)
kldstat -q -m zfs || kldload zfs

# Resolve the root filesystem's GPT label to the physical disk
PART=$(glabel status -s | awk '/gpt\/rootfs/ {print $3}')
if [ -z "$PART" ]; then
  echo "ERROR: Could not find gpt/rootfs label. Labels found:"
  glabel status -s
  exit 1
fi
DISK=$(echo "$PART" | sed 's/p[0-9]*$//')
if [ -z "$DISK" ] || [ ! -e "/dev/$DISK" ]; then
  echo "ERROR: Could not determine disk from partition: $PART"
  exit 1
fi
echo "    Detected disk: $DISK (partition: $PART)"
gpart show "$DISK"

# Disable swap (frees the swap partition)
swapoff -a 2>/dev/null || true

# Recover GPT to recognize the full disk (VM image was smaller than the disk)
gpart recover "$DISK"

# Add ZFS partition using free space at end of disk
gpart add -t freebsd-zfs -l zfs0 "$DISK"

# Update protective MBR for UEFI compatibility
gpart bootcode -b /boot/pmbr "$DISK"

# --- Create ZFS pool with production settings ---
# -R /mnt sets altroot: datasets mount under /mnt now but store final mountpoints
zpool create -f \
  -O compress=lz4 \
  -O atime=off \
  -O mountpoint=none \
  -o autoexpand=on \
  -o autotrim=on \
  -o ashift=12 \
  -R /mnt \
  zroot /dev/gpt/zfs0

# --- Dataset layout (mountpoints are final; altroot prepends /mnt for now) ---

# Boot environment container
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ zroot/ROOT/default
zpool set bootfs=zroot/ROOT/default zroot

# Separate /usr dataset (keeps boot environments lean)
zfs create -o mountpoint=/usr zroot/usr

# Separate datasets for independent snapshots, quotas, and security properties
zfs create -o mountpoint=/tmp -o exec=off -o setuid=off -o devices=off zroot/tmp
zfs create -o mountpoint=/var zroot/var
zfs create -o mountpoint=/var/log -o exec=off -o setuid=off -o devices=off zroot/var/log
zfs create -o mountpoint=/var/tmp -o exec=off -o setuid=off -o devices=off zroot/var/tmp
zfs create -o mountpoint=/home -o setuid=off -o devices=off zroot/home

# --- Migrate running system to ZFS ---
echo "==> Copying system to ZFS..."
cd /
tar cpf - --one-file-system . | tar xpf - -C /mnt

# Verify critical files were copied (/boot/loader.conf may not exist on a fresh image)
for f in /mnt/etc/rc.conf /mnt/etc/ssh/sshd_config /mnt/boot/kernel/kernel; do
  if [ ! -f "$f" ]; then
    echo "ERROR: Critical file missing after copy: $f"
    exit 1
  fi
done

# Ensure required directories exist with correct permissions
mkdir -p /mnt/dev /mnt/proc /mnt/mnt
chmod 1777 /mnt/tmp /mnt/var/tmp

# --- Boot configuration ---

# Update loader.conf for ZFS boot (preserve existing settings)
if [ -f /mnt/boot/loader.conf ]; then
  sed -i '' '/^zfs_load/d; /^vfs.root.mountfrom/d; /^kern.geom.label/d; /^autoboot_delay/d; /^vfs.zfs.min_auto_ashift/d' /mnt/boot/loader.conf
fi
cat >> /mnt/boot/loader.conf << 'EOF'
zfs_load="YES"
vfs.root.mountfrom="zfs:zroot/ROOT/default"
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gptid.enable="0"
vfs.zfs.min_auto_ashift=12
autoboot_delay="3"
EOF

# Enable ZFS and disable crash dumps in rc.conf
sysrc -R /mnt zfs_enable=YES
sysrc -R /mnt dumpdev=NO

# Clear UFS fstab entries (ZFS manages its own mounts)
echo "# ZFS manages mountpoints — no fstab entries needed" > /mnt/etc/fstab

# Also update the CURRENT (UFS) loader.conf — the EFI loader reads from UFS first
if [ -f /boot/loader.conf ]; then
  sed -i '' '/^zfs_load/d; /^vfs.root.mountfrom/d' /boot/loader.conf
fi
cat >> /boot/loader.conf << 'EOF'
zfs_load="YES"
vfs.root.mountfrom="zfs:zroot/ROOT/default"
EOF

# Export pool cleanly before reboot (altroot is discarded on export)
sync
zpool export zroot || { echo "WARNING: zpool export failed, forcing..."; zpool export -f zroot; }

echo "==> ZFS conversion complete. Rebooting into ZFS..."
shutdown -r now
