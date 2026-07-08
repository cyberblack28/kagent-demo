#!/usr/bin/env bash
set -uo pipefail
# 注意: 削除スクリプトは途中で失敗しても最後まで掃除を続けたいので、
#       set -e は使わず、各コマンドを best effort で実行する。

# OKE cleanup:
# create-oke-cluster.sh が作ったものを逆順で削除する。
#   - demo workloads (10/20/30/40/41 番台マニフェスト)
#   - kagent の CR (agents / modelconfigs / toolservers)  ※CRD削除前に消す
#   - helm release: kagent (UI が LoadBalancer の場合、OCI LB もここで消える)
#   - helm release: kagent-crds
#   - namespaces: kagent / demo-app (PVC も一緒に消え、Block Volume が解放される)
#
# OKE 固有の注意:
#   - kagent-ui を type=LoadBalancer にしていた場合、helm uninstall で
#     Service が消えると OCI Load Balancer も自動削除される。
#     namespace を先に強制削除すると LB が孤児として課金され続けることが
#     あるため、必ず helm uninstall → namespace 削除の順で行う。
#   - kagent-postgresql の PVC は namespace 削除で消え、OCI Block Volume も
#     reclaimPolicy: Delete により解放される。

KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

for bin in kubectl helm; do
  need_bin "$bin"
done

kubectl get nodes >/dev/null 2>&1 || {
  echo "kubectl cannot access the OKE cluster."
  echo "Check your kubeconfig / current context first."
  exit 1
}

echo "[1/6] Delete demo workloads"
for f in \
  "${SCRIPT_DIR}/manifests/41-demo-service-restore.yaml" \
  "${SCRIPT_DIR}/manifests/40-demo-service-mismatch.yaml" \
  "${SCRIPT_DIR}/manifests/30-demo-imagepull.yaml" \
  "${SCRIPT_DIR}/manifests/20-demo-fault-crashloop.yaml" \
  "${SCRIPT_DIR}/manifests/10-demo-app.yaml"; do
  if [[ -f "${f}" ]]; then
    kubectl delete -f "${f}" --ignore-not-found=true 2>/dev/null || true
  fi
done

echo "[2/6] Delete kagent custom resources (before CRDs are removed)"
# CRD を先に消すと CR の finalizer が解決できず namespace 削除が固まるため、
# CR → helm release (kagent) → helm release (kagent-crds) の順に消す。
for kind in agents.kagent.dev modelconfigs.kagent.dev toolservers.kagent.dev; do
  if kubectl get crd "${kind}" >/dev/null 2>&1; then
    kubectl -n "${KAGENT_NAMESPACE}" delete "${kind}" --all --timeout=60s 2>/dev/null || true
  fi
done

echo "[3/6] Uninstall kagent helm release (Service/LB もここで消える)"
if helm -n "${KAGENT_NAMESPACE}" status kagent >/dev/null 2>&1; then
  helm -n "${KAGENT_NAMESPACE}" uninstall kagent --wait --timeout 10m || true
fi

# UI を LoadBalancer にしていた場合、OCI LB の削除完了を確認する
if kubectl -n "${KAGENT_NAMESPACE}" get svc kagent-ui >/dev/null 2>&1; then
  echo "Waiting for kagent-ui Service (and its OCI Load Balancer) to be deleted..."
  kubectl -n "${KAGENT_NAMESPACE}" wait --for=delete svc/kagent-ui --timeout=300s 2>/dev/null || \
    echo "WARNING: kagent-ui Service still exists. Check for a leftover OCI Load Balancer in the console."
fi

echo "[4/6] Uninstall kagent-crds helm release"
if helm -n "${KAGENT_NAMESPACE}" status kagent-crds >/dev/null 2>&1; then
  helm -n "${KAGENT_NAMESPACE}" uninstall kagent-crds --wait --timeout 5m || true
fi

echo "[5/6] Delete namespaces"
kubectl delete namespace "${DEMO_NAMESPACE}" --ignore-not-found=true --timeout=120s || true
kubectl delete namespace "${KAGENT_NAMESPACE}" --ignore-not-found=true --timeout=300s || true

echo "[6/6] Verify cleanup"
leftover=0
for ns in "${KAGENT_NAMESPACE}" "${DEMO_NAMESPACE}"; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    echo "WARNING: namespace ${ns} is still terminating."
    kubectl get namespace "${ns}" -o jsonpath='{.status.conditions}' 2>/dev/null && echo ""
    leftover=1
  fi
done

# 消し忘れ課金の定番2つを最終確認する
echo ""
echo "--- Leftover check (OCI 課金リソース) ---"
echo "PVC (Block Volume):"
kubectl get pvc -A 2>/dev/null | grep -E "^(${KAGENT_NAMESPACE}|${DEMO_NAMESPACE})\b" || echo "  none"
echo "LoadBalancer Service (OCI LB):"
kubectl get svc -A 2>/dev/null | awk '$5 == "LoadBalancer"' | grep -E "^(${KAGENT_NAMESPACE}|${DEMO_NAMESPACE})\b" || echo "  none"

if [[ "${leftover}" -eq 1 ]]; then
  cat <<'EOF'

namespace が Terminating のまま残る場合、CR の finalizer が原因のことが
多いです。次で残存 CR を確認してください:
  kubectl api-resources --verbs=list --namespaced -o name \
    | xargs -n1 -I{} kubectl get {} -n kagent --no-headers 2>/dev/null
EOF
fi

echo ""
echo "Cleanup done."
echo ""
echo "確認:"
echo "  kubectl get ns | grep -E '^(${KAGENT_NAMESPACE}|${DEMO_NAMESPACE})\\b' || true"
echo "  helm list -A | grep kagent || true"
