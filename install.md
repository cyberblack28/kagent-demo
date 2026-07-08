# kagent デモ環境構築手順

この手順で、**kind(ローカル検証)** と **OKE(本番デモ)** のどちらにも
kagent とデモ環境を構築できます。
どちらも **Helm ベースで同一バージョン**の kagent を入れ、
OCI Generative AI(OpenAI 互換エンドポイント)をモデルとして使い、
`default-model-config` を OCI 設定で上書きする前提です。

- **パターン A: kind** … ローカル 1 台で完結。事前検証・リハーサル向け
  → 構築スクリプト `create-kind-cluster.sh` / 破棄 `delete-kind-cluster.sh`
- **パターン B: OKE** … 既存の OKE クラスタ上に構築。本番デモ向け
  → 構築スクリプト `create-oke-cluster.sh` / 破棄 `delete-oke-cluster.sh`

> kind 版と OKE 版は同じ Helm チャート・同じマニフェスト・同じ ModelConfig を
> 使うため、ローカルで検証した内容がそのまま OKE でも再現できます。

---

## 0. 前提

### 共通で必要なもの
- `kubectl` / `helm` / `curl` / `bash` / `envsubst`
- インターネット接続
- OCI Generative AI の OpenAI-compatible API key

### パターン A(kind)で追加で必要なもの
- Ubuntu Linux + `sudo` 権限
- Docker / kind

### パターン B(OKE)で追加で必要なもの
- 構築済みの OKE クラスタ(ワーカーノードが Ready)
- 対象クラスタに接続できる kubeconfig / current-context
  (`oci ce cluster create-kubeconfig ...` 済み)

---

## 1. 共通ツールをインストールする(kubectl / helm)

> kind パターンで Docker / kind も必要な場合は、先に「付録 A. Docker と kind の
> インストール」を実施してください。OKE パターンでは Docker / kind は不要です。

### 1-1. kubectl をインストールする
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### 1-2. helm をインストールする
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 1-3. envsubst を確認する
`envsubst` は多くの環境で `gettext-base` パッケージに含まれます。
```bash
command -v envsubst || sudo apt-get install -y gettext-base
```

---

## 2. OCI Generative AI の API key を設定する(共通)

### 2-1. API key を設定する
```bash
export OCI_GENAI_API_KEY="$(printf %s 'sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | tr -d '[:space:]')"
```

### 2-2. ブートストラップ用の OpenAI キーを設定する
kagent の初回インストールは provider=openAI で立ち上げます。
`create-*-cluster.sh` は `OPENAI_PROVIDER_API_KEY` → `OPENAI_API_KEY` →
`OCI_GENAI_API_KEY` の順にキーを探すため、OCI キーを流用する場合は次を実行します。

```bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
```

### 2-3. リージョン / モデル / base URL を設定する
```bash
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"
```

### 2-4. OCI GenAI の疎通確認
```bash
curl -sS "${OCI_GENAI_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${OCI_GENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${OCI_GENAI_MODEL}"'","messages":[{"role":"user","content":"ping"}]}'
```

応答が返れば OCI GenAI 側は正常です。

---

## 3A. パターン A:kind で構築する

### 3A-1. 前提
- 「付録 A. Docker と kind のインストール」まで完了していること
- Docker デーモンが起動していること(`docker ps` が通る)

### 3A-2. スクリプトに実行権限を付ける
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
```

### 3A-3. 構築する
```bash
./create-kind-cluster.sh
```

このスクリプトは次を実行します。

1. kind クラスタを作成する(`kind-config.yaml`)
2. `kagent` / `demo-app` namespace を作成する
3. Helm で kagent CRDs をインストールする
4. Helm で kagent 本体をインストールする
   (`registry=ghcr.io` / `grafana-mcp.enabled=false` / provider=openAI)
5. CRD が Established になるまで待つ
6. OCI GenAI の Secret と ModelConfig を作成する
   (`default-model-config` を OCI 設定で上書き)
7. 既存 Agent を OCI 用 ModelConfig に向け直し、Deployment を再起動する
8. デモワークロード(healthy baseline + CrashLoop)を投入する

→ 続きは「4. 動作確認」へ。

---

## 3B. パターン B:OKE で構築する

### 3B-1. 前提
- OKE クラスタのワーカーノードが `Ready`
- 対象クラスタの kubeconfig が current-context に設定済み

```bash
kubectl config current-context
kubectl get nodes
```

`Ready` なノードが 1 つも無い場合、スクリプトは先に失敗します。
ノードプールの状態を先に確認してください。

### 3B-2. スクリプトに実行権限を付ける
```bash
chmod +x create-oke-cluster.sh delete-oke-cluster.sh
```

### 3B-3. UI の公開方式を選ぶ
kagent UI は **認証がありません**。OKE では公開方式を 2 通りから選べます。

- **ClusterIP(既定・推奨)**:外部公開せず `port-forward` で使う
  ```bash
  ./create-oke-cluster.sh
  ```
- **LoadBalancer**:OCI Load Balancer で公開する。無認証のため、接続元 CIDR を
  必ず `UI_LB_ALLOWED_CIDR` で絞ること。
  ```bash
  KAGENT_UI_SERVICE_TYPE=LoadBalancer \
  UI_LB_ALLOWED_CIDR="203.0.113.10/32" \
    ./create-oke-cluster.sh
  ```

このスクリプトは次を実行します。

1. `kagent` / `demo-app` namespace を作成する
2. Helm で kagent CRDs をインストールする
3. Helm で kagent 本体をインストールする
   (`registry=ghcr.io` / `grafana-mcp.enabled=false` / provider=openAI /
   UI Service タイプ)
4. CRD が Established になるまで待つ
5. OCI GenAI の Secret と ModelConfig を作成する
   (`default-model-config` を OCI 設定で上書き)
6. 既存 Agent を OCI 用 ModelConfig に向け直し、Deployment を再起動する
7. デモワークロード(healthy baseline + CrashLoop)を投入する
8. 確認コマンドを表示する

### 3B-4. OKE 固有の注意
- **registry=ghcr.io**:チャート既定の `cr.kagent.dev` が
  "repository name not known" を返すことがあるため、イメージ実体のある
  ghcr.io を直接向ける。
- **grafana-mcp を無効化**:`mcp/grafana:latest` はレジストリ名なしの短縮名で、
  OKE(Oracle Linux)ノードは short-name 解決を enforcing にしているため
  ErrImagePull になる。今回のデモでは Grafana を使わないため無効化する。
- **課金リソースの後始末**:UI を LoadBalancer にした場合の OCI LB、および
  PostgreSQL の PVC(Block Volume)は消し忘れると課金が続く。破棄は必ず
  `delete-oke-cluster.sh` を使う(helm uninstall → namespace 削除の順で安全に消える)。

→ 続きは「4. 動作確認」へ。

---

## 4. 動作確認(共通)

### 4-1. Pod を確認する
```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
```

### 4-2. ModelConfig を確認する
```bash
kubectl -n kagent get modelconfig
kubectl -n kagent get modelconfig default-model-config -o yaml | grep -A3 openAI
kubectl -n kagent get modelconfig oci-genai-openai-compatible -o yaml | grep -A3 openAI
```

`default-model-config` の baseUrl が OCI を向いていれば成功です。

---

## 5. UI を開く

### kind / OKE(ClusterIP)の場合
```bash
kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```
ブラウザで `http://localhost:8080` を開きます。

### OKE(LoadBalancer)の場合
EXTERNAL-IP が付与されるまで数分待ちます。
```bash
kubectl get svc -n kagent kagent-ui -w
# → http://<EXTERNAL-IP>:8080 にアクセス
```

---

## 6. デモの流れ

詳細な台本は `demo.md` を参照してください。概要は次の 4 本です。

1. **デモ1**: CrashLoopBackOff の原因調査と修復
2. **デモ2**: ImagePullBackOff の原因調査と修復
3. **デモ3**: Service と Pod のつながり確認(複数リソースをまたいだ推論)
4. **デモ4**: 自作エージェントを UI から作る(運用の標準化)

障害の注入(デモ2/3)は、デモ中にその場で `kubectl apply` します。
`create-*-cluster.sh` の実行時点では、healthy baseline と CrashLoop のみ投入済みです。

---

## 7. クリーンアップ

### パターン A(kind)
```bash
./delete-kind-cluster.sh
```

### パターン B(OKE)
```bash
./delete-oke-cluster.sh
```

OKE 版は、孤児化した OCI Load Balancer / Block Volume による課金を防ぐため、
**CR 削除 → helm uninstall(Service/LB もここで消える)→ namespace 削除**の
順で処理し、最後に残存 PVC / LoadBalancer をチェックします。

---

## 付録 A. Docker と kind のインストール(kind パターンのみ)

### A-1. パッケージ更新
```bash
sudo apt-get update
sudo apt-get -y upgrade
```

### A-2. 必要なパッケージを入れる
```bash
sudo apt-get install -y ca-certificates curl gnupg
```

### A-3. Docker の公式 GPG キーを登録する
```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

### A-4. Docker リポジトリを追加する
```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### A-5. Docker Engine をインストールする
```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### A-6. Docker を起動する
```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

### A-7. Docker グループ権限を設定する
`docker ps` で permission denied が出る場合は、ユーザーを `docker` グループに
追加して再ログインします。
```bash
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

### A-8. kind をインストールする
```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
```
