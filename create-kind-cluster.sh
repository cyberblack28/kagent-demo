#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"
KAGENT_PROFILE="${KAGENT_PROFILE:-demo}"

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

for bin in docker kind kubectl curl bash envsubst; do
  need_bin "$bin"
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  exit 1
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set."
  echo "kagent install requires a valid OpenAI key."
  exit 1
fi
if [[ "${OPENAI_API_KEY}" == "${OCI_GENAI_API_KEY}" ]]; then
  echo "OPENAI_API_KEY and OCI_GENAI_API_KEY must be different."
  echo "Using the OCI key for kagent install is what causes 401."
  exit 1
fi

docker ps >/dev/null 2>&1 || { echo "Docker daemon is not running."; exit 1; }

echo "[1/8] Create kind cluster"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
fi

echo "[2/8] Create namespaces"
kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${DEMO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "[3/8] Install kagent CLI if needed"
if ! command -v kagent >/dev/null 2>&1; then
  curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
fi

echo "[4/8] Install kagent"
kagent install --profile "${KAGENT_PROFILE}"

echo "[5/8] Create OCI GenAI secret and ModelConfig"
kubectl -n "${KAGENT_NAMESPACE}" create secret generic kagent-oci-genai   --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}"   --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" envsubst | kubectl apply -f -
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: oci-genai-openai-compatible
  namespace: ${KAGENT_NAMESPACE}
spec:
  provider: OpenAI
  model: ${OCI_GENAI_MODEL}
  apiKeySecret: kagent-oci-genai
  apiKeySecretKey: OCI_GENAI_API_KEY
  openAI:
    baseUrl: "${OCI_GENAI_BASE_URL}"
EOF

echo "[6/8] Apply demo workloads"
kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true

echo "[7/8] Apply service mismatch demo"
kubectl apply -f manifests/30-demo-service-mismatch.yaml || true

echo "[8/8] Done"
cat <<EOF

Verify:
  kubectl get pods -n ${KAGENT_NAMESPACE}
  kubectl get pods -n ${DEMO_NAMESPACE}
  kubectl get modelconfig -n ${KAGENT_NAMESPACE}
  kagent dashboard

EOF
