#!/usr/bin/env bash
# kagent 導入済みクラスタに対して、エージェントを OCI GenAI(OpenAI 互換)へ向け直す。
# 環境構築(kind / kagent install)には手を出さない。元の create-kind-cluster.sh で
# 環境を作った後にこれを実行する想定。
set -euo pipefail
 
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
# 末尾スラッシュなし(/chat/completions 連結時の // 事故防止)
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"
MODEL_CONFIG_NAME="${MODEL_CONFIG_NAME:-oci-genai-openai-compatible}"
 
[[ -n "${OCI_GENAI_API_KEY:-}" ]] || { echo "OCI_GENAI_API_KEY is not set."; exit 1; }
 
# 前提チェック: kagent の CRD が存在すること
kubectl get crd 2>/dev/null | grep -qi modelconfig || {
  echo "ModelConfig CRD が見つかりません。先に環境構築スクリプトで kagent を導入してください。"
  exit 1
}
 
oci_modelconfig_patch() {
  cat <<JSON
{"spec":{"provider":"OpenAI","model":"${OCI_GENAI_MODEL}","apiKeySecret":"kagent-oci-genai","apiKeySecretKey":"OCI_GENAI_API_KEY","openAI":{"baseUrl":"${OCI_GENAI_BASE_URL}"}}}
JSON
}
 
# 1) Secret(キーは前後空白・改行を除去して格納)
CLEAN_KEY="$(printf %s "${OCI_GENAI_API_KEY}" | tr -d '[:space:]')"
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai \
  --from-literal=OCI_GENAI_API_KEY="${CLEAN_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
 
# 2) OCI 用 ModelConfig(インライン適用)
cat <<YAML | kubectl apply -f -
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: ${MODEL_CONFIG_NAME}
  namespace: ${KAGENT_NAMESPACE}
spec:
  provider: OpenAI
  model: ${OCI_GENAI_MODEL}
  apiKeySecret: kagent-oci-genai
  apiKeySecretKey: OCI_GENAI_API_KEY
  openAI:
    baseUrl: "${OCI_GENAI_BASE_URL}"
YAML
 
# 3) baseUrl 未設定の OpenAI 系 ModelConfig(=デモのデフォルト)を OCI へ向け直す
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
 
# 4) すべての Agent を OCI 用 ModelConfig に向ける(declarative / spec直下 両対応)
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
 
# 5) 反映のため再起動
kubectl rollout restart deployment -n "${KAGENT_NAMESPACE}" >/dev/null 2>&1 || true
 
echo
echo "=== ModelConfig wiring ==="
kubectl get modelconfig -n "${KAGENT_NAMESPACE}" \
  -o custom-columns=NAME:.metadata.name,PROVIDER:.spec.provider,BASEURL:.spec.openAI.baseUrl 2>/dev/null || true
echo
echo "=== Agent -> ModelConfig ==="
kubectl get agent -n "${KAGENT_NAMESPACE}" -o yaml 2>/dev/null | grep -iE "name:|modelConfig" || true
 
echo
echo "Done. Run: kagent dashboard"