# kagent デモ台本(k8s-agent 版)

このファイルは、**すべて k8s-agent だけ**で完結する3本のデモを、
コピペしながら進めるための台本です。

- **デモ1: CrashLoopBackOff の原因調査と修復**
- **デモ2: ImagePullBackOff の原因調査と修復**
- **デモ3: Service と Pod のつながり確認(複数リソースをまたいだ推論)**
- **デモ4: 自作エージェントを UI から作る(運用の標準化)**

3本とも「Kubernetes オブジェクトを跨いで原因を推論できるか」を見せる点は共通ですが、
障害の見た目・原因の種類をあえて変えることで、単調にならないようにしています。
デモ4は視点を変えて、「エージェントを使う」から「エージェントを設計する」への
ステップアップを見せます。発表タイトルの「運用を標準化する」の回収パートです。

| デモ | 障害の見え方 | kagent が読むもの |
|---|---|---|
| 1 | Pod が再起動を繰り返す | Pod の exit code / ログ |
| 2 | Pod が起動すらしない | Pod の Event(イメージ取得エラー) |
| 3 | Pod は動いているのに繋がらない | Service / Endpoints / Pod label の関係 |
| 4 | (障害ではなく) 運用ルールをエージェント化 | システムプロンプト+ツール選択 |

## 進め方の方針

- **修復はすべてチャットでエージェントに指示する**。登壇者が kubectl で直す場面は作らない
- 登壇者がコマンドを打つのは次の2つだけ:
  - **障害の注入**(わざと壊すのは人間の仕込みとして行う)
  - **修復後の事実確認**(エージェントの報告を鵜呑みにせず裏取りする姿勢を見せる)
- 各所の「参考: 手動で行う場合」のコマンドは、エージェントが実行する内容の
  理解用+デモが滞った場合の保険として残してある

前提:
- `create-kind-cluster.sh`(または OKE 版)で環境構築済み
- `kagent` UI に `kubectl port-forward -n kagent svc/kagent-ui 8080:8080` でアクセス済み
- `demo-app` namespace に `demo-web` と `demo-crashloop` が存在する
- `manifests/30-demo-imagepull.yaml` がある(ImagePullBackOff 用)
- `manifests/40-demo-service-mismatch.yaml` と `manifests/41-demo-service-restore.yaml` がある

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

## 3. チャットで修復させる

原因の要約が返ってきたら、そのまま同じセッションで修復まで指示する。

### 画面で入力する依頼文
```text
原因は分かりました。demo-crashloop Deployment のコンテナの command を
"sleep infinity" に変更して、修復してください。
修復後、Pod が Running になったことも確認して報告してください。
```

### 話すこと
- 調査と修復が**同じチャットの流れの中で**完結する
- エージェントが patch を実行し、rollout の結果まで自分で確認して報告する
- 人間は「何をするか」を決め、実行はエージェントに任せる、という分担

### 参考: 手動で行う場合のコマンド(エージェントが実行する内容と同等)
```bash
kubectl patch deployment demo-crashloop -n demo-app --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","sleep infinity"]}
]'
kubectl rollout status deployment/demo-crashloop -n demo-app
```

## 4. 修復後の確認

エージェントの報告を受けたら、裏取りとして手元でも確認して見せる。
(「AI の報告を鵜呑みにせず、事実で確認する」姿勢を見せる意図)

```bash
kubectl get pods -n demo-app -l app=demo-crashloop
```

### 話すこと
- もう `CrashLoopBackOff` ではない。エージェントの報告と実際の状態が一致している
- 調査 → 修復 → 確認までチャットだけで完結し、最後に人間が事実確認する型

---

# デモ2: ImagePullBackOff の原因調査と修復

CrashLoopBackOff とは違い、**コンテナが一度も起動しない**障害です。
「壊れたコードが動いて落ちる」のではなく「そもそも取ってこられない」ことを
kagent が Event から読み取れるかを見せます。運用現場での発生頻度が高く、
観客にも馴染みのある障害なので、CrashLoopBackOff との対比として効果的です。

## 0. 障害を注入する

```bash
kubectl apply -f manifests/30-demo-imagepull.yaml
kubectl get pods -n demo-app -l app=demo-imagepull -w
```

### 話すこと
- `demo-imagepull` は存在しないイメージタグを指定してある
- Pod が `ContainerCreating` のまま止まり、やがて `ImagePullBackOff` になる
- CrashLoopBackOff と違い、**コンテナは一度も起動していない**点がポイント

## 1. 現状確認

```bash
kubectl get pods -n demo-app -l app=demo-imagepull
kubectl describe pod -n demo-app -l app=demo-imagepull
```

### 話すこと
- `describe` の Events に `Failed to pull image` 系のメッセージが出ている
- ログではなく Event を見る必要がある障害だと気づいてほしい

## 2. kagent に原因を調べさせる

### 画面で入力する依頼文
```text
demo-app namespace の demo-imagepull Pod が起動しません。
Events を確認して、なぜ起動できないのかを要約してください。
```

### 話すこと
- ログが空でも、Event から原因を引き出せるかを見る
- 「イメージタグが存在しない」まで具体的に言い当てられれば成功
- CrashLoopBackOff(ログ起因)と ImagePullBackOff(Event起因)で、
  kagent が見る情報源を自分で切り替えている点に注目してほしい

## 3. チャットで修復させる

### 画面で入力する依頼文
```text
原因は存在しないイメージタグですね。
demo-imagepull Deployment のイメージを nginx:1.27-alpine に変更して修復し、
Pod が Running になったことを確認して報告してください。
```

### 話すこと
- デモ1と同じく、調査の会話の延長で修復まで指示する
- `ImagePullBackOff` から `Running` に変わったという報告が返る
- 障害の種類が違っても「調べて → 直して」という対話の型は同じ

### 参考: 手動で行う場合のコマンド(エージェントが実行する内容と同等)
```bash
kubectl set image deployment/demo-imagepull -n demo-app \
  demo-imagepull=nginx:1.27-alpine
kubectl rollout status deployment/demo-imagepull -n demo-app
```

## 4. 修復後の確認

```bash
kubectl get pods -n demo-app -l app=demo-imagepull
```

### 話すこと
- Pod が正常に起動し、Restarts も 0 のままであることを事実確認する

---

# デモ3: Service と Pod のつながりを確認するデモ

デモ1・2は「1つの Pod の中で何が起きているか」でしたが、
このデモは**複数リソースをまたいだ関係**を kagent が読み解けるかを見せます。
Pod 自体は正常なのに繋がらない、という運用でありがちな地味な障害を、
kagent が Service / Endpoints / Pod label を突き合わせて説明できるかがポイントです。

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

```bash
kubectl apply -f manifests/40-demo-service-mismatch.yaml
```

```bash
kubectl get endpoints -n demo-app demo-web
kubectl describe svc -n demo-app demo-web
kubectl get pods -n demo-app -o wide
```

### 話すこと
- Service の selector をずらして、不整合を意図的に作る
- Pod は動いているのに Service から届かない状態にする
- ログやイベントには何も出ない「見えない障害」であることを強調する
  (だからこそ、人手で見つけにくく、kagent の見どころになる)

## 3. kagent に調べさせる

### 画面で入力する依頼文
```text
demo-app namespace の demo-web Service が Pod に届かない理由を調べてください。
Service selector, Pod label, endpoints の観点で確認してください。
```

### 話すこと
- Pod 単体ではなく、Service / Deployment / Pod の関係を見たい
- selector の不一致や endpoint 不在を見抜けるかを確認する
- デモ1・2が「単一オブジェクトの原因調査」なら、これは「関係性の調査」

## 4. チャットで復旧させる

### 画面で入力する依頼文
```text
selector の不一致が原因ですね。
demo-web Service の selector を、実際に稼働している Pod のラベルに合わせて
修正してください。修正後、endpoints に Pod が復帰したことを確認して
報告してください。
```

### 話すこと
- **修正内容を具体的に指示していない**点がデモ1・2との違い。
  「Pod のラベルに合わせて」という意図だけ伝え、正しい値の特定は
  エージェント自身にやらせる
- Service / Pod / Endpoints を跨いだ「関係の修復」ができることを見せる
- endpoints 復帰の報告が返れば復旧成功

### 参考: 手動で行う場合(保険としてもこれを使う)
```bash
kubectl apply -f manifests/41-demo-service-restore.yaml
kubectl get endpoints -n demo-app demo-web
```

## 5. 修復後の確認

```bash
kubectl get endpoints -n demo-app demo-web
kubectl describe svc -n demo-app demo-web
```

### 話すこと
- endpoint が復活していることを事実確認する
- つながりの調査 → 復旧 → 確認まで、チャットの対話で一巡した

---

# デモ4: 自作エージェントを UI から作る(運用の標準化)

デモ1〜3は「用意されたエージェントを使う」でしたが、ここでは
**自分の運用ルールを持ったエージェントを、UI からその場で作ります**。
作るのは「demo-app 専属・読み取り専用の調査エージェント」です。

見せたいポイントは3つ:
- エージェント = システムプロンプト + モデル + ツール選択、という構造(スライドの再現)
- **ツールを読み取り系に絞る = 権限設計**。エージェントに「できないこと」を作れる
- 報告フォーマットの固定 = 属人化しがちな障害報告の**標準化**

## 1. UI からエージェントを作成する

kagent UI → Agents → **New Agent** を開き、以下を設定する。

### Identity(基本情報)
- **Agent name**: `demo-app-inspector`
- **Namespace**: `kagent` を選択する
  - ModelConfig と Tools は**エージェントと同じ namespace から解決される**。
    OCI の ModelConfig(`oci-genai-openai-compatible`)も kagent のツールも
    `kagent` namespace にあるため、ここを `demo-app` にすると
    モデルもツールも選択肢に出てこない。
  - 「demo-app 専属」という性格は、エージェントの居場所ではなく、
    この後の **Instructions と Tools 選択**で表現する。
- **Agent type**: `Declarative`(モデル+ツール+プロンプトで定義する既定の方式)
- **ADK runtime**: `Python`(既定のまま)
- **Description**: `demo-app namespace 専属の読み取り専用調査エージェント`
  - これは**内部メモで、モデルには渡らない**(Internal note only)。
    実際の振る舞いは次の Instructions で決まる。

### Model & behavior(モデルと振る舞い)
- **Agent Instructions(システムプロンプト)**: 初期テンプレートを消して下記をコピペ

```text
あなたは demo-app namespace 専属の Kubernetes 調査エージェントです。

ルール:
- 調査対象は demo-app namespace のみ。他の namespace は調査しない。
- get / describe / logs / events による調査のみを行う。
- リソースの変更(apply, patch, delete, scale)は絶対に実行しない。
  修復が必要な場合は、実行すべきコマンドを提案として提示するに留める。
- 回答は必ず日本語で、以下のフォーマットで報告する:

【状況】いま何が起きているか(1-2行)
【原因】なぜ起きているか(根拠となるログ・イベントを添えて)
【推奨アクション】実行すべきコマンドと、その効果
```

- **Model**: `oci-genai-openai-compatible` を選択
  (ここで「モデルも差し替え可能。今日は OCI Generative AI」と一言添える)
- **Stream model output** / **Service account (optional)**: 触らない(既定のまま)

### Tools(ツール)
**Add Tools & Agents** を押し、kagent ツールサーバーの一覧から**読み取り系のみ**を選ぶ。

ツールは `kagent-tool-server` の中にある `k8s_*` を使う。

選択する(read-only):
- `k8s_get_resources` … Pod / Service / Endpoints / Deployment 等の取得(全デモ共通)
- `k8s_get_resource_yaml` … selector / label を YAML で確認(デモ3)
- `k8s_describe_resource` … describe 相当(全デモ共通)
- `k8s_get_events` … Event 確認(デモ2 の ImagePullBackOff)
- `k8s_get_pod_logs` … Pod ログ(デモ1 の CrashLoop)
- `k8s_check_service_connectivity` … Service ↔ Pod の疎通確認(デモ3)
- (任意)`k8s_get_available_api_resources` / `k8s_get_cluster_configuration`
- (任意)`k8s_generate_resource` … 修復用マニフェストを**生成するだけ**(適用はしない)

選択しない(mutating = 変更系。読み取り専用にするため必ず外す):
- `k8s_apply_manifest` / `k8s_create_resource` / `k8s_create_resource_from_url`
- `k8s_patch_resource` / `k8s_patch_status` / `k8s_delete_resource`
- `k8s_scale` / `k8s_rollout`
- `k8s_label_resource` / `k8s_remove_label` / `k8s_annotate_resource` / `k8s_remove_annotation`
- `k8s_execute_command`(Pod 内でコマンド実行=変更になりうるため外す)

### その他のセクション(すべて既定のまま)
- **Long-term memory** / **Context(Event Compaction)** / **Skills** は
  このデモでは使わないため、何も設定しない。

最後に **Create Agent** を押すと、エージェントが Kubernetes 上にデプロイされる。

### 話すこと
- いま YAML を1行も書いていない。UI の入力がそのまま Agent リソースになる
- ツールを選ばなかった操作は、このエージェントには**物理的にできない**
- 「するな」とプロンプトで頼むのではなく、能力自体を与えないのが権限設計
- 「調査対象は demo-app」だがエージェント自体は `kagent` に置く。
  監視対象と、エージェントの居場所は別物、という設計の話も一言添えられる

## 2. デプロイされたことを確認する

```bash
kubectl get agents.kagent.dev -n kagent
kubectl get pods -n kagent | grep demo-app-inspector
```

### 話すこと
- UI で作ったエージェントが Agent リソース + Pod として稼働している
- kubectl で見える = 普段の Kubernetes 運用の延長で管理できる
- GitOps に乗せるなら、この Agent リソースを YAML としてリポジトリ管理すればよい

## 3. 同じ質問を、k8s-agent と自作エージェントに投げ比べる

事前に障害を仕込み直す(デモ1で修復済みのため):

```bash
kubectl apply -f manifests/20-demo-fault-crashloop.yaml
```

### 画面で入力する依頼文(両エージェントに同じ文面・それぞれ新しいセッションで)
```text
demo-app namespace で問題のある Pod を調べて、対応方法を教えてください。
```

### 話すこと
- k8s-agent: 汎用的で丁寧だが、形式は毎回変わる
- demo-app-inspector: 必ず【状況】【原因】【推奨アクション】の型で返る
- **誰が聞いても同じ型の報告が返る = 運用の標準化**。
  チームの障害報告テンプレートをエージェントに埋め込んだのと同じこと

## 4. 読み取り専用の縛りを確認する(ダメ押し)

### 画面で入力する依頼文(demo-app-inspector に)
```text
では、その Pod を直してください。
```

### 話すこと
- 修復コマンドの「提案」は返すが、実行はしない(できない)
- 本番クラスタに導入するとき、この設計ができるかどうかが安心感の分かれ目
- 「調査は AI に任せ、変更は人間が承認して実行する」という運用の型を作れる

## 補足(リハーサル時の保険)

UI での作成が本番で滞った場合に備え、リハーサルで一度作成した後に
YAML をエクスポートしておく:

```bash
kubectl get agents.kagent.dev demo-app-inspector -n kagent -o yaml \
  > manifests/60-demo-custom-agent-backup.yaml
```

本番で UI 操作に手間取ったら `kubectl apply -f` で即座に同じエージェントを
再現できる(このバックアップ自体が「エージェントはただの Kubernetes
リソース」という主張の証明にもなる)。

---

# デモの締め

### 話すこと
- デモ1では、ログから原因を特定し、チャットの指示だけで修復する流れを見せる
- デモ2では、ログではなく Event から原因を特定し、同じ対話の型で修復する
- デモ3では、複数リソースの関係を読み解かせ、意図だけ伝えて修復させる
- デモ4では、運用ルールを持った自作エージェントを UI から数分で作れることを見せる
- 一連を通して、登壇者は一度も修復コマンドを打っていない。
  人間の役割は「意図の指示」と「結果の事実確認」に変わる

### 追加で言うとよい一言
```text
今日のデモで、私は障害を仕込むコマンドと確認コマンドしか打っていません。
調査も修復も、すべてチャットの対話でエージェントが行いました。
そしてデモ4のとおり、その振る舞い自体をチームのルールとして設計できる。
これが「kagent で Kubernetes 運用を標準化する」ということです。
```
