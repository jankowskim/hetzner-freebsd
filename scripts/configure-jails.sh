#!/bin/sh
# Runs on FreeBSD (booted from ZFS): installs Bastille jail manager, creates
# a ZFS dataset for jails, configures the lo1 loopback interface for jail
# networking, and updates PF rules for NAT.
#
# Environment variables:
#   JAIL_READY         — set to "true" to enable jail configuration (otherwise exits)
#   JAIL_NETWORK       — CIDR for jail network (default: 10.42.42.0/24)
#   FREEBSD_VERSION    — FreeBSD release to bootstrap (e.g. 15.0-RELEASE)
#   SSH_PORT           — SSH listening port (for PF rules)
#   WEBRTC_TURN_TUNING — set to "true" to apply WebRTC/TURN sysctl tuning
set -eux

if [ "${JAIL_READY:-false}" != "true" ]; then
  echo "==> Skipping jail configuration (jail_ready=false)"
  exit 0
fi

SSH_PORT="${SSH_PORT:-22}"
JAIL_NETWORK="${JAIL_NETWORK:-10.42.42.0/24}"
: "${FREEBSD_VERSION:?FREEBSD_VERSION must be set}"

# Validate inputs
case "$SSH_PORT" in
  ''|*[!0-9]*) echo "ERROR: SSH_PORT must be numeric"; exit 1 ;;
esac
echo "$JAIL_NETWORK" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
  || { echo "ERROR: Invalid CIDR: $JAIL_NETWORK"; exit 1; }

# Derive gateway IP (first usable address in the network, e.g. 10.0.0.1)
JAIL_GW=$(echo "$JAIL_NETWORK" | sed 's|\.[0-9]*/.*|.1|')
# Derive netmask from CIDR prefix
CIDR_PREFIX=$(echo "$JAIL_NETWORK" | cut -d'/' -f2)
case "$CIDR_PREFIX" in
  8)  JAIL_NETMASK="255.0.0.0" ;;
  16) JAIL_NETMASK="255.255.0.0" ;;
  24) JAIL_NETMASK="255.255.255.0" ;;
  *)  echo "ERROR: Unsupported CIDR prefix /$CIDR_PREFIX (supported: /8, /16, /24)"; exit 1 ;;
esac

echo "==> Configuring Bastille jail manager..."
echo "    Jail network: $JAIL_NETWORK (gateway: $JAIL_GW)"

# =============================================================================
# Install Bastille
# =============================================================================

pkg install -y bastille

# =============================================================================
# ZFS dataset for jails
# =============================================================================

echo "==> Creating ZFS dataset for jails..."
zfs list zroot/bastille > /dev/null 2>&1 \
  || zfs create -o mountpoint=/usr/local/bastille zroot/bastille

# =============================================================================
# Bastille configuration
# =============================================================================

echo "==> Configuring Bastille..."
sysrc bastille_zfs_enable=YES
sysrc bastille_zfs_zpool=zroot
sysrc bastille_enable=YES

# Bastille also reads its own config file for ZFS settings
sed -i '' 's|^bastille_zfs_enable=.*|bastille_zfs_enable="YES"|' /usr/local/etc/bastille/bastille.conf
sed -i '' 's|^bastille_zfs_zpool=.*|bastille_zfs_zpool="zroot"|' /usr/local/etc/bastille/bastille.conf

# =============================================================================
# Loopback interface for jail networking
# =============================================================================

echo "==> Configuring lo1 interface..."
# Append lo1 to cloned_interfaces (preserves existing cloned interfaces)
EXISTING_CLONED=$(sysrc -n cloned_interfaces 2>/dev/null || echo "")
if echo "$EXISTING_CLONED" | grep -q "lo1"; then
  echo "    lo1 already in cloned_interfaces"
else
  sysrc cloned_interfaces+="lo1"
fi
sysrc ifconfig_lo1="inet ${JAIL_GW} netmask ${JAIL_NETMASK}"

# Enable IP forwarding (required for jail NAT)
sysrc gateway_enable="YES"

# Bring up lo1 now for the bootstrap step
ifconfig lo1 create 2>/dev/null || true
ifconfig lo1 inet "$JAIL_GW" netmask "$JAIL_NETMASK"

# Enable forwarding immediately (takes effect on next boot via gateway_enable)
sysctl net.inet.ip.forwarding=1

# =============================================================================
# PF firewall rules (replaces base rules with jail-aware version)
# =============================================================================

echo "==> Rewriting PF rules for jail NAT..."
cat > /etc/pf.conf << PF
# FreeBSD on Hetzner Cloud — Firewall Rules (Jail-Aware)
# Edit and reload: service pf reload

ext_if = "vtnet0"
jail_net = "${JAIL_NETWORK}"
table <bruteforce> persist

set block-policy return
set loginterface \$ext_if
set skip on lo0

# Normalize incoming traffic
scrub in all

# NAT for jail traffic (translation rules must precede filter rules)
nat on \$ext_if from \$jail_net to any -> (\$ext_if)

# Anti-spoofing
antispoof quick for \$ext_if

# Block brute-force attackers
block quick from <bruteforce>

# Default deny all traffic
block all

# Allow SSH (rate-limited)
pass in on \$ext_if proto tcp to port ${SSH_PORT} flags S/SA keep state \
  (max-src-conn-rate 5/30, overload <bruteforce> flush global)

# Allow all outbound traffic (stateful)
pass out all keep state

# Allow ICMP (ping and essential messages)
pass in on \$ext_if inet proto icmp icmp-type { echoreq, unreach }
pass in on \$ext_if inet6 proto icmp6 icmp6-type { echoreq, unreach, toobig, neighbrsol, neighbradv }

# Jail loopback — allow all traffic between host and jails
pass on lo1
PF
chmod 640 /etc/pf.conf

# Reload PF with new rules (ensure PF module is loaded)
kldstat -q -m pf || kldload pf 2>/dev/null || true
pfctl -f /etc/pf.conf || echo "WARNING: Could not reload PF rules (will apply on next boot)"

# =============================================================================
# WebRTC / TURN sysctl tuning (optional)
# =============================================================================

if [ "${WEBRTC_TURN_TUNING:-false}" = "true" ]; then
  echo "==> Applying WebRTC/TURN sysctl tuning..."
  cat >> /etc/sysctl.conf << 'SYSCTL'

# WebRTC / TURN relay tuning
kern.ipc.maxsockbuf=26214400
net.inet.udp.recvspace=2621440
SYSCTL

  # Apply immediately
  sysctl kern.ipc.maxsockbuf=26214400
  sysctl net.inet.udp.recvspace=2621440
else
  echo "==> Skipping WebRTC/TURN sysctl tuning (webrtc_turn_tuning=false)"
fi

# =============================================================================
# Bootstrap FreeBSD release for jails
# =============================================================================

echo "==> Bootstrapping FreeBSD ${FREEBSD_VERSION} for jails..."
bastille bootstrap "${FREEBSD_VERSION}" update

echo "==> Jail configuration complete."
echo "    - Bastille installed and enabled"
echo "    - ZFS dataset: zroot/bastille"
echo "    - Jail network: ${JAIL_NETWORK} on lo1"
echo "    - IP forwarding enabled (gateway_enable=YES)"
echo "    - PF NAT configured"
echo "    - FreeBSD ${FREEBSD_VERSION} bootstrapped"
