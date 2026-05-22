resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [kind_cluster.platform_lab]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [
    templatefile("${path.module}/values/argocd.yaml", {
      hostname = "argocd.${var.base_domain}"
    })
  ]

  set {
    name  = "configs.secret.argocdServerAdminPassword"
    value = bcrypt(var.argocd_admin_password, 10)
  }

  set {
    name  = "configs.secret.argocdServerAdminPasswordMtime"
    value = "2026-05-21T00:00:00Z"
  }

  lifecycle {
    ignore_changes = [
      set,
    ]
  }

  depends_on = [
    helm_release.ingress_nginx,
  ]
}

resource "kubernetes_manifest" "argocd_ingress" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "argocd-server"
      namespace = kubernetes_namespace.argocd.metadata[0].name
      annotations = {
        "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
      }
    }
    spec = {
      ingressClassName = "nginx"
      rules = [
        {
          host = "argocd.${var.base_domain}"
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "argocd-server"
                    port = {
                      number = 80
                    }
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = kubernetes_namespace.argocd.metadata[0].name
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = "apps"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ApplyOutOfSyncOnly=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}
