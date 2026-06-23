# kagent kind デモ環境構築手順（Ubuntu Linux）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。  
kagent の公式 quick start では、**kind / Helm / kubectl** が前提で、AI エージェントを動かすには **OpenAI API key** が必要です。インストールは `curl ... get-kagent | bash` で CLI を入れ、その後 `kagent install --profile demo` を実行する流れが案内されています。citeturn868914view0turn330075view0

構成は次の 3 つです。

- `kagent` : kagent 本体
- `demo-app` : 意図的に不具合を作れるデモ用ワークロード
- `observability` : Prometheus / Grafana などの監視基盤（任意）

---

## 0. 前提

- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続
- OpenAI API key
- デモ用 namespace を作成できる権限

---

## 1. Docker をインストールする

### 1-1. パッケージ更新

```bash
sudo apt-get update
sudo apt-get -y upgrade
```

### 1-2. 依存関係を入れる

```bash
sudo apt-get install -y ca-certificates curl gnupg
```

### 1-3. Docker の GPG キーを登録する

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

## 2. kind / kubectl / helm をインストールする

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

## 3. OpenAI API key を用意する

kagent の quick start では、AI エージェントを動かすために OpenAI API key が必要です。  
OpenAI Platform のダッシュボードで API key を作成し、環境変数に設定します。citeturn868914view0

### 3-1. API key を環境変数に設定する

```bash
export OPENAI_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxx"
```

### 3-2. 確認する

```bash
echo "$OPENAI_API_KEY"
```

---

## 4. kind クラスタを作成する

### 4-1. 実行ファイル権限を付ける

```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
```

### 4-2. kind クラスタを作成し、デモ環境まで投入する

```bash
./create-kind-cluster.sh
```

このスクリプトは、次の順で処理します。

1. kind クラスタ作成
2. `kagent` namespace 作成
3. kagent CLI の導入（未導入なら）
4. `kagent install --profile demo`
5. `demo-app` namespace のデモアプリ投入
6. `CrashLoopBackOff` のワークロード投入（任意）
7. 稼働確認

kagent の quick start では、CLI を入れたあと `kagent install --profile demo` を実行する流れが案内されています。`kagent dashboard` を使うと UI へアクセスできます。citeturn868914view0turn868914view2

---

## 5. 手動で実行したい場合

### 5-1. namespace を作成する

```bash
kubectl apply -f manifests/00-namespaces.yaml
```

### 5-2. kagent をインストールする

kagent は CLI でインストールします。  
必要なら `--profile minimal` に変更できますが、このデモでは `demo` を使います。citeturn868914view0

```bash
curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
kagent install --profile demo
```

### 5-3. デモアプリをデプロイする

```bash
kubectl apply -f manifests/10-demo-app.yaml
```

### 5-4. 障害系ワークロードをデプロイする（任意）

`CrashLoopBackOff` を見せたい場合のみ適用します。

```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

---

## 6. 動作確認

### 6-1. Pod を確認する

```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
kubectl get pods -n observability -o wide
```

### 6-2. kagent の UI を開く

kagent の quick start では、CLI の `kagent dashboard` で UI へアクセスする手順が案内されています。  
デフォルトでは `http://localhost:8082` で開きます。citeturn868914view2

```bash
kagent dashboard
```

### 6-3. ブラウザで確認する

```text
http://localhost:8082
```

---

## 7. デモの流れ

1. `kagent` の Pod を確認する
2. UI から Agent を作成する
3. `demo-app` のワークロードを調査させる
4. 必要なら `observability` の情報も確認する
5. 外部連携は補足として触れる

---

## 8. デモ用の依頼例

- `demo-app namespace の Pod の状態を確認してください`
- `この Pod が不調な原因候補をまとめてください`
- `直近のイベントとログを要約してください`
- `必要なら次に見るべき箇所を提案してください`

---

## 9. クリーンアップ

### 9-1. スクリプトで削除する

```bash
./delete-kind-cluster.sh
```

### 9-2. 手動で削除する

```bash
kubectl delete -f manifests/20-demo-fault-crashloop.yaml
kubectl delete -f manifests/10-demo-app.yaml
kubectl delete -f manifests/00-namespaces.yaml
kind delete cluster --name kagent-demo
```

---

## 10. 注意

- このキットは、デモの流れを安定させるための土台です。
