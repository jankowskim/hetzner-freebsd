# =============================================================================
# Hetzner Cloud — Provision FreeBSD Jail Server from Packer Snapshot
# =============================================================================

# -----------------------------------------------------------------------------
# Snapshot lookup
# -----------------------------------------------------------------------------

data "hcloud_image" "freebsd" {
  with_selector = "freebsd-snapshot=yes"
  most_recent   = true
  name          = var.snapshot_name != "" ? var.snapshot_name : null
}

# -----------------------------------------------------------------------------
# SSH key
# -----------------------------------------------------------------------------

resource "hcloud_ssh_key" "deploy" {
  name       = "${var.server_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------

resource "hcloud_firewall" "jail_server" {
  name = "${var.server_name}-fw"

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(var.ssh_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # STUN/TURN TCP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "3478"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # STUN/TURN UDP
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "3478"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # TURNS (TLS)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "5349"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # TURN relay UDP range (must match coturn min-port/max-port)
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "49152-55000"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # ICMP
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------

resource "hcloud_server" "jail_server" {
  name        = var.server_name
  image       = data.hcloud_image.freebsd.id
  server_type = var.server_type
  location    = var.hcloud_location
  ssh_keys    = [hcloud_ssh_key.deploy.id]

  firewall_ids = [hcloud_firewall.jail_server.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = {
    role = "feilschaehr"
    os   = "freebsd"
  }
}
