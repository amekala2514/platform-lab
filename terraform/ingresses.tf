# ---------------------------------------------------------------------------
# Infrastructure UI ingresses (Grafana, Prometheus, Alertmanager)
# ---------------------------------------------------------------------------
# These stay in Terraform because they're tied to the kube-prometheus-stack
# Helm release, which is also Terraform-managed. The platform-api ingress
# moved to GitOps (Argo CD) — see platform-lab-gitops/workloads/platform-api/.

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
