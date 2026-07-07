#!/usr/bin/env bash
set -euo pipefail

# OKE 版: 既存の OKE クラスタに kagent とデモ環境を載せる。
# kind / Docker の作成部分は含めない。
#
# 前提:
#   - OKE クラスタの kubeconfig 設定済み
#   - kubectl で OKE に接続できる
#   - OCI_GENAI_API_KEY が設定済み
#
# このスクリプトは、kind 版と同じく
#   1) kagent install
#   2) default-model-config を OCI 設定で上書き
#   3) agent を OCI 用 ModelConfig に向け直し
#   4) demo-app の workload を投入
# を実行する。

CLUSTER_NAME="${CLUSTER_NAME:-oke-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
KAGENT_PROFILE="${KAGENT_PROFILE:-demo}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_for_crd() {
  local pattern="$1"
  local timeout_seconds="${2:-180}"
  local elapsed=0
  local crd_name=""
  echo "Waiting for CRD matching: ${pattern}"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    crd_name="$(kubectl get crd -o name 2>/dev/null | grep -i "${pattern}" | head -n1 || true)"
    if [[ -n "${crd_name}" ]]; then
      kubectl wait --for=condition=Established "${crd_name}" --timeout=60s >/dev/null 2>&1 || true
      echo "Found CRD: ${crd_name}"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "Timed out waiting for CRD matching: ${pattern}"
  return 1
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

for bin in kubectl curl bash envsubst; do
  need_bin "$bin"
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  echo "export OCI_GENAI_API_KEY='sk-...'"
  exit 1
fi

# kagent インストーラが既定 Secret を作る都合で OPENAI_API_KEY を要求する場合に備える。
# ただし、実際のモデル呼び出しは後で作る OCI 用 ModelConfig に切り替える。
export OPENAI_API_KEY="${OPENAI_API_KEY:-${OCI_GENAI_API_KEY}}"

# kubectl が OKE を見ているか確認
kubectl get nodes >/dev/null 2>&1 || {
  echo "kubectl cannot access the OKE cluster."
  echo "Check your kubeconfig / current context first."
  exit 1
}

echo "[1/8] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[2/8] Install kagent CLI if needed"
# OCI Cloud Shell など sudo が使えない環境でも動くように、
# --no-sudo で $HOME/bin にインストールする(sudo が使える環境でも無害)。
# PATH への追加はインストールより前に行う。後続の kagent install が
# 同一シェル内で kagent コマンドを解決できるようにするため。
mkdir -p "${HOME}/bin"
export PATH="${HOME}/bin:${PATH}"
if ! command -v kagent >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent \
    | bash -s -- --no-sudo
fi

echo "[3/8] Install kagent (profile: ${KAGENT_PROFILE})"
kagent install --profile "${KAGENT_PROFILE}"

echo "[4/8] Wait for CRDs"
wait_for_crd "modelconfig" 300
wait_for_crd "agent" 300

echo "[5/8] Create OCI GenAI secret and ModelConfig"
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai   --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}"   --dry-run=client -o yaml | kubectl apply -f -

# default-model-config を OCI 設定で上書きし、別名 ModelConfig も用意する。
OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}"   envsubst < "${SCRIPT_DIR}/manifests/01-modelconfig-oci.yaml" | kubectl apply -f -

echo "[6/8] Point bundled agents at the OCI model and reload"
for a in $(kubectl -n "${KAGENT_NAMESPACE}" get agents.kagent.dev -o name 2>/dev/null || true); do
  kubectl -n "${KAGENT_NAMESPACE}" patch "$a" --type=merge     -p '{"spec":{"declarative":{"modelConfig":"oci-genai-openai-compatible"}}}' >/dev/null 2>&1 || true
done

# モデル設定の変更を Pod に反映させるため再起動する。
kubectl -n "${KAGENT_NAMESPACE}" rollout restart deploy >/dev/null 2>&1 || true
kubectl -n "${KAGENT_NAMESPACE}" rollout status deploy --timeout=180s >/dev/null 2>&1 || true

echo "[7/8] Deploy demo app (healthy baseline + crashloop fault)"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-demo-app.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/20-demo-fault-crashloop.yaml"

echo "[8/8] Done"

cat <<EOF

Done.

確認:
  kubectl get pods -n ${KAGENT_NAMESPACE}
  kubectl get pods -n ${DEMO_NAMESPACE}
  kubectl get modelconfig -n ${KAGENT_NAMESPACE}
  kubectl -n ${KAGENT_NAMESPACE} get modelconfig default-model-config -o yaml | grep -A3 openAI

UI:
  kubectl port-forward -n ${KAGENT_NAMESPACE} svc/kagent-ui 8080:8080
  # もしくは: kagent dashboard

デモ中の障害注入(その場で):
  kubectl apply -f ${SCRIPT_DIR}/manifests/30-demo-service-mismatch.yaml
  kubectl apply -f ${SCRIPT_DIR}/manifests/31-demo-service-restore.yaml

EOF
