#!/usr/bin/env bash
set -euo pipefail

# kagent を kind 上に構築し、OCI Generative AI(OpenAI 互換)をモデルとして使う。
#
# 重要な前提(なぜ 401 が出ていたか):
#   `kagent install --profile demo` は default-model-config という名前の ModelConfig
#   (provider OpenAI / baseUrl 未指定 = api.openai.com)と、それを参照する同梱エージェントを入れる。
#   OCI 用 ModelConfig を別名で作っても、エージェントは default-model-config を使い続けるため、
#   OCI のキーを OpenAI 本家に投げて 401 になる。
#   → 対策: default-model-config 自体を OCI 設定で上書きし、念のため各エージェントも向け直す。

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
KAGENT_PROFILE="${KAGENT_PROFILE:-demo}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
# 末尾スラッシュは付けない(OpenAI SDK が /chat/completions を自動付与する)。
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

for bin in docker kind kubectl curl bash envsubst; do
  need_bin "$bin"
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  echo "export OCI_GENAI_API_KEY='sk-...'"
  exit 1
fi

# kagent インストーラが既定 Secret を作る際に OPENAI_API_KEY を要求することがあるため、
# 値を入れておく。ただしエージェントが実際に使うのは下で作る kagent-oci-genai Secret であり、
# default-model-config を OCI で上書きするので、この値が OpenAI 本家に使われることはない。
export OPENAI_API_KEY="${OPENAI_API_KEY:-${OCI_GENAI_API_KEY}}"

docker ps >/dev/null 2>&1 || { echo "Docker daemon is not running."; exit 1; }

echo "[1/8] Create kind cluster"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
else
  echo "Cluster already exists: ${CLUSTER_NAME}"
fi

echo "[2/8] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[3/8] Install kagent CLI if needed"
if ! command -v kagent >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
fi

echo "[4/8] Install kagent (profile: ${KAGENT_PROFILE})"
kagent install --profile "${KAGENT_PROFILE}"

echo "[5/8] Wait for CRDs"
wait_for_crd "modelconfig" 300
wait_for_crd "agent" 300

echo "[6/8] Create OCI GenAI secret and ModelConfig"
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai \
  --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# default-model-config を OCI 設定で上書きし、別名 ModelConfig も用意する。
OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" \
  envsubst < "${SCRIPT_DIR}/manifests/01-modelconfig-oci.yaml" | kubectl apply -f -

echo "[7/8] Point bundled agents at the OCI model and reload"
# 既定名(default-model-config)の上書きで通常は十分だが、バージョン差異に備えて
# 既存エージェントを明示的に OCI 用 ModelConfig へ向け直す(宣言的エージェントのみ・失敗は無視)。
for a in $(kubectl -n "${KAGENT_NAMESPACE}" get agents.kagent.dev -o name 2>/dev/null || true); do
  kubectl -n "${KAGENT_NAMESPACE}" patch "$a" --type=merge \
    -p '{"spec":{"declarative":{"modelConfig":"oci-genai-openai-compatible"}}}' >/dev/null 2>&1 || true
done
# モデル設定の変更を Pod に反映させるため再起動する。
kubectl -n "${KAGENT_NAMESPACE}" rollout restart deploy >/dev/null 2>&1 || true
kubectl -n "${KAGENT_NAMESPACE}" rollout status deploy --timeout=180s >/dev/null 2>&1 || true

echo "[8/8] Deploy demo app (healthy baseline + crashloop fault for Demo 2)"
# ベースラインの healthy アプリと、自己修復デモ用の crashloop を投入する。
# Service mismatch(30)/restore(31)は“その場で壊す/直す”ためのものなので、ここでは適用しない。
kubectl apply -f "${SCRIPT_DIR}/manifests/10-demo-app.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/20-demo-fault-crashloop.yaml"

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
  # サービスのセレクタずれを起こす
  kubectl apply -f ${SCRIPT_DIR}/manifests/30-demo-service-mismatch.yaml
  # 直す
  kubectl apply -f ${SCRIPT_DIR}/manifests/31-demo-service-restore.yaml
EOF
