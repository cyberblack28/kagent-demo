# kagent kind デモキット v7

Ubuntu Linux 上で `kind` を使って kagent のデモ環境を構築するためのキットです。  
本番デモは OKE を推奨します。

## kind 構成
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
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
export OPENAI_API_KEY="sk-..."
./create-kind-cluster.sh
```
