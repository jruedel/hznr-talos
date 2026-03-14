output "controlplane_public_ips" {
  description = "Public IPv4 addresses of control plane nodes"
  value       = hcloud_server.controlplane[*].ipv4_address
}

output "controlplane_private_ips" {
  description = "Private network IPs of control plane nodes"
  value       = [for s in hcloud_server.controlplane : one(s.network[*].ip)]
}

output "worker_public_ips" {
  description = "Public IPv4 addresses of worker nodes"
  value       = hcloud_server.worker[*].ipv4_address
}

output "worker_private_ips" {
  description = "Private network IPs of worker nodes"
  value       = [for s in hcloud_server.worker : one(s.network[*].ip)]
}

output "load_balancer_ipv4" {
  description = "Public IPv4 address of the API load balancer (empty if single CP)"
  value       = var.control_plane_count > 1 ? hcloud_load_balancer.api[0].ipv4 : ""
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value = var.control_plane_count > 1 ? (
    "https://${hcloud_load_balancer.api[0].ipv4}:6443"
    ) : (
    "https://${hcloud_server.controlplane[0].ipv4_address}:6443"
  )
}
