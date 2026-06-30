# kagent kind デモ環境構築手順（Ubuntu Linux / OCI GenAI OpenAI-compatible 版）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。
この版では、OCI GenAI 用のキーと kagent install 用の OpenAI キーを分けて扱います。

## 重要
- `OCI_GENAI_API_KEY` は OCI Generative AI の OpenAI-compatible API key
- `OPENAI_API_KEY` は kagent install 用の OpenAI キー
- 2つを同じ値にしない

---

## 0. 前提
- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続
- OCI Generative AI の OpenAI-compatible API key
- kagent install 用の OpenAI API key
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
echo       "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu       $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" |       sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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

## 3. 環境変数を設定する
```bash
export OCI_GENAI_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export OPENAI_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
```

---

## 4. kind クラスタを作成する
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
```

このスクリプトは、次の順で処理します。

1. kind クラスタ作成
2. namespace 作成
3. kagent CLI の導入（未導入なら）
4. kagent install
5. CRD が立つまで待機
6. OCI GenAI 用 Secret と ModelConfig 作成
7. demo アプリ投入
8. Service mismatch のデモ投入

---

## 5. 動作確認
```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
kubectl get modelconfig -n kagent
kagent dashboard
```

---

## 6. Service / Pod ずれのデモを元に戻す
```bash
kubectl apply -f manifests/31-demo-service-restore.yaml
```

---

## 7. クリーンアップ
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
