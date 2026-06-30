#!/usr/bin/env bash
set -euo pipefail

# 401回避版
# OpenAI / OCI GenAI への API 呼び出しはしない。
# kind クラスタ作成と namespace / demo workload 作成のみを行う。

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

for bin in docker kind kubectl; do
  need_bin "$bin"
done

docker ps >/dev/null 2>&1 || { echo "Docker daemon is not running."; exit 1; }

echo "[1/4] Create kind cluster"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
else
  echo "Cluster already exists: ${CLUSTER_NAME}"
fi

echo "[2/4] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] Apply demo workloads"
kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true

echo "[4/4] Apply service mismatch demo"
kubectl apply -f manifests/30-demo-service-mismatch.yaml || true

cat <<EOF

Done.

This version does not perform any OpenAI / OCI GenAI API calls.

To restore the service selector:
  kubectl apply -f manifests/31-demo-service-restore.yaml

EOF
