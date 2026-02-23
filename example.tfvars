# FreeBSD Jail Server — Terraform Example Variables
#
# Copy this file and customize:
#   cp example.tfvars my.tfvars
#   terraform plan -var-file=my.tfvars
#
# Or set the token as an environment variable:
#   export TF_VAR_hcloud_token="your-token"
#   terraform plan

# Hetzner Cloud API token (required — no default)
# hcloud_token = "your-hcloud-api-token"

# Hetzner Cloud datacenter location
# hcloud_location = "fsn1"

# Server type for the production server
# server_type = "cx23"

# Name for the server instance
# server_name = "freebsd-jail"

# Path to SSH public key to register with Hetzner Cloud
# ssh_public_key_path = "~/.ssh/id_ed25519.pub"

# SSH listening port (must match the port baked into the Packer snapshot)
# ssh_port = 22

# Exact snapshot name to use (if empty, uses the most recent freebsd-snapshot=yes)
# snapshot_name = "FreeBSD 15.0-RELEASE x86 ZFS Jails"
