variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "platform-lab"
}

variable "base_domain" {
  description = "Base hostname suffix for ingress (use .test, never .local on macOS)"
  type        = string
  default     = "platform-lab.test"
}

variable "kps_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "77.1.0"
}

variable "ingress_nginx_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.13.0"
}

variable "metrics_server_version" {
  description = "metrics-server Helm chart version"
  type        = string
  default     = "3.13.0"
}

variable "argocd_version" {
  description = "Argo CD Helm chart version (argoproj/argo-helm)"
  type        = string
  default     = "8.6.3"
}

variable "argocd_admin_password" {
  description = "Argo CD admin password (bcrypt-hashed before storing). Default for homelab use."
  type        = string
  default     = "platform-admin"
  sensitive   = true
}

variable "gitops_repo_url" {
  description = "HTTPS URL of the GitOps repo Argo CD watches"
  type        = string
  default     = "https://github.com/amekala2514/platform-lab-gitops.git"
}

variable "gitops_target_revision" {
  description = "Git ref Argo CD tracks (branch, tag, or commit)"
  type        = string
  default     = "main"
}
