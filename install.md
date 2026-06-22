# OKE 上での kagent デモ環境構築手順

この手順は、Oracle Cloud Hangout Cafe 向けのデモ環境を **OKE 上に kagent を載せて動かす** ための最小構成です。  
本キットでは、以下の 3 つを分けて扱います。

- `kagent-system` : kagent 本体
- `demo-app` : 意図的に不具合を作れるデモ用ワークロード
- `observability` : Prometheus / Grafana などの監視基盤（任意）

## 前提

- OKE クラスタへ `kubectl` で接続できること
- `helm` が利用できること
- kagent の Helm chart と values が取得できること
- デモ用 namespace を作成できる権限があること

## ディレクトリ構成

```text
manifests/
  00-namespaces.yaml
  10-demo-app.yaml
  20-demo-fault-crashloop.yaml
  kustomization.yaml
```

## 手順

### 1. namespace を作成

```bash
kubectl apply -f manifests/00-namespaces.yaml
```

### 2. kagent をデプロイ

kagent の Helm chart は、実際に利用しているリポジトリ / バージョンに合わせて置き換えてください。

```bash
helm upgrade --install kagent <KAGENT_CHART_DIR> \
  -n kagent-system \
  -f <KAGENT_VALUES_FILE> \
  --wait
```

デプロイ後に確認するもの:

```bash
kubectl get pods -n kagent-system -o wide
kubectl get svc  -n kagent-system
kubectl get crd | grep -i kagent
```

### 3. デモアプリをデプロイ

```bash
kubectl apply -f manifests/10-demo-app.yaml
```

### 4. 障害系ワークロードをデプロイ（任意）

`CrashLoopBackOff` を見せたい場合のみ適用します。

```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

### 5. 動作確認

```bash
kubectl get pods -n demo-app
kubectl get pods -n observability
kubectl logs -n kagent-system deploy/<DEPLOYMENT_NAME> --tail=50
```

### 6. UI へアクセス

kagent の UI Service 名に合わせて port-forward します。

```bash
kubectl port-forward -n kagent-system svc/<KAGENT_UI_SERVICE> 8080:80
```

ブラウザから以下を開きます。

```text
http://localhost:8080
```

### 7. デモの流れ

1. `kagent-system` の Pod を確認
2. UI から Agent を作成
3. `demo-app` を調査させる
4. 必要なら `observability` の情報も確認する
5. 外部連携は補足として触れる

## デモ用の依頼例

- `demo-app namespace の Pod の状態を確認してください`
- `この Pod が不調な原因候補をまとめてください`
- `直近のイベントとログを要約してください`
- `必要なら次に見るべき箇所を提案してください`

## クリーンアップ

```bash
kubectl delete -f manifests/20-demo-fault-crashloop.yaml
kubectl delete -f manifests/10-demo-app.yaml
kubectl delete -f manifests/00-namespaces.yaml
```

## 注意

- kagent の Helm chart や values の詳細は、利用しているリポジトリ / バージョンに合わせて調整してください。
- このキットは、デモの流れを安定させるための土台です。
