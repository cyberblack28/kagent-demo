# observability-agent の有効化(Prometheus / Grafana / grafana-mcp)

プリセットの `observability-agent` を使えるようにするための追加セットアップです。

## なぜいま使えないのか

```
Accepted / False / ReconcileFailed /
failed to compile agent kagent/observability-agent:
RemoteMCPServer.kagent.dev "kagent-grafana-mcp" not found
```

observability-agent は、Grafana 用の MCP サーバー `kagent-grafana-mcp` を参照しています。
構築スクリプトでは `grafana-mcp.enabled=false` にしている(OKE でイメージを取得できないため)ので、
参照先が存在せず、エージェントが受理されていません。

## 何を入れるか

```
observability-agent ──(MCP)──▶ kagent-grafana-mcp ──▶ Grafana ──▶ Prometheus
        │                       (mcp/grafana)        (kube-prometheus-stack)
        └──(A2A)──▶ promql-agent(PromQL の生成。すでに稼働中)
```

1. **Prometheus + Grafana**(kube-prometheus-stack)
2. **Grafana のサービスアカウントトークン**(grafana-mcp が Grafana に接続するため)
3. **grafana-mcp**(`kagent-grafana-mcp` という名前の RemoteMCPServer が作られる)

---

## 0. 前提と方針

### 前提
- kagent 0.9.11 が OKE 上で稼働中(`install.md`)
- `kubectl` / `helm` / `git` / `envsubst` / `jq`(OCI Cloud Shell にはすべて入っている)

### 方針:kagent 本体は `helm upgrade` しない
grafana-mcp は kagent チャートのサブチャートなので、`helm upgrade kagent --set grafana-mcp.enabled=true`
でも有効化できます。しかし **Helm 3 はアップグレード時に、実クラスタ上の差分をチャートの状態に戻します**。
このデモでは構築後に次の2つを手で上書きしているため、アップグレードすると元に戻され、
**OCI Generative AI への接続が壊れます**。

- `default-model-config` を OCI 用に上書き(`manifests/01-modelconfig-oci.yaml`)
- 各エージェントの `modelConfig` を `oci-genai-openai-compatible` にパッチ

そこで **grafana-mcp のチャートだけを、別のリリースとして単独で入れます**。リリース名を
`kagent-grafana-mcp` にすると、作られる RemoteMCPServer の名前が observability-agent の参照先と一致します。

### OKE の注意:イメージ名は完全修飾にする
grafana-mcp チャートのイメージは既定で `mcp/grafana:latest`(`registry: mcp` / `repository: grafana`)です。
`mcp` は**レジストリではなく Docker Hub の組織名**なので、OKE では短縮名として扱われ取得に失敗します。
`image.registry=docker.io/mcp` を指定して `docker.io/mcp/grafana:latest` にします。

> `image.registry=docker.io` だと `docker.io/grafana:latest` という**別のイメージ**になるので注意。

---

## 1. Prometheus と Grafana をインストールする

### 1-1. チャートを用意してバージョンを決める
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack   # CHART VERSION を確認
KPS_VERSION=<上で表示された CHART VERSION>
```
> 作り直したときに同じ版が入るよう、使った版をメモしておく。

### 1-2. values を作る(OKE 向けに軽量化)
```bash
cat > kps-values.yaml <<'EOF'
# デモ用途なので Alertmanager は使わない
alertmanager:
  enabled: false

# マネージドなコントロールプレーンは直接スクレイプできないため無効化
# (有効のままだと Prometheus のターゲットが Down 扱いになる)
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
kubeProxy:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 6h
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits: { memory: 1Gi }
    # ほかの namespace の ServiceMonitor / PodMonitor も拾う
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

grafana:
  persistence:
    enabled: false
  service:
    type: ClusterIP
EOF
```

### 1-3. 事前チェック:短縮名のイメージが含まれていないか(OKE)
```bash
helm template kps prometheus-community/kube-prometheus-stack \
  --version "${KPS_VERSION}" -n observability -f kps-values.yaml \
  | grep -E '^\s+image:' | sed -E 's/^\s+image:\s*//; s/"//g' | sort -u \
  | awk -F/ '{ if ($1 !~ /\./ && $1 !~ /:/ && $1 != "localhost") print "SHORT-NAME: " $0; else print "ok:         " $0 }'
```
`SHORT-NAME:` が出た場合は、そのイメージの `registry` を values で `docker.io` などに明示してから進む。

### 1-4. インストール
```bash
helm install kps prometheus-community/kube-prometheus-stack \
  --version "${KPS_VERSION}" -n observability --create-namespace \
  -f kps-values.yaml --wait --timeout 15m

kubectl -n observability get pods
```
すべて Running になれば完了。Prometheus は Grafana のデータソースとして自動で登録されます。

---

## 2. Grafana のサービスアカウントトークンを作る

grafana-mcp が Grafana に接続するためのトークンを発行し、**Kubernetes の Secret に入れます**
(helm の値に平文で残さないため)。

OCI Cloud Shell では `kubectl port-forward` が使えないため、**クラスタ内に一時的な Pod を立てて
そこから Grafana の API を叩きます**。応答の JSON は Cloud Shell 側の `jq` で読み取ります。

```bash
# 管理者の資格情報(kube-prometheus-stack が作る Secret)
GF_USER=$(kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-user}' | base64 -d)
GF_PASS=$(kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
GF_URL=http://kps-grafana.observability.svc.cluster.local

# クラスタ内の一時 Pod から curl を実行し、完了を待ってからログ(=応答)を読む
# - kubectl run -i で接続する方式だと、curl がすぐ終わったときに接続が間に合わず
#   応答を取りこぼすことがある。トークンは発行時に一度しか返らないため、
#   Pod の完了を待ってからログを読む方式にしている
# - イメージは OKE の短縮名問題を避けるため docker.io から完全修飾で指定
gf() {
  local p="gf-curl-${RANDOM}"
  kubectl -n observability run "$p" --restart=Never \
    --image=docker.io/curlimages/curl:8.10.1 -- \
    curl -s -u "${GF_USER}:${GF_PASS}" -H 'Content-Type: application/json' "$@" >/dev/null
  kubectl -n observability wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$p" --timeout=60s >/dev/null
  kubectl -n observability logs "$p"
  kubectl -n observability delete pod "$p" --wait=false >/dev/null
}

# 疎通確認(Grafana のバージョン情報が返ればよい)
gf "${GF_URL}/api/health"

# サービスアカウントを作成(まずは閲覧のみ)
gf -X POST "${GF_URL}/api/serviceaccounts" \
  -d '{"name":"kagent-grafana-mcp","role":"Viewer"}'
echo

# 作成したサービスアカウントの ID を取得(認証が必要な API なので、認証の確認も兼ねる)
SA_ID=$(gf "${GF_URL}/api/serviceaccounts/search?query=kagent-grafana-mcp" \
  | jq -r '.serviceAccounts[] | select(.name=="kagent-grafana-mcp") | .id')
echo "SA_ID=${SA_ID}"        # 数字が出ること

# トークンを発行(名前に時刻を付けて、再実行しても名前が重複しないようにする)
RESP=$(gf -X POST "${GF_URL}/api/serviceaccounts/${SA_ID}/tokens" \
  -d "{\"name\":\"kagent-grafana-mcp-$(date +%s)\"}")
echo "${RESP}" | jq 'del(.key)'      # キー以外を表示して成否を確認
TOKEN=$(echo "${RESP}" | jq -r .key)
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] && echo "token OK" || echo "token NG"

# kagent namespace に Secret として格納(キー名はこの名前で固定)
kubectl -n kagent create secret generic grafana-mcp-token \
  --from-literal=GRAFANA_SERVICE_ACCOUNT_TOKEN="${TOKEN}"
unset TOKEN RESP GF_PASS
```

> 一時 Pod の引数に管理者の資格情報が含まれます(Pod が動いている数秒間は Pod の定義から見える)。
> デモ環境なら許容範囲ですが、本番では避けてください。

**うまくいかないとき**
- **サービスアカウントの作成で「すでに存在する」エラーが出る**: 以前の実行で作成済みです。
  そのまま次の `SA_ID=` の行から続ければよい(検索で既存の ID を取得する)。
- **`SA_ID=` が空**: 認証に失敗している可能性。`echo "${GF_USER} ${#GF_PASS}"` で
  資格情報の変数が入っているか確認する(シェルを開き直すと消える)。
- **`token NG`**: `echo "${RESP}" | jq 'del(.key)'` でエラー内容を確認する。トークン名は毎回
  変わるので、原因を直してそのまま再実行してよい。
- **`kubectl wait` がタイムアウトする**: 一時 Pod が失敗している。
  `kubectl -n observability get pods | grep gf-curl` で状態を確認し、残った Pod は削除する。

### 別案:トークンを作らず、ベーシック認証で接続する
mcp-grafana は `GRAFANA_USERNAME` / `GRAFANA_PASSWORD` によるベーシック認証にも対応しています。
API を叩かずに済む一方、**エージェントが Grafana の管理者権限で動く**ことになるので、
上の方法がうまくいかない場合の代替として使ってください。

```bash
GF_USER=$(kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-user}' | base64 -d)
GF_PASS=$(kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

# 先に上の方法で Secret を作りかけていた場合は消してから作り直す
kubectl -n kagent delete secret grafana-mcp-token --ignore-not-found

kubectl -n kagent create secret generic grafana-mcp-token \
  --from-literal=GRAFANA_USERNAME="${GF_USER}" \
  --from-literal=GRAFANA_PASSWORD="${GF_PASS}"
unset GF_PASS
```
Secret の名前が同じなので、手順3はそのままで動きます(Secret のキーはすべて環境変数として読み込まれる)。

> **ロールについて**: `Viewer` は閲覧のみ。observability-agent にダッシュボードの作成・更新
> (`update_dashboard`)まで試させたい場合は `Editor` にする。デモ4・デモ6 と同じく、
> まずは読み取りから始めるのがおすすめ。

> kube-prometheus-stack の Grafana 管理者パスワードは既定で固定値です。ClusterIP のまま
> 外部に公開しない前提なら問題ありませんが、公開する場合は変更してください。

---

## 3. grafana-mcp を単独でインストールする

kagent 0.9.11 のリポジトリから grafana-mcp のチャートだけを取り出して入れます。

```bash
git clone --depth 1 --branch v0.9.11 https://github.com/kagent-dev/kagent.git "$HOME/kagent-src"

# Chart.yaml はテンプレートから生成する(これを忘れると helm install が失敗する)
VERSION=0.9.11 envsubst \
  < "$HOME/kagent-src/helm/tools/grafana-mcp/Chart-template.yaml" \
  > "$HOME/kagent-src/helm/tools/grafana-mcp/Chart.yaml"

# mcp-grafana の Host チェックで、kagent からの接続が 403 にならないようにする
cat > grafana-mcp-args.yaml <<'EOF'
args:
  - --allowed-hosts=kagent-grafana-mcp.kagent:8000,kagent-grafana-mcp.kagent.svc.cluster.local:8000
EOF

helm install kagent-grafana-mcp "$HOME/kagent-src/helm/tools/grafana-mcp" -n kagent \
  --set-string image.registry=docker.io/mcp \
  --set-string grafana.url=http://kps-grafana.observability.svc.cluster.local \
  --set-string grafana.secretRef=grafana-mcp-token \
  -f grafana-mcp-args.yaml \
  --wait --timeout 5m
```

| 値 | 理由 |
|---|---|
| リリース名 `kagent-grafana-mcp` | RemoteMCPServer の名前がこれになり、observability-agent の参照先と一致する |
| `image.registry=docker.io/mcp` | OKE の短縮名問題の回避(`docker.io/mcp/grafana:latest`) |
| `grafana.url` | Grafana のベース URL。`http://` を付け、`/api` は付けない |
| `grafana.secretRef` | 手順2の Secret を使う。チャート側では Secret を作らない |
| `--allowed-hosts`(args) | 下記参照 |

### `--allowed-hosts` が必要な理由
mcp-grafana の最新版は、DNS リバインディング対策として **`Host` ヘッダーを検証**し、既定では
ループバック(`localhost:8000` など)以外を **403 で拒否**します。kagent のコントローラやエージェントは
`Host: kagent-grafana-mcp.kagent:8000` で接続するため、許可しないとツール一覧が取れず、
RemoteMCPServer が `ACCEPTED False` のままになります。

kagent 0.9.11 のチャートはこの制約を想定していない(`mcp/grafana` は `latest` しかなく、後から
入った変更のため)ので、引数で明示的に許可します。`--allowed-hosts=*` で検証を無効にもできますが、
許可するホストを明示する方が安全です。

> **すでに引数なしで入れてしまった場合**: `helm -n kagent upgrade kagent-grafana-mcp
> "$HOME/kagent-src/helm/tools/grafana-mcp" --reuse-values -f grafana-mcp-args.yaml --wait`
> で引数だけ追加できる(kagent 本体のリリースとは別なので、OCI の設定には影響しない)。

### 確認
```bash
# Pod と、実際に使われたイメージ
kubectl -n kagent get pods -l app.kubernetes.io/instance=kagent-grafana-mcp
kubectl -n kagent get pod -l app.kubernetes.io/instance=kagent-grafana-mcp \
  -o jsonpath='{.items[0].spec.containers[0].image}'; echo     # docker.io/mcp/grafana:latest

# RemoteMCPServer が受理され、ツールが見えているか
kubectl -n kagent get remotemcpserver kagent-grafana-mcp
kubectl -n kagent describe remotemcpserver kagent-grafana-mcp | grep -E 'Name:\s+(query_prometheus|search_dashboards|list_datasources)'
```

---

## 4. observability-agent が受理されたことを確認する

```bash
kubectl -n kagent get agent observability-agent \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
# Accepted=True Reconciled / Ready=True DeploymentReady になればよい

# 使われるモデル(oci-genai-openai-compatible か default-model-config。どちらも OCI 向け)
kubectl -n kagent get agent observability-agent -o jsonpath='{.spec.declarative.modelConfig}'; echo

kubectl -n kagent rollout status deploy/observability-agent --timeout=180s
```

**ツールの読み込みを張り直しておく**(エージェントが `ask_user` しか持たない状態で起動する問題の予防):
```bash
kubectl -n kagent rollout restart deploy/observability-agent
```

1分ほど待っても `Accepted=False` のままなら、コントローラに再評価させる:
```bash
kubectl -n kagent rollout restart deploy/kagent-controller
```

---

## 5. 試してみる

インストール直後はメトリクスが少ないので、**数分おいてから**試す。
kagent UI で `observability-agent` を選び、たとえば次のように頼む:

```text
Prometheus を使って、demo-app namespace で CPU 使用量が多い Pod を上位5件教えてください。
```
```text
demo-app の Pod ごとのメモリ使用量を出す PromQL を作り、実行して結果を表で教えてください。
```
```text
Grafana に登録されているデータソースとダッシュボードの一覧を教えてください。
```

2つ目は、observability-agent が PromQL の生成を **promql-agent に委譲**する(A2A)ことがあります。
5レイヤーで言えば「グラフ」(誰に任せるか)の実例として見せられます。

> **gpt-oss は PromQL を作っただけで止まりがち**です。結果まで欲しいときは、
> 「list_datasources で Prometheus の UID を確認し、query_prometheus で実際に実行して」と
> 手順まで明示してください。

デモとしての流れは `demo.md` の **デモ7(メトリクスにしか出ない障害を調べる)** にまとめています。

### (任意)Grafana の画面をブラウザで見る
observability-agent を動かすだけなら Grafana の画面は不要です。見せたい場合は、Cloud Shell では
port-forward が使えないので、デモ5の手順1-b と同じく **一時的に LoadBalancer にして接続元を絞ります**。

```bash
# ① LoadBalancer にして、EXTERNAL-IP が付くまで待つ(付くまでは追加のパッチを当てない)
kubectl -n observability patch svc kps-grafana -p '{"metadata":{"annotations":{"service.beta.kubernetes.io/oci-load-balancer-shape":"flexible","service.beta.kubernetes.io/oci-load-balancer-shape-flex-min":"10","service.beta.kubernetes.io/oci-load-balancer-shape-flex-max":"10"}},"spec":{"type":"LoadBalancer"}}'
kubectl -n observability get svc kps-grafana -w     # EXTERNAL-IP が付いたら Ctrl+C

# ② PC のブラウザで https://ifconfig.me を開き、自分のグローバル IP を控える
#    (Cloud Shell の curl では Cloud Shell 自身の IP が出るので使わない)

# ③ すぐに接続元を絞る
MYIP=<②で控えたIP>
kubectl -n observability patch svc kps-grafana -p "{\"spec\":{\"loadBalancerSourceRanges\":[\"${MYIP}/32\"]}}"
```
③を済ませてから `http://<EXTERNAL-IP>/` を開き、手順2で取得した管理者アカウントでログインする。
管理者パスワードが既定値のままなので、**接続元の制限は必須**です。①〜③は間を空けずに続けて行う。

> EXTERNAL-IP が付く前に別のパッチを当てると、`409 Conflict ... Token Collision` で
> `<pending>` のまま止まることがある。type を戻しても直らず、Service を作り直して
> UID を新しくする必要がある(詳しくは `demo.md` デモ5の手順1-b)。

**見終わったら必ず戻す**(OCI Load Balancer の課金を止めるため):
```bash
kubectl -n observability patch svc kps-grafana -p '{"spec":{"type":"ClusterIP"}}'
```

---

## 6. クリーンアップ

```bash
helm -n kagent uninstall kagent-grafana-mcp
kubectl -n kagent delete secret grafana-mcp-token
helm -n observability uninstall kps
kubectl delete namespace observability

# kube-prometheus-stack の CRD は uninstall では消えない(必要なら削除)
kubectl get crd | grep monitoring.coreos.com
```
grafana-mcp を消すと、observability-agent はまた `Accepted=False` に戻ります(想定どおりの状態)。

---

## 既知の制約・注意

- **`mcp/grafana` は `latest` タグしかない**ため、版を固定できません。実際に、後から追加された
  `Host` ヘッダーの検証により、kagent 0.9.11 のチャートのままでは接続が 403 で拒否されました
  (手順3の `--allowed-hosts` で対処)。今後もツール名や起動オプションが変わる可能性があります。
  observability-agent が参照するツールのうち `list_alert_rules` は、現在の mcp-grafana の README に見当たりません。
  Prometheus の照会(`query_prometheus` など)やダッシュボード検索など主要なものは存在します。
- インシデント・オンコール系のツール(`list_incidents`、`list_oncall_*` など)は Grafana Cloud の機能向けで、
  OSS の Grafana では使えません。
- `create-oke-cluster.sh` を再実行しても、このリリース(`kagent-grafana-mcp`)とは別なので影響しません。
  ただし将来 kagent 本体側で `grafana-mcp.enabled=true` にすると、**同名のリソースが衝突する**ので、
  その場合は先にこのリリースを削除してください。
- kagent 1.0 系(API v1alpha3)ではエージェントの定義方法が変わるため、この手順は 0.9.x 前提です。
