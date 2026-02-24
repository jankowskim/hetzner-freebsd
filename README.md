# FreeBSD on Hetzner Cloud

Automated [Packer](https://www.packer.io/) pipeline that builds FreeBSD snapshots** on [Hetzner Cloud](https://www.hetzner.com/cloud) with ZFS root filesystem and security hardening.

Hetzner Cloud doesn't offer FreeBSD as a native OS option. This project downloads an official FreeBSD VM image, writes it to a cloud server's disk, converts the root filesystem from UFS to ZFS, applies security hardening, and saves the result as a reusable snapshot.

## What's Included

The snapshot ships a hardened FreeBSD system.

### Storage
- ZFS root filesystem with **LZ4 compression** and `atime=off`
- Proper dataset layout: separate `/tmp`, `/var`, `/var/log`, `/var/tmp`, `/home`
- `autoexpand=on` and `autotrim=on` for SSD and disk resize support
- Boot environment support (`zroot/ROOT/default`)

### Security
- SSH **key-only authentication** (passwords disabled)
- **PF firewall** enabled — default deny with SSH and ICMP allowed (port configurable via `ssh_port`)
- **Sysctl hardening** — process visibility restrictions, TCP/UDP blackhole
- SSH host keys regenerated per instance

### System
- **NTP** time synchronization enabled
- **Sendmail** disabled
- Syslog hardened (no remote listening)
- `/tmp` cleaned on boot
- Daily ZFS health monitoring via periodic(8)
- Base packages: `ca_root_nss`, `sudo`, `curl`
- `pkg` bootstrapped and ready
- VM-optimized (`kern.hz=100`)

### Optional
- **Bastille jail manager** with lo1 loopback networking and PF NAT (enable with `jail_ready=true`)
- **WebRTC/TURN sysctl tuning** for larger UDP buffers (enable with `webrtc_turn_tuning=true`)

## Prerequisites

- [Packer](https://www.packer.io/) >= 1.7
- A [Hetzner Cloud](https://console.hetzner.cloud/) account
- An API token with read/write permissions ([generate one here](https://console.hetzner.cloud/projects/default/security/tokens))

## Quick Start

```bash
# Set your Hetzner Cloud API token
export HCLOUD_TOKEN="your-token-here"

# Initialize Packer plugins
packer init hcloud-freebsd-snapshots.pkr.hcl

# Build the snapshot
packer build hcloud-freebsd-snapshots.pkr.hcl
```

The build takes approximately 5-10 minutes. When complete, a snapshot named **"FreeBSD 15.0-RELEASE x86 ZFS"** appears in your Hetzner Cloud console under **Snapshots**.

## Configuration

Copy the example variables file and customize:

```bash
cp example.pkrvars.hcl my.pkrvars.hcl
# Edit my.pkrvars.hcl with your settings

packer build -var-file=my.pkrvars.hcl hcloud-freebsd-snapshots.pkr.hcl
```

Or pass variables directly:

```bash
packer build \
  -var 'ssh_public_key=ssh-ed25519 AAAA...' \
  -var 'packages_to_install=["vim", "htop", "git"]' \
  hcloud-freebsd-snapshots.pkr.hcl
```

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `freebsd_version` | `15.0-RELEASE` | FreeBSD release version |
| `hcloud_location` | `fsn1` | Datacenter location (fsn1, nbg1, hel1, ash, hil) |
| `hcloud_server_type` | `cx23` | Server type for the build (temporary) |
| `packages_to_install` | `[]` | Additional packages to install |
| `ssh_public_key` | `""` | SSH public key for root access |
| `ssh_port` | `22` | SSH listening port baked into the snapshot |
| `jail_ready` | `false` | Pre-install Bastille jail manager and configure jail networking (lo1, NAT) |
| `jail_network` | `10.42.42.0/24` | Internal network CIDR for jails |
| `webrtc_turn_tuning` | `false` | Apply sysctl tuning for WebRTC/TURN relay (larger UDP buffers) |
| `freebsd_x86_mirror_link` | auto | Override FreeBSD download URL |

### Changing the SSH Port

By default SSH listens on port 22. To use a non-standard port, set `ssh_port` at **both** the Packer build step and the Terraform deploy step — the values must match.

**Packer** bakes the port into the snapshot (`sshd_config` and PF firewall rules):

```bash
packer build -var 'ssh_port=2222' hcloud-freebsd-snapshots.pkr.hcl
```

**Terraform** opens the matching port in the Hetzner Cloud firewall:

```hcl
ssh_port = 2222
```

After deploying, connect with:

```bash
ssh -p 2222 root@<server-ip>
```

If the ports don't match, SSH will either be unreachable (firewall blocks it) or listen on a port that isn't allowed through.

### Bastille Jails

Set `jail_ready=true` to pre-install the [Bastille](https://bastillebsd.org/) jail manager and configure the networking stack for jails. This adds:

- **Bastille** package installed and enabled
- **ZFS dataset** `zroot/bastille` for jail storage
- **lo1 loopback interface** with a private jail network (default `10.42.42.0/24`, configurable via `jail_network`)
- **IP forwarding** enabled (`gateway_enable=YES`)
- **PF NAT rules** so jails can reach the internet through the host
- **FreeBSD release bootstrapped** for creating jails immediately after deploy

```bash
packer build \
  -var 'jail_ready=true' \
  -var 'jail_network=10.42.42.0/24' \
  hcloud-freebsd-snapshots.pkr.hcl
```

When enabled, the snapshot name changes to **"FreeBSD 15.0-RELEASE x86 ZFS Jails"**. After deploying, create a jail with:

```bash
bastille create myjail 15.0-RELEASE 10.42.42.1
bastille start myjail
bastille console myjail
```

### WebRTC/TURN Tuning

Set `webrtc_turn_tuning=true` to apply sysctl settings that increase UDP buffer sizes for WebRTC/TURN relay workloads (e.g., [coturn](https://github.com/coturn/coturn)). This requires `jail_ready=true` since it is applied during the jail configuration step.

The following sysctls are set:

| Sysctl | Value | Purpose |
|--------|-------|---------|
| `kern.ipc.maxsockbuf` | `26214400` (25 MB) | Maximum socket buffer size |
| `net.inet.udp.recvspace` | `2621440` (2.5 MB) | Default UDP receive buffer |

```bash
packer build \
  -var 'jail_ready=true' \
  -var 'webrtc_turn_tuning=true' \
  hcloud-freebsd-snapshots.pkr.hcl
```

These values are written to `/etc/sysctl.conf` and persist across reboots. Without this option, FreeBSD defaults apply (which may cause packet drops under heavy TURN relay traffic).

## Deploying a Server

### From the Hetzner Console

1. Go to **Servers** > **Add Server**
2. Under **Image**, select the **Snapshots** tab
3. Choose **"FreeBSD 14.2-RELEASE x86 ZFS"**
4. Select your SSH key and server type
5. Create the server

### Using hcloud CLI

```bash
# Find the snapshot ID
hcloud image list --type snapshot

# Create a server from the snapshot
hcloud server create \
  --name my-freebsd \
  --type cx23 \
  --image <snapshot-id> \
  --ssh-key <your-key-name> \
  --location fsn1
```

### Using Terraform (included)

This project includes a Terraform configuration that deploys a server from the Packer snapshot. It provisions the snapshot, registers your SSH key, and creates a Hetzner Cloud firewall with SSH and ICMP rules (additional ports are configurable via `firewall_rules`).

```bash
export TF_VAR_hcloud_token="your-token-here"

terraform init
terraform plan
terraform apply
```

After apply completes, Terraform outputs a ready-to-use SSH command:

```bash
terraform output ssh_command
# ssh -p 22 root@<server-ip>
```

#### Terraform Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `hcloud_token` | — | Hetzner Cloud API token (set via `TF_VAR_hcloud_token`) |
| `hcloud_location` | `fsn1` | Datacenter location |
| `server_type` | `cx23` | Hetzner Cloud server type |
| `server_name` | `freebsd-jail` | Name for the server instance |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Path to SSH public key file |
| `ssh_port` | `22` | SSH port (must match the port baked into the snapshot) |
| `snapshot_name` | `""` | Exact snapshot name to use; if empty, uses the most recent snapshot labeled `freebsd-snapshot=yes` |
| `firewall_rules` | `[]` | Additional inbound firewall rules (list of `{ protocol, port, source_ips }`) |

#### Firewall Rules

The Terraform firewall (`hcloud_firewall`) always includes **SSH** and **ICMP** rules. Additional service ports are configured via the `firewall_rules` variable.

By default no extra ports are opened. To add rules, set `firewall_rules` in your `terraform.tfvars`:

```hcl
firewall_rules = [
  { protocol = "tcp", port = "80" },
  { protocol = "tcp", port = "443" },
]
```

Each entry accepts `protocol` (tcp/udp), `port` (single port or range), and an optional `source_ips` (defaults to `["0.0.0.0/0", "::/0"]`). To restrict a rule to specific sources:

```hcl
firewall_rules = [
  { protocol = "tcp", port = "443", source_ips = ["10.0.0.0/8"] },
]
```

##### WebRTC / TURN Example

If you are running a WebRTC application with [coturn](https://github.com/coturn/coturn) in a jail, open the following ports:

```hcl
firewall_rules = [
  { protocol = "tcp", port = "80" },          # HTTP
  { protocol = "tcp", port = "443" },         # HTTPS
  { protocol = "tcp", port = "3478" },        # STUN/TURN TCP
  { protocol = "udp", port = "3478" },        # STUN/TURN UDP
  { protocol = "tcp", port = "5349" },        # TURNS (TLS)
  { protocol = "udp", port = "49152-55000" }, # TURN relay range (must match coturn min-port/max-port)
]
```

All outbound traffic is allowed by the Hetzner Cloud default. These rules complement the PF firewall running inside the snapshot — both must allow a port for traffic to reach a service.

#### Outputs

| Output | Description |
|--------|-------------|
| `server_ip` | Public IPv4 address |
| `server_name` | Server instance name |
| `snapshot_name` | Name of the snapshot used |
| `ssh_command` | Ready-to-use SSH command |

## Architecture

The Packer build runs a 5-stage pipeline on a temporary Hetzner Cloud server:

```
┌──────────┬───────────┬───────────┬───────────┬──────────┐
│ Download │   Write   │  Convert  │ Configure │ Cleanup  │
│  Image   │  Image    │  to ZFS   │  System   │ & Verify │
│          │  + SSH    │           │           │          │
│ (rescue) │ (rescue)  │ (FreeBSD) │ (FreeBSD) │(FreeBSD) │
│          │ → reboot  │ → reboot  │           │→snapshot │
└──────────┴───────────┴───────────┴───────────┴──────────┘
```

1. **Download** — Fetches the official FreeBSD VM image in Hetzner Linux rescue mode
2. **Write Image** — Decompresses and writes the image to disk, configures SSH for key-only access, reboots into FreeBSD (UFS)
3. **Convert to ZFS** — Creates a ZFS pool in the remaining disk space, migrates the system with a proper dataset layout, reboots into FreeBSD (ZFS)
4. **Configure** — Bootstraps `pkg`, installs packages, applies security hardening (PF firewall, sysctl, SSH), configures services (NTP, syslog)
5. **Cleanup** — Verifies ZFS boot, removes build artifacts (Packer keys, logs, caches, machine IDs), Packer creates the snapshot

The temporary build server is automatically destroyed after the snapshot is created.

### ZFS Dataset Layout

```
zroot                       pool (LZ4, atime=off, autoexpand, autotrim)
├── ROOT/default            /              (boot environment)
├── tmp                     /tmp           (exec=off, setuid=off)
├── var                     /var
│   ├── log                 /var/log
│   └── tmp                 /var/tmp       (exec=off, setuid=off)
└── home                    /home
```

### Security Configuration

**SSH** (`/etc/ssh/sshd_config`):
- `PermitRootLogin prohibit-password` — key-only root access
- `PasswordAuthentication no` — no password authentication
- `MaxAuthTries 3` — limit brute force attempts
- `X11Forwarding no` — disable X11

**PF Firewall** (`/etc/pf.conf`):
- Default deny all inbound traffic
- Allow SSH inbound (port 22 by default, configurable via `ssh_port`)
- Allow all outbound (stateful)
- Allow ICMP (ping + unreachable)
- Brute-force protection (5 connections per 30 seconds)

**Sysctl** (`/etc/sysctl.conf`):
- `security.bsd.see_other_uids=0` — users can't see others' processes
- `net.inet.tcp.blackhole=2` — silently drop TCP to closed ports
- `net.inet.udp.blackhole=1` — silently drop UDP to closed ports

## Post-Deployment

### Opening additional firewall ports

The default PF rules allow only SSH. To allow additional services, edit `/etc/pf.conf`:

```
# Example: allow HTTP and HTTPS
pass in on $ext_if proto tcp to port { 80, 443 } flags S/SA keep state
```

Then reload: `service pf reload`

### Creating a non-root user

```bash
pw useradd -n myuser -m -s /bin/sh -G wheel
mkdir -p /home/myuser/.ssh
cp /root/.ssh/authorized_keys /home/myuser/.ssh/
chown -R myuser:myuser /home/myuser/.ssh
visudo  # Uncomment: %wheel ALL=(ALL:ALL) ALL
```

### Updating the system

```bash
pkg update && pkg upgrade
```

### ZFS snapshots

```bash
# Create a snapshot before changes
zfs snapshot -r zroot@before-upgrade

# List snapshots
zfs list -t snapshot

# Rollback if needed
zfs rollback zroot/ROOT/default@before-upgrade
```

## ARM Support

ARM builds are included but commented out in the Packer config. To enable:

1. Open `hcloud-freebsd-snapshots.pkr.hcl`
2. Uncomment the `source "hcloud" "freebsd-arm"` block
3. Uncomment the ARM `build` block at the bottom
4. Run: `packer build hcloud-freebsd-snapshots.pkr.hcl`

ARM builds require an ARM-capable server type (e.g., `cax11`).

## Troubleshooting

**Build fails at "Download" step**
- Check your internet connection and try again
- If using a custom mirror, verify the URL is accessible
- Verify the FreeBSD version exists: `https://download.freebsd.org/releases/VM-IMAGES/`

**Build fails at "Convert to ZFS" step**
- The 30-second pause may not be enough for the server to reboot — increase `pause_before` in the Packer config

**Can't SSH after deploying from snapshot**
- Ensure you specified `ssh_public_key` during build, or use the Hetzner console to add your key
- Check PF rules from console: `pfctl -sr`

**PF is blocking my application**
- Edit `/etc/pf.conf` to allow your application's ports
- Reload: `service pf reload`
- To temporarily disable: `pfctl -d` (re-enables on reboot)

**Need to change the network interface in PF rules**
- Edit `/etc/pf.conf` and change `ext_if = "vtnet0"` to your interface
- List interfaces: `ifconfig`

## References

- [FreeBSD Handbook — Security](https://docs.freebsd.org/en/books/handbook/security/)
- [FreeBSD Handbook — Firewalls](https://docs.freebsd.org/en/books/handbook/firewalls/)
- [FreeBSD Handbook — ZFS](https://docs.freebsd.org/en/books/handbook/zfs/)
- [FreeBSD Handbook — Virtualization](https://docs.freebsd.org/en/books/handbook/virtualization/)
- [Hetzner Cloud API](https://docs.hetzner.cloud/)

## License

[BSD 2-Clause](LICENSE)
