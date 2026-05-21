output "kubeconfig_path" {
  value = kind_cluster.platform_lab.kubeconfig_path
}

output "endpoints" {
  value = {
    platform_api = "http://${var.base_domain}"
    grafana      = "http://grafana.${var.base_domain}"
    prometheus   = "http://prometheus.${var.base_domain}"
    alertmanager = "http://alertmanager.${var.base_domain}"
  }
}

output "grafana_admin_password" {
  value     = var.grafana_admin_password
  sensitive = true
}
