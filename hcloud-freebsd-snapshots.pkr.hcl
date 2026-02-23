/*
 * FreeBSD on Hetzner Cloud — Packer Snapshot Builder
 *
 * Creates a FreeBSD snapshot with:
 *   - ZFS root filesystem (LZ4, proper dataset layout)
 *   - SSH hardening (key-only authentication, configurable port)
 *   - PF firewall (default deny, SSH allowed)
 *   - Sysctl security hardening
 *   - NTP time synchronization
 *   - Optimized for cloud VMs (kern.hz=100)
 *   - Optional: Bastille jail manager with lo1/NAT networking
 */

packer {
  required_plugins {
    hcloud = {
      version = ">= 1.0.5"
      source  = "github.com/hashicorp/hcloud"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "hcloud_token" {
  type        = string
  default     = env("HCLOUD_TOKEN")
  sensitive   = true
  description = "Hetzner Cloud API token"

  validation {
    condition     = length(var.hcloud_token) > 0
    error_message = "The hcloud_token must be set (via HCLOUD_TOKEN env var or -var flag)."
  }
}

variable "freebsd_version" {
  type        = string
  default     = "15.0-RELEASE"
  description = "FreeBSD release version (e.g. 15.0-RELEASE, 14.2-RELEASE)"
}

variable "hcloud_location" {
  type        = string
  default     = "fsn1"
  description = "Hetzner Cloud datacenter (fsn1, nbg1, hel1, ash, hil)"
}

variable "hcloud_server_type" {
  type        = string
  default     = "cx23"
  description = "Hetzner Cloud server type for the build (temporary)"
}

variable "packages_to_install" {
  type        = list(string)
  default     = []
  description = "Additional packages to install via pkg (e.g. [\"vim\", \"htop\"])"
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "SSH public key to bake into root's authorized_keys"
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH listening port for the final snapshot (default: 22)"
}

variable "freebsd_x86_mirror_link" {
  type        = string
  default     = ""
  description = "Override the default FreeBSD x86 download URL"
}

variable "freebsd_arm_mirror_link" {
  type        = string
  default     = ""
  description = "Override the default FreeBSD ARM download URL"
}

variable "jail_ready" {
  type        = bool
  default     = false
  description = "Pre-install Bastille jail manager and configure jail networking (lo1, NAT)"
}

variable "jail_network" {
  type        = string
  default     = "10.42.42.0/24"
  description = "Internal network CIDR for jails (default: 10.42.42.0/24)"
}

variable "webrtc_turn_tuning" {
  type        = bool
  default     = false
  description = "Apply sysctl tuning for WebRTC/TURN relay (larger UDP buffers)"
}

# =============================================================================
# Locals
# =============================================================================

locals {
  freebsd_x86_url = (
    var.freebsd_x86_mirror_link != "" ? var.freebsd_x86_mirror_link :
    "https://download.freebsd.org/releases/VM-IMAGES/${var.freebsd_version}/amd64/Latest/FreeBSD-${var.freebsd_version}-amd64-ufs.raw.xz"
  )
  freebsd_arm_url = (
    var.freebsd_arm_mirror_link != "" ? var.freebsd_arm_mirror_link :
    "https://download.freebsd.org/releases/VM-IMAGES/${var.freebsd_version}/aarch64/Latest/FreeBSD-${var.freebsd_version}-arm64-ufs.raw.xz"
  )
  download_cmd = "wget --timeout=5 --waitretry=5 --tries=5 --retry-connrefused --inet4-only"
}

# =============================================================================
# Sources
# =============================================================================

source "hcloud" "freebsd-x86" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  location    = var.hcloud_location
  server_type = var.hcloud_server_type
  snapshot_labels = {
    freebsd-snapshot = "yes"
  }
  snapshot_name = var.jail_ready ? "FreeBSD ${var.freebsd_version} x86 ZFS Jails" : "FreeBSD ${var.freebsd_version} x86 ZFS"
  ssh_username  = "root"
  ssh_timeout   = "10m"
  token         = var.hcloud_token
}

# Uncomment to enable ARM builds (requires ARM server type, e.g. cax11):
#
# source "hcloud" "freebsd-arm" {
#   image       = "ubuntu-24.04"
#   rescue      = "linux64"
#   location    = var.hcloud_location
#   server_type = "cax11"
#   snapshot_labels = {
#     freebsd-snapshot = "yes"
#   }
#   snapshot_name = var.jail_ready ? "FreeBSD ${var.freebsd_version} ARM ZFS Jails" : "FreeBSD ${var.freebsd_version} ARM ZFS"
#   ssh_username  = "root"
#   token         = var.hcloud_token
# }

# =============================================================================
# Build — x86
# =============================================================================

build {
  sources = ["source.hcloud.freebsd-x86"]

  # Step 1: Download FreeBSD image (runs in Hetzner Linux rescue mode)
  provisioner "shell" {
    inline = ["${local.download_cmd} ${local.freebsd_x86_url}"]
  }

  # Step 2: Write image to disk, configure SSH (rescue mode → reboot into FreeBSD UFS)
  provisioner "shell" {
    script            = "scripts/write-image.sh"
    environment_vars  = ["SSH_PUBKEY=${var.ssh_public_key}"]
    expect_disconnect = true
  }

  # Step 3: Convert UFS root to ZFS with proper dataset layout (→ reboot into FreeBSD ZFS)
  provisioner "shell" {
    pause_before      = "30s"
    script            = "scripts/convert-to-zfs.sh"
    expect_disconnect = true
  }

  # Step 4: Install packages and apply system hardening
  # remote_folder=/root because /tmp has exec=off on ZFS
  provisioner "shell" {
    pause_before     = "30s"
    script           = "scripts/configure.sh"
    remote_folder    = "/root"
    environment_vars = ["PACKAGES=${join(" ", var.packages_to_install)}", "SSH_PORT=${var.ssh_port}"]
  }

  # Step 4b: Configure Bastille jail manager (optional, skipped when jail_ready=false)
  provisioner "shell" {
    script           = "scripts/configure-jails.sh"
    remote_folder    = "/root"
    environment_vars = [
      "JAIL_READY=${var.jail_ready}",
      "JAIL_NETWORK=${var.jail_network}",
      "FREEBSD_VERSION=${var.freebsd_version}",
      "SSH_PORT=${var.ssh_port}",
      "WEBRTC_TURN_TUNING=${var.webrtc_turn_tuning}",
    ]
  }

  # Step 5: Verify ZFS boot and clean up for snapshot
  provisioner "shell" {
    script           = "scripts/clean-up-zfs.sh"
    remote_folder    = "/root"
    environment_vars = ["SSH_PORT=${var.ssh_port}"]
  }
}

# =============================================================================
# Build — ARM (uncomment to enable)
# =============================================================================

# build {
#   sources = ["source.hcloud.freebsd-arm"]
#
#   provisioner "shell" {
#     inline = ["${local.download_cmd} ${local.freebsd_arm_url}"]
#   }
#
#   provisioner "shell" {
#     script            = "scripts/write-image.sh"
#     environment_vars  = ["SSH_PUBKEY=${var.ssh_public_key}"]
#     expect_disconnect = true
#   }
#
#   provisioner "shell" {
#     pause_before      = "30s"
#     script            = "scripts/convert-to-zfs.sh"
#     expect_disconnect = true
#   }
#
#   provisioner "shell" {
#     pause_before     = "30s"
#     script           = "scripts/configure.sh"
#     remote_folder    = "/root"
#     environment_vars = ["PACKAGES=${join(" ", var.packages_to_install)}", "SSH_PORT=${var.ssh_port}"]
#   }
#
#   provisioner "shell" {
#     script           = "scripts/configure-jails.sh"
#     remote_folder    = "/root"
#     environment_vars = [
#       "JAIL_READY=${var.jail_ready}",
#       "JAIL_NETWORK=${var.jail_network}",
#       "FREEBSD_VERSION=${var.freebsd_version}",
#       "SSH_PORT=${var.ssh_port}",
#       "WEBRTC_TURN_TUNING=${var.webrtc_turn_tuning}",
#     ]
#   }
#
#   provisioner "shell" {
#     script           = "scripts/clean-up-zfs.sh"
#     remote_folder    = "/root"
#     environment_vars = ["SSH_PORT=${var.ssh_port}"]
#   }
# }
