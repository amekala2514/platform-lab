resource "kubernetes_manifest" "platform_api_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "platform-api"
      namespace = "default"
    }
    spec = {
      ingressClassName = "nginx"
      rules = [{
        host = var.base_domain
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "platform-api"
                port = { number = 8080 }
              }
            }
          }]
        }
      }]
    }
  }
  depends_on = [helm_release.ingress_nginx]
}

resource "kubernetes_manifest" "grafana_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "grafana"
      namespace = kubernetes_namespace.observability.metadata[0].name
    }
    spec = {
      ingressClassName = "nginx"
      rules = [{
        host = "grafana.${var.base_domain}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "kps-grafana"
                port = { number = 80 }
              }
            }
          }]
        }
      }]
    }
  }
  depends_on = [helm_release.ingress_nginx, helm_release.kube_prometheus_stack]
}

resource "kubernetes_manifest" "prometheus_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "prometheus"
      namespace = kubernetes_namespace.observability.metadata[0].name
    }
    spec = {
      ingressClassName = "nginx"
      rules = [{
        host = "prometheus.${var.base_domain}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "kps-kube-prometheus-stack-prometheus"
                port = { number = 9090 }
              }
            }
          }]
        }
      }]
    }
  }
  depends_on = [helm_release.ingress_nginx, helm_release.kube_prometheus_stack]
}

resource "kubernetes_manifest" "alertmanager_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "alertmanager"
      namespace = kubernetes_namespace.observability.metadata[0].name
    }
    spec = {
      ingressClassName = "nginx"
      rules = [{
        host = "alertmanager.${var.base_domain}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "kps-kube-prometheus-stack-alertmanager"
                port = { number = 9093 }
              }
            }
          }]
        }
      }]
    }
  }
  depends_on = [helm_release.ingress_nginx, helm_release.kube_prometheus_stack]
}

resource "kubernetes_manifest" "platform_api_servicemonitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "platform-api"
      namespace = kubernetes_namespace.observability.metadata[0].name
      labels    = { release = "kps" }
    }
    spec = {
      namespaceSelector = { matchNames = ["default"] }
      selector          = { matchLabels = { app = "platform-api" } }
      endpoints = [{
        port     = "http"
        path     = "/metrics"
        interval = "15s"
      }]
    }
  }
  depends_on = [helm_release.kube_prometheus_stack]
}
