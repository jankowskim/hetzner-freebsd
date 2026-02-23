# FreeBSD on Hetzner Cloud — Example Variables
#
# Copy this file and customize:
#   cp example.pkrvars.hcl my.pkrvars.hcl
#   packer build -var-file=my.pkrvars.hcl hcloud-freebsd-snapshots.pkr.hcl
#
# Or set HCLOUD_TOKEN as an environment variable and pass variables inline:
#   packer build -var 'ssh_public_key=ssh-ed25519 AAAA...' hcloud-freebsd-snapshots.pkr.hcl

# FreeBSD version (must match an available VM-IMAGES release)
# freebsd_version = "14.2-RELEASE"

# Hetzner Cloud datacenter location
# hcloud_location = "fsn1"

# Server type for the build (temporary, destroyed after snapshot creation)
# hcloud_server_type = "cx23"

# Additional FreeBSD packages to install
# packages_to_install = ["vim", "htop", "git", "tmux"]

# SSH public key to bake into the snapshot for root access
# ssh_public_key = "ssh-ed25519 AAAA... user@host"

# SSH listening port (baked into sshd_config and PF firewall rules)
# ssh_port = 22

# Override FreeBSD download URL (e.g. for a local mirror)
# freebsd_x86_mirror_link = "https://your-mirror.example.com/FreeBSD-14.2-RELEASE-amd64.raw.xz"

# Pre-install Bastille jail manager and configure jail networking
# jail_ready = true

# Internal network CIDR for jails (only used when jail_ready = true)
# jail_network = "10.42.42.0/24"
