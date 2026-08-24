# Argo Rollouts デモ(デモ5・追加)環境構築

デモ5「Deployment → Argo Rollouts カナリアへの移行」を行うための追加セットアップです。
kagent 本体・OCI モデルの構成はそのまま使い、**Argo Rollouts コントローラ**と
**kubectl プラグイン**を足すだけです。kagent の再インストールや `helm upgrade` は不要
（＝OCI の `default-model-config` を壊しません）。

- 対象エージェント: `argo-rollouts-conversion-agent`(kagent 同梱・プリセット)
- 使う argo ツール(kagent-tool-server 内):
  `argo_verify_argo_rollouts_controller_install` / `argo_verify_kubectl_plugin_install` /
  `argo_rollouts_list` / `argo_set_rollout_image` / `argo_pause_rollout` /
  `argo_promote_rollout` / `argo_check_plugin_logs`

---

## 0. 前提
- kagent 環境が構築済み(`install.md`)。`demo-web`(Deployment)が `demo-app` に存在。
- クラスタに接続できる kubectl / current-context。

---

## 1. Argo Rollouts コントローラを導入する
```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s
```

> OKE 補足: コントローラのイメージは `quay.io/argoproj/argo-rollouts:...` と
> **完全修飾**なので、OKE(Oracle Linux)の short-name 解決問題は起きません。
> grafana-mcp のときのようなイメージ差し替えは不要です。

---

## 2. kubectl プラグインを導入する(可視化用・登壇者マシン)
カナリアの進行をライブで見せるために使います(Linux/amd64 の例)。
OCI Cloud Shell は sudo/root が使えないため、PATH の通った `~/bin` に置きます。
```bash
mkdir -p ~/bin
curl -sSL -o ~/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ~/bin/kubectl-argo-rollouts
# ~/bin が PATH に無ければ通す(Cloud Shell は通常入っている)
case ":$PATH:" in *":$HOME/bin:"*) ;; *) echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc; export PATH="$HOME/bin:$PATH";; esac
kubectl argo rollouts version
```
> sudo が使える通常の環境なら `sudo mv kubectl-argo-rollouts /usr/local/bin/` でも可。

---

## 3. サンプルアプリを投入する
デモ5 の対象ワークロード `demo-rollout` を入れます。Argo 公式デモアプリ
`docker.io/argoproj/rollouts-demo`(完全修飾。バージョンごとに色が変わる)を使うため、
OKE の short-name 問題(`nginx` などで出る ImageInspectError)を回避できます。
demo-web(デモ1〜3)とは別アプリなので互いに影響しません。
```bash
kubectl apply -f manifests/50-demo-rollout-app.yaml
kubectl get deploy,svc -n demo-app -l app=demo-rollout
```

---

## 4. 動作確認
```bash
# コントローラ Pod
kubectl get pods -n argo-rollouts
# CRD(Rollout など)が入ったか
kubectl get crd | grep argoproj
```
kagent 側では、`argo-rollouts-conversion-agent` に
「Argo Rollouts コントローラが入っているか確認して」と聞くと、
`argo_verify_argo_rollouts_controller_install` で確認してくれます。

---

## 5. デモの実施
`demo.md` の「デモ5(追加): Deployment → Argo Rollouts カナリアへの移行」に従って進めます。
保険用マニフェスト: `manifests/51-demo-rollout-canary.yaml`

---

## 6. クリーンアップ
```bash
# デモ5 のワークロードを撤去(Rollout / Deployment / Service)
kubectl -n demo-app delete rollout demo-rollout --ignore-not-found
kubectl -n demo-app delete -f manifests/50-demo-rollout-app.yaml --ignore-not-found

# Argo Rollouts コントローラを撤去
kubectl delete -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl delete namespace argo-rollouts
```

> デモ5 は demo-web を触らないので、デモ1〜3 の状態には影響しません。
> デモ5 をもう一度やるだけなら、`kubectl -n demo-app delete rollout demo-rollout` の後に
> `kubectl apply -f manifests/50-demo-rollout-app.yaml` で blue の Deployment に戻せます。
