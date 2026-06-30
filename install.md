# kagent kind デモ環境構築手順（復元版）

この版は、うまくいっていた当時の same-key フローに戻しています。

## 実行順
```bash
export OCI_GENAI_API_KEY="$(printf %s 'sk-...' | tr -d '[:space:]')"
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"

curl -sS "${OCI_GENAI_BASE_URL}/chat/completions"       -H "Authorization: Bearer ${OCI_GENAI_API_KEY}"       -H "Content-Type: application/json"       -d "{"model":"${OCI_GENAI_MODEL}","messages":[{"role":"user","content":"ping"}]}"

kind get clusters

chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```

## ポイント
- `OCI_GENAI_API_KEY` と `OPENAI_API_KEY` は同じ値
- OCI GenAI の `ping -> pong` 確認を先に行う
- その後に kind / kagent の流れへ進む
