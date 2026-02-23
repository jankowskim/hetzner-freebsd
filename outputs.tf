output "server_ip" {
  value       = hcloud_server.jail_server.ipv4_address
  description = "Public IPv4 address of the server"
}

output "server_name" {
  value       = hcloud_server.jail_server.name
  description = "Name of the server"
}

output "snapshot_name" {
  value       = data.hcloud_image.freebsd.name
  description = "Name of the snapshot used"
}

output "ssh_command" {
  value       = "ssh -p ${var.ssh_port} root@${hcloud_server.jail_server.ipv4_address}"
  description = "SSH command to connect to the server"
}
