# kagent デモ一式

このバンドルは、kagent の環境構築からデモ実施までをまとめた一式です。

## デモの構成
- デモ1: CrashLoopBackOff の原因調査と修復
- デモ2: Service と Pod のつながり確認
- デモ3: k8s-agent → observability-agent / promql-agent

## 使い方
1. `install.md` に従って環境を構築する
2. `kubectl port-forward -n kagent svc/kagent-ui 8080:8080` で UI を開く
3. `demo.md` に従ってデモを進める
4. デモ3を使うときは `manifests/40-promql-cpu-burn.yaml` を適用する

## 補足
- `default-model-config` を OCI GenAI 向けに切り替える前提です
- `demo-web` と `demo-crashloop` はデモ用ワークロードです
- `30-demo-service-mismatch.yaml` と `31-demo-service-restore.yaml` は、Service の selector 不整合を見せるためのファイルです
