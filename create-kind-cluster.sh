#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-demo}"
KAGENT_NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-app}"
OCI_GENAI_REGION="${OCI_GENAI_REGION:-us-chicago-1}"
OCI_GENAI_MODEL="${OCI_GENAI_MODEL:-openai.gpt-oss-120b}"
KAGENT_PROFILE="${KAGENT_PROFILE:-demo}"
OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL:-https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1}"

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

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is not set."
  echo "export OPENAI_API_KEY='sk-...'"
  exit 1
fi

docker ps >/dev/null 2>&1 || { echo "Docker daemon is not running."; exit 1; }

echo "[1/8] Create kind cluster"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
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

echo "[4/8] Install kagent"
kagent install --profile "${KAGENT_PROFILE}"

echo "[5/8] Wait for CRDs"
wait_for_crd "modelconfig" 300
wait_for_crd "agent" 300

echo "[6/8] Create OCI GenAI secret and ModelConfig"
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

echo "[7/8] Deploy demo apps"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-web
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-web
  template:
    metadata:
      labels:
        app: demo-web
    spec:
      containers:
        - name: web
          image: nginx:1.27
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: demo-web
  namespace: demo-app
spec:
  selector:
    app: demo-web
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-crashloop
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-crashloop
  template:
    metadata:
      labels:
        app: demo-crashloop
    spec:
      containers:
        - name: crash
          image: busybox:1.36
          command: ["sh", "-c", "echo 'intentional crash for demo'; exit 1"]
EOF

echo "[8/8] Optional Service mismatch demo manifests"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: demo-web
  namespace: demo-app
spec:
  selector:
    app: demo-web-mismatch
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
EOF

cat <<EOF

Done.

Verify:
  kubectl get pods -n ${KAGENT_NAMESPACE}
  kubectl get pods -n ${DEMO_NAMESPACE}
  kubectl get modelconfig -n ${KAGENT_NAMESPACE}
  kagent dashboard

To restore Service selector:
  kubectl apply -f manifests/31-demo-service-restore.yaml
EOF
