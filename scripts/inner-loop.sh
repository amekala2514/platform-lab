#!/usr/bin/env bash
# inner-loop.sh — Fast dev loop for platform-api
# Usage: ./scripts/inner-loop.sh [cluster-name]
set -euo pipefail

CLUSTER="${1:-platform-lab}"
SERVICE_DIR="go-services/platform-api"
IMAGE_NAME="platform-api"
IMAGE_TAG="dev"
K8S_MANIFEST="k8s/platform-api.yaml"

log() { echo "==> $*"; }

# Move to repo root regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 1. Run tests
log "Running tests..."
(cd "$SERVICE_DIR" && go test ./... -count=1)

# 2. Build Docker image
log "Building Docker image $IMAGE_NAME:$IMAGE_TAG..."
docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$SERVICE_DIR"

# 3. Load image into kind
log "Loading image into kind cluster '$CLUSTER'..."
kind load docker-image "$IMAGE_NAME:$IMAGE_TAG" --name "$CLUSTER"

# 4. Apply Kubernetes manifests (Deployment + Service, then Ingress)
log "Applying Kubernetes manifests..."
kubectl apply -f "$K8S_MANIFEST" --context "kind-$CLUSTER"
kubectl apply -f k8s/ingress.yaml --context "kind-$CLUSTER"

# 5. Wait for rollout
log "Waiting for rollout to complete..."
kubectl rollout status deployment/platform-api --context "kind-$CLUSTER" --timeout=60s

# 6. Validate
log "Checking pods..."
kubectl get pods -l app=platform-api --context "kind-$CLUSTER"

log "Starting port-forward to localhost:8080 (Ctrl+C to stop)..."
kubectl port-forward svc/platform-api 8080:8080 --context "kind-$CLUSTER"
