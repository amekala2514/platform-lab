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
- GitOps for workloads (added in v0.2)

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

## Phase 8 — GitOps with Argo CD (v0.2 Phase A)

### Decision: Argo CD over Flux

Both are CNCF-graduated GitOps controllers. Argo CD won on:

- **UI included.** Flux is CLI-only; Argo CD ships a usable web UI. For a homelab where I'll routinely poke at sync status, that matters.
- **Application abstraction.** Argo's `Application` CR is a single object that fully describes "what + where", which composes well with the app-of-apps pattern.
- **Larger ecosystem.** ApplicationSets, ArgoCD Image Updater, Argo Rollouts — all in the same family with shared concepts.

Flux remains the right pick for environments that prize lower runtime footprint and fully-imperative-free workflows. Not this homelab.

### Decision: separate gitops repo (platform-lab-gitops) over monorepo

Two-repo split:

| Repo | Owns | Tooling |
|---|---|---|
| `platform-lab` | Cluster + Helm releases + Argo CD itself + infrastructure ingresses | Terraform |
| `platform-lab-gitops` | Workload manifests (Deployment, Service, Ingress, ServiceMonitor) | Argo CD |

Reasons:
- **Blast-radius separation.** A bad Terraform change can't break workloads; a bad workload commit can't break the platform.
- **Permissions story.** In a real org, infra and app teams have different write access. Two repos make that easy; a monorepo needs CODEOWNERS gymnastics.
- **Argo CD source-of-truth is narrow.** It only watches the gitops repo, not the whole platform-lab repo. Faster reconcile loops, cleaner audit trail.

Stretch goal for v0.3: make the gitops repo private and use sealed-secrets / external-secrets for credential management.

### Decision: app-of-apps pattern with `directory: { recurse: true }`

Terraform creates exactly one `Application` CR — the `root` app — pointing at the gitops repo's `apps/` directory. The root app discovers all child Applications under that directory.

```yaml
spec:
  source:
    repoURL: https://github.com/amekala2514/platform-lab-gitops.git
    path: apps
    directory:
      recurse: true
```

Adding a new workload now means:
1. Drop manifests in `workloads/<name>/`
2. Drop an `Application` CR in `apps/<name>.yaml`
3. `git push`

No Terraform changes, no new helm releases, no operator restarts. The root app picks up the new child within ~3 minutes (or instantly with `kubectl -n argocd patch app root --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`).

### Problem 9: Argo CD `Application` CRD not registered at plan time

**Symptom:** `terraform apply` failed during plan with:

```
Error: API did not recognize GroupVersionKind from manifest (CRD may not be installed)
  with kubernetes_manifest.root_app,
  on argocd.tf line 90, in resource "kubernetes_manifest" "root_app":
no matches for kind "Application" in group "argoproj.io"
```

**Root cause:** Same family of bug as Problem 6 (cold start `kubernetes_manifest` plan), but now triggered by Argo CD CRDs specifically. Plan validates `Application` against the live API server's CRD list. If `helm_release.argocd` hasn't applied yet, the CRD isn't there, and plan fails.

**Fix:** Targeted apply for the helm release first, then a normal apply for the manifest:

```bash
terraform apply -target=helm_release.argocd -target=kubernetes_manifest.argocd_ingress
terraform apply
```

**Lesson:** Any time you add a new CRD-introducing helm release that's followed by `kubernetes_manifest` resources of that CRD's kinds, you'll hit this. The two-phase pattern from Phase 6 is the permanent answer.

### Problem 10: bcrypt drift on every `terraform plan`

**Symptom:** After installing Argo CD, every subsequent `terraform plan` showed the helm release as "will be updated in-place" even though no inputs had changed.

**Root cause:** I was computing the admin password's bcrypt hash inline:

```hcl
set {
  name  = "configs.secret.argocdServerAdminPassword"
  value = bcrypt(var.argocd_admin_password, 10)
}
```

`bcrypt()` is non-deterministic — same plaintext input produces a different hash every time, by design (the salt is randomized). Plan re-evaluated the function every run, saw a different hash, and reported drift.

**Fix:** `lifecycle.ignore_changes = [set]` on the `helm_release.argocd` resource. The actual password value is fixed, and `set` blocks include the password — telling Terraform to ignore changes to them stops the spurious diff.

```hcl
resource "helm_release" "argocd" {
  # ...
  set { name = "configs.secret.argocdServerAdminPassword"; value = bcrypt(var.argocd_admin_password, 10) }
  set { name = "configs.secret.argocdServerAdminPasswordMtime"; value = "2026-05-21T00:00:00Z" }
  lifecycle { ignore_changes = [set] }
}
```

**Lesson:** Any non-deterministic function in Terraform inputs (`bcrypt`, `uuid`, `timestamp`) is a drift trap. Either compute the value once and store it as input, or use `ignore_changes` on the field that holds it.

### Problem 11: cat heredoc silently dropped a Terraform file

**Symptom:** Wrote four new files via `cat > FILE <<'EOF'` blocks. Three landed; one (`argocd.tf`) didn't, and I didn't notice until `terraform plan` reported no changes.

**Root cause:** A multi-line `cat` heredoc pasted into a terminal session can be interrupted mid-paste — usually by an unbalanced quote or a pasted comment that the shell interprets as the start of a new command. The heredoc never closes, the shell stays in heredoc mode silently, and the file never gets written.

**Detection:**

```bash
ls -la /Users/ashish/Desktop/platform-lab/terraform/argocd.tf
# ls: argocd.tf: No such file or directory
```

**Fix:** Re-pasted the single failed heredoc, this time wrapping the entire block in a single fenced clipboard copy without inline comments. Verified file size > 0 immediately after.

**Lesson:** When pasting heredocs, paste each one separately, and `ls -la` the file right after. Multi-block paste is a known footgun on zsh/bash with TTY paste-bracketing disabled.

### Decision: cluster-side adoption via `ServerSideApply`

When migrating platform-api from Terraform-managed to Argo-CD-managed, the resources already existed in the cluster (created originally by `kubectl apply -f k8s/platform-api.yaml` in v0.1). I needed Argo CD to "adopt" them rather than fight them.

Both Application CRs use:

```yaml
syncOptions:
  - ServerSideApply=true
  - ApplyOutOfSyncOnly=true
```

Server-side apply makes Argo CD a co-owner via field manager `argocd-controller`, which lets the existing resources stay in place but progressively migrate ownership of fields as they're touched. There was a single rolling restart of the platform-api Deployment when sync started (the manifests had minor differences from what was in the cluster — different `imagePullPolicy` defaults from `kubectl apply`'s client-side merge), but no downtime: both replicas rolled cleanly.

**Lesson:** Adopting existing resources into GitOps without a service interruption is a solved problem if you use server-side apply from day one. Client-side apply leaves brittle annotations (`kubectl.kubernetes.io/last-applied-configuration`) that force resource recreation when ownership changes.

### Decision: `terraform state rm` for handoff, not destroy

To complete the migration, Terraform needed to stop claiming ownership of the platform-api Ingress and ServiceMonitor — without deleting them from the cluster (Argo CD owns them now).

```bash
terraform state rm kubernetes_manifest.platform_api_ingress
terraform state rm kubernetes_manifest.platform_api_servicemonitor
```

`state rm` removes the resource from Terraform's state file but leaves the live cluster object untouched. Then I deleted `platform-api.tf` (renamed to `ingresses.tf` for what remained — the infra ingresses for Grafana/Prometheus/Alertmanager). A final `terraform plan` showed "No changes", confirming the handoff was clean.

**Lesson:** The right way to migrate ownership of cluster resources from one IaC tool to another is to remove them from the source state without applying, then let the destination tool reconcile. Never `terraform destroy` first; that rips down the cluster object before anyone else can adopt it.

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
| GitOps controller | Argo CD | UI included, app-of-apps pattern, broad ecosystem |
| Repo split | `platform-lab` (infra) + `platform-lab-gitops` (workloads) | Blast-radius separation, clean permissions story |
| Workload migration | Server-side apply + `terraform state rm` | Adopt without recreating; no downtime |
| Argo bcrypt drift | `lifecycle.ignore_changes = [set]` | Non-deterministic functions force drift otherwise |

---

## What I'd do differently next time

- **Pin all chart versions in variables.tf from day one.** I bumped them ad-hoc during development and that made some debugging harder than it needed to be.
- **Build the dashboard JSON last, not first.** I iterated on PromQL queries against an empty target for an hour before realizing the ServiceMonitor wasn't being picked up. Validate the scrape pipeline end-to-end before touching the dashboard.
- **Add the `Makefile` earlier.** Twelve copy-pasted command blocks across a session is a sign you need a Makefile. Adding it on day three felt overdue.
- **Run `terraform fmt` as a pre-commit hook from the start.** I had to fix formatting after writing the validate workflow because my files weren't formatted.
- **Verify file existence after every cat heredoc.** Lost 10 minutes to a silent drop.

---

## Open work

- Local AI inference platform (v0.2 Phases B–D)
- Alertmanager → Slack webhook + meaningful PrometheusRules
- Distributed tracing with OpenTelemetry + Grafana Tempo
- Integration test workflow that provisions the cluster in GitHub Actions
- Private gitops repo + sealed-secrets / external-secrets
## Phase 9 — Ollama Plumbing (v0.2 Phase B)

**Goal:** Wire the cluster to a host-native Ollama on the Mac Studio so workloads inside Kubernetes can call LLM inference without running models in pods (Metal acceleration stays on macOS).

### Design decisions

1. **Inference stays outside the cluster.** Ollama runs natively on macOS to keep Metal/GPU acceleration. No GPU passthrough into Docker Desktop, no model weights in pods.
2. **Coexistence with existing Ollama project.** A second project on this Mac already uses Ollama on `127.0.0.1:11434`. Rather than running a second instance on a different port, we expanded the bind from `127.0.0.1` to `0.0.0.0` — the existing project continues to hit `localhost` unchanged (non-breaking), and Docker/cluster traffic now reaches it via `host.docker.internal`.
3. **ExternalName Service, not Endpoints + headless Service.** Cleaner: one YAML, no IP to babysit, and `host.docker.internal` is the canonical Docker-for-Mac bridge alias.
4. **GitOps-managed.** The `inference` namespace and the `ollama` Service live in the gitops repo, applied by Argo CD via the `inference` Application (app-of-apps child).

### Implementation

**Mac side — Ollama bind change:**

```bash
# Set env var for current session + future launchctl-spawned processes
launchctl setenv OLLAMA_HOST 0.0.0.0:11434

# Restart Ollama so it picks up the new bind
pkill -x Ollama && open -a Ollama

# Verify
lsof -nP -iTCP:11434 -sTCP:LISTEN
# → ollama ... TCP *:11434 (LISTEN)
```

LaunchAgent (`~/Library/LaunchAgents/com.ollama.host.plist`) was prepared for persistence across reboots — sets `OLLAMA_HOST=0.0.0.0:11434` in the user session environment before Ollama launches.

**Cluster side — gitops repo additions:**

```
workloads/inference/
├── namespace.yaml         # inference namespace
└── ollama-service.yaml    # ExternalName → host.docker.internal:11434
```

```yaml
# ollama-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: inference
spec:
  type: ExternalName
  externalName: host.docker.internal
  ports:
    - port: 11434
      targetPort: 11434
      protocol: TCP
```

Plus `apps/inference.yaml` (Argo Application pointing at `workloads/inference`).

### Smoke tests (all from inside the cluster)

```bash
# 1. Version — proves DNS + ExternalName + network path
kubectl -n inference run curl-test --rm -i --restart=Never \
  --image=curlimages/curl:latest -- -s http://ollama:11434/api/version
# → {"version":"0.24.0"}

# 2. Generate — proves end-to-end inference
kubectl -n inference run curl-gen --rm -i --restart=Never \
  --image=curlimages/curl:latest -- -s -X POST \
  http://ollama:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:7b-instruct","prompt":"Say hi in exactly 5 words","stream":false}'
# → {"response":"Hello, nice to meet you.", "eval_count":8, "eval_duration":113874501, ...}

# 3. Tags — confirms all 6 host models visible
kubectl -n inference run curl-tags --rm -i --restart=Never \
  --image=curlimages/curl:latest -- -s http://ollama:11434/api/tags
# → qwen2.5:7b-instruct, llava, deepseek-coder-v2:16b, nomic-embed-text,
#    qwen2.5-coder:14b, llama3.1:8b
```

### Performance baseline (qwen2.5:7b-instruct, Metal, cold start)

| Metric              | Value          |
|---------------------|----------------|
| Total round-trip    | 1.58 s         |
| Model load          | 1.14 s (cold)  |
| Prompt eval         | 317 ms (36 tok)|
| Generation          | 114 ms (8 tok) |
| Throughput          | ~70 tok/s      |

Warm calls (model resident) should drop total round-trip to <200 ms for short completions.

### Problem 12 — `OLLAMA_HOST` env var is consumed by both client and server

Setting `OLLAMA_HOST` at shell scope affects the `ollama` CLI too — running `ollama list` later tries to hit `0.0.0.0:11434` from the client side. Workaround: the CLI happily talks to that address since the server is bound there. No action needed, but worth noting for anyone wondering why `ollama list` keeps working unchanged.

### Problem 13 — `osascript` "User canceled" on automation prompt

First attempt to restart Ollama via AppleScript triggered a macOS automation permission dialog that was dismissed. Used `pkill -x Ollama && open -a Ollama` instead — bypasses the AppleScript permissions layer entirely.

### What's now reachable from cluster pods

| Service DNS                  | Target                        | Use case            |
|------------------------------|-------------------------------|---------------------|
| `ollama.inference:11434`     | `host.docker.internal:11434`  | All LLM inference   |

### Next (Phase C)

- Custom Go `inference-gateway` Deployment (OpenAI-compatible API in front of Ollama, exporting Prometheus metrics: TTFT, tokens/sec, active requests, error rate)
- Open WebUI Deployment + Ingress at `chat.platform-lab.test`
- Grafana dashboard: "LLM Inference" panel — request rate, p50/p95 latency, tokens/sec, error rate
