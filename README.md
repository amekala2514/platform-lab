# platform-lab

A reproducible local Kubernetes platform built with **Terraform**, **Helm**, and a Go microservice — instrumented end-to-end with Prometheus and Grafana.

[![Terraform](https://img.shields.io/badge/Terraform-1.6%2B-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![Helm](https://img.shields.io/badge/Helm-3-0F1689?logo=helm)](https://helm.sh/)
[![Go](https://img.shields.io/badge/Go-1.23-00ADD8?logo=go)](https://golang.org/)

> Stands up a complete observable Kubernetes platform — cluster, ingress, monitoring stack, custom application, and dashboards — with a single `terraform apply`.

---

## What this is

A portfolio-grade platform engineering project demonstrating:

- **Infrastructure as Code** — entire stack provisioned by Terraform (cluster + Helm releases + Kubernetes manifests)
- **Observability** — kube-prometheus-stack with custom RED-method dashboard auto-imported via ConfigMap sidecar
- **Application instrumentation** — Go service exporting Prometheus metrics through HTTP middleware
- **Production patterns** — ServiceMonitor-based scraping, DaemonSet ingress controller, hostname-based routing

## Architecture

```
                            ┌────────────────────────────────────┐
                            │   macOS host (Kind via Docker)     │
                            │                                    │
  http://*.platform-lab.test│  ┌──────────────────────────────┐  │
  ───────────────────────►──┼──┤ control-plane node           │  │
                            │  │  ingress-nginx (DaemonSet)   │  │
                            │  │  hostPort 80/443             │  │
                            │  └────┬─────────────────────────┘  │
                            │       │                            │
                            │  ┌────▼─────────┬───────────────┐  │
                            │  │ worker-1     │ worker-2      │  │
                            │  │ platform-api │ platform-api  │  │
                            │  └──────────────┴───────────────┘  │
                            │                                    │
                            │  Namespaces:                       │
                            │    default        — platform-api   │
                            │    observability  — kps stack      │
                            │    ingress-nginx  — controller     │
                            │    kube-system    — metrics-server │
                            └────────────────────────────────────┘
```

## Stack

| Layer | Component | Version |
|---|---|---|
| Cluster | Kind (1 control-plane + 2 workers) | k8s 1.35 |
| IaC | Terraform + `tehcyx/kind`, `hashicorp/kubernetes`, `hashicorp/helm` | 1.6+ |
| Ingress | ingress-nginx (DaemonSet on control-plane, hostPort) | 4.13 |
| Monitoring | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, operators) | 77.1.0 |
| Metrics API | metrics-server | 3.13 |
| Application | platform-api (Go, instrumented with `prometheus/client_golang`) | 0.1.0 |

## Quick start

### Prerequisites

- Docker Desktop (or compatible runtime)
- Terraform ≥ 1.6
- kubectl
- kind
- Go 1.23+ (only if rebuilding the platform-api image)

### Add hostnames

```bash
sudo tee -a /etc/hosts <<'HOSTS'
127.0.0.1 platform-lab.test
127.0.0.1 grafana.platform-lab.test
127.0.0.1 prometheus.platform-lab.test
127.0.0.1 alertmanager.platform-lab.test
HOSTS
```

### Build the application image

```bash
cd go-services/platform-api
docker build -t platform-api:dev .
```

### Provision the platform

Terraform's `kubernetes_manifest` resource needs the cluster + CRDs to exist before it can plan, so this is a deliberate two-phase apply:

```bash
cd terraform
terraform init

# Phase 1 — cluster + Helm releases + dashboard ConfigMap
terraform apply -auto-approve \
  -target=kind_cluster.platform_lab \
  -target=kubernetes_namespace.observability \
  -target=kubernetes_namespace.ingress_nginx \
  -target=helm_release.metrics_server \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.ingress_nginx \
  -target=kubernetes_config_map.platform_api_dashboard

# Phase 2 — Ingresses + ServiceMonitor (now that CRDs exist)
terraform apply -auto-approve
```

### Deploy the application

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kind load docker-image platform-api:dev --name platform-lab
kubectl apply -f ../k8s/platform-api.yaml
kubectl rollout status deploy/platform-api
```

### Verify

```bash
curl -sf http://platform-lab.test/healthz
curl -sf http://platform-lab.test/metrics | head
```

Open the UIs:

| Service | URL | Credentials |
|---|---|---|
| platform-api | http://platform-lab.test | – |
| Grafana | http://grafana.platform-lab.test | `admin` / `platform-admin` |
| Prometheus | http://prometheus.platform-lab.test | – |
| Alertmanager | http://alertmanager.platform-lab.test | – |

The custom dashboard is at **Dashboards → Platform Lab → Platform API — RED + Runtime**.

### Tear down

```bash
cd terraform
terraform destroy -auto-approve
```

## Custom Grafana dashboard

`grafana/dashboards/platform-api.json` defines a 12-panel **RED-method** dashboard:

- **Stat row** — request rate, error rate (5xx %), p95 latency, in-flight requests
- **Time series** — request rate by path & status, latency p50/p95/p99
- **Distribution** — latency bucket heatmap, errors by status code
- **Go runtime** — goroutines, heap-in-use, GC pause

It's auto-imported into Grafana via the kube-prometheus-stack **sidecar** pattern: the dashboard JSON is wrapped in a `ConfigMap` labeled `grafana_dashboard=1` and the sidecar container watches for it cluster-wide.

## Application metrics

`platform-api` exposes Prometheus metrics at `/metrics` via `promhttp.Handler()`. An HTTP middleware records:

| Metric | Type | Labels |
|---|---|---|
| `http_requests_total` | CounterVec | `method`, `path`, `status` |
| `http_request_duration_seconds` | HistogramVec | `method`, `path` (default buckets) |
| `http_inflight_requests` | Gauge | – |

The `ServiceMonitor` (managed by Terraform) instructs the Prometheus operator to scrape the `platform-api` service every 15s.

## Repository layout

```
platform-lab/
├── terraform/             # Full IaC for the stack
│   ├── main.tf            # Providers + kind cluster
│   ├── variables.tf
│   ├── outputs.tf
│   ├── namespaces.tf
│   ├── metrics-server.tf
│   ├── ingress-nginx.tf
│   ├── kube-prometheus-stack.tf
│   ├── platform-api.tf    # Ingresses + ServiceMonitor
│   ├── values/            # Helm values files
│   └── dashboards/        # Grafana dashboard JSON (mounted as ConfigMap)
├── go-services/
│   └── platform-api/      # Go HTTP service with Prometheus instrumentation
├── k8s/
│   └── platform-api.yaml  # Deployment + Service (kubectl-applied)
├── helm/values/           # Reference values files (mirrors terraform/values)
├── grafana/dashboards/    # Source-of-truth dashboard JSON
└── README.md
```

## Notable engineering decisions

- **Kind + DaemonSet ingress** — ingress-nginx runs as a DaemonSet on the control-plane node, which has label `ingress-ready=true` and `hostPort: 80/443` mapped to localhost. This is the canonical Kind ingress pattern; `LoadBalancer` services stay `Pending` in Kind without MetalLB.
- **`.test` instead of `.local`** — macOS routes `.local` lookups through mDNS, which intercepts before `/etc/hosts`. `.test` is an [RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606) reserved TLD that goes through the normal resolver path.
- **Two-phase Terraform apply** — `kubernetes_manifest` resources do a server-side dry-run during `plan`, which fails on a cold cluster. Solved by targeting cluster + Helm releases first, then a full apply.
- **Dashboard via ConfigMap sidecar** — keeps the dashboard JSON in version control and lets Terraform handle import idempotently. No clicking through the Grafana UI on a fresh install.
- **Kind-tuned Prometheus rules** — disabled `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` ServiceMonitors and the `NodeClockNotSynchronising`/`CPUThrottlingHigh` rules that fire false-positives in Kind.
- **Application not in Terraform (yet)** — `platform-api` Deployment/Service are applied via `kubectl` because they iterate hourly during development. Terraform owns the platform; `kubectl` owns the app.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: Resolving timed out` on `.local` hostnames | macOS mDNS intercepts `.local` | Use `.test` hostnames (already done in this repo) |
| `terraform plan` fails with `cannot create REST client` | `kubernetes_manifest` server-side dry-run with no cluster | Use the two-phase apply above |
| Prometheus doesn't show `platform-api` in targets after creating ServiceMonitor | Stale operator config cache | `kubectl -n observability delete pod prometheus-kps-prometheus-0` |
| 503 from ingress to a backend that's running | Service port name/number mismatch in Ingress | Check `kubectl get svc <name>` ports vs. Ingress `port.number` |
| Docker `credsStore: desktop` errors during build/push | macOS Docker Desktop creds helper misconfigured | Remove `"credsStore": "desktop"` from `~/.docker/config.json` |

## Roadmap

- [ ] `.github/workflows/validate.yml` — `terraform fmt -check`, `validate`, `helm lint` on PRs
- [ ] `.github/workflows/plan.yml` — `terraform plan` posted as PR comment
- [ ] Alertmanager → Slack webhook + meaningful PrometheusRules
- [ ] GitOps with Argo CD
- [ ] Distributed tracing with OpenTelemetry + Grafana Tempo
- [ ] `docs/ARCHITECTURE.md`, `docs/GETTING_STARTED.md`
- [ ] Integration test workflow that provisions the cluster in GitHub Actions

## License

MIT
