locals {
  common_labels = {
    cluster       = var.cluster_name
    managed_by    = "terraform"
    talos_version = var.talos_version
  }
}
