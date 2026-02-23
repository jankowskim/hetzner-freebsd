#!/bin/sh
# Runs on FreeBSD (booted from ZFS): verifies ZFS root and thoroughly cleans
# the system for use as a reusable snapshot template.
#
# Environment variables:
#   SSH_PORT — configured SSH port (for summary display)
set -ex

echo "==> Verifying ZFS boot and cleaning up for snapshot..."

# =============================================================================
# Verify ZFS root
# =============================================================================

ROOTFS=$(mount -p | awk '$2 == "/" {print $1}')
echo "    Root filesystem: $ROOTFS"
if ! echo "$ROOTFS" | grep -q "zroot"; then
  echo "ERROR: Not booted from ZFS! Root is: $ROOTFS"
  exit 1
fi

echo "==> ZFS pool status:"
zpool status zroot
echo "==> ZFS datasets:"
zfs list

# =============================================================================
# SSH key management
# =============================================================================

# Remove SSH host keys (each server generates unique keys on first boot)
rm -f /etc/ssh/ssh_host_*

# Replace authorized_keys with only the user's key (remove Packer's temp key)
if [ -f /root/.ssh/user_key.pub ]; then
  cp /root/.ssh/user_key.pub /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  rm -f /root/.ssh/user_key.pub
else
  echo "WARNING: No SSH public key provided (ssh_public_key variable was empty)."
  echo "         The snapshot will have no authorized SSH keys."
  echo "         Set ssh_public_key to enable SSH access after deployment."
  rm -f /root/.ssh/authorized_keys
fi

# =============================================================================
# Clean machine-specific identifiers
# =============================================================================

# Remove hostid (regenerated on first boot)
rm -f /etc/hostid /var/db/hostid

# Remove saved entropy (each instance must generate its own)
# FreeBSD stores entropy in multiple locations across versions
rm -f /entropy
rm -rf /var/db/entropy/*
rm -f /boot/entropy
rm -f /var/db/entropy-file

# Remove machine-id files (may be created by dbus or similar packages)
rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# =============================================================================
# Clean logs, temp files, and caches
# =============================================================================

# Truncate log files (keep the files so newsyslog doesn't complain)
find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null || true
find /var/log -type f -name '*.gz' -delete 2>/dev/null || true
truncate -s 0 /var/log/utx.lastlogin 2>/dev/null || true
truncate -s 0 /var/log/utx.log 2>/dev/null || true

# Clear temporary files
rm -rf /tmp/* /var/tmp/*

# Clear package cache
pkg clean -ay 2>/dev/null || true

# Clear shell history
rm -f /root/.history /root/.sh_history /root/.bash_history
unset HISTFILE

# Clear mail spool
rm -f /var/mail/*

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==> Snapshot ready: FreeBSD on ZFS"
echo "    - ZFS root with LZ4 compression (autoexpand, autotrim, ashift=12)"
echo "    - SSH hardened (key-only, port ${SSH_PORT:-22})"
echo "    - PF firewall enabled (SSH port ${SSH_PORT:-22} + ICMP, brute-force protection)"
echo "    - NTP time synchronization enabled"
echo "    - Sendmail disabled"
echo "    - Sysctl security hardening applied"
echo "    - VM optimized (kern.hz=100)"
echo "    - Base packages: ca_root_nss, sudo, curl"
if zfs list zroot/bastille > /dev/null 2>&1; then
  echo "    - Bastille jail manager installed (zroot/bastille)"
  echo "    - Jail network on lo1 with PF NAT"
  bastille list 2>/dev/null || true
fi
