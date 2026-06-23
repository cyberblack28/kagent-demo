# kagent kind デモ環境構築手順（Ubuntu Linux）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。  
構成は次の 3 つです。

- `kagent-system` : kagent 本体
- `demo-app` : 意図的に不具合を作れるデモ用ワークロード
- `observability` : Prometheus / Grafana などの監視基盤（任意）

---

## 0. 前提

- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続
- デモ用 namespace を作成できる権限

---

## 1. Docker のインストール

### 1-1. パッケージ更新

```bash
sudo apt-get update
sudo apt-get -y upgrade
```

### 1-2. Docker の依存関係を入れる

```bash
sudo apt-get install -y ca-certificates curl gnupg
```

### 1-3. Docker の公式 GPG キーを登録する

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

### 1-4. Docker リポジトリを追加する

```bash
echo   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu   $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" |   sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 1-5. Docker Engine をインストールする

```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 1-6. Docker を起動する

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

### 1-7. sudo なしで docker を使う（任意）

```bash
sudo usermod -aG docker $USER
newgrp docker
```

再ログインが必要な場合があります。

### 1-8. 動作確認

```bash
docker version
docker ps
docker info
```

`docker ps` が成功すれば、Docker のセットアップは完了です。

---

## 2. kind / kubectl / helm のインストール

### 2-1. kind をインストールする

```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

### 2-2. kubectl をインストールする

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### 2-3. helm をインストールする

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 2-4. バージョン確認

```bash
kind version
kubectl version --client
helm version
```

---

## 3. kind クラスタを作成する

### 3-1. ディレクトリを確認する

この手順は、以下のファイルを前提にしています。

```text
kind-config.yaml
create-kind-cluster.sh
delete-kind-cluster.sh
manifests/
kagent-values-kind.yaml
```

### 3-2. kind クラスタを作成する

```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
```

スクリプトの中では次を実行します。

- kind クラスタ作成
- namespace 作成
- kagent デプロイ
- demo-app デプロイ
- CrashLoopBackOff のワークロード適用（任意）

### 3-3. 手動でクラスタだけ作る場合

```bash
kind create cluster --name kagent-demo --config kind-config.yaml
```

---

## 4. デモ環境を構築する

### 4-1. namespace を作成する

```bash
kubectl apply -f manifests/00-namespaces.yaml
```

### 4-2. kagent をデプロイする

kagent の Helm chart は、実際に利用しているリポジトリ / バージョンに合わせて置き換えてください。

```bash
helm upgrade --install kagent <KAGENT_CHART_DIR>   -n kagent-system   -f <KAGENT_VALUES_FILE>   --wait
```

### 4-3. デモアプリをデプロイする

```bash
kubectl apply -f manifests/10-demo-app.yaml
```

### 4-4. 障害系ワークロードをデプロイする（任意）

`CrashLoopBackOff` を見せたい場合のみ適用します。

```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

### 4-5. 動作確認

```bash
kubectl get pods -n kagent-system -o wide
kubectl get pods -n demo-app -o wide
kubectl get pods -n observability -o wide
```

---

## 5. UI へアクセスする

kagent の UI Service 名に合わせて port-forward します。

```bash
kubectl port-forward -n kagent-system svc/<KAGENT_UI_SERVICE> 8080:80
```

ブラウザから以下を開きます。

```text
http://localhost:8080
```

---

## 6. デモの流れ

1. `kagent-system` の Pod を確認する
2. UI から Agent を作成する
3. `demo-app` のワークロードを調査させる
4. 必要なら `observability` の情報も確認する
5. 外部連携は補足として触れる

---

## 7. デモ用の依頼例

- `demo-app namespace の Pod の状態を確認してください`
- `この Pod が不調な原因候補をまとめてください`
- `直近のイベントとログを要約してください`
- `必要なら次に見るべき箇所を提案してください`

---

## 8. クリーンアップ

### 8-1. スクリプトで削除する

```bash
./delete-kind-cluster.sh
```

### 8-2. 手動で削除する

```bash
kubectl delete -f manifests/20-demo-fault-crashloop.yaml
kubectl delete -f manifests/10-demo-app.yaml
kubectl delete -f manifests/00-namespaces.yaml
kind delete cluster --name kagent-demo
```

---

## 9. 注意

- kagent の Helm chart や values の詳細は、利用しているリポジトリ / バージョンに合わせて調整してください。
- このキットは、デモの流れを安定させるための土台です。
