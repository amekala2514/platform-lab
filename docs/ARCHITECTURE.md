# Architecture

This document describes the platform's components, how they connect, and the design decisions behind the structure. For setup instructions see [GETTING_STARTED.md](GETTING_STARTED.md); for the debugging history see [IMPLEMENTATION_LOG.md](../IMPLEMENTATION_LOG.md).

---

## System overview

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            macOS host (Docker)                             │
│                                                                            │
│  Browser / curl ──► localhost:80 ──► Kind extra_port_mappings              │
│                                              │                             │
│  ┌───────────────────────────────────────────▼──────────────────────────┐  │
│  │                  Kind container: control-plane                       │  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │  │
│  │  │  ingress-nginx DaemonSet (hostPort 80/443)                     │  │  │
│  │  │  ├─ Host: platform-lab.test               → svc/platform-api   │  │  │
│  │  │  ├─ Host: grafana.platform-lab.test       → svc/kps-grafana    │  │  │
│  │  │  ├─ Host: prometheus.platform-lab.test    → svc/kps-…-prom     │  │  │
│  │  │  └─ Host: alertmanager.platform-lab.test  → svc/kps-…-am       │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  │  kube-apiserver, etcd, controller-manager, scheduler                 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                            │
│  ┌────────────────────────────┐    ┌───────────────────────────────────┐   │
│  │  Kind container: worker-1  │    │  Kind container: worker-2         │   │
│  │  ┌──────────────────────┐  │    │  ┌──────────────────────────────┐ │   │
│  │  │ ns: default          │  │    │  │ ns: observability            │ │   │
│  │  │  - platform-api pod  │  │    │  │  - prometheus-kps-…-0        │ │   │
│  │  └──────────────────────┘  │    │  │  - kps-grafana (sidecar)     │ │   │
│  │  ┌──────────────────────┐  │    │  │  - alertmanager-…-0          │ │   │
│  │  │ ns: observability    │  │    │  │  - kps-…-operator            │ │   │
│  │  │  - kube-state-metrics│  │    │  │  - kube-state-metrics        │ │   │
│  │  │  - node-exporter     │  │    │  └──────────────────────────────┘ │   │
│  │  └──────────────────────┘  │    │  ns: default                      │   │
│  └────────────────────────────┘    │   - platform-api pod              │   │
│                                    └───────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Component inventory

| Component | Namespace | Workload type | Manages |
|---|---|---|---|
| `kind_cluster.platform_lab` (Terraform) | – | Kind cluster | 1 control-plane + 2 workers, k8s 1.35 |
| `ingress-nginx-controller` | `ingress-nginx` | DaemonSet | Routes external HTTP → internal Services |
| `metrics-server` | `kube-system` | Deployment | Kubelet stats → `kubectl top`, HPA source |
| `prometheus-kps-prometheus-0` | `observability` | StatefulSet (operator-owned) | Scrapes ServiceMonitors, stores TSDB |
| `alertmanager-kps-…-0` | `observability` | StatefulSet (operator-owned) | Dedupes + routes alerts |
| `kps-grafana` | `observability` | Deployment | UI + sidecar dashboard importer |
| `kps-…-operator` | `observability` | Deployment | Reconciles ServiceMonitor, PrometheusRule, etc. |
| `kube-state-metrics` | `observability` | Deployment | Exposes k8s object state as metrics |
| `node-exporter` | `observability` | DaemonSet | Node-level system metrics |
| `platform-api` | `default` | Deployment (2 replicas) | The instrumented Go service |
| `platform-api` Service | `default` | ClusterIP | Stable endpoint for the pods |
| `ServiceMonitor/platform-api` | `observability` | CRD | Tells the operator how to scrape platform-api |
| `ConfigMap/platform-api-dashboard` | `observability` | ConfigMap | Dashboard JSON, imported by Grafana sidecar |

---

## Data flows

### 1. External request → application

```
curl http://platform-lab.test/healthz
  │
  ▼
macOS /etc/hosts        → 127.0.0.1
  │
  ▼
TCP :80                 → Kind extra_port_mappings (host → control-plane container)
  │
  ▼
hostPort 80             → ingress-nginx pod on control-plane
  │
  ▼  (Host header match)
Ingress rule            → Service/platform-api:8080
  │
  ▼  (ClusterIP load-balanced across endpoints)
Pod                     → /healthz handler returns 200
```

### 2. Metrics collection (Prometheus scrape)

```
ServiceMonitor/platform-api
  │ (operator reconciles)
  ▼
Prometheus scrape config (generated on the fly)
  │
  ▼  every 15s
GET http://<pod-ip>:8080/metrics
  │
  ▼
Prometheus TSDB         (retention: 7d)
```

The operator pattern means **adding a new scrape target is just a `kubectl apply` of a ServiceMonitor**. No editing of `prometheus.yml`, no reload signal — the operator regenerates the config and signals the StatefulSet pod automatically.

### 3. Dashboard auto-import

```
ConfigMap (label: grafana_dashboard=1)
  │
  ▼  (kps-grafana pod has a sidecar container)
Sidecar: kiwigrid/k8s-sidecar
  │ watches all namespaces for matching labels
  ▼
Mounts each ConfigMap's data under /tmp/dashboards
  │
  ▼
Grafana provisioner reloads dashboards every 30s
  │
  ▼
Dashboard appears in UI under folder "Platform Lab"
```

This design means dashboards are **version-controlled JSON in `terraform/dashboards/`** that get re-applied on every `terraform apply`. No imperative "import dashboard" step, no drift between repo and live cluster.

### 4. Alert routing (built but not yet wired to a destination)

```
PrometheusRule (CRD)
  │ (operator reconciles into prometheus rules.yml)
  ▼
Prometheus rule evaluator
  │ every evaluation_interval
  ▼  (alert condition true)
Alertmanager
  │ (deduplication, grouping, inhibition)
  ▼
Receiver (TODO: Slack webhook)
```

Currently only the `Watchdog` rule fires (intentional dead-man's-switch). Real PrometheusRule + receiver wiring is on the roadmap.

---

## Terraform structure

```
terraform/
├── main.tf                       # providers + kind cluster
├── variables.tf                  # versions, hostnames, passwords
├── outputs.tf                    # kubeconfig path, URLs
├── namespaces.tf                 # observability, ingress-nginx
├── metrics-server.tf             # helm_release
├── ingress-nginx.tf              # helm_release with custom values
├── kube-prometheus-stack.tf      # helm_release + dashboard ConfigMap
├── platform-api.tf               # 4 Ingresses + ServiceMonitor (kubernetes_manifest)
├── values/
│   ├── ingress-nginx.yaml
│   └── kube-prometheus-stack.yaml
└── dashboards/
    └── platform-api.json
```

### Provider chain

```hcl
provider "kind" {}                 # creates the cluster
  │
  ▼
provider "kubernetes" {            # reads kubeconfig from kind_cluster output
  host                   = kind_cluster.platform_lab.endpoint
  cluster_ca_certificate = kind_cluster.platform_lab.cluster_ca_certificate
  client_certificate     = kind_cluster.platform_lab.client_certificate
  client_key             = kind_cluster.platform_lab.client_key
}

provider "helm" {                  # same wiring as kubernetes provider
  kubernetes { ... }
}
```

The Helm and Kubernetes providers depend implicitly on `kind_cluster.platform_lab` being applied first — the provider configurations reference its outputs, so Terraform's dependency graph orders them correctly.

### Why two-phase apply

The `kubernetes_manifest` resource performs a **server-side dry-run during plan** to validate the manifest against the live CRD schemas. On a cold start (no cluster yet), the dry-run fails with `cannot create REST client: no client config`.

Solution: apply the cluster + Helm releases (which install the CRDs) first, then run a normal apply for the manifest resources.

```bash
# Phase 1 — cluster + CRDs
terraform apply -target=kind_cluster.platform_lab \
                -target=helm_release.kube_prometheus_stack \
                -target=helm_release.ingress_nginx \
                # ...

# Phase 2 — manifests using newly installed CRDs
terraform apply
```

On subsequent applies (e.g., when only a value file changes), a single `terraform apply` is sufficient because the cluster + CRDs already exist.

---

## Networking & hostname resolution

### Why `.test` instead of `.local`

macOS routes `.local` lookups through **mDNS** (Bonjour) before consulting `/etc/hosts`. With no Bonjour responder for `platform-lab.local`, lookups hang for the full mDNS timeout (~5 seconds) on a portion of attempts. See [IMPLEMENTATION_LOG.md Problem 7](../IMPLEMENTATION_LOG.md#problem-7-local-hostnames-intermittently-hang-for-5-seconds) for the diagnosis.

`.test` is reserved by [RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606) for testing purposes, has no special OS handling, and resolves via the standard path that honors `/etc/hosts`.

### Why DaemonSet + hostPort for ingress

In Kind, a `Service` of type `LoadBalancer` stays `<pending>` forever because there's no cloud controller to assign an external IP. The two options are:

1. Install MetalLB to provide load balancing inside the cluster
2. Run nginx as a DaemonSet with `hostPort: 80/443`, pinned to a node that's mapped to the host network via `extra_port_mappings`

Option 2 is simpler, has no additional moving parts, and matches the pattern documented in the Kind ingress guide. The control-plane node carries the label `ingress-ready=true` and tolerates the control-plane taint so the DaemonSet schedules there.

### Host → cluster port mapping

In `terraform/main.tf`:

```hcl
kind_config {
  node {
    role = "control-plane"
    extra_port_mappings {
      container_port = 80
      host_port      = 80
    }
    extra_port_mappings {
      container_port = 443
      host_port      = 443
    }
  }
}
```

This is the Docker port forward from host `localhost:80` to the control-plane container's `:80`. Once inside the control-plane container, nginx-ingress is listening on `:80` directly (via hostPort) and serves the request.

---

## Observability design choices

### kube-prometheus-stack over standalone Prometheus

The chart bundles:
- Prometheus + operator (for ServiceMonitor / PrometheusRule CRDs)
- Alertmanager
- Grafana with sidecar-based dashboard provisioning
- node-exporter (DaemonSet)
- kube-state-metrics

This is the same stack most production teams run. Picking standalone Prometheus would mean manually wiring service discovery, alertmanager integration, and dashboard import — work the operator pattern eliminates.

### Kind-tuned values

The default Helm values try to scrape `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, and `etcd` on standard ports. Kind doesn't expose those — they run inside the kube-apiserver static pod's network namespace. Without tuning, Prometheus fires `TargetDown` alerts on every install.

The Terraform-managed `terraform/values/kube-prometheus-stack.yaml` disables those ServiceMonitors and the false-positive `NodeClockNotSynchronising` / `CPUThrottlingHigh` rules that don't apply to containerized nodes.

### platform-api instrumentation pattern

```go
// metrics.go declares 3 metrics
httpRequestsTotal    *prometheus.CounterVec    // labels: method, path, status
httpRequestDuration  *prometheus.HistogramVec  // labels: method, path
httpInflightRequests prometheus.Gauge

// middleware wraps the entire handler
func instrumentingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        httpInflightRequests.Inc()
        defer httpInflightRequests.Dec()

        rec := &statusRecorder{ResponseWriter: w, status: 200}
        start := time.Now()

        next.ServeHTTP(rec, r)

        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, strconv.Itoa(rec.status)).Inc()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(time.Since(start).Seconds())
    })
}
```

These three metrics give you the **RED method** (Rate, Errors, Duration) for free on every endpoint. The Grafana dashboard uses them to build:
- `sum(rate(http_requests_total[1m]))` → request rate
- `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` → error %
- `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` → p95 latency

---

## CI/CD architecture

Two workflows in `.github/workflows/`:

### `validate.yml` (runs on push + PR)

Four parallel jobs, all complete in ~60 seconds:

1. **terraform** — `terraform fmt -check`, `init -backend=false`, `validate`
2. **helm** — `helm pull` charts at pinned versions, then `helm lint` with our values files
3. **kubeconform** — offline manifest schema validation against k8s 1.31 schemas
4. **yaml-lint** — Python YAML parser over the whole repo

### `plan.yml` (runs on PR touching terraform/**)

1. Setup terraform, init with no backend, validate
2. Targeted `terraform plan` (excluding `kubernetes_manifest` resources — they need a live cluster)
3. Post the plan output as a **sticky bot comment** on the PR (finds existing comment and updates instead of creating new ones on each push)
4. Fail the job if plan exited non-zero

### Why kubeconform, not `kubectl --dry-run`

`kubectl --dry-run=client` still tries to fetch the cluster's OpenAPI schema. In CI without a cluster, that fails. `kubeconform` bundles the upstream Kubernetes JSON schemas for every version and validates offline in milliseconds.

---

## Design principles followed

1. **Infrastructure as code over imperative scripts.** Everything that can be in Terraform, is.
2. **First-class Kubernetes objects over volume mounts and init containers.** Dashboards are ConfigMaps, scrape configs are ServiceMonitors.
3. **Pin versions explicitly.** No `latest` tags, no floating chart versions. Variables in `variables.tf`.
4. **Honest about scope.** The application code (Deployment, Service) is `kubectl`-applied because it iterates hourly during development. Terraform owns the platform; `kubectl` owns the app.
5. **CI mirrors local development as closely as possible.** Same Helm chart versions in lint that we'd install in apply; same Kubernetes version in kubeconform that the cluster runs.

---

## Future architecture work

| Item | Where it fits |
|---|---|
| Alertmanager → Slack webhook | `terraform/kube-prometheus-stack.tf` values |
| PrometheusRules (high error rate, p99 latency) | New `terraform/rules.tf` with kubernetes_manifest |
| Argo CD for GitOps | New `terraform/argocd.tf`, point at this repo |
| OpenTelemetry tracing + Tempo | New worker service + `terraform/tempo.tf` |
| Integration test workflow | New `.github/workflows/integration-test.yml` that spins up Kind in CI |
| Production-ready secrets | External secrets operator + a real secrets backend |
