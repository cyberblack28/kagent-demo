# kagent kind デモ環境構築手順（Ubuntu Linux / OCI GenAI OpenAI-compatible 版）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。
kagent のセットアップ時には `OPENAI_API_KEY` の設定を要求されるため、**OCI Generative AI の OpenAI-compatible API key を `OPENAI_API_KEY` として渡す** 形にします。ModelConfig 側は OCI GenAI 用に、`kagent-oci-genai` Secret と `openai.gpt-oss-120b`、そして OCI の OpenAI-compatible `baseUrl` を明示します。

---

## 0. 前提
- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続
- OCI Generative AI の OpenAI-compatible API key
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

### 1-7. 動作確認
```bash
docker version
docker ps
```

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

---

## 3. OCI Generative AI の API key を用意する

### 3-1. API key を環境変数に設定する
```bash
export OCI_GENAI_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### 3-2. kagent が要求する名前にマッピングする
```bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
```

### 3-3. 使うリージョンとモデルを固定する
- リージョン: `us-chicago-1`
- モデル: `openai.gpt-oss-120b`

```bash
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
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
5. kagent の CRD が立つまで待機
6. OCI Generative AI 用の `ModelConfig` と Secret を作成
7. `demo-app` namespace のデモアプリ投入
8. `CrashLoopBackOff` のワークロード投入（任意）
9. 稼働確認

---

## 5. 手動で実行したい場合

### 5-1. namespace を作成する
```bash
kubectl apply -f manifests/00-namespaces.yaml
```

### 5-2. kagent をインストールする
```bash
curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
kagent install --profile demo
```

### 5-3. kagent の CRD が立つまで待つ
```bash
kubectl get crd | grep -i kagent
kubectl get crd | grep -i modelconfig
```

### 5-4. OCI Generative AI 用の Secret と ModelConfig を作成する
```bash
kubectl -n kagent create secret generic kagent-oci-genai   --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}"

envsubst < manifests/01-modelconfig-oci.yaml | kubectl apply -f -
```

### 5-5. デモアプリをデプロイする
```bash
kubectl apply -f manifests/10-demo-app.yaml
```

### 5-6. 障害系ワークロードをデプロイする（任意）
```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

### 5-7. Service / Pod ずれのデモを行う（任意）
```bash
kubectl apply -f manifests/30-demo-service-mismatch.yaml
kubectl get endpoints -n demo-app demo-web
```

元に戻すには:

```bash
kubectl apply -f manifests/31-demo-service-restore.yaml
```

---

## 6. 動作確認

### 6-1. Pod を確認する
```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
```

### 6-2. kagent の UI を開く
```bash
kagent dashboard
```

---

## 7. デモの流れ
1. `kagent` の Pod を確認する
2. UI から Agent を作成する
3. OCI Generative AI の ModelConfig を選択する
4. `demo-app` のワークロードを調査させる
5. 必要に応じて Service / Pod の不整合も見せる

---

## 8. クリーンアップ
```bash
./delete-kind-cluster.sh
```

または手動で:
```bash
kubectl delete -f manifests/31-demo-service-restore.yaml
kubectl delete -f manifests/30-demo-service-mismatch.yaml
kubectl delete -f manifests/20-demo-fault-crashloop.yaml
kubectl delete -f manifests/10-demo-app.yaml
kubectl delete -f manifests/01-modelconfig-oci.yaml
kubectl delete -f manifests/00-namespaces.yaml
kind delete cluster --name kagent-demo
```

---

## 9. 注意
- このキットは、デモの流れを安定させるための土台です。
