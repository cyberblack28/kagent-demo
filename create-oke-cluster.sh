#!/usr/bin/env bash
set -euo pipefail

# OKE bootstrap:
# - Use Helm directly (officially supported) instead of the kagent CLI wrapper.
# - This gives us explicit control over Helm --wait/--timeout on OKE.
# - After install, we apply the OCI ModelConfig and demo workloads.
#
# 改善点:
# - Helm install 失敗時に、Pod 状態・Events・異常 Pod の describe を自動表示
# - API キーは --set ではなく --set-string で渡す(特殊文字対策)
# - 前回失敗したリリース(pending-install / failed)が残っていたら検出して掃除

KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"
OPENAI_PROVIDER_API_KEY="${OPENAI_PROVIDER_API_KEY:-${OPENAI_API_KEY:-${OCI_GENAI_API_KEY:-}}}"
KAGENT_HELM_TIMEOUT="${KAGENT_HELM_TIMEOUT:-15m}"
# UI の公開方式: ClusterIP(既定、port-forward で利用) or LoadBalancer
# LoadBalancer にする場合は、可能な限り UI_LB_ALLOWED_CIDR で接続元を絞ること。
#   例: KAGENT_UI_SERVICE_TYPE=LoadBalancer UI_LB_ALLOWED_CIDR="203.0.113.10/32" ./create-oke-cluster.sh
KAGENT_UI_SERVICE_TYPE="${KAGENT_UI_SERVICE_TYPE:-ClusterIP}"
UI_LB_ALLOWED_CIDR="${UI_LB_ALLOWED_CIDR:-}"
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
  echo ""
  echo "--- Node capacity/arch (参考: ARM ノードやリソース不足の確認) ---"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory 2>/dev/null || true
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
    echo "  - ImagePullBackOff : イメージ取得失敗(ネットワーク/アーキテクチャ)"
    echo "  - Pending          : ノードのリソース不足 or スケジュール不可"
    echo "  - CrashLoopBackOff : 設定不備(Secret / 環境変数)"
    exit 1
  fi
}

for bin in kubectl helm curl bash envsubst; do
  need_bin "$bin"
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  echo "export OCI_GENAI_API_KEY='sk-...'"
  exit 1
fi

if [[ -z "${OPENAI_PROVIDER_API_KEY}" ]]; then
  echo "OPENAI_API_KEY (or OPENAI_PROVIDER_API_KEY) is not set."
  echo "For the bootstrap install, set a valid OpenAI API key, or temporarily reuse the OCI key."
  exit 1
fi

kubectl get nodes >/dev/null 2>&1 || {
  echo "kubectl cannot access the OKE cluster."
  echo "Check your kubeconfig / current context first."
  exit 1
}

# ワーカーノードが Ready でなければ先に失敗させる(configuring のまま等)
ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)"
if [[ "${ready_nodes}" -eq 0 ]]; then
  echo "No Ready worker nodes found. Check node pool status first:"
  kubectl get nodes || true
  exit 1
fi

echo "[1/8] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[2/8] Install kagent CRDs"
cleanup_stuck_release kagent-crds "${KAGENT_NAMESPACE}"
helm_install_or_diagnose kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace "${KAGENT_NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout "${KAGENT_HELM_TIMEOUT}"

echo "[3/8] Install kagent core chart"
cleanup_stuck_release kagent "${KAGENT_NAMESPACE}"
# API キーは --set ではなく --set-string で渡す。
# --set は値中の "," や特殊文字を Helm の構文として解釈してしまうため。
#
# OKE 向けの追加設定:
# - registry=ghcr.io:
#     チャートのデフォルト cr.kagent.dev が "repository name not known" を
#     返すことがあるため、イメージの実体がある ghcr.io を直接向ける。
# - grafana-mcp.enabled=false:
#     grafana-mcp のイメージ "mcp/grafana:latest" はレジストリ名なしの
#     短縮名で、OKE(Oracle Linux)ノードは short-name 解決を enforcing に
#     しているため ErrImagePull になる。今回のデモでは Grafana を使わない
#     ため無効化する。
# UI の Service 設定を組み立てる
HELM_UI_ARGS=(--set ui.service.type="${KAGENT_UI_SERVICE_TYPE}")
if [[ "${KAGENT_UI_SERVICE_TYPE}" == "LoadBalancer" ]]; then
  # OCI Flexible LB の最小シェイプ(10Mbps固定)でコストを抑える
  HELM_UI_ARGS+=(
    --set-string 'ui.service.annotations.service\.beta\.kubernetes\.io/oci-load-balancer-shape=flexible'
    --set-string 'ui.service.annotations.service\.beta\.kubernetes\.io/oci-load-balancer-shape-flex-min=10'
    --set-string 'ui.service.annotations.service\.beta\.kubernetes\.io/oci-load-balancer-shape-flex-max=10'
  )
fi

helm_install_or_diagnose kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace "${KAGENT_NAMESPACE}" \
  --wait \
  --timeout "${KAGENT_HELM_TIMEOUT}" \
  --set registry=ghcr.io \
  --set grafana-mcp.enabled=false \
  --set providers.default=openAI \
  --set-string providers.openAI.apiKey="${OPENAI_PROVIDER_API_KEY}" \
  "${HELM_UI_ARGS[@]}"

# LoadBalancer の場合、接続元 CIDR を制限する(kagent UI は無認証のため)
if [[ "${KAGENT_UI_SERVICE_TYPE}" == "LoadBalancer" ]]; then
  if [[ -n "${UI_LB_ALLOWED_CIDR}" ]]; then
    echo "Restricting UI LoadBalancer source range to: ${UI_LB_ALLOWED_CIDR}"
    kubectl -n "${KAGENT_NAMESPACE}" patch svc kagent-ui \
      -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"${UI_LB_ALLOWED_CIDR}\"]}}"
  else
    echo "WARNING: kagent UI will be exposed to the internet WITHOUT authentication."
    echo "         Set UI_LB_ALLOWED_CIDR to restrict access, and delete the"
    echo "         LoadBalancer after the demo."
  fi
fi

echo "[4/8] Wait for CRDs to become Established"
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

echo "[5/8] Create OCI GenAI secret and ModelConfig"
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai \
  --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" \
  envsubst < "${SCRIPT_DIR}/manifests/01-modelconfig-oci.yaml" | kubectl apply -f -

echo "[6/8] Point bundled agents at the OCI model and reload"
for a in $(kubectl -n "${KAGENT_NAMESPACE}" get agents.kagent.dev -o name 2>/dev/null || true); do
  kubectl -n "${KAGENT_NAMESPACE}" patch "$a" --type=merge \
    -p '{"spec":{"declarative":{"modelConfig":"oci-genai-openai-compatible"}}}' >/dev/null 2>&1 || true
done

kubectl -n "${KAGENT_NAMESPACE}" rollout restart deploy >/dev/null 2>&1 || true
if ! kubectl -n "${KAGENT_NAMESPACE}" rollout status deploy --timeout=180s >/dev/null 2>&1; then
  echo "WARNING: some deployments did not become ready after restart."
  diagnose_namespace "${KAGENT_NAMESPACE}"
fi

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
  # ClusterIP の場合:
  kubectl port-forward -n ${KAGENT_NAMESPACE} svc/kagent-ui 8080:8080
  # LoadBalancer の場合(EXTERNAL-IP が付与されるまで数分待つ):
  kubectl get svc -n ${KAGENT_NAMESPACE} kagent-ui -w
  # → http://<EXTERNAL-IP>:8080 にアクセス

デモ中の障害注入(その場で):
  # デモ2: ImagePullBackOff を起こす
  kubectl apply -f ${SCRIPT_DIR}/manifests/30-demo-imagepull.yaml
  # デモ3: サービスのセレクタずれを起こす
  kubectl apply -f ${SCRIPT_DIR}/manifests/40-demo-service-mismatch.yaml
  # 直す
  kubectl apply -f ${SCRIPT_DIR}/manifests/41-demo-service-restore.yaml

EOF
