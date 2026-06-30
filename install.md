# kagent kind デモ環境構築手順（401回避版）

この版では、`create-kind-cluster.sh` は kind クラスタとデモ用 namespace / workload を作成するだけです。
OpenAI / OCI GenAI の API 呼び出しを行わないため、401 を避けられます。

## 実行
```bash
chmod +x create-kind-cluster.sh delete-kind-cluster.sh
./create-kind-cluster.sh
```

## 使い方
- `demo-web` は正常系
- `demo-crashloop` は CrashLoop デモ用
- `demo-web` Service は selector mismatch で一時的に接続断のデモが可能
- 復元は `manifests/31-demo-service-restore.yaml`

## 注意
- `OCI_GENAI_API_KEY` を `OPENAI_API_KEY` に流用しない
- このキットは kagent install を含まない
