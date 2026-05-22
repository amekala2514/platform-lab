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
│  │  │  ├─ Host: alertmanager.platform-lab.test  → svc/kps-…-am       │  │  │
│  │  │  └─ Host: argocd.platform-lab.test        → svc/argocd-server  │  │  │
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
│  │  │ ns: argocd           │  │    │  │  - kps-…-operator            │ │   │
│  │  │  - argocd-server     │  │    │  └──────────────────────────────┘ │   │
│  │  │  - argocd-repo-server│  │    │  ┌──────────────────────────────┐ │   │
│  │  │  - argocd-app-ctrl   │  │    │  │ ns: default                  │ │   │
│  │  │  - argocd-appset-ctrl│  │    │  │  - platform-api pod          │ │   │
│  │  │  - argocd-redis      │  │    │  └──────────────────────────────┘ │   │
│  │  └──────────────────────┘  │    │                                   │   │
│  └────────────────────────────┘    └───────────────────────────────────┘   │
└──────────────────┬─────────────────────────────────────────────────────────┘
                   │ pulls every 3 min (or on push refresh)
                   ▼
       ┌─────────────────────────────────────────────┐
       │  github.com/amekala2514/platform-lab-gitops │
       │  ├─ apps/                                   │
       │  │   ├─ platform-api.yaml                   │
       │  │   └─ platform-api-monitoring.yaml        │
       │  └─ workloads/platform-api/                 │
       │      ├─ deployment.yaml                     │
       │      ├─ service.yaml                        │
       │      ├─ ingress.yaml                        │
       │      └─ servicemonitor.yaml                 │
       └─────────────────────────────────────────────┘
```

---

## Component inventory

### Platform (Terraform-managed)

| Component | Namespace | Workload type | Manages |
|---|---|---|---|
| `kind_cluster.platform_lab` | – | Kind cluster | 1 control-plane + 2 workers, k8s 1.35 |
| `ingress-nginx-controller` | `ingress-nginx` | DaemonSet | Routes external HTTP → internal Services |
| `metrics-server` | `kube-system` | Deployment | Kubelet stats → `kubectl top`, HPA source |
| `prometheus-kps-prometheus-0` | `observability` | StatefulSet (operator-owned) | Scrapes ServiceMonitors, stores TSDB |
| `alertmanager-kps-…-0` | `observability` | StatefulSet (operator-owned) | Dedupes + routes alerts |
| `kps-grafana` | `observability` | Deployment | UI + sidecar dashboard importer |
| `kps-…-operator` | `observability` | Deployment | Reconciles ServiceMonitor, PrometheusRule, etc. |
| `kube-state-metrics` | `observability` | Deployment | Exposes k8s object state as metrics |
| `node-exporter` | `observability` | DaemonSet | Node-level system metrics |
| `argocd-server` | `argocd` | Deployment | Argo CD API + web UI |
| `argocd-repo-server` | `argocd` | Deployment | Clones gitops repo, renders manifests |
| `argocd-application-controller` | `argocd` | StatefulSet | Reconciles Application CRs against the cluster |
| `argocd-applicationset-controller` | `argocd` | Deployment | (Reserved for ApplicationSet usage) |
| `argocd-redis` | `argocd` | Deployment | Cache for repo-server |
| `Ingress/argocd-server` | `argocd` | Ingress | Exposes argocd at argocd.platform-lab.test |
| `Application/root` | `argocd` | Argo CD CR | App-of-apps pointing at gitops repo `apps/` |
| Grafana / Prometheus / Alertmanager Ingresses | `observability` | Ingress | Public access to UIs |
| `ConfigMap/platform-api-dashboard` | `observability` | ConfigMap | Dashboard JSON, imported by Grafana sidecar |

### Workloads (Argo CD–managed, defined in `platform-lab-gitops`)

| Component | Namespace | Workload type | Defined in |
|---|---|---|---|
| `platform-api` Deployment | `default` | Deployment (2 replicas) | `workloads/platform-api/deployment.yaml` |
| `platform-api` Service | `default` | ClusterIP | `workloads/platform-api/service.yaml` |
| `platform-api` Ingress | `default` | Ingress | `workloads/platform-api/ingress.yaml` |
| `ServiceMonitor/platform-api` | `observability` | CRD | `workloads/platform-api/servicemonitor.yaml` |
| `Application/platform-api` | `argocd` | Argo CD CR | `apps/platform-api.yaml` |
| `Application/platform-api-monitoring` | `argocd` | Argo CD CR | `apps/platform-api-monitoring.yaml` |

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

The operator pattern means **adding a new scrape target is just a YAML commit in the gitops repo**. No editing of `prometheus.yml`, no reload signal — Argo CD applies the ServiceMonitor, the operator regenerates the Prometheus config, and the StatefulSet pod picks up the change automatically.

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

### 4. GitOps reconciliation (Argo CD)

```
git push to platform-lab-gitops main
  │
  ▼
argocd-repo-server (clones every 3 min by default)
  │
  ▼
argocd-application-controller diffs cluster vs git
  │
  ▼  (drift detected)
Server-side apply via kube-apiserver
  │
  ▼
Resources reconciled (created/updated/pruned)
  │
  ▼
Application status: Synced / Healthy
```

Auto-sync with `prune: true` + `selfHeal: true` means any deviation from git is automatically corrected. Deleting a manifest from the repo prunes the cluster resource; an out-of-band `kubectl edit` is reverted within 3 minutes.

To force an immediate sync:

```bash
kubectl -n argocd patch app platform-api --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
```

### 5. App-of-apps discovery

```
Application/root  (Terraform-created)
  │  source: platform-lab-gitops/apps/   recurse: true
  ▼
discovers apps/platform-api.yaml          → creates Application/platform-api
discovers apps/platform-api-monitoring.yaml → creates Application/platform-api-monitoring
  │
  ▼  each child app
syncs its own workloads/<name>/ directory into the target namespace
```

Adding a new workload requires zero Terraform changes — just two YAML files in the gitops repo (the workload manifests and an Application CR).

### 6. Alert routing (built but not yet wired to a destination)

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
├── variables.tf                  # versions, hostnames, passwords, gitops repo URL
├── outputs.tf                    # kubeconfig path, URLs, admin passwords
├── namespaces.tf                 # observability, ingress-nginx
├── metrics-server.tf             # helm_release
├── ingress-nginx.tf              # helm_release with custom values
├── kube-prometheus-stack.tf      # helm_release + dashboard ConfigMap
├── argocd.tf                     # helm_release + ingress + root Application
├── ingresses.tf                  # Grafana/Prometheus/Alertmanager ingresses
├── values/
│   ├── ingress-nginx.yaml
│   ├── kube-prometheus-stack.yaml
│   └── argocd.yaml
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

The `kubernetes_manifest` resource performs a **server-side dry-run during plan** to validate the manifest against the live CRD schemas. On a cold start (no cluster yet), the dry-run fails with `cannot create REST client: no client config`. With Argo CD added in v0.2, the same issue applies to the `Application` CR — its CRD only exists after the Argo CD helm release runs.

Solution: apply the cluster + Helm releases (which install the CRDs) first, then run a normal apply for the manifest resources.

```bash
# Phase 1 — cluster + CRDs
terraform apply -target=kind_cluster.platform_lab \
                -target=helm_release.kube_prometheus_stack \
                -target=helm_release.ingress_nginx \
                -target=helm_release.argocd \
                # ...

# Phase 2 — manifests using newly installed CRDs
terraform apply
```

On subsequent applies (e.g., when only a value file changes), a single `terraform apply` is sufficient because the cluster + CRDs already exist.

---

## GitOps split: two repos

| Repo | Owns | Tooling | Why separate |
|---|---|---|---|
| `platform-lab` | Cluster, Helm releases, Argo CD, infrastructure ingresses, dashboards | Terraform | The platform itself — Terraform is the right tool |
| `platform-lab-gitops` | Workload manifests + Argo CD `Application` CRs | Argo CD watches it | Workloads change far more often than platform; separation isolates blast radius and aligns with how real org permissions are scoped |

### Gitops repo structure

```
platform-lab-gitops/
├── apps/                          # Argo CD Application CRs (root app discovers these)
│   ├── platform-api.yaml          # default namespace workload
│   └── platform-api-monitoring.yaml  # observability namespace ServiceMonitor
├── bootstrap/                     # Reserved for cross-environment app-of-apps wiring
└── workloads/
    └── platform-api/
        ├── deployment.yaml
        ├── service.yaml
        ├── ingress.yaml
        └── servicemonitor.yaml
```

### Why two Applications for platform-api

The platform-api workload spans two namespaces:
- `default` — Deployment, Service, Ingress
- `observability` — ServiceMonitor (must live with the Prometheus operator)

An Argo CD `Application` has a single destination namespace. Trying to put cross-namespace resources in one Application creates "OutOfSync" noise because Argo will keep trying to move the ServiceMonitor into `default`. The clean solution: one Application per destination namespace, using `directory.include` globs to slice the manifests.

```yaml
# apps/platform-api.yaml
spec:
  source:
    path: workloads/platform-api
    directory:
      include: '{deployment.yaml,service.yaml,ingress.yaml}'
  destination:
    namespace: default

# apps/platform-api-monitoring.yaml
spec:
  source:
    path: workloads/platform-api
    directory:
      include: 'servicemonitor.yaml'
  destination:
    namespace: observability
```

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

### Argo CD ingress: HTTP-only backend

Argo CD's server defaults to TLS-on-everything, including its own pod-to-pod port. For homelab use, that's overkill — there's no TLS termination on ingress-nginx either. The chart values set:

```yaml
configs:
  params:
    server.insecure: true   # argocd-server speaks HTTP only
```

…and the ingress carries:

```yaml
annotations:
  nginx.ingress.kubernetes.io/backend-protocol: HTTP
```

Without the annotation, nginx-ingress tries HTTPS to the backend pod and gets a 502. With both pieces in place, the flow is plain HTTP end-to-end.

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

### Argo CD ServiceMonitors

All four Argo CD components (controller, server, repo-server, applicationSet) expose Prometheus metrics. The chart values enable ServiceMonitors with the `release: kps` label, which matches kube-prometheus-stack's default selector. Result: Argo CD metrics show up in Prometheus automatically with zero extra wiring.

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kps
# …repeated for server, repoServer, applicationSet
```

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
2. **Platform vs workload separation.** Terraform owns the cluster and what runs on it as infrastructure (ingress controller, Prometheus, Argo CD). Argo CD owns everything else.
3. **First-class Kubernetes objects over volume mounts and init containers.** Dashboards are ConfigMaps, scrape configs are ServiceMonitors, deployments are Application CRs.
4. **Pin versions explicitly.** No `latest` tags, no floating chart versions. Variables in `variables.tf`.
5. **CI mirrors local development as closely as possible.** Same Helm chart versions in lint that we'd install in apply; same Kubernetes version in kubeconform that the cluster runs.
6. **Git is the source of truth.** For workloads, what's in `platform-lab-gitops/main` is what's running. Out-of-band changes are reverted within 3 minutes by Argo CD's selfHeal.

---

## Future architecture work

| Item | Where it fits |
|---|---|
| Local AI inference (Ollama on host, gateway in-cluster) | v0.2 Phase B–C, new `workloads/inference-*` in gitops repo |
| Alertmanager → Slack webhook | `terraform/kube-prometheus-stack.tf` values |
| PrometheusRules (high error rate, p99 latency) | New `workloads/platform-rules/` in gitops repo (now that Argo CD is there) |
| OpenTelemetry tracing + Tempo | New `terraform/tempo.tf` + workloads via gitops |
| Integration test workflow | New `.github/workflows/integration-test.yml` that spins up Kind in CI |
| Private gitops repo | Argo CD repo Secret with PAT or SSH deploy key; sealed-secrets for in-cluster credentials |
| ApplicationSets for fleet management | When/if we add a second cluster |
