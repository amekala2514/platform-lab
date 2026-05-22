# v0.1.0 — Initial release

First tagged release of `platform-lab`. A reproducible local Kubernetes platform demonstrating IaC, observability, and CI/CD patterns.

## Highlights

- **One-command platform provisioning** — Terraform brings up a 3-node Kind cluster, installs the full observability stack via Helm, configures ingress, and registers application monitoring in a two-phase apply.
- **End-to-end observability** — kube-prometheus-stack v77.1.0 with custom RED-method Grafana dashboard auto-imported via the ConfigMap sidecar pattern.
- **Application instrumentation** — Go service exporting Prometheus metrics through HTTP middleware (request rate, error rate, latency histogram, in-flight gauge).
- **Hostname-based ingress** — nginx-ingress as DaemonSet with hostPort on the control-plane, routing `*.platform-lab.test` to 4 backends.
- **CI-gated IaC** — GitHub Actions workflows for `terraform fmt`/`validate`, `helm lint` with pinned chart versions, kubeconform schema validation, and `terraform plan` posted as sticky PR comments.

## What's included

| Layer | Component | Version |
|---|---|---|
| Cluster | Kind (1 control-plane + 2 workers) | k8s 1.35 |
| IaC | Terraform + `tehcyx/kind`, `hashicorp/kubernetes`, `hashicorp/helm` | 1.6+ |
| Ingress | ingress-nginx (DaemonSet) | 4.13 |
| Monitoring | kube-prometheus-stack | 77.1.0 |
| Metrics API | metrics-server | 3.13 |
| Application | platform-api (Go, `prometheus/client_golang`) | 0.1.0 |

## Quick start

```bash
git clone https://github.com/amekala2514/platform-lab.git
cd platform-lab
# Follow docs/GETTING_STARTED.md
```

Full setup in ~15 minutes — see [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

## Documentation

- [README.md](README.md) — overview and architecture
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system design, data flows, design rationale
- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) — setup walkthrough
- [IMPLEMENTATION_LOG.md](IMPLEMENTATION_LOG.md) — 8 debugging incidents with root cause analysis

## Notable engineering decisions

- **Two-phase Terraform apply** — works around `kubernetes_manifest` requiring a live cluster during plan
- **`.test` hostnames** — sidesteps macOS mDNS interception of `.local`
- **DaemonSet + hostPort ingress** — canonical Kind pattern (no MetalLB needed)
- **Dashboard via ConfigMap sidecar** — version-controlled JSON, auto-imported, no UI clicks
- **kubeconform in CI** — offline manifest validation without needing a cluster

## What's next (v0.2.0 candidates)

- Alertmanager → Slack webhook with meaningful PrometheusRules
- GitOps with Argo CD
- Distributed tracing with OpenTelemetry + Grafana Tempo
- Integration test workflow spinning up Kind in GitHub Actions

## Acknowledgements

Built as a portfolio project for platform engineering interviews. The full debugging history is in [IMPLEMENTATION_LOG.md](IMPLEMENTATION_LOG.md) — every problem encountered, why it happened, and how it was fixed.
