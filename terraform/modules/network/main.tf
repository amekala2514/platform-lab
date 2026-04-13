# network module
# ----------------------------------------------------------------------------
# Phase 1 (local): No-op — kind handles its own networking via Docker.
# Phase 2 (cloud): Populate with VPC, subnets, and security group resources
#                  for the target cloud provider.
# ----------------------------------------------------------------------------

variable "environment" {
  description = "Target environment: local | aws-dev | gcp-dev"
  type        = string
  default     = "local"
}

variable "cidr_block" {
  description = "VPC CIDR block (used in cloud environments)"
  type        = string
  default     = "10.0.0.0/16"
}

output "environment" {
  value = var.environment
}

output "note" {
  value = "Network module is a placeholder for the local environment. Populate for cloud deployment."
}
