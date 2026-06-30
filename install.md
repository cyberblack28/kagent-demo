# kagent kind デモ環境構築手順（install 分離版）

この版では、`OCI_GENAI_API_KEY` と `OPENAI_API_KEY` を分けて扱います。
**OCI のキーを `OPENAI_API_KEY` に入れると 401 の原因になります。**

## 実行前の環境変数
```bash
export OCI_GENAI_API_KEY="...OCI GenAI のキー..."
export OPENAI_API_KEY="...kagent install 用の OpenAI キー..."
export OCI_GENAI_REGION="us-chicago-1"
export OCI_GENAI_MODEL="openai.gpt-oss-120b"
```

## 動作確認
```bash
curl -sS "${OCI_GENAI_BASE_URL}/chat/completions"   -H "Authorization: Bearer ${OCI_GENAI_API_KEY}"   -H "Content-Type: application/json"   -d "{"model":"${OCI_GENAI_MODEL}","messages":[{"role":"user","content":"ping"}]}"
```

## 実行
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
```

## ポイント
- `kagent install` には `OPENAI_API_KEY` を使う
- OCI GenAI は `ModelConfig` で使う
- 2つのキーが同じだと 401 になりやすい
