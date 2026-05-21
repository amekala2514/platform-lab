resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_version
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  values = [file("${path.module}/values/ingress-nginx.yaml")]

  depends_on = [
    kind_cluster.platform_lab,
    helm_release.kube_prometheus_stack, # so the ServiceMonitor CRD exists
  ]
}
