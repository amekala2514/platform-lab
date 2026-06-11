# platform-lab

A local Kubernetes-based platform engineering lab on Mac Studio. Production-style observability, GitOps, and now an LLM inference layer — all running on a 3-node kind cluster.

## What's inside

- **Kubernetes** — kind cluster (1 control-plane + 2 workers, K8s v1.35)
- **GitOps** — Argo CD app-of-apps reconciling all workloads from [platform-lab-gitops](https://github.com/amekala2514/platform-lab-gitops)
- **Observability** — kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)
- **Ingress** — ingress-nginx with `*.platform-lab.test` resolving locally via `/etc/hosts`
- **Inference layer** *(v0.2.0)* — Go gateway exposing OpenAI-compatible API over local Ollama, fronted by Open WebUI, observed by a custom Grafana dashboard
- **Reference workload** — `platform-api` service with its own ServiceMonitor + dashboard

## Architecture

```
                     ┌────────────────────────────────────────────┐
                     │            Mac Studio (host)               │
                     │  ┌───────────────┐    ┌──────────────────┐ │
                     │  │   Ollama      │◄───┤ kind cluster     │ │
                     │  │   :11434      │    │ (3 nodes)        │ │
                     │  └───────────────┘    └──────────────────┘ │
                     └────────────────────────────────────────────┘
                                              │
                                              ▼
              ┌───────────────────────────────────────────────────┐
              │                inference namespace                │
              │  ┌────────────┐   ┌────────────────────────────┐  │
              │  │ Open WebUI │──▶│ inference-gateway (Go)     │  │
              │  │  :8080     │   │ /v1/chat/completions       │  │
              │  └────────────┘   │ /v1/embeddings  /v1/models │  │
              │       ▲           │ SSE streaming + Prom /metrics│ │
              │       │           └────────────────────────────┘  │
              │       │                       │                    │
              └───────┼───────────────────────┼────────────────────┘
                      │                       │
              chat.platform-lab.test    inference.platform-lab.test
                      │                       │
                      ▼                       ▼
              ┌─────────────────── ingress-nginx ──────────────────┐
              │                                                     │
              └─────────────────────────────────────────────────────┘

              observability namespace
              ┌─────────────────────────────────────────────────────┐
              │ kps-prometheus ◄── ServiceMonitor ◄── inference-gw  │
              │      │                                              │
              │      ▼                                              │
              │ kps-grafana ◄── ConfigMap (grafana_dashboard=1)     │
              │ • LLM Inference dashboard (TTFT, latency, tokens)   │
              │ • platform-api dashboard                            │
              └─────────────────────────────────────────────────────┘

              argocd namespace
              ┌─────────────────────────────────────────────────────┐
              │ root ──▶ inference, inference-gateway, open-webui,  │
              │          grafana-dashboards, observability-ingress, │
              │          platform-api, platform-api-monitoring      │
              └─────────────────────────────────────────────────────┘
```

## Local hostnames

| Host                          | Service                |
|-------------------------------|------------------------|
| `argocd.platform-lab.test`    | Argo CD UI             |
| `grafana.platform-lab.test`   | Grafana UI             |
| `chat.platform-lab.test`      | Open WebUI chat        |
| `inference.platform-lab.test` | Inference gateway API  |

Add to `/etc/hosts`:

```
127.0.0.1 argocd.platform-lab.test grafana.platform-lab.test chat.platform-lab.test inference.platform-lab.test
```

## Quick start

```bash
# 1. Bring up the cluster + core components
make cluster        # kind create + ingress-nginx + cert-manager
make argocd         # install Argo CD + bootstrap root app

# 2. Wait for Argo to reconcile everything (~3 min)
kubectl -n argocd get applications

# 3. Open the dashboards
open http://grafana.platform-lab.test
open http://chat.platform-lab.test
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/IMPLEMENTATION_LOG.md`](docs/IMPLEMENTATION_LOG.md) for details.

## Releases

- **v0.2.0** — Inference gateway + Open WebUI + LLM Inference Grafana dashboard
- **v0.1.0** — Cluster bootstrap + kps + ingress-nginx + platform-api reference workload
