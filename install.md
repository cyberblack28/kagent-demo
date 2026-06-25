# kagent kind デモ環境構築手順（Ubuntu Linux / OCI GenAI OpenAI-compatible 版）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。  
kagent のセットアップ時には `OPENAI_API_KEY` の設定を要求されるため、**OCI Generative AI の OpenAI-compatible API key を `OPENAI_API_KEY` として渡す** 形にします。kagent は BYO OpenAI-compatible model をサポートしており、`ModelConfig` で `provider: OpenAI`、`baseUrl`、API key Secret を設定できます。今回はモデルを **`openai.gpt-oss-120b`** に固定します。citeturn487179view0turn120376view0

---

## 0. 前提
- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続
- OCI Generative AI の OpenAI-compatible API key
- デモ用 namespace を作成できる権限

---

## 1. Docker をインストールする
（省略可。以前の版と同様）

---

## 2. kind / kubectl / helm をインストールする
（省略可。以前の版と同様）

---

## 3. OCI Generative AI の API key を用意する

### 3-1. API key を環境変数に設定する
```bash
export OCI_GENAI_API_KEY="sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### 3-2. kagent が要求する環境変数にマッピングする
kagent のセットアップで `OPENAI_API_KEY` を要求するため、**同じ値を `OPENAI_API_KEY` にも入れます**。

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
kubectl -n kagent create secret generic kagent-oci-genai   --from-literal=PROVIDER_API_KEY="${OCI_GENAI_API_KEY}"

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

---

## 8. クリーンアップ
```bash
./delete-kind-cluster.sh
```

または手動で:
```bash
kubectl delete -f manifests/20-demo-fault-crashloop.yaml
kubectl delete -f manifests/10-demo-app.yaml
kubectl delete -f manifests/01-modelconfig-oci.yaml
kubectl delete -f manifests/00-namespaces.yaml
kind delete cluster --name kagent-demo
```
