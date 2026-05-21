resource "helm_release" "kube_prometheus_stack" {
  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kps_version
  namespace  = kubernetes_namespace.observability.metadata[0].name

  values = [file("${path.module}/values/kube-prometheus-stack.yaml")]

  timeout = 600

  depends_on = [
    kind_cluster.platform_lab,
    kubernetes_namespace.observability,
  ]
}

resource "kubernetes_config_map" "platform_api_dashboard" {
  metadata {
    name      = "platform-api-dashboard"
    namespace = kubernetes_namespace.observability.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Platform Lab"
    }
  }

  data = {
    "platform-api.json" = file("${path.module}/dashboards/platform-api.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
