#!/usr/bin/env bash
set -euo pipefail
 
CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
# 末尾スラッシュなし。OpenAI SDK が /chat/completions を連結する際の "//" 事故を防ぐ。
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-oci-genai-openai-compatible}"
 
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
 
# OCI GenAI(OpenAI 互換)へ向け直すための JSON merge patch を生成（ModelConfig 用）。
oci_modelconfig_patch() {
  cat <<JSON
{"spec":{"provider":"OpenAI","model":"${OCI_GENAI_MODEL}","apiKeySecret":"kagent-oci-genai","apiKeySecretKey":"OCI_GENAI_API_KEY","openAI":{"baseUrl":"${OCI_GENAI_BASE_URL}"}}}
JSON
}
 
for bin in docker kind kubectl curl bash envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin"; exit 1; }
done
 
if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  exit 1
fi
 
# 重要: OPENAI_API_KEY を環境に残したまま `kagent install` すると、
# kagent が「OpenAI 本家向けデフォルト ModelConfig(baseUrl 無し)」に
# このキー(=OCI のキー)を流し込み、デモ用 Agent がそれを参照して
# api.openai.com に送信 → "Incorrect API key sk-..." の 401 になる。
# OCI に確実に向けるため、install 前に明示的に除去する。
unset OPENAI_API_KEY || true
 
docker ps >/dev/null 2>&1 || { echo "Docker daemon is not running."; exit 1; }
 
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
fi
 
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
 
if ! command -v kagent >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
fi
 
kagent install --profile demo
 
wait_for_crd "modelconfig" 180
wait_for_crd "agent" 180
 
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai \
  --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
 
OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" \
  envsubst < manifests/01-modelconfig-oci.yaml | kubectl apply -f -
 
# --- ここが今回の本質的な修正 -------------------------------------------------
# (1) baseUrl 未設定の OpenAI 系 ModelConfig(= kagent デモのデフォルト)を OCI へ向け直す。
#     Agent がデフォルトを参照していても api.openai.com に飛ばなくなる。
echo "Redirecting baseUrl-less OpenAI ModelConfigs to OCI..."
for mc in $(kubectl get modelconfig -n "${KAGENT_NAMESPACE}" -o name 2>/dev/null || true); do
  [[ "${mc}" == *"${MODEL_CONFIG_NAME}" ]] && continue
  prov="$(kubectl get "${mc}" -n "${KAGENT_NAMESPACE}" -o jsonpath='{.spec.provider}' 2>/dev/null || true)"
  base="$(kubectl get "${mc}" -n "${KAGENT_NAMESPACE}" -o jsonpath='{.spec.openAI.baseUrl}' 2>/dev/null || true)"
  if [[ "${prov}" == "OpenAI" && -z "${base}" ]]; then
    echo "  patching ${mc}"
    kubectl patch "${mc}" -n "${KAGENT_NAMESPACE}" --type merge -p "$(oci_modelconfig_patch)" || true
  fi
done
 
# (2) すべての Agent を OCI 用 ModelConfig に明示的に向ける(declarative / spec直下 両対応)。
echo "Pointing agents to ${MODEL_CONFIG_NAME}..."
for ag in $(kubectl get agent -n "${KAGENT_NAMESPACE}" -o name 2>/dev/null || true); do
  if kubectl get "${ag}" -n "${KAGENT_NAMESPACE}" -o jsonpath='{.spec.declarative}' 2>/dev/null | grep -q .; then
    kubectl patch "${ag}" -n "${KAGENT_NAMESPACE}" --type merge \
      -p "{\"spec\":{\"declarative\":{\"modelConfig\":\"${MODEL_CONFIG_NAME}\"}}}" || true
  else
    kubectl patch "${ag}" -n "${KAGENT_NAMESPACE}" --type merge \
      -p "{\"spec\":{\"modelConfig\":\"${MODEL_CONFIG_NAME}\"}}" || true
  fi
done
 
# (3) 反映のため再起動(Kind デモ用途なので namespace まとめて)。
kubectl rollout restart deployment -n "${KAGENT_NAMESPACE}" >/dev/null 2>&1 || true
# ---------------------------------------------------------------------------
 
kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true
 
echo
echo "=== ModelConfig wiring ==="
kubectl get modelconfig -n "${KAGENT_NAMESPACE}" \
  -o custom-columns=NAME:.metadata.name,PROVIDER:.spec.provider,BASEURL:.spec.openAI.baseUrl 2>/dev/null || true
echo
echo "=== Agent -> ModelConfig ==="
kubectl get agent -n "${KAGENT_NAMESPACE}" -o yaml 2>/dev/null | grep -iE "^  - |name:|modelConfig" || true
 
echo
echo "Done. Run: kagent dashboard"