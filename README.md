# kagent kind デモキット（401回避版）

このキットは、kind 環境とデモ用ワークロードを作るためのものです。
OpenAI / OCI GenAI への API 呼び出しは行いません。

## 含まれるもの
- `install.md`
- `kind-config.yaml`
- `create-kind-cluster.sh`
- `delete-kind-cluster.sh`
- `manifests/`

## できること
- kind クラスタ作成
- demo namespace 作成
- demo-web / demo-crashloop のデプロイ
- Service selector mismatch のデモ

## しないこと
- OpenAI API 呼び出し
- OCI GenAI API 呼び出し
- kagent install
