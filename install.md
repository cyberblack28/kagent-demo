# kagent kind デモ環境構築手順

この手順だけで、Ubuntu Linux 上に **Docker / kind / kubectl / helm / kagent / デモ環境** まで構築できるようにまとめています。  
OCI Generative AI(OpenAI 互換エンドポイント) を kagent のモデルとして使い、`default-model-config` を OCI 設定で上書きする前提です。

---

## 0. 前提
- Ubuntu Linux
- `sudo` 権限
- インターネット接続
- OCI Generative AI の OpenAI-compatible API key

---

## 1. Docker をインストールする

### 1-1. パッケージ更新
```bash
sudo apt-get update
sudo apt-get -y upgrade
```

### 1-2. 必要なパッケージを入れる
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
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
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
kind version
```

### 2-2. kubectl をインストールする
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### 2-3. helm をインストールする
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## 3. OCI Generative AI の API key を設定する

### 3-1. API key を設定する
```bash
export OCI_GENAI_API_KEY="$(printf %s 'sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | tr -d '[:space:]')"
```

### 3-2. same-key フローを再現したい場合
`create-kind-cluster.sh` は `OPENAI_API_KEY` が未設定なら `OCI_GENAI_API_KEY` を使います。  
当時の流れをそのまま再現したい場合は、先に同じ値を入れておきます。

```bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
```

### 3-3. リージョン / モデル / base URL を設定する
```bash
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"
```

### 3-4. OCI GenAI の疎通確認
```bash
curl -sS "${OCI_GENAI_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${OCI_GENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{"model":"${OCI_GENAI_MODEL}","messages":[{"role":"user","content":"ping"}]}"
```

`pong` が返れば OCI GenAI 側は正常です。

---

## 4. デモキットを展開する
このリポジトリ一式を作業ディレクトリに置いた上で、実行権限を付けます。

```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
```

---

## 5. kind クラスタとデモ環境を構築する
```bash
./create-kind-cluster.sh
```

このスクリプトは次を実行します。

1. kind クラスタを作成する
2. `kagent` namespace を作成する
3. `kagent install --profile demo` を実行する
4. `default-model-config` を OCI 設定で上書きする
5. 既存の Agent を OCI 用 ModelConfig に向け直す
6. `demo-app` のワークロードを投入する
7. CrashLoop デモを投入する

---

## 6. 動作確認

### 6-1. Pod を確認する
```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
```

### 6-2. ModelConfig を確認する
```bash
kubectl -n kagent get modelconfig default-model-config -o yaml | grep -A3 openAI
kubectl -n kagent get modelconfig oci-genai-openai-compatible -o yaml | grep -A3 openAI
```

### 6-3. UI を開く
```bash
kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```

ブラウザで次を開きます。

```text
http://localhost:8080
```

---

## 7. デモの流れ
1. OCI GenAI の `ping -> pong` を確認する
2. `./create-kind-cluster.sh` を実行する
3. `default-model-config` が OCI を向いていることを確認する
4. `demo-crashloop` の調査を行う
5. 必要に応じて `demo-web` の Service selector mismatch を見せる

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
