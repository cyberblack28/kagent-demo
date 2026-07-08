#!/usr/bin/env bash
set -euo pipefail

# kagent を kind 上に構築し、OCI Generative AI(OpenAI 互換)をモデルとして使う。
#
# OKE 版 (create-oke-cluster.sh) と同じ Helm ベースのインストールに統一している。
# 理由:
#   - kagent CLI (get-kagent) は最新ベータ版を入れるため、Helm(安定版)を使う
#     OKE 環境とバージョンがずれる。検証環境と本番デモ環境は同一バージョンにする。
#   - Helm なら --wait/--timeout、レジストリ切り替え、コンポーネント無効化を
#     明示的に制御できる。
#
# 重要な前提(なぜ 401 が出ていたか):
#   既定では default-model-config という名前の ModelConfig
#   (provider OpenAI / baseUrl 未指定 = api.openai.com)と、それを参照する同梱エージェントが入る。
#   OCI 用 ModelConfig を別名で作っても、エージェントは default-model-config を使い続けるため、
#   OCI のキーを OpenAI 本家に投げて 401 になる。
#   → 対策: default-model-config 自体を OCI 設定で上書きし、念のため各エージェントも向け直す。

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
# 末尾スラッシュは付けない(OpenAI SDK が /chat/completions を自動付与する)。
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"
OPENAI_PROVIDER_API_KEY="${OPENAI_PROVIDER_API_KEY:-${OPENAI_API_KEY:-${OCI_GENAI_API_KEY:-}}}"
KAGENT_HELM_TIMEOUT="${KAGENT_HELM_TIMEOUT:-15m}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

# ------------------------------------------------------------------
# 失敗時診断: どの Pod が、なぜ上がらないのかをその場で表示する
# ------------------------------------------------------------------
diagnose_namespace() {
  local ns="$1"
  echo ""
  echo "================ DIAGNOSTICS: namespace=${ns} ================"
  echo "--- Pods ---"
  kubectl -n "${ns}" get pods -o wide 2>/dev/null || true
  echo ""
  echo "--- Recent events (last 20) ---"
  kubectl -n "${ns}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  echo ""
  echo "--- Not-ready pods: describe (tail) ---"
  local pods
  pods="$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print $1}')" || true
  for p in ${pods}; do
    echo ""
    echo "### kubectl describe pod ${p} (末尾30行)"
    kubectl -n "${ns}" describe pod "${p}" 2>/dev/null | tail -30 || true
  done
  echo "==============================================================="
}

# 前回失敗したリリースが残っていると upgrade --install が詰まるため掃除する
cleanup_stuck_release() {
  local release="$1"
  local ns="$2"
  local status
  status="$(helm -n "${ns}" status "${release}" -o json 2>/dev/null \
    | grep -o '"status":"[^"]*"' | head -n1 | cut -d'"' -f4)" || true
  case "${status}" in
    pending-install|pending-upgrade|pending-rollback|failed)
      echo "Release ${release} is in state '${status}'. Uninstalling before retry..."
      helm -n "${ns}" uninstall "${release}" --wait --timeout 5m || true
      ;;
  esac
}

helm_install_or_diagnose() {
  local release="$1"
  shift
  if ! helm upgrade --install "${release}" "$@"; then
    echo ""
    echo "ERROR: helm install failed for release: ${release}"
    diagnose_namespace "${KAGENT_NAMESPACE}"
    echo "上記の Pod 状態 / Events から原因を確認してください。"
    exit 1
  fi
}

for bin in docker kind kubectl helm curl bash envsubst; do
  need_bin "$bin"
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  echo "export OCI_GENAI_API_KEY='sk-...'"
  exit 1
fi

if [[ -z "${OPENAI_PROVIDER_API_KEY}" ]]; then
  echo "OPENAI_API_KEY (or OPENAI_PROVIDER_API_KEY) is not set."
  exit 1
fi

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

echo "[3/8] Install kagent CRDs (Helm)"
cleanup_stuck_release kagent-crds "${KAGENT_NAMESPACE}"
helm_install_or_diagnose kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace "${KAGENT_NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout "${KAGENT_HELM_TIMEOUT}"

echo "[4/8] Install kagent core chart (Helm)"
cleanup_stuck_release kagent "${KAGENT_NAMESPACE}"
# OKE 版と同一の設定:
# - registry=ghcr.io       : cr.kagent.dev の不調を回避し、イメージ実体の ghcr.io を直接使う
# - grafana-mcp.enabled=false : 今回のデモでは Grafana を使わない(Pod 数も減り起動が速くなる)
# - --set-string           : API キー中の特殊文字を Helm が解釈しないようにする
helm_install_or_diagnose kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace "${KAGENT_NAMESPACE}" \
  --wait \
  --timeout "${KAGENT_HELM_TIMEOUT}" \
  --set registry=ghcr.io \
  --set grafana-mcp.enabled=false \
  --set providers.default=openAI \
  --set-string providers.openAI.apiKey="${OPENAI_PROVIDER_API_KEY}"

echo "[5/8] Wait for CRDs to become Established"
for pattern in modelconfig agent; do
  elapsed=0
  timeout_seconds=300
  crd_name=""
  echo "Waiting for CRD matching: ${pattern}"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    crd_name="$(kubectl get crd -o name 2>/dev/null | grep -i "${pattern}" | head -n1 || true)"
    if [[ -n "${crd_name}" ]]; then
      kubectl wait --for=condition=Established "${crd_name}" --timeout=60s >/dev/null 2>&1 || true
      echo "Found CRD: ${crd_name}"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  [[ -n "${crd_name}" ]] || { echo "Timed out waiting for CRD matching: ${pattern}"; exit 1; }
done

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
if ! kubectl -n "${KAGENT_NAMESPACE}" rollout status deploy --timeout=180s >/dev/null 2>&1; then
  echo "WARNING: some deployments did not become ready after restart."
  diagnose_namespace "${KAGENT_NAMESPACE}"
fi

echo "[8/8] Deploy demo app (healthy baseline + crashloop fault)"
# ベースラインの healthy アプリと、デモ1用の crashloop を投入する。
# Service mismatch(30)/restore(31)、ImagePull(40)は“その場で壊す/直す”ためのものなので、ここでは適用しない。
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

デモ中の障害注入(その場で):
  # デモ2: ImagePullBackOff を起こす
  kubectl apply -f ${SCRIPT_DIR}/manifests/30-demo-imagepull.yaml
  # デモ3: サービスのセレクタずれを起こす
  kubectl apply -f ${SCRIPT_DIR}/manifests/40-demo-service-mismatch.yaml
  # 直す
  kubectl apply -f ${SCRIPT_DIR}/manifests/41-demo-service-restore.yaml
EOF
