# --- SSH Key (dummy — Talos ignores SSH, but Hetzner requires one) ---

resource "tls_private_key" "talos" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "talos" {
  name       = "${var.cluster_name}-talos"
  public_key = tls_private_key.talos.public_key_openssh
  labels     = local.common_labels
}

# --- Private Network ---

resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-network"
  ip_range = var.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.subnet_cidr
}

# --- Firewall ---

resource "hcloud_firewall" "talos" {
  name   = "${var.cluster_name}-firewall"
  labels = local.common_labels

  # Talos API — needed for talosctl from operator machine
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "50000"
    source_ips = var.operator_cidrs
  }

  # Kubernetes API
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.operator_cidrs
  }

  # etcd (2379-2380), kubelet (10250), Flannel VXLAN (4789):
  # No rules needed — all traffic goes over the private network,
  # and Hetzner Cloud Firewalls don't apply to private network traffic
}

# --- Placement Groups ---

resource "hcloud_placement_group" "controlplane" {
  name   = "${var.cluster_name}-controlplane"
  type   = "spread"
  labels = local.common_labels
}

resource "hcloud_placement_group" "worker" {
  name   = "${var.cluster_name}-worker"
  type   = "spread"
  labels = local.common_labels
}

# --- Control Plane Servers ---

resource "hcloud_server" "controlplane" {
  count              = var.control_plane_count
  name               = "${var.cluster_name}-cp-${count.index}"
  image              = var.image_id
  server_type        = var.server_type_controlplane
  location           = var.location
  placement_group_id = hcloud_placement_group.controlplane.id
  ssh_keys           = [hcloud_ssh_key.talos.id]
  firewall_ids       = [hcloud_firewall.talos.id]

  labels = merge(local.common_labels, {
    role = "controlplane"
  })

  network {
    network_id = hcloud_network.cluster.id
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# --- Worker Servers ---

resource "hcloud_server" "worker" {
  count              = var.worker_count
  name               = "${var.cluster_name}-worker-${count.index}"
  image              = var.image_id
  server_type        = var.server_type_worker
  location           = var.location
  placement_group_id = hcloud_placement_group.worker.id
  ssh_keys           = [hcloud_ssh_key.talos.id]
  firewall_ids       = [hcloud_firewall.talos.id]

  labels = merge(local.common_labels, {
    role = "worker"
  })

  network {
    network_id = hcloud_network.cluster.id
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# --- Load Balancer (only for HA with multiple control plane nodes) ---

resource "hcloud_load_balancer" "api" {
  count              = var.control_plane_count > 1 ? 1 : 0
  name               = "${var.cluster_name}-api-lb"
  load_balancer_type = "lb11"
  location           = var.location
  labels             = local.common_labels
}

resource "hcloud_load_balancer_network" "api" {
  count            = var.control_plane_count > 1 ? 1 : 0
  load_balancer_id = hcloud_load_balancer.api[0].id
  network_id       = hcloud_network.cluster.id
  depends_on       = [hcloud_network_subnet.nodes]
}

resource "hcloud_load_balancer_target" "controlplane" {
  count            = var.control_plane_count > 1 ? var.control_plane_count : 0
  type             = "server"
  load_balancer_id = hcloud_load_balancer.api[0].id
  server_id        = hcloud_server.controlplane[count.index].id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.api]
}

resource "hcloud_load_balancer_service" "api" {
  count            = var.control_plane_count > 1 ? 1 : 0
  load_balancer_id = hcloud_load_balancer.api[0].id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
