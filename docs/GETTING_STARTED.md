# Getting Started

Set up `platform-lab` on your machine from scratch in about 15 minutes.

> This guide focuses on **what to run**. For **why** see [ARCHITECTURE.md](ARCHITECTURE.md); for **what broke and how it was fixed** see [IMPLEMENTATION_LOG.md](../IMPLEMENTATION_LOG.md).

---

## 1. Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Docker Desktop | 4.30+ | https://www.docker.com/products/docker-desktop |
| Terraform | 1.6 | `brew install terraform` |
| kubectl | 1.30 | `brew install kubectl` |
| kind | 0.23 | `brew install kind` |
| Helm | 3.14 (or 4.x) | `brew install helm` |
| Go | 1.23 | `brew install go` *(only if rebuilding platform-api)* |
| curl, git | – | already installed |

Verify everything:

```bash
docker --version && terraform version && kubectl version --client \
  && kind --version && helm version && go version
```

Make sure Docker Desktop has at least **4 CPUs and 8 GB RAM** allocated (Docker Desktop → Settings → Resources). The default 2 CPUs / 2 GB will fail to fit the kube-prometheus-stack pods.

---

## 2. Clone the repository

```bash
git clone https://github.com/amekala2514/platform-lab.git
cd platform-lab
```

---

## 3. Configure host DNS

The platform routes traffic through 4 hostnames. Add them to your hosts file (one-time setup):

```bash
sudo tee -a /etc/hosts <<'HOSTS'
127.0.0.1 platform-lab.test
127.0.0.1 grafana.platform-lab.test
127.0.0.1 prometheus.platform-lab.test
127.0.0.1 alertmanager.platform-lab.test
HOSTS
```

Verify:

```bash
host platform-lab.test  # should return 127.0.0.1
```

---

## 4. Build the application image

```bash
cd go-services/platform-api
docker build -t platform-api:dev .
cd -
```

Confirm:

```bash
docker images | grep platform-api
# platform-api    dev    <sha>    <date>    ~62MB
```

---

## 5. Provision the platform with Terraform

Terraform's `kubernetes_manifest` resource needs CRDs to exist before it can plan. This is a **deliberate two-phase apply**:

```bash
cd terraform
terraform init
```

### Phase 1 — cluster + Helm releases + dashboard ConfigMap

```bash
terraform apply -auto-approve \
  -target=kind_cluster.platform_lab \
  -target=kubernetes_namespace.observability \
  -target=kubernetes_namespace.ingress_nginx \
  -target=helm_release.metrics_server \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.ingress_nginx \
  -target=kubernetes_config_map.platform_api_dashboard
```

Takes about 5-7 minutes (most of it is kube-prometheus-stack pulling images and waiting for CRDs to settle).

### Phase 2 — Ingresses + ServiceMonitor

```bash
terraform apply -auto-approve
```

Takes about 30 seconds.

### Configure kubectl

```bash
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
kubectl get nodes
```

Should print 3 nodes — 1 control-plane and 2 workers, all `Ready`.

---

## 6. Deploy the application

```bash
kind load docker-image platform-api:dev --name platform-lab
kubectl apply -f ../k8s/platform-api.yaml
kubectl rollout status deploy/platform-api
```

Verify the pods are running:

```bash
kubectl get pods -l app=platform-api
# NAME                            READY   STATUS    RESTARTS   AGE
# platform-api-xxxxxxxxxx-aaaaa   1/1     Running   0          20s
# platform-api-xxxxxxxxxx-bbbbb   1/1     Running   0          20s
```

---

## 7. Verify the stack end-to-end

### All 4 hostnames return 200

```bash
echo "=== platform-api ===" && curl -sf -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://platform-lab.test/healthz
echo "=== grafana ==="      && curl -sf -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://grafana.platform-lab.test/login
echo "=== prometheus ==="   && curl -sf -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://prometheus.platform-lab.test/-/ready
echo "=== alertmanager ===" && curl -sf -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://alertmanager.platform-lab.test/-/ready
```

All four should be `HTTP 200` in under 10ms.

### Application metrics

```bash
curl -sf http://platform-lab.test/metrics | grep -E '^http_(requests|inflight)' | head
```

Should show Counter/Gauge entries.

### Prometheus scraping platform-api

Open http://prometheus.platform-lab.test/targets and look for the `serviceMonitor/observability/platform-api/0` entry — state should be `UP`.

If the target is missing after 60 seconds:

```bash
kubectl -n observability delete pod prometheus-kps-prometheus-0
```

This forces the operator to push a fresh config (see [IMPLEMENTATION_LOG.md Problem 6](../IMPLEMENTATION_LOG.md#problem-6-servicemonitor-created-but-prometheus-didnt-scrape)).

### Grafana dashboard auto-imported

Open http://grafana.platform-lab.test
Login: `admin` / `platform-admin`
Navigate to **Dashboards → Platform Lab → Platform API — RED + Runtime**

You should see 12 panels — most will be `No data` until you generate some traffic. Run this in another terminal:

```bash
while true; do
  curl -sf -o /dev/null http://platform-lab.test/healthz
  curl -sf -o /dev/null http://platform-lab.test/info
  curl -sf -o /dev/null http://platform-lab.test/nonexistent || true
  sleep 0.5
done
```

Within 30 seconds the dashboard will light up with request rate, latency percentiles, and error rate.

---

## 8. Tear down

```bash
cd terraform
terraform destroy -auto-approve
```

This removes the Kind cluster and all Helm releases. Your `/etc/hosts` entries persist (harmless).

To remove the hosts entries too:

```bash
sudo sed -i '' '/platform-lab\.test/d' /etc/hosts
```

---

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `terraform plan` fails with `cannot create REST client` | Cluster doesn't exist yet | Use the two-phase apply in Step 5 |
| `kubectl` can't connect | `KUBECONFIG` not set | `export KUBECONFIG=$(terraform output -raw kubeconfig_path)` |
| 503 from ingress | Service port mismatch | `kubectl get svc <name>` and confirm the port matches the Ingress |
| `curl` hangs for ~5s on `.local` hostnames | macOS mDNS intercepts `.local` | Use `.test` hostnames — they're already in this guide |
| Docker build fails with `credsStore: desktop` | Docker Desktop creds helper broken | Remove `"credsStore"` from `~/.docker/config.json` |
| Prometheus target missing | Operator config cache stale | `kubectl -n observability delete pod prometheus-kps-prometheus-0` |
| Pods stuck in `ImagePullBackOff` | Image not loaded into Kind | Run `kind load docker-image platform-api:dev --name platform-lab` again |

---

## Useful commands

### Cluster

```bash
# Switch kubeconfig
export KUBECONFIG=$(cd terraform && terraform output -raw kubeconfig_path)

# Resource usage by node
kubectl top nodes

# Resource usage by pod
kubectl top pods -A

# All workloads in observability
kubectl -n observability get all
```

### Logs

```bash
# Ingress controller logs (live)
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx -f

# Prometheus logs
kubectl -n observability logs prometheus-kps-prometheus-0 -c prometheus

# Grafana logs (look for sidecar dashboard imports)
kubectl -n observability logs deploy/kps-grafana -c grafana-sc-dashboard
```

### Forcing reloads

```bash
# Restart platform-api after image rebuild
kind load docker-image platform-api:dev --name platform-lab
kubectl rollout restart deploy/platform-api

# Force Prometheus to reload config
kubectl -n observability delete pod prometheus-kps-prometheus-0

# Force Grafana to re-scan dashboard ConfigMaps
kubectl -n observability rollout restart deploy/kps-grafana
```

### Iterating on Terraform

```bash
cd terraform

# Format
terraform fmt -recursive

# Validate without touching the cluster
terraform validate

# Plan a single resource
terraform plan -target=helm_release.kube_prometheus_stack

# Apply a single resource
terraform apply -target=helm_release.kube_prometheus_stack
```

---

## Next steps

Once you have the platform running:

1. Generate traffic and watch the Grafana dashboard light up
2. Browse the alerts at http://alertmanager.platform-lab.test (the `Watchdog` alert is always firing — that's intentional)
3. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the design choices
4. Try the roadmap items in the [README](../README.md#roadmap)
