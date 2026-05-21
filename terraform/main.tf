terraform {
  required_version = ">= 1.6"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }
}

provider "kind" {}

resource "kind_cluster" "platform_lab" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }

    node { role = "worker" }
    node { role = "worker" }
  }
}

provider "kubernetes" {
  host                   = kind_cluster.platform_lab.endpoint
  cluster_ca_certificate = kind_cluster.platform_lab.cluster_ca_certificate
  client_certificate     = kind_cluster.platform_lab.client_certificate
  client_key             = kind_cluster.platform_lab.client_key
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.platform_lab.endpoint
    cluster_ca_certificate = kind_cluster.platform_lab.cluster_ca_certificate
    client_certificate     = kind_cluster.platform_lab.client_certificate
    client_key             = kind_cluster.platform_lab.client_key
  }
}
