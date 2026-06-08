output "control_plane_ip" {
  value       = digitalocean_droplet.control_plane.ipv4_address
  description = "Public IP of the control plane node"
}

output "worker_ip" {
  value       = digitalocean_droplet.worker.ipv4_address
  description = "Public IP of the worker node"
}

output "ssh_command" {
  value       = "ssh -i ${path.module}/id_rsa_dr_drill root@${digitalocean_droplet.control_plane.ipv4_address}"
  description = "SSH command for the control plane"
}
