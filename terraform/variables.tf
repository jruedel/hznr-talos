variable "cluster_name" {
  description = "Name prefix for all cluster resources"
  type        = string
  default     = "talos"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.cluster_name))
    error_message = "Cluster name must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}

variable "control_plane_count" {
  description = "Number of control plane nodes (1 for dev, 3 for HA)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "Control plane count must be 1 (dev) or 3 (HA)."
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "Worker count must be between 1 and 10."
  }
}

variable "server_type_controlplane" {
  description = "Hetzner server type for control plane nodes"
  type        = string
  default     = "cx23"
}

variable "server_type_worker" {
  description = "Hetzner server type for worker nodes"
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil"], var.location)
    error_message = "Location must be a valid Hetzner datacenter."
  }
}

variable "image_id" {
  description = "Hetzner snapshot ID of the Talos image (from Packer build)"
  type        = string
}

variable "talos_version" {
  description = "Talos version string for resource labeling"
  type        = string
  default     = "v1.12.5"
}

variable "network_cidr" {
  description = "CIDR for the Hetzner private network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the node subnet within the private network"
  type        = string
  default     = "10.0.1.0/24"
}
