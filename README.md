# kagent kind デモキット v5

このキットは、Ubuntu Linux 上で `kind` を使って kagent を試すためのひな形です。  
デモの準備・リハーサル用途を想定しており、当日の本番デモは OKE を推奨します。

## 含まれるもの

- `install.md` : Docker / kind / kagent デモ環境の全手順
- `kind-config.yaml` : 3 ノード kind クラスタ定義
- `create-kind-cluster.sh` : クラスタ作成とデモ環境投入
- `delete-kind-cluster.sh` : クラスタ削除
- `manifests/` : デモ用 namespace / アプリ / 障害ワークロード
- `kagent-values-kind.yaml` : デモ用 values のたたき台

## 前提

- Ubuntu Linux
- Docker
- kind
- kubectl
- helm

## 使い方

```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
```

## 重要な置き換え項目

スクリプト内の次の値は、実際の kagent リポジトリ / chart / values に合わせて置き換えてください。

- `KAGENT_CHART_DIR`
- `KAGENT_VALUES_FILE`
- `KAGENT_UI_SERVICE`
- `KAGENT_NAMESPACE`

## デモの考え方

- まず `kagent-system` の Pod が kind 上で動いていることを確認
- 次に `demo-app` namespace のワークロードを調査
- 必要なら `CrashLoopBackOff` を仕込んで再現
- 監視基盤は必要最低限にし、リハーサルを安定させる

## クリーンアップ

```bash
./delete-kind-cluster.sh
```
