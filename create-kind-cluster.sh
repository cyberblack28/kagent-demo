#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent-system}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"

# ここは実際の環境に合わせて修正してください
KAGENT_CHART_DIR="${KAGENT_CHART_DIR:-./helm/kagent}"
KAGENT_VALUES_FILE="${KAGENT_VALUES_FILE:-./kagent-values-kind.yaml}"
KAGENT_UI_SERVICE="${KAGENT_UI_SERVICE:-kagent-ui}"

echo "[1/7] Preflight checks"
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin"; exit 1; }
done

docker ps >/dev/null 2>&1 || {
  echo "Docker daemon is not running."
  echo "See install.md"
  exit 1
}

echo "[2/7] Create kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster already exists: ${CLUSTER_NAME}"
else
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
fi

echo "[3/7] Create namespaces"
kubectl apply -f manifests/00-namespaces.yaml

echo "[4/7] Install kagent"
if [[ ! -d "${KAGENT_CHART_DIR}" ]]; then
  echo "WARNING: chart dir not found: ${KAGENT_CHART_DIR}"
  echo "         Replace KAGENT_CHART_DIR with your actual chart path."
else
  helm upgrade --install kagent "${KAGENT_CHART_DIR}"     -n "${KAGENT_NAMESPACE}"     -f "${KAGENT_VALUES_FILE}"     --wait
fi

echo "[5/7] Deploy demo app"
kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true

echo "[6/7] Verify"
kubectl get pods -n "${KAGENT_NAMESPACE}" -o wide || true
kubectl get pods -n "${DEMO_NAMESPACE}" -o wide || true
kubectl get pods -n "${OBS_NAMESPACE}" -o wide || true

echo "[7/7] Next step"
cat <<EOF

Done.

Suggested next steps:
- Port-forward the kagent UI service:
  kubectl port-forward -n ${KAGENT_NAMESPACE} svc/${KAGENT_UI_SERVICE} 8080:80
- Open: http://localhost:8080
- Use the demo-app workload to test diagnosis flows

EOF
