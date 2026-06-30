# kagent kind デモキット（install 分離版）

このキットは、OCI GenAI の接続確認と kagent install を分離した版です。
`OCI_GENAI_API_KEY` を OpenAI のキーに流用しないことで、401 を避けやすくしています。

## 必須
- `OCI_GENAI_API_KEY` : OCI GenAI 用
- `OPENAI_API_KEY` : kagent install 用（OCI と同じ値にしない）

## 含まれるもの
- `install.md`
- `kind-config.yaml`
- `create-kind-cluster.sh`
- `delete-kind-cluster.sh`
- `manifests/`
