locals {
  common_labels = {
    cluster       = var.cluster_name
    managed_by    = "terraform"
    talos_version = var.talos_version
  }

  # All node public IPs as /32 CIDRs for inter-node firewall rules
  node_public_cidrs = [
    for ip in concat(
      hcloud_server.controlplane[*].ipv4_address,
      hcloud_server.worker[*].ipv4_address
    ) : "${ip}/32"
  ]
}
