# =============================================================================
# Hetzner Cloud — FreeBSD Jail Server Variables
# =============================================================================

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Set via TF_VAR_hcloud_token or -var flag."
}

variable "hcloud_location" {
  type        = string
  default     = "fsn1"
  description = "Hetzner Cloud datacenter (fsn1, nbg1, hel1, ash, hil)"
}

variable "server_type" {
  type        = string
  default     = "cx23"
  description = "Hetzner Cloud server type for the production server"
}

variable "server_name" {
  type        = string
  default     = "freebsd-jail"
  description = "Name for the server instance"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Path to SSH public key file to register with Hetzner Cloud"
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH listening port (must match the port baked into the snapshot)"
}

variable "snapshot_name" {
  type        = string
  default     = ""
  description = "Exact snapshot name to use. If empty, uses the most recent snapshot with label freebsd-snapshot=yes"
}

variable "firewall_rules" {
  type = list(object({
    protocol   = string
    port       = string
    source_ips = optional(list(string), ["0.0.0.0/0", "::/0"])
  }))
  default = []
  description = "Additional firewall rules (beyond SSH and ICMP which are always included)"
}
