terraform {
  required_version = ">= 1.6"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Local backend — swap this for S3/GCS when moving to cloud
  backend "local" {
    path = "terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the local kind cluster"
  type        = string
  default     = "platform-lab"
}

variable "project_root" {
  description = "Absolute path to the platform-lab repo root"
  type        = string
  default     = "../../../"
}

# ---------------------------------------------------------------------------
# Generate a local kubeconfig symlink target record (informational)
# ---------------------------------------------------------------------------
resource "local_file" "cluster_info" {
  filename = "${path.module}/cluster-info.txt"
  content  = <<-EOT
    Cluster name : ${var.cluster_name}
    Created by   : Terraform local environment
    Kubeconfig   : ~/.kube/config (context: kind-${var.cluster_name})
    kubectl cmd  : kubectl cluster-info --context kind-${var.cluster_name}
  EOT
}

# ---------------------------------------------------------------------------
# Null resource — placeholder for future kind cluster lifecycle automation
# Replace with a real provider (e.g. hashicorp/kubernetes) as the project grows
# ---------------------------------------------------------------------------
resource "null_resource" "cluster_placeholder" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    command = "echo 'Terraform local env ready for cluster: ${var.cluster_name}'"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "cluster_name" {
  value = var.cluster_name
}

output "kubectl_context" {
  value = "kind-${var.cluster_name}"
}
