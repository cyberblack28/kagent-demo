#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
KAGENT_PROFILE="${KAGENT_PROFILE:-demo}"

echo "[1/8] Preflight checks"
for bin in docker kind kubectl curl bash; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin"; exit 1; }
done

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set."
  echo "Export your OpenAI API key first."
  exit 1
fi

docker ps >/dev/null 2>&1 || {
  echo "Docker daemon is not running."
  echo "See install.md"
  exit 1
}

echo "[2/8] Create kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster already exists: ${CLUSTER_NAME}"
else
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
fi

echo "[3/8] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${OBS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[4/8] Install kagent CLI if needed"
if ! command -v kagent >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
fi

echo "[5/8] Install kagent into the cluster"
kagent install --profile "${KAGENT_PROFILE}"

echo "[6/8] Deploy demo app"
kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true

echo "[7/8] Verify"
kubectl get pods -n "${KAGENT_NAMESPACE}" -o wide || true
kubectl get pods -n "${DEMO_NAMESPACE}" -o wide || true
kubectl get pods -n "${OBS_NAMESPACE}" -o wide || true
kagent get agent || true

echo "[8/8] Next step"
cat <<EOF

Done.

Suggested next steps:
- Open the dashboard:
  kagent dashboard
- Use the demo-app workload to test diagnosis flows.

EOF
