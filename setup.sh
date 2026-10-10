#!/usr/bin/env bash
# ==============================================================================
# Enterprise Bot DevOps Take-Home — Part 3: One-command Setup
#
# Idempotent cluster bootstrap and deployment script:
# 1. Creates (or reuses) a kind cluster named 'demo' configured for ingress
# 2. Installs the ingress-nginx controller and waits for readiness
# 3. Builds the service image and loads it into the kind cluster
# 4. Deploys/upgrades the demo Helm chart into namespace 'demo'
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"
IMAGE_NAME="demo-service"
IMAGE_TAG="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " Starting Enterprise Bot Demo Setup"
echo "============================================================"

# --- 1. Verify required host dependencies ---
for bin in docker kind kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: Required tool '$bin' is not installed or not in PATH." >&2
    exit 1
  fi
done

# --- 2. Create or reuse kind cluster 'demo' ---
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> Reusing existing kind cluster '${CLUSTER_NAME}'..."
else
  echo "==> Creating kind cluster '${CLUSTER_NAME}' with ingress-ready port mappings..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
fi

# Ensure kubectl context points to the demo cluster
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

# --- 3. Install ingress-nginx controller ---
echo "==> Checking ingress-nginx controller status..."
if kubectl get namespace ingress-nginx >/dev/null 2>&1 && \
   kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=5s >/dev/null 2>&1; then
  echo "==> ingress-nginx controller is already running and ready."
else
  echo "==> Deploying ingress-nginx controller for kind..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  echo "==> Waiting for ingress-nginx controller to be ready (up to 180s)..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
fi

# --- 4. Build and load container image ---
echo "==> Building service container image '${IMAGE_NAME}:${IMAGE_TAG}'..."
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "${SCRIPT_DIR}/service"

echo "==> Loading container image into kind cluster '${CLUSTER_NAME}'..."
kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"

# --- 5. Deploy Helm chart ---
echo "==> Deploying/upgrading Helm release '${RELEASE_NAME}' into namespace '${NAMESPACE}'..."
helm upgrade --install "${RELEASE_NAME}" "${SCRIPT_DIR}/chart" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 120s

echo ""
echo "============================================================"
echo " Setup complete! Service is deployed and ready."
echo "============================================================"
echo ""
echo "Verification commands:"
echo "  1. Check Pods:     kubectl get pods -n ${NAMESPACE}"
echo "  2. Test Root:      curl -s -H 'Host: demo.local' http://localhost/"
echo "  3. Test Health:    curl -s -H 'Host: demo.local' http://localhost/healthz"
echo ""
