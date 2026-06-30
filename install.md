# kagent kind デモ環境構築手順（rollback 版）

この版は、会話の中で使っていた流れに合わせて戻したものです。

## 前提
- Ubuntu Linux
- kind / kubectl / docker / helm
- `OCI_GENAI_API_KEY` と `OPENAI_API_KEY` を同じ値で設定する前提
- `OCI_GENAI_REGION=us-chicago-1`
- `OCI_GENAI_MODEL=openai.gpt-oss-120b`

## 実行順
1. `export OCI_GENAI_API_KEY="..."`
2. `export OPENAI_API_KEY="$OCI_GENAI_API_KEY"`
3. `export OCI_GENAI_REGION="us-chicago-1"`
4. `export OCI_GENAI_MODEL="openai.gpt-oss-120b"`
5. `export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"`
6. `curl -sS "${OCI_GENAI_BASE_URL}/chat/completions" ...`
7. `chmod +x create-kind-cluster.sh delete-kind-cluster.sh`
8. `./create-kind-cluster.sh`
9. `kubectl port-forward -n kagent svc/kagent-ui 8080:8080`

## 重要
- この版では `OCI_GENAI_API_KEY` を `OPENAI_API_KEY` に流し込みます。
- そのため、以前うまくいっていた流れの再現を優先しています。
