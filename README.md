# platform-lab

A reproducible local Kubernetes platform built with **Terraform**, **Helm**, **Argo CD**, and a Go microservice — instrumented end-to-end with Prometheus and Grafana, and managed via GitOps.

[![validate](https://github.com/amekala2514/platform-lab/actions/workflows/validate.yml/badge.svg)](https://github.com/amekala2514/platform-lab/actions/workflows/validate.yml)

[![Terraform](https://img.shields.io/badge/Terraform-1.6%2B-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![Helm](https://img.shields.io/badge/Helm-3-0F1689?logo=helm)](https://helm.sh/)
[![Argo CD](https://img.shields.io/badge/Argo%20CD-3.x-EF7B4D?logo=argo)](https://argo-cd.readthedocs.io/)
[![Go](https://img.shields.io/badge/Go-1.23-00ADD8?logo=go)](https://golang.org/)

> Stands up a complete observable Kubernetes platform — cluster, ingress, monitoring stack, GitOps controller, custom application, and dashboards — with a single `terraform apply`. Workloads are managed declaratively from a [separate gitops repo](https://github.com/amekala2514/platform-lab-gitops).

---

## What this is

A portfolio-grade platform engineering project demonstrating:

- **Infrastructure as Code** — entire platform (cluster + Helm releases + Argo CD + ingresses) provisioned by Terraform
- **GitOps** — workloads defined in a separate repo, continuously reconciled by Argo CD
- **Observability** — kube-prometheus-stack with custom RED-method dashboard auto-imported via ConfigMap sidecar
- **Application instrumentation** — Go service exporting Prometheus metrics through HTTP middleware
- **Production patterns** — ServiceMonitor-based scraping, DaemonSet ingress controller, hostname-based routing, app-of-apps pattern

## Architecture

```
                          ┌───────────────────────────────────────────┐
                          │   macOS host (Kind via Docker)            │
                          │                                           │
http://*.platform-lab.test│  ┌─────────────────────────────────────┐  │
─────────────────────────►├──┤ control-plane node                  │  │
                          │  │  ingress-nginx (DaemonSet)          │  │
                          │  │  hostPort 80/443                    │  │
                          │  └────┬────────────────────────────────┘  │
                          │       │                                   │
                          │  ┌────▼────────┬─────────────────────┐    │
                          │  │ worker-1    │ worker-2            │    │
                          │  │ platform-api│ platform-api        │    │
                          │  └─────────────┴─────────────────────┘    │
                          │                                           │
                          │  Namespaces:                              │
                          │    default        — platform-api          │
                          │    observability  — kps stack             │
                          │    ingress-nginx  — controller            │
                          │    argocd         — Argo CD               │
                          │    kube-system    — metrics-server        │
                          └────────────────┬──────────────────────────┘
                                           │ pulls every 3 min
                                           ▼
                          ┌────────────────────────────────────┐
                          │ github.com/amekala2514/             │
                          │ platform-lab-gitops                │
                          │  ├─ apps/      (Argo Applications) │
                          │  └─ workloads/ (K8s manifests)     │
                          └────────────────────────────────────┘
```

Argo CD watches the gitops repo and reconciles any change into the cluster within ~3 minutes. Push a YAML change → it applies. Delete a manifest → it prunes. Drift away from git → it self-heals.

## Stack

| Layer | Component | Version |
|---|---|---|
| Cluster | Kind (1 control-plane + 2 workers) | k8s 1.35 |
| IaC | Terraform + `tehcyx/kind`, `hashicorp/kubernetes`, `hashicorp/helm` | 1.6+ |
| Ingress | ingress-nginx (DaemonSet on control-plane, hostPort) | 4.13 |
| Monitoring | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, operators) | 77.1.0 |
| GitOps | Argo CD (chart 8.6.3, app v3.x) | 8.6.3 |
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
127.0.0.1 argocd.platform-lab.test
HOSTS
```

### Build the application image

```bash
cd go-services/platform-api
docker build -t platform-api:dev .
```

### Provision the platform

Terraform's `kubernetes_manifest` resources need the cluster + CRDs to exist before they can plan. The Argo CD `Application` CR also needs the Argo CD CRDs installed. Two-phase apply handles both:

```bash
cd terraform
terraform init

# Phase 1 — cluster + Helm releases (installs CRDs)
terraform apply -auto-approve \
  -target=kind_cluster.platform_lab \
  -target=kubernetes_namespace.observability \
  -target=kubernetes_namespace.ingress_nginx \
  -target=kubernetes_namespace.argocd \
  -target=helm_release.metrics_server \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.ingress_nginx \
  -target=helm_release.argocd \
  -target=kubernetes_manifest.argocd_ingress \
  -target=kubernetes_config_map.platform_api_dashboard

# Phase 2 — manifests using the newly installed CRDs
terraform apply -auto-approve
```

### Load the application image into Kind

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kind load docker-image platform-api:dev --name platform-lab
```

The platform-api Deployment/Service/Ingress are managed by **Argo CD**, not Terraform — see the [gitops repo](https://github.com/amekala2514/platform-lab-gitops). Argo CD applies them automatically once it can reach the repo (no `kubectl apply` needed).

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
| Argo CD | http://argocd.platform-lab.test | `admin` / `platform-admin` |

The custom dashboard is at **Dashboards → Platform Lab → Platform API — RED + Runtime**.

In Argo CD you'll see three Applications: `root` (the app-of-apps), `platform-api` (workload), `platform-api-monitoring` (ServiceMonitor in observability namespace).

### Tear down

```bash
cd terraform
terraform destroy -auto-approve
```

Argo CD's CRDs are kept on uninstall (`crds.keep: true`) so Application objects survive a helm release deletion. To wipe completely, run `terraform destroy` then `kind delete cluster --name platform-lab`.

## GitOps loop

Workloads live in a separate repository: **[platform-lab-gitops](https://github.com/amekala2514/platform-lab-gitops)**.

```
platform-lab-gitops/
├── apps/                          # Argo CD Application CRs
│   ├── platform-api.yaml          # default namespace workload
│   └── platform-api-monitoring.yaml  # observability namespace ServiceMonitor
├── bootstrap/
└── workloads/
    └── platform-api/
        ├── deployment.yaml
        ├── service.yaml
        ├── ingress.yaml
        └── servicemonitor.yaml
```

The flow:

1. Terraform installs Argo CD + creates a single `root` Application pointing at this repo's `apps/` directory
2. The `root` app discovers all child Applications under `apps/` (the **app-of-apps** pattern)
3. Each child Application syncs its `workloads/<name>/` directory into the target cluster namespace
4. Auto-sync with `prune: true` and `selfHeal: true` keeps cluster state in lockstep with git

To change a workload: edit YAML in the gitops repo, `git push`, wait ~3 min (or click Refresh in the Argo UI). To roll back: `git revert` and push.

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

The `ServiceMonitor` (now managed by Argo CD via the gitops repo) instructs the Prometheus operator to scrape the `platform-api` service every 15s.

## Repository layout

```
platform-lab/
├── terraform/                 # Full IaC for the platform
│   ├── main.tf                # Providers + kind cluster
│   ├── variables.tf
│   ├── outputs.tf
│   ├── namespaces.tf
│   ├── metrics-server.tf
│   ├── ingress-nginx.tf
│   ├── kube-prometheus-stack.tf
│   ├── argocd.tf              # Argo CD helm release + ingress + root app
│   ├── ingresses.tf           # Grafana, Prometheus, Alertmanager ingresses
│   ├── values/                # Helm values files (incl. argocd.yaml)
│   └── dashboards/            # Grafana dashboard JSON (mounted as ConfigMap)
├── go-services/
│   └── platform-api/          # Go HTTP service with Prometheus instrumentation
├── helm/values/               # Reference values files (mirrors terraform/values)
├── grafana/dashboards/        # Source-of-truth dashboard JSON
└── README.md
```

Workload manifests live in the [companion gitops repo](https://github.com/amekala2514/platform-lab-gitops).

## Notable engineering decisions

- **Kind + DaemonSet ingress** — ingress-nginx runs as a DaemonSet on the control-plane node, which has label `ingress-ready=true` and `hostPort: 80/443` mapped to localhost. This is the canonical Kind ingress pattern; `LoadBalancer` services stay `Pending` in Kind without MetalLB.
- **`.test` instead of `.local`** — macOS routes `.local` lookups through mDNS, which intercepts before `/etc/hosts`. `.test` is an [RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606) reserved TLD that goes through the normal resolver path.
- **Two-phase Terraform apply** — `kubernetes_manifest` resources do a server-side dry-run during `plan`, which fails on a cold cluster. Solved by targeting cluster + Helm releases first, then a full apply.
- **Dashboard via ConfigMap sidecar** — keeps the dashboard JSON in version control and lets Terraform handle import idempotently. No clicking through the Grafana UI on a fresh install.
- **Kind-tuned Prometheus rules** — disabled `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` ServiceMonitors and the `NodeClockNotSynchronising`/`CPUThrottlingHigh` rules that fire false-positives in Kind.
- **Argo CD via Terraform, workloads via Argo CD** — the controller itself is infrastructure (Terraform-managed), but everything *deployed onto* the cluster is GitOps-managed. Clean separation of "platform" vs "workloads".
- **App-of-apps pattern** — Terraform creates one `root` Application; it discovers all children. Adding a new workload is a single `apps/<name>.yaml` commit in the gitops repo, no Terraform changes.
- **Two repos, public** — split keeps Argo CD's source-of-truth narrow and the platform repo focused on infrastructure. Public for now; private + sealed-secrets is a v0.3 stretch goal.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: Resolving timed out` on `.local` hostnames | macOS mDNS intercepts `.local` | Use `.test` hostnames (already done in this repo) |
| `terraform plan` fails with `cannot create REST client` | `kubernetes_manifest` server-side dry-run with no cluster | Use the two-phase apply above |
| `terraform plan` fails with `no matches for kind Application in argoproj.io` | Argo CD CRDs not yet installed when planning the root app | Same two-phase apply — target `helm_release.argocd` first |
| Prometheus doesn't show `platform-api` in targets after creating ServiceMonitor | Stale operator config cache | `kubectl -n observability delete pod prometheus-kps-prometheus-0` |
| Argo CD `argocd-server` ingress returns 502 | backend-protocol annotation missing or HTTPS-vs-HTTP mismatch | Verify `nginx.ingress.kubernetes.io/backend-protocol: HTTP` on the ingress + `server.insecure: true` in chart values |
| Argo CD shows app `OutOfSync` immediately after migration | Annotations or fields not in the gitops manifest that TF originally set | Use `ServerSideApply=true` sync option to adopt cleanly |
| 503 from ingress to a backend that's running | Service port name/number mismatch in Ingress | Check `kubectl get svc <name>` ports vs. Ingress `port.number` |
| Docker `credsStore: desktop` errors during build/push | macOS Docker Desktop creds helper misconfigured | Remove `"credsStore": "desktop"` from `~/.docker/config.json` |

## Roadmap

- [x] `.github/workflows/validate.yml` — `terraform fmt -check`, `validate`, `helm lint` on PRs
- [x] `.github/workflows/plan.yml` — `terraform plan` posted as PR comment
- [x] GitOps with Argo CD (Phase A complete)
- [ ] Local AI inference platform (Phase B–C of v0.2)
- [ ] Alertmanager → Slack webhook + meaningful PrometheusRules
- [ ] Distributed tracing with OpenTelemetry + Grafana Tempo
- [ ] Integration test workflow that provisions the cluster in GitHub Actions
- [ ] Private gitops repo with sealed-secrets / external-secrets

## License

MIT
