# kagent kind デモキット

Ubuntu Linux 上で `kind` を使って kagent のデモ環境を構築するためのキットです。
OCI Generative AI の OpenAI-compatible API を使う前提にしています。

## 構成
- control-plane x1
- worker x3

## 含まれるもの
- `install.md`
- `kind-config.yaml`
- `create-kind-cluster.sh`
- `delete-kind-cluster.sh`
- `manifests/`
- `kagent-values-kind.yaml`

## 使い方
1. `OCI_GENAI_API_KEY` を設定する
2. `OPENAI_API_KEY` を別途用意する
3. `./create-kind-cluster.sh` を実行する
