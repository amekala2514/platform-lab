resource "kubernetes_namespace" "observability" {
  metadata { name = "observability" }
  depends_on = [kind_cluster.platform_lab]
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata { name = "ingress-nginx" }
  depends_on = [kind_cluster.platform_lab]
}
