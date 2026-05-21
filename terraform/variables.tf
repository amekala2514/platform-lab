variable "cluster_name" {
  type    = string
  default = "platform-lab"
}

variable "base_domain" {
  type    = string
  default = "platform-lab.test"
}

variable "kps_version" {
  type    = string
  default = "77.1.0"
}

variable "ingress_nginx_version" {
  type    = string
  default = "4.13.0"
}

variable "metrics_server_version" {
  type    = string
  default = "3.13.0"
}

variable "grafana_admin_password" {
  type      = string
  default   = "platform-admin"
  sensitive = true
}
