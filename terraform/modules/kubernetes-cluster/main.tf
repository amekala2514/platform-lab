# kubernetes-cluster module
# ----------------------------------------------------------------------------
# Phase 1 (local): Documents the cluster shape for kind.
# Phase 2 (cloud): Replace with real provider resources (e.g. aws_eks_cluster,
#                  google_container_cluster) and wire into the cloud environment.
# ----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Cluster name"
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "environment" {
  description = "Target environment: local | aws-dev | gcp-dev"
  type        = string
  default     = "local"
}

output "cluster_name" {
  value = var.cluster_name
}

output "node_count" {
  value = var.node_count
}

output "environment" {
  value = var.environment
}
