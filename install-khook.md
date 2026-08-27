# khook デモ(デモ6・追加)環境構築

デモ6「イベント駆動でエージェントが自動起動する」を行うための追加セットアップです。
kagent 本体の構成はそのまま使い、**khook コントローラ**を足すだけです。
kagent の再インストールや `helm upgrade` は不要（＝OCI の `default-model-config` を壊しません）。

- khook: <https://github.com/kagent-dev/khook>
- 役割: Kubernetes の Event を監視し、条件に合致したら **A2A でエージェントを呼ぶ**
  Kubernetes コントローラ。kagent 本体は「呼ばれたら動く」ので、khook が
  「呼ぶ人」を代行してくれる＝**対話駆動からイベント駆動(ループ)への橋渡し**。

```
Kubernetes Event ─▶ khook ─(A2A: prompt + コンテキスト)─▶ kagent エージェント
                      └ 同一イベントは 10 分間 重複抑制(dedup)
```

---

## 0. 前提
- kagent 環境が構築済み(`install.md`)。`demo-app` namespace が存在する。
- クラスタに接続できる kubectl / helm / git / make。

---

## 1. khook をインストールする

```bash
git clone https://github.com/kagent-dev/khook.git
cd khook
# Chart.yaml をテンプレートから生成する(これを忘れると helm install が失敗する)
make helm-version

# CRD を先に入れる
helm install khook-crds ./helm/khook-crds --namespace kagent --create-namespace
# コントローラを入れる
helm install khook ./helm/khook --namespace kagent --create-namespace
```

> `make helm-deploy` でも同等（CRD＋コントローラをまとめて導入）。

### 動作確認
```bash
kubectl get pods -n kagent | grep khook
kubectl get crd | grep hooks.kagent.dev
```

---

## 2. Hook を作成する

`demo-app` namespace の Pod 再起動を拾い、`kagent` namespace の `k8s-agent` を
呼ぶ Hook を投入します。

```bash
kubectl apply -f manifests/60-demo-hook-readonly.yaml
kubectl get hooks -n demo-app
```

### 設計上のポイント
- **Hook は「監視したい namespace」に置く**。エージェント本体は別 namespace でよく、
  `agentRef.namespace` で指定する。
- サポートされるイベント種別:
  `pod-restart` / `pod-pending` / `oom-kill` / `probe-failed` / `node-not-ready`
- プロンプト内で使えるテンプレート変数は `{{.ResourceName}}` と `{{.EventTime}}`。
- **読み取り専用に倒している**。khook の公式サンプルは
  「AUTONOMOUS MODE / Never ask for permission」という全自動修復だが、
  本デモでは「調査して報告するだけ」に留める(理由は `demo.md` のデモ6を参照)。

---

## 3. デモの実施
`demo.md` の「デモ6(追加): イベント駆動でエージェントを自動起動する」に従って進めます。

---

## 4. クリーンアップ

```bash
# Hook を削除(これでイベント駆動は止まる)
kubectl delete -f manifests/60-demo-hook-readonly.yaml --ignore-not-found

# khook 本体を撤去する場合
helm -n kagent uninstall khook
helm -n kagent uninstall khook-crds
```

> Hook を残したままにすると、以降 `demo-app` で Pod が再起動するたびに
> エージェントが起動します。デモ1(CrashLoopBackOff)を後で回す予定があるなら、
> 意図しない起動を避けるため Hook を削除しておくのが無難です。
