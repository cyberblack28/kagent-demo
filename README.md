# kagent kind デモキット（rollback）

この版は、会話の中でうまく動いていた流れに戻したものです。

## 実行イメージ
```bash
export OCI_GENAI_API_KEY="$(printf %s '...' | tr -d '[:space:]')"
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"

curl -sS "${OCI_GENAI_BASE_URL}/chat/completions"   -H "Authorization: Bearer ${OCI_GENAI_API_KEY}"   -H "Content-Type: application/json"   -d "{"model":"${OCI_GENAI_MODEL}","messages":[{"role":"user","content":"ping"}]}"

kind get clusters

chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```

## 返却内容
- create-kind-cluster.sh
- delete-kind-cluster.sh
- install.md
- kind-config.yaml
- manifests/
