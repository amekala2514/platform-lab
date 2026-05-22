output "kubeconfig_path" {
  description = "Path to the kubeconfig for the kind cluster"
  value       = kind_cluster.platform_lab.kubeconfig_path
}

output "endpoints" {
  description = "Ingress endpoints (add these to /etc/hosts pointing at 127.0.0.1)"
  value = {
    platform_api = "http://platform-lab.${var.base_domain}"
    grafana      = "http://grafana.${var.base_domain}"
    prometheus   = "http://prometheus.${var.base_domain}"
    alertmanager = "http://alertmanager.${var.base_domain}"
    argocd       = "http://argocd.${var.base_domain}"
  }
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = "platform-admin"
  sensitive   = true
}

output "argocd_admin_password" {
  description = "Argo CD admin password (user: admin)"
  value       = var.argocd_admin_password
  sensitive   = true
}

output "argocd_initial_setup_hint" {
  description = "How to log in to Argo CD"
  value       = "Open http://argocd.${var.base_domain} -> user: admin -> password: terraform output -raw argocd_admin_password"
}
