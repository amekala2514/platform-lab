#!/usr/bin/env bash
# setup-ingress.sh — Install nginx ingress controller on the kind cluster
# and configure /etc/hosts for local domain resolution.
# Usage: ./scripts/setup-ingress.sh [cluster-name]
set -euo pipefail

CLUSTER="${1:-platform-lab}"
CONTEXT="kind-$CLUSTER"
HOSTS_ENTRY="127.0.0.1 platform-lab.local"

log()  { echo "==> $*"; }
warn() { echo "!!! $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ---------------------------------------------------------------------------
# 1. Confirm cluster is running
# ---------------------------------------------------------------------------
log "Checking cluster '$CLUSTER'..."
if ! kind get clusters | grep -q "^$CLUSTER$"; then
  warn "Cluster '$CLUSTER' not found. Create it first:"
  echo "  kind create cluster --name $CLUSTER --config kind-config.yaml"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Install nginx ingress controller (kind-specific build)
# ---------------------------------------------------------------------------
log "Installing nginx ingress controller..."
kubectl apply \
  --context "$CONTEXT" \
  -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# ---------------------------------------------------------------------------
# 3. Wait for the ingress controller to be ready
# ---------------------------------------------------------------------------
log "Waiting for ingress controller to be ready (this takes ~60s)..."
kubectl wait \
  --context "$CONTEXT" \
  --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

log "Ingress controller is ready."

# ---------------------------------------------------------------------------
# 4. Apply the platform-api Ingress resource
# ---------------------------------------------------------------------------
log "Applying Ingress resource for platform-api..."
kubectl apply -f k8s/ingress.yaml --context "$CONTEXT"

# ---------------------------------------------------------------------------
# 5. Add /etc/hosts entry (requires sudo)
# ---------------------------------------------------------------------------
if grep -q "platform-lab.local" /etc/hosts; then
  log "/etc/hosts already has platform-lab.local — skipping."
else
  log "Adding platform-lab.local to /etc/hosts (requires sudo)..."
  echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
  log "Added: $HOSTS_ENTRY"
fi

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
log "Waiting a moment for ingress to sync..."
sleep 5

log "Done! Test your service:"
echo ""
echo "  curl http://platform-lab.local/healthz"
echo "  curl http://platform-lab.local/info"
echo ""
echo "Or open in browser: http://platform-lab.local"
