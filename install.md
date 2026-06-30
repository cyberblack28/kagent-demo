# kagent kind デモ環境構築手順

OCI Generative AI(OpenAI 互換エンドポイント)を kagent のモデルとして使う構成。

## なぜ以前 401 になっていたか
`kagent install --profile demo` が入れる **同梱エージェントは `default-model-config`** を参照する。
この既定 ModelConfig は `provider: OpenAI` で baseUrl 未指定 = `api.openai.com` を向く。
OCI 用 ModelConfig を別名で作っても、エージェントはそれを使わず `default-model-config` を使い続けるため、
OCI のキーを OpenAI 本家に送って `invalid_api_key (401)` になっていた。

→ 本キットでは **`default-model-config` 自体を OCI 設定で上書き** し、さらに各エージェントを
OCI 用 ModelConfig へ向け直してから Pod を再起動する。これで同梱エージェントも OCI を使う。

`OPENAI_API_KEY` に OCI キーを入れているのはインストーラの都合(既定 Secret 作成)だけで、
エージェントが実際に使うのは `kagent-oci-genai` Secret。OpenAI 本家には送られない。

## 実行順
```bash
export OCI_GENAI_API_KEY="$(printf %s 'sk-...' | tr -d '[:space:]')"
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
export OCI_GENAI_BASE_URL="https://inference.generativeai.${OCI_GENAI_REGION}.oci.oraclecloud.com/20231130/actions/v1"

# (推奨)先に OCI 側の疎通を確認する。200 と補完テキストが返ればOCI側は健全。
curl -sS "${OCI_GENAI_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${OCI_GENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${OCI_GENAI_MODEL}"'","messages":[{"role":"user","content":"ping"}]}'

chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh

kubectl port-forward -n kagent svc/kagent-ui 8080:8080
```

## うまく動いているかの確認
```bash
# エージェントが OCI を向いているか(baseUrl が OCI になっているか)
kubectl -n kagent get modelconfig default-model-config -o yaml | grep -A3 openAI

# 失敗時は、実際に叩いている base_url をログで確認する
kubectl -n kagent logs deploy/<agent> --tail=50
```

## 後始末
```bash
./delete-kind-cluster.sh
# デモが終わったら、共有・露出した API キーは必ずローテートする。
```
