# Implementation Log

A chronological record of design decisions, problems encountered, and fixes during the platform-lab build. Treat each entry as a self-contained incident report.

---

## Project goals

Build a reproducible local Kubernetes platform that demonstrates the patterns I'd use on a production cluster:

- One-command provisioning via Terraform
- Helm-managed observability stack with custom dashboards
- A Go service instrumented with Prometheus metrics
- Hostname-based ingress routing that mirrors how production traffic flows
- CI gates on every change

---

## Phase 1 — Cluster + cluster validation

### Decision: Kind over minikube/k3d

Kind runs the kubelet in containers (not VMs), which means faster startup, identical to upstream Kubernetes (not stripped down like k3s), and easy multi-node simulation by adding more containers. The only real downside is `LoadBalancer` services — see "DaemonSet ingress" below for that workaround.

### Cluster shape

1 control-plane + 2 workers, Kubernetes 1.35. Worker nodes simulate real scheduling decisions and let me observe pod distribution. The control-plane is also labeled `ingress-ready=true` so it can host the ingress controller via `hostPort` (the canonical Kind pattern).

---

## Phase 2 — Observability stack

### Decision: kube-prometheus-stack over standalone Prometheus + Grafana

Standalone deployments require manually wiring service discovery, dashboard import, alertmanager integration, and CRDs. kube-prometheus-stack ships the operator pattern out of the box: define a `ServiceMonitor` CRD and Prometheus auto-discovers scrape targets. Saves hours and matches what most teams actually run.

### Problem 1: Kind-specific false-positive alerts

**Symptom:** Right after install, Prometheus was firing 6+ critical alerts: `KubeControllerManagerDown`, `KubeSchedulerDown`, `KubeProxyDown`, `etcdMembersDown`, `CPUThrottlingHigh`, `NodeClockNotSynchronising`.

**Root cause:** Kind embeds the control-plane components (controller-manager, scheduler, kube-proxy, etcd) inside the `kube-apiserver` static pod's namespace and doesn't expose them on the standard scrape ports the operator expects. The clock-sync and CPU-throttling alerts assume baremetal nodes — they're meaningless inside Docker containers.

**Fix:** Disabled the relevant ServiceMonitors and default rules in the kube-prometheus-stack values:

```yaml
defaultRules:
  rules:
    nodeClock: false
    kubeProxy: false

kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeProxy:             { enabled: false }
kubeEtcd:              { enabled: false }
```

After tuning, only the always-firing `Watchdog` alert remains — that's intentional (dead-man's-switch for the alerting pipeline itself).

**Lesson:** Default Helm values are calibrated for production clusters. Always read the values file and trim what doesn't apply to your environment, or you'll page yourself for noise on day one.

### Problem 2: Orphan `kps-kube-*` services

**Symptom:** Even after disabling the ServiceMonitors, `TargetDown` alerts persisted for `kps-kube-controller-manager`, `kps-kube-scheduler`, `kps-kube-proxy`, `kps-kube-etcd`.

**Root cause:** The Helm chart created the Services on first install. Setting `enabled: false` later prevents the chart from creating them but doesn't remove the existing objects, so Prometheus kept trying to scrape them.

**Fix:** Deleted the orphan services explicitly:

```bash
kubectl -n observability delete svc \
  kps-kube-controller-manager kps-kube-scheduler kps-kube-proxy kps-kube-etcd
```

**Lesson:** Helm doesn't reconcile deletions of conditionally-managed resources. After flipping a feature flag off, audit what the chart leaves behind.

---

## Phase 3 — Ingress

### Problem 3: LoadBalancer Service stuck Pending

**Symptom:** Installed ingress-nginx via the standard manifests. The controller pod ran, but the `LoadBalancer` service stayed `<pending>` for its external IP, and `http://localhost` returned `Empty reply from server`.

**Root cause:** Kind has no cloud provider integration. `LoadBalancer` Services require a controller (a real cloud LB or MetalLB) to assign an external IP. Without one, the Service is functionally inert.

**Fix:** Reinstalled ingress-nginx as a **DaemonSet on the control-plane node with `hostPort: 80/443`**:

```yaml
controller:
  kind: DaemonSet
  hostPort:
    enabled: true
    ports: { http: 80, https: 443 }
  service:
    type: ClusterIP   # no longer trying to be a LoadBalancer
  nodeSelector:
    ingress-ready: "true"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Equal
      effect: NoSchedule
```

The Kind cluster config maps host port 80/443 → control-plane container port 80/443. Now `curl http://localhost` hits the nginx pod directly.

**Lesson:** Pick ingress patterns based on your environment. The `LoadBalancer + cloud controller` pattern is great in EKS/GKE, useless in Kind. `DaemonSet + hostPort + node label` is the right pattern for Kind, MicroK8s, k3s, and any other "no cloud LB" environment.

---

## Phase 4 — Application instrumentation

### Decision: prometheus/client_golang with middleware-based instrumentation

The canonical pattern for HTTP services: `promhttp.Handler()` at `/metrics`, plus a middleware that records request count, duration histogram, and in-flight gauge. This produces the three metrics needed for the RED method (Rate, Errors, Duration) without touching individual handlers.

```go
// metrics.go
var (
  httpRequestsTotal    = prometheus.NewCounterVec(...)   // labels: method, path, status
  httpRequestDuration  = prometheus.NewHistogramVec(...) // labels: method, path
  httpInflightRequests = prometheus.NewGauge(...)
)

func instrumentingMiddleware(next http.Handler) http.Handler { ... }
```

### Problem 4: Docker build failed with `credsStore: desktop`

**Symptom:** After adding `github.com/prometheus/client_golang` to `go.mod`, `docker build` failed with:

```
error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH
```

**Root cause:** Docker Desktop on macOS configured `~/.docker/config.json` with `"credsStore": "desktop"`, which requires the `docker-credential-desktop` binary. Recent Docker Desktop versions don't always install it correctly, and removing it from the config falls back to plaintext auth (fine for local dev).

**Fix:**

```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / '.docker' / 'config.json'
c = json.loads(p.read_text())
c.pop('credsStore', None)
p.write_text(json.dumps(c, indent=2))
"
```

**Lesson:** Authentication helpers on macOS Docker Desktop are a known source of friction. When in doubt, drop to plaintext auth for local dev.

### Problem 5: `/metrics` returned 404 even after rebuild

**Symptom:** Built the new image with metrics support, `docker push` worked, pod restarted — but `curl /metrics` still returned 404.

**Root cause:** Kind runs its own image store (containerd via `crictl`), separate from the host's Docker daemon. `docker build` puts the image in Docker's store; the kubelet inside Kind nodes can't see it. Without `kind load`, the kubelet falls back to pulling the `:dev` tag from Docker Hub — which doesn't exist — and the old cached image keeps running.

**Fix:**

```bash
docker build -t platform-api:dev .
kind load docker-image platform-api:dev --name platform-lab
kubectl rollout restart deploy/platform-api
```

The `kind load` step copies the image from Docker's store into each Kind node's containerd store. Combined with `imagePullPolicy: IfNotPresent` in the Deployment, the kubelet uses the loaded image.

**Lesson:** Kind has two image stores — Docker's and containerd's inside the node containers. Always `kind load` after a local rebuild, and always set `imagePullPolicy: IfNotPresent` to prevent attempted remote pulls.

### Problem 6: ServiceMonitor created but Prometheus didn't scrape

**Symptom:** Created the `ServiceMonitor` resource for platform-api. Verified the labels matched, the selector was correct, the operator logged no errors — but the platform-api target never appeared in `http://prometheus/targets`.

**Root cause:** The Prometheus operator generates a config from all matching ServiceMonitors and writes it to the Prometheus pod, but the running Prometheus process holds onto its in-memory config until it receives a reload signal. The operator's reload mechanism sometimes misses changes on rapidly-mutating clusters.

**Fix:**

```bash
kubectl -n observability delete pod prometheus-kps-prometheus-0
```

The StatefulSet recreates the pod, which boots with the freshly generated config and immediately picks up the new ServiceMonitor.

**Lesson:** The Prometheus operator's reload flow is mostly automatic but occasionally needs a manual nudge. If a ServiceMonitor doesn't appear in targets within 30 seconds, restart the Prometheus pod before debugging deeper.

---

## Phase 5 — Hostname routing

### Problem 7: `.local` hostnames intermittently hang for 5 seconds

**Symptom:** With `127.0.0.1 platform-lab.local` in `/etc/hosts`, `curl http://platform-lab.local` worked sometimes but hung for 5004ms before failing about half the time.

**Diagnosis sequence:**

```bash
dscacheutil -q host -a name platform-lab.local
# → returns 127.0.0.1 (hosts file IS being read)

host platform-lab.local
# → NXDOMAIN in 51ms (DNS path does NOT see the hosts entry)

curl -sf -m 5 --resolve platform-lab.local:80:127.0.0.1 http://platform-lab.local/healthz
# → instant 200 (bypassing all resolution works perfectly)
```

**Root cause:** macOS's DNS resolver short-circuits `.local` lookups through mDNS (Bonjour). The hosts file is consulted by one code path; the resolver used by libcurl and most network libraries goes through mDNS, which has no responder for these hostnames and waits its full timeout before failing over.

**Fix:** Switched all hostnames from `.platform-lab.local` to `.platform-lab.test`. `.test` is an [RFC 2606](https://datatracker.ietf.org/doc/html/rfc2606) reserved TLD that goes through the normal resolver path on macOS, which honors `/etc/hosts`.

**Lesson:** Don't fight macOS over `.local` — it's owned by Bonjour. Use `.test` for dev hostnames; it's reserved exactly for this purpose and works everywhere.

### Problem 8: Two of four Ingresses returned 503 after Terraform reconcile

**Symptom:** After moving to Terraform-managed Ingresses, `platform-api` and `grafana` returned 200, but `prometheus` and `alertmanager` returned 503. The ingress controller logs showed `[observability-kps-prometheus-9090] []` — empty upstream pool.

**Root cause:** The Helm chart names the Services with the long form `kps-kube-prometheus-stack-prometheus`, not `kps-prometheus` as I'd assumed. The Ingress backend `service.name` pointed to a non-existent service, so nginx had no backend to forward to.

**Fix:** Updated the two Ingress resources in `terraform/platform-api.tf` to reference the actual service names, then re-applied. Caught and verified in one apply cycle:

```bash
kubectl -n observability get svc
# kps-kube-prometheus-stack-prometheus    ← actual name
# kps-kube-prometheus-stack-alertmanager  ← actual name
```

**Lesson:** Don't assume service naming conventions across Helm charts. Always `kubectl get svc` after a fresh install and copy the exact names into downstream references.

---

## Phase 6 — Terraform automation

### Decision: two-phase apply for `kubernetes_manifest` resources

**Problem:** Running `terraform plan` from a cold start failed with:

```
Error: Failed to construct REST client
  cannot create REST client: no client config
```

**Root cause:** The `kubernetes_manifest` resource type does a server-side dry-run during `plan` to validate the manifest against the cluster's actual CRD schemas. On a cold start (no cluster yet), there's no API server to talk to, so plan fails.

**Fix:** Documented and committed to a two-phase apply:

```bash
# Phase 1 — bring up cluster + CRDs first (via Helm)
terraform apply -auto-approve \
  -target=kind_cluster.platform_lab \
  -target=kubernetes_namespace.observability \
  -target=kubernetes_namespace.ingress_nginx \
  -target=helm_release.metrics_server \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.ingress_nginx \
  -target=kubernetes_config_map.platform_api_dashboard

# Phase 2 — apply the kubernetes_manifest resources (now CRDs exist)
terraform apply -auto-approve
```

**Lesson:** `kubernetes_manifest` is more powerful than `kubectl_manifest` (the older provider) because it validates against live CRDs, but the cost is a hard dependency on cluster reachability during plan. For greenfield IaC that creates the cluster *and* applies CRDs, structure your applies in two phases.

### Decision: dashboard auto-import via ConfigMap sidecar

The kube-prometheus-stack Grafana ships with a sidecar that watches for ConfigMaps labeled `grafana_dashboard=1` cluster-wide and auto-imports the JSON they contain. This means:

```hcl
resource "kubernetes_config_map" "platform_api_dashboard" {
  metadata {
    labels      = { grafana_dashboard = "1" }
    annotations = { grafana_folder    = "Platform Lab" }
  }
  data = {
    "platform-api.json" = file("${path.module}/dashboards/platform-api.json")
  }
}
```

…and Grafana picks the dashboard up within 30 seconds. No clicking through the import UI, no provisioning files mounted as volumes, no manual sync after re-apply. The dashboard JSON is plain text in version control and Terraform reconciles it on every apply.

**Lesson:** Provisioning patterns that use first-class Kubernetes objects (ConfigMaps with labels) compose better than out-of-band mechanisms (volume mounts, init containers, etc.). Look for the "label-driven sidecar" pattern across CNCF projects.

---

## Phase 7 — CI/CD

### Decision: kubeconform over `kubectl apply --dry-run`

**Problem:** Initial CI used `kubectl apply --dry-run=client -f k8s/platform-api.yaml`, which failed in GitHub Actions with:

```
error: error validating "k8s/platform-api.yaml":
failed to download openapi:
Get "http://localhost:8080/openapi/v2": connection refused
```

**Root cause:** Even in `--dry-run=client` mode, `kubectl` tries to fetch the cluster's OpenAPI schema for validation. No cluster → no schema → no validation → exit 1.

**Fix:** Replaced `kubectl` with **kubeconform** — an offline manifest validator that bundles the upstream Kubernetes OpenAPI schemas for every version. It runs in ~100ms per manifest, has no dependencies, and is more strict than `kubectl --dry-run`.

```yaml
- name: Validate k8s manifests
  run: kubeconform -strict -summary -kubernetes-version 1.31.0 k8s/
```

**Lesson:** `kubectl --dry-run=client` is a useful local debugging tool but the wrong choice for CI. Use a purpose-built offline validator (`kubeconform` or `datree`) for static manifest checks.

### Decision: terraform plan as sticky PR comment

The `plan.yml` workflow runs on every PR that touches `terraform/**`, executes a targeted plan (excluding the kubernetes_manifest resources that need a live cluster), and posts the output as a single, updating bot comment on the PR. Subsequent commits update the same comment rather than spamming the PR.

This makes infrastructure review work the same as code review: read the diff, then read the plan output below it. No need to clone the PR locally to see what changes Terraform thinks it would make.

---

## Summary of architectural decisions

| Area | Decision | Rationale |
|---|---|---|
| Cluster | Kind, 1 control-plane + 2 workers | Upstream-faithful, multi-node, fast |
| Ingress | nginx as DaemonSet + hostPort | Only viable pattern without cloud LB |
| Hostnames | `*.platform-lab.test` | RFC 2606 reserved, no mDNS conflict |
| Monitoring | kube-prometheus-stack | Operator pattern, dashboards auto-import |
| App instrumentation | client_golang + middleware | Standard pattern for Go HTTP services |
| IaC | Terraform with two-phase apply | Needed for cluster + manifest cohabitation |
| Manifest validation | kubeconform in CI | Offline, no cluster required |
| Dashboard provisioning | ConfigMap with sidecar label | First-class object, version-controlled |

---

## What I'd do differently next time

- **Pin all chart versions in variables.tf from day one.** I bumped them ad-hoc during development and that made some debugging harder than it needed to be.
- **Build the dashboard JSON last, not first.** I iterated on PromQL queries against an empty target for an hour before realizing the ServiceMonitor wasn't being picked up. Validate the scrape pipeline end-to-end before touching the dashboard.
- **Add the `Makefile` earlier.** Twelve copy-pasted command blocks across a session is a sign you need a Makefile. Adding it on day three felt overdue.
- **Run `terraform fmt` as a pre-commit hook from the start.** I had to fix formatting after writing the validate workflow because my files weren't formatted.

---

## Open work

- `docs/ARCHITECTURE.md` — diagram and component data flow
- `docs/GETTING_STARTED.md` — copy/paste onboarding for someone else
- Alertmanager → Slack webhook + meaningful PrometheusRules
- GitOps with Argo CD
- Distributed tracing with OpenTelemetry + Grafana Tempo
- v0.1.0 release tag with proper release notes
