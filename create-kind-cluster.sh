#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1/}"

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

for bin in docker kind kubectl curl bash envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin"; exit 1; }
done

if [[ -z "${OCI_GENAI_API_KEY:-}" ]]; then
  echo "OCI_GENAI_API_KEY is not set."
  exit 1
fi

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
  --from-literal=PROVIDER_API_KEY="${OCI_GENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" envsubst < manifests/01-modelconfig-oci.yaml | kubectl apply -f -

kubectl apply -f manifests/10-demo-app.yaml
kubectl apply -f manifests/20-demo-fault-crashloop.yaml || true

echo "Done. Run: kagent dashboard"
