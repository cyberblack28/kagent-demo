# kagent kind デモキット

kind 上に kagent を構築し、**OCI Generative AI(OpenAI 互換エンドポイント)** をモデルとして使うデモ環境。

## このキットの肝
`kagent install --profile demo` の同梱エージェントは既定 ModelConfig(`default-model-config`)を参照する。
素の `default-model-config` は `api.openai.com` を向くため、OCI のキーを渡しても OpenAI 本家に弾かれて 401 になる。
本キットは `default-model-config` を **OCI 設定で上書き** し、エージェントを OCI 用 ModelConfig へ向け直してから
再起動することで、同梱エージェントを OCI で動かす。

## 使い方
1. OCI GenAI のキー等を環境変数に設定する(`install.md` 参照)
2. `./create-kind-cluster.sh` を実行する
3. `kubectl port-forward -n kagent svc/kagent-ui 8080:8080` で UI を開く

詳細な手順とトラブルシュートは `install.md` を参照。

## 構成
- `create-kind-cluster.sh` … kind 作成 → kagent 導入 → OCI ModelConfig 設定 → デモアプリ投入
- `delete-kind-cluster.sh` … クラスタ削除
- `manifests/01-modelconfig-oci.yaml` … OCI 用 ModelConfig(default 上書き + 別名)
- `manifests/10-demo-app.yaml` … healthy なデモアプリ(demo-web)
- `manifests/20-demo-fault-crashloop.yaml` … 自己修復デモ用の crashloop
- `manifests/30-demo-service-mismatch.yaml` / `31-demo-service-restore.yaml` … サービス障害の注入/復旧(デモ中に個別 apply)

## セキュリティ
API キーは平文で共有・露出しないこと。万一露出したら速やかにローテートする。
