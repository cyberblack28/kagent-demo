# kagent デモキット

このキットは、OKE 上で kagent を紹介するデモを組み立てるための補助ファイルです。

## 含まれるもの

- `install.md`
- `manifests/00-namespaces.yaml`
- `manifests/10-demo-app.yaml`
- `manifests/20-demo-fault-crashloop.yaml`
- `manifests/kustomization.yaml`

## 使い方

1. `install.md` に沿って namespace を作成
2. kagent を Helm でデプロイ
3. `demo-app` を適用
4. 必要なら `demo-crashloop` を適用
5. UI から Agent を作ってデモを実行

## 想定

- `kagent-system` : kagent 本体
- `demo-app` : 調査対象
- `observability` : 監視基盤（任意）

## 変更ポイント

- `install.md` の Helm chart パス
- `install.md` の UI Service 名
- 必要なら namespace 名

## 補足

この構成は、デモを安定させるために **「読むだけの対象」** と **「壊せる対象」** を分けています。
