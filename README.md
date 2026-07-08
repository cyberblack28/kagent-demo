# kagent デモ一式

このバンドルは、kagent の環境構築からデモ実施までをまとめた一式です。
**kind(ローカル検証)** と **OKE(本番デモ)** の両方に対応しています。

## デモの構成
- デモ1: CrashLoopBackOff の原因調査と修復
- デモ2: ImagePullBackOff の原因調査と修復
- デモ3: Service と Pod のつながり確認(複数リソースをまたいだ推論)
- デモ4: 自作エージェントを UI から作る(運用の標準化)

## クラスタの選択
| パターン | 用途 | 構築 | 破棄 |
|---|---|---|---|
| kind | ローカル検証・リハーサル | `create-kind-cluster.sh` | `delete-kind-cluster.sh` |
| OKE  | 本番デモ | `create-oke-cluster.sh` | `delete-oke-cluster.sh` |

kind 版と OKE 版は同じ Helm チャート・同じマニフェスト・同じ ModelConfig を
使うため、ローカルで検証した内容をそのまま OKE で再現できます。

## 使い方
1. `install.md` に従って環境を構築する(kind / OKE いずれかを選ぶ)
2. `kubectl port-forward -n kagent svc/kagent-ui 8080:8080` で UI を開く
   (OKE で LoadBalancer 公開にした場合は EXTERNAL-IP を使う)
3. `demo.md` に従ってデモを進める

## 補足
- `default-model-config` を OCI Generative AI 向けに切り替える前提です
- `demo-web`(healthy baseline)と `demo-crashloop`(デモ1)は構築時に投入されます
- デモ2/3 の障害は、デモ中にその場で `kubectl apply` で注入します
  - `30-demo-imagepull.yaml`: ImagePullBackOff を起こす(デモ2)
  - `40-demo-service-mismatch.yaml` / `41-demo-service-restore.yaml`:
    Service の selector 不整合を起こす/直す(デモ3)
- OKE では、kagent UI が無認証のため、LoadBalancer 公開時は接続元 CIDR を
  `UI_LB_ALLOWED_CIDR` で必ず制限してください。後始末は必ず
  `delete-oke-cluster.sh` を使い、OCI Load Balancer / Block Volume の
  消し忘れ課金を防ぎます。
