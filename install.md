# kagent kind デモ環境構築手順（Ubuntu Linux / OCI GenAI OpenAI-compatible 版）

この手順は、Ubuntu Linux 上で `kind` を使い、kagent のデモ環境を構築するためのものです。
kagent のセットアップ時には `OPENAI_API_KEY` の設定を要求されるため、**OCI Generative AI の OpenAI-compatible API key を `OPENAI_API_KEY` として渡して install を完走させ**、その後 ModelConfig / Agent を OCI 側へ向け直します。ModelConfig 側は `kagent-oci-genai` Secret、`openai.gpt-oss-120b`、OCI の OpenAI-compatible `baseUrl` を明示します。

> **重要（今回の 401 の要点）**
> `kagent install --profile demo` は、`OPENAI_API_KEY` を拾って **OpenAI 本家向けのデフォルト ModelConfig（baseUrl 無し）** を作り、サンプル Agent はそれを参照します。ここに OCI のキーが入ると「OCI キーを `api.openai.com` に送信」となり `Incorrect API key sk-...` の 401 になります。
> 対策は、install 後に **(a) デフォルト ModelConfig の baseUrl を OCI に向け直す**、**(b) 全 Agent を OCI 用 ModelConfig に向け直す** ことです。本手順とスクリプトはこれを行います。

---

## 0. 前提
- Ubuntu Linux
- 管理者権限（`sudo`）
- インターネット接続（`ghcr.io` / `raw.githubusercontent.com` への到達が必要）
- OCI Generative AI の OpenAI-compatible API key（`sk-` で始まる GenAI 専用キー）
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
sudo apt-get install -y ca-certificates curl gnupg gettext-base
```
> `gettext-base` は `envsubst` を含みます（ModelConfig のテンプレート展開に使用）。

### 1-3. Docker の GPG キーを登録する
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
> `docker ps` が権限エラーになる場合は `sudo usermod -aG docker $USER` 後に再ログイン、または各 docker コマンドを `sudo` で実行してください。

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

### 3-1. API key を環境変数に設定する（前後の空白・改行を除去）
```bash
export OCI_GENAI_API_KEY="$(printf %s 'sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' | tr -d '[:space:]')"
```
> キーをコピペすると末尾に改行が混入しやすく、`Authorization: Bearer sk-...\n` となって **ルーティングが正しくても 401** になります。上記のように空白・改行を除去して格納してください。

### 3-2. kagent install 用に `OPENAI_API_KEY` へマッピングする
```bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"
```
> これは **`kagent install` を完走させるため**のものです。install 後に Agent / ModelConfig を OCI 側へ向け直すので、デフォルトに一時的に入るこの値は上書きされます。

### 3-3. 使うリージョン・モデル・baseUrl を固定する
- リージョン: `us-chicago-1`
- モデル: `openai.gpt-oss-120b`
- baseUrl: OCI OpenAI-compatible エンドポイント（**末尾スラッシュなし**）

```bash
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"
```
> 末尾スラッシュを付けると、OpenAI SDK が `/chat/completions` を連結する際に `//chat/completions` となり 404/401 を誘発することがあります。

### 3-4. （任意・推奨）キー単体の疎通確認
kagent を介さず、キーとエンドポイントが生きているかを先に確認しておくと切り分けが楽です。
```bash
curl -sS "${OCI_GENAI_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${OCI_GENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${OCI_GENAI_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
```
正常応答が返れば、キー・URL・リージョン・モデルの組み合わせは問題ありません。

---

## 4. kind クラスタを作成する（自動）

### 4-1. （再実行時）まずクリーンにする
過去に install が途中で失敗していると、kagent の helm リリースが中途状態で残り、再実行時の `kagent install` が CRD を入れ直さず **「CRD 待ちタイムアウト」** になります。再構築時は先にクラスタを削除してください。
```bash
kind get clusters
kind delete cluster --name kagent-demo   # 既存があれば削除（クリーンな1回目の条件に戻す）
```

### 4-2. 実行ファイル権限を付ける
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
```

### 4-3. kind クラスタを作成し、デモ環境まで投入する
```bash
./create-kind-cluster.sh
```

このスクリプトは、次の順で処理します。

1. kind クラスタ作成（既存なら再利用 ※不安定時は 4-1 で削除）
2. `kagent` / `demo-app` namespace 作成
3. kagent CLI の導入（未導入なら）
4. `OPENAI_API_KEY` を持たせて `kagent install --profile demo`（CRD・コントローラ・サンプル Agent 導入）
5. kagent の CRD が確立するまで待機（最大 300s、失敗時は helm/Pod の診断を出力）
6. `kagent-oci-genai` Secret を作成
7. OCI Generative AI 用の `ModelConfig` を適用（`envsubst`）
8. **baseUrl 未設定の OpenAI 系デフォルト ModelConfig を OCI へ向け直す**
9. **全 Agent を OCI 用 ModelConfig に向け直し、Deployment を再起動**
10. `demo-app` のデモアプリ投入 / `CrashLoopBackOff` ワークロード投入（任意）/ 稼働確認

> 末尾に ModelConfig 一覧（`PROVIDER` / `BASEURL`）と Agent → ModelConfig の対応が出力されます。`BASEURL` に OCI の URL が入り、Agent が `oci-genai-openai-compatible` を指していれば正常です。

---

## 5. 手動で実行したい場合

> 自動スクリプトを使わない場合は、**(a) baseUrl を空にしない**、**(b) Agent を OCI 用 ModelConfig に向け直す** の 2 点を必ず実施してください。これを忘れると 401 になります。

### 5-1. namespace を作成する
```bash
kubectl apply -f manifests/00-namespaces.yaml
```

### 5-2. kagent をインストールする
```bash
curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash
export OPENAI_API_KEY="$OCI_GENAI_API_KEY"   # install を完走させるため
kagent install --profile demo
```

### 5-3. kagent の CRD が立つまで待つ
```bash
kubectl get crd | grep -i kagent
kubectl wait --for=condition=Established crd/modelconfigs.kagent.dev --timeout=300s
kubectl wait --for=condition=Established crd/agents.kagent.dev --timeout=300s
```
> CRD が出てこない場合は「9. トラブルシュート」を参照してください。

### 5-4. OCI Generative AI 用の Secret と ModelConfig を作成する
```bash
# 3-3 で OCI_GENAI_REGION / OCI_GENAI_MODEL / OCI_GENAI_BASE_URL を export 済みであること
kubectl -n kagent create secret generic kagent-oci-genai \
  --from-literal=OCI_GENAI_API_KEY="${OCI_GENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

OCI_GENAI_MODEL="${OCI_GENAI_MODEL}" OCI_GENAI_BASE_URL="${OCI_GENAI_BASE_URL}" \
  envsubst < manifests/01-modelconfig-oci.yaml | kubectl apply -f -

# 反映確認（baseUrl が空でないこと！）
kubectl get modelconfig oci-genai-openai-compatible -n kagent \
  -o jsonpath='{.spec.openAI.baseUrl}{"\n"}'
```
> `baseUrl` が空文字なら、`OCI_GENAI_BASE_URL` を export せずに `envsubst` した状態です。3-3 を実行してから再適用してください。

### 5-5. デフォルト ModelConfig と Agent を OCI へ向け直す（**最重要**）
```bash
# (a) baseUrl 未設定の OpenAI 系デフォルトを OCI へ向け直す
PATCH="{\"spec\":{\"provider\":\"OpenAI\",\"model\":\"${OCI_GENAI_MODEL}\",\"apiKeySecret\":\"kagent-oci-genai\",\"apiKeySecretKey\":\"OCI_GENAI_API_KEY\",\"openAI\":{\"baseUrl\":\"${OCI_GENAI_BASE_URL}\"}}}"
for mc in $(kubectl get modelconfig -n kagent -o name); do
  [[ "$mc" == *oci-genai-openai-compatible ]] && continue
  prov="$(kubectl get "$mc" -n kagent -o jsonpath='{.spec.provider}' 2>/dev/null || true)"
  base="$(kubectl get "$mc" -n kagent -o jsonpath='{.spec.openAI.baseUrl}' 2>/dev/null || true)"
  [[ "$prov" == "OpenAI" && -z "$base" ]] && kubectl patch "$mc" -n kagent --type merge -p "$PATCH"
done

# (b) 全 Agent を OCI 用 ModelConfig に向ける（declarative / spec直下 両対応）
for ag in $(kubectl get agent -n kagent -o name); do
  if kubectl get "$ag" -n kagent -o jsonpath='{.spec.declarative}' 2>/dev/null | grep -q .; then
    kubectl patch "$ag" -n kagent --type merge -p '{"spec":{"declarative":{"modelConfig":"oci-genai-openai-compatible"}}}'
  else
    kubectl patch "$ag" -n kagent --type merge -p '{"spec":{"modelConfig":"oci-genai-openai-compatible"}}'
  fi
done

# (c) 反映のため再起動
kubectl rollout restart deployment -n kagent
```

### 5-6. デモアプリをデプロイする
```bash
kubectl apply -f manifests/10-demo-app.yaml
```

### 5-7. 障害系ワークロードをデプロイする（任意）
```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

---

## 6. 動作確認

### 6-1. Pod / 配線を確認する
```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide

# ModelConfig が OCI を指しているか
kubectl get modelconfig -n kagent \
  -o custom-columns=NAME:.metadata.name,PROVIDER:.spec.provider,BASEURL:.spec.openAI.baseUrl

# Agent がどの ModelConfig を参照しているか
kubectl get agent -n kagent -o yaml | grep -iE "name:|modelConfig"
```

### 6-2. kagent の UI を開く
```bash
kagent dashboard
```

---

## 7. デモの流れ
1. `kagent` の Pod を確認する
2. UI から Agent を作成（または既存 Agent を使用）する
3. OCI Generative AI の ModelConfig（`oci-genai-openai-compatible`）を選択する
4. `demo-app` のワークロード（`CrashLoopBackOff`）を調査・修正させる

---

## 8. クリーンアップ
```bash
./delete-kind-cluster.sh
```

または手動で:
```bash
kubectl delete -f manifests/20-demo-fault-crashloop.yaml --ignore-not-found
kubectl delete -f manifests/10-demo-app.yaml --ignore-not-found
kubectl delete -f manifests/01-modelconfig-oci.yaml --ignore-not-found
kubectl delete -f manifests/00-namespaces.yaml --ignore-not-found
kind delete cluster --name kagent-demo
```

---

## 9. トラブルシュート

### 9-1. `Timed out waiting for CRD matching: modelconfig`
kagent の CRD が作成されていません。多くは **汚れたクラスタの使い回し**（前回 install が中途で失敗し helm リリースが残存）が原因です。
```bash
helm list -A --all | grep -i kagent      # failed / pending-* の release が無いか
kubectl get crd | grep -i kagent
kubectl get pods -A | grep -i kagent     # ImagePullBackOff / Pending なら取得待ち
```
- **release が中途状態**: `kind delete cluster --name kagent-demo` でクリーンにして再実行（推奨）。
- **release が無い / 取得失敗**: CRD だけ明示導入してから再実行。
  ```bash
  helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds -n kagent --create-namespace
  kubectl get crd | grep -i kagent
  ```
- **Pod が Pending/ImagePullBackOff**: 初回 pull 待ちの可能性。少し待って `kubectl get pods -n kagent -w` で監視。

### 9-2. `Error code: 401 ... Incorrect API key provided: sk-... platform.openai.com`
リクエストが OCI ではなく `api.openai.com` に飛んでいます。原因は次のいずれか。
1. **Agent がデフォルト(OpenAI)の ModelConfig を参照**している → 5-5 を実施。
2. **ModelConfig の `baseUrl` が空** → 5-4 の確認コマンドで空なら、`OCI_GENAI_BASE_URL` を export して再適用。
3. **キーに改行・空白が混入** → 3-1 のように `tr -d '[:space:]'` で除去して Secret を作り直し、`kubectl rollout restart deployment -n kagent`。

### 9-3. キーの取り扱い
API キーはチャットや共有ログに貼らないでください。誤って共有した場合は OCI 側でローテーション（再生成）してください。

---

## 10. 注意
- このキットは、デモの流れを安定させるための土台です。
- 再構築時は「9-1」のとおり、まずクラスタを削除してクリーンな状態から始めるのが最も安定します。