# kagent デモ台本

このファイルは、**デモ1（CrashLoopBackOff の原因調査と修復）**、  
**デモ2（Service と Pod のつながり確認）**、  
**デモ3（k8s-agent → observability-agent / promql-agent）** を、コピペしながら進めるための台本です。

前提:
- `create-kind-cluster.sh` で環境構築済み
- `kagent` UI に `kubectl port-forward -n kagent svc/kagent-ui 8080:8080` でアクセス済み
- `demo-app` namespace に `demo-web` と `demo-crashloop` が存在する
- `manifests/30-demo-service-mismatch.yaml` と `manifests/31-demo-service-restore.yaml` がある
- `manifests/40-promql-cpu-burn.yaml` がある

---

## 共通の確認コマンド

```bash
kubectl get pods -n kagent
kubectl get pods -n demo-app -o wide
kubectl get svc -n demo-app
kubectl get endpoints -n demo-app
```

---

# デモ1: CrashLoopBackOff の原因調査と修復

## 1. 現状確認

```bash
kubectl get pods -n demo-app
kubectl describe pod -n demo-app -l app=demo-crashloop
kubectl logs -n demo-app -l app=demo-crashloop --tail=100
```

### 話すこと
- `demo-crashloop` は意図的に壊してある
- `describe` と `logs` と `events` を見れば原因が分かる
- コンテナが `exit 1` で落ちていることを確認したい

## 2. kagent に原因を調べさせる

### 画面で入力する依頼文
```text
demo-app namespace の crashloop している Pod を調べてください。
describe, events, logs を確認して、なぜ落ちているかを要約してください。
```

### 話すこと
- 単に落ちていることではなく、**なぜ落ちているかを短時間で要約できるか**を見る
- `exit 1` が原因だと分かれば成功

## 3. 修復する

### 修復コマンド
```bash
kubectl patch deployment demo-crashloop -n demo-app --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","sleep infinity"]}
]'
```

### 再確認
```bash
kubectl rollout status deployment/demo-crashloop -n demo-app
kubectl get pods -n demo-app -l app=demo-crashloop -w
```

### 話すこと
- コマンドを `sleep infinity` に変えた
- 再起動後に `Running` に戻れば復旧成功
- 「原因調査」から「修復」までを一気通貫で見せる

## 4. 修復後の確認

```bash
kubectl get pods -n demo-app -l app=demo-crashloop
kubectl describe pod -n demo-app -l app=demo-crashloop
```

### 話すこと
- もう `CrashLoopBackOff` ではない
- 再起動回数が止まっていればよい

---

# デモ2: Service と Pod のつながりを確認するデモ

## 1. 正常系の確認

```bash
kubectl get pods -n demo-app -l app=demo-web
kubectl get svc -n demo-app demo-web
kubectl get endpoints -n demo-app demo-web
kubectl describe svc -n demo-app demo-web
```

### 話すこと
- `demo-web` は正常稼働している
- Service に endpoint が付いている状態を先に見せる
- ここでは「Pod と Service がつながっている」ことを確認する

## 2. わざと不整合を作る

まず、`30-demo-service-mismatch.yaml` を適用して Service の selector をずらします。

```bash
kubectl apply -f manifests/30-demo-service-mismatch.yaml
```

そのあと、endpoint が消えていることを確認します。

```bash
kubectl get endpoints -n demo-app demo-web
kubectl describe svc -n demo-app demo-web
kubectl get pods -n demo-app -o wide
```

### 話すこと
- Service の selector をずらして、不整合を意図的に作る
- Pod は動いているのに Service から届かない状態にする
- Kubernetes ではこういう「つながりのズレ」が運用上よくある

## 3. kagent に調べさせる

### 画面で入力する依頼文
```text
demo-app namespace の demo-web Service が Pod に届かない理由を調べてください。
Service selector, Pod label, endpoints の観点で確認してください。
```

### 話すこと
- Pod 単体ではなく、Service / Deployment / Pod の関係を見たい
- selector の不一致や endpoint 不在を見抜けるかを確認する

## 4. 元に戻す

次に、`31-demo-service-restore.yaml` を適用して復旧します。

```bash
kubectl apply -f manifests/31-demo-service-restore.yaml
```

復旧確認をします。

```bash
kubectl get endpoints -n demo-app demo-web
kubectl describe svc -n demo-app demo-web
kubectl get pods -n demo-app -o wide
```

### 話すこと
- selector を元に戻す
- endpoint が復活すれば復旧成功
- つながりの確認と復旧をセットで見せる

---

# デモ3: k8s-agent → observability-agent / promql-agent

このデモは、**k8s-agent で「何が起きているか」を整理し、  
observability-agent / promql-agent で「本当にそうか」をメトリクスで裏取りする** 流れです。

## 0. 追加 workload を入れる

PromQL デモ用に CPU を少し使う workload を入れます。

```bash
kubectl apply -f manifests/40-promql-cpu-burn.yaml
kubectl get pods -n demo-app -l app=demo-cpu-burn -w
```

### 話すこと
- `demo-cpu-burn` は軽い CPU 負荷を出すだけの簡単な Pod
- observability / promql のデモで、メトリクスを見る対象にする

## 1. まずは k8s-agent に全体像を聞く

### 画面で入力する依頼文
```text
demo-app namespace の状態を調べてください。
CrashLoopBackOff の Pod、Service の endpoint、CPU を使っている Pod を含めて整理してください。
```

### 話すこと
- まず k8s-agent に全体像を要約させる
- 単発の障害だけでなく、namespace 全体の状態を見せる
- 「どこが気になるか」を短時間で返せるのがポイント

## 2. observability-agent / promql-agent で裏取りする

### 画面で入力する依頼文
```text
demo-app namespace で気になる Pod や Service の状態を、メトリクス観点で確認してください。
再起動回数、Ready 状態、endpoint の有無、CPU 使用傾向など、運用上の判断材料をまとめてください。
```

### 話すこと
- `k8s-agent` の要約を、observability の観点で確認する
- `promql-agent` でメトリクスの見方を補助してもらう
- `demo-cpu-burn` を使うと、CPU 使用傾向の話がしやすい
- 「なぜその Pod を気にするのか」をメトリクスで説明できると強い

## 3. 使い分けの見せ方

### 話すこと
- `k8s-agent` は **Kubernetes オブジェクトの関係を読む**
- `observability-agent` / `promql-agent` は **状態をメトリクスで裏取りする**
- 2つを組み合わせると、**原因の切り分けと優先度付け** がやりやすい

---

# デモの締め

### 話すこと
- デモ1では、障害の原因特定と修復を見せる
- デモ2では、Service / Pod / Deployment の関係を見せる
- デモ3では、k8s-agent と observability 系 agent の役割分担を見せる
- kagent は単なる障害調査ではなく、Kubernetes の構造理解と運用判断を支援できる

### 追加で言うとよい一言
```text
この3本を通して、kagent は単発の障害対応だけでなく、Kubernetes のオブジェクト関係とメトリクスを見ながら運用判断を支援できることが分かります。
```
