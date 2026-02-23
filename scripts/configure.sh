#!/bin/sh
# Runs on FreeBSD (booted from ZFS): bootstraps pkg, installs packages,
# applies system hardening, and configures services.
#
# Environment variables:
#   PACKAGES — space-separated list of additional packages to install
#   SSH_PORT — SSH listening port (default: 22)
set -ex

SSH_PORT="${SSH_PORT:-22}"

# Validate SSH_PORT
case "$SSH_PORT" in
  ''|*[!0-9]*) echo "ERROR: SSH_PORT must be numeric"; exit 1 ;;
esac

echo "==> Configuring system..."

# =============================================================================
# Package management
# =============================================================================

echo "==> Bootstrapping pkg..."
env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
pkg update

# Install essential packages
pkg install -y ca_root_nss sudo curl

# =============================================================================
# Service configuration (rc.conf)
# =============================================================================

echo "==> Configuring services..."

# Disable sendmail (enabled by default on FreeBSD)
sysrc sendmail_enable="NONE"
sysrc sendmail_submit_enable="NO"
sysrc sendmail_outbound_enable="NO"
sysrc sendmail_msp_queue_enable="NO"

# Enable NTP time synchronization
sysrc ntpd_enable="YES"
sysrc ntpd_sync_on_start="YES"

# Enable PF firewall (rules written below, starts on next boot)
sysrc pf_enable="YES"
sysrc pflog_enable="YES"

# Syslog: disable remote listening
sysrc syslogd_flags="-ss"

# Clean /tmp on boot
sysrc clear_tmp_enable="YES"

# Set SSH port (only takes effect on next boot, not during Packer build)
if [ "$SSH_PORT" != "22" ]; then
  echo "==> Setting SSH port to $SSH_PORT..."
  sed -i '' "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# =============================================================================
# VM optimization
# =============================================================================

# Reduce idle CPU usage from ~15% to ~5% on virtual machines
grep -q 'kern.hz' /boot/loader.conf || echo 'kern.hz=100' >> /boot/loader.conf

# =============================================================================
# PF firewall
# =============================================================================

echo "==> Writing PF firewall rules..."
cat > /etc/pf.conf << PF
# FreeBSD on Hetzner Cloud — Default Firewall Rules
# Edit and reload: service pf reload
# Reference: https://docs.freebsd.org/en/books/handbook/firewalls/

ext_if = "vtnet0"
table <bruteforce> persist

set block-policy return
set loginterface \$ext_if
set skip on lo0

# Normalize incoming traffic
scrub in all

# Anti-spoofing
antispoof quick for \$ext_if

# Block brute-force attackers
block quick from <bruteforce>

# Default deny all traffic
block all

# Allow SSH (rate-limited)
pass in on \$ext_if proto tcp to port $SSH_PORT flags S/SA keep state \
  (max-src-conn-rate 5/30, overload <bruteforce> flush global)

# Allow all outbound traffic (stateful)
pass out all keep state

# Allow ICMP (ping and essential messages)
pass in on \$ext_if inet proto icmp icmp-type { echoreq, unreach }
pass in on \$ext_if inet6 proto icmp6 icmp6-type { echoreq, unreach, toobig, neighbrsol, neighbradv }
PF
chmod 640 /etc/pf.conf

# =============================================================================
# Sysctl hardening
# =============================================================================

echo "==> Applying sysctl hardening..."
cat > /etc/sysctl.conf << 'SYSCTL'
# Security hardening
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.unprivileged_read_msgbuf=0
security.bsd.unprivileged_proc_debug=0
security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1

# Silently drop packets to closed ports (stealth mode)
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1

# Network hardening
net.inet.tcp.drop_synfin=1
net.inet.ip.random_id=1
net.inet.ip.redirect=0
net.inet6.ip6.redirect=0
net.inet.icmp.drop_redirect=1

# Disable core dumps (prevent information leakage)
kern.coredump=0
SYSCTL

# =============================================================================
# Periodic task configuration
# =============================================================================

cat > /etc/periodic.conf.local << 'PERIODIC'
# ZFS health monitoring
daily_status_zfs_enable="YES"

# Send periodic output to log files instead of email
daily_output="/var/log/daily.log"
weekly_output="/var/log/weekly.log"
monthly_output="/var/log/monthly.log"
PERIODIC

# =============================================================================
# Install user-specified packages (last, so hardening is applied even if this fails)
# =============================================================================

if [ -n "${PACKAGES:-}" ]; then
  echo "==> Installing user packages: $PACKAGES"
  # shellcheck disable=SC2086
  pkg install -y $PACKAGES
fi

echo "==> System configuration complete."
