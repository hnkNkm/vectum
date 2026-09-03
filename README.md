# vectum

> A lightweight, reliable, self-hosted event router built with Gleam and BEAM, designed for cloud, on-premise, and edge environments.

Gleam / BEAM で構築された、クラウド・オンプレミス・エッジ環境向けの軽量 self-hosted Event Router です。

外部システムから HTTP でイベントを受信し、共通 Envelope に正規化したうえで、TOML で宣言したルーティングルールに従って複数の HTTP Destination へ配送します。外部データベースは不要で、SQLite のみで At-least-once delivery、retry、dead-letter を提供します。

Amazon EventBridge の完全互換実装ではありません。Kafka / RabbitMQ / Camel の代替でもありません。小さな Webhook 集約やオンプレ連携には過剰だが、大規模バスはまだ早い、という用途向けです。

詳細仕様は [docs/](./docs/README.md) を参照してください。v0.1 の充足状況は [docs/spec-compliance.md](./docs/spec-compliance.md) です。

## 特徴 (v0.1)

- HTTP Ingress (`POST /events/:source`)
- HTTP Destination (POST)
- JSON Event と共通 Envelope
- 宣言的ルーティング / フィールドフィルタ / fan-out
- Exponential backoff + jitter による retry
- Dead letter と CLI からの再配送
- SQLite 永続化 (外部 DB 不要)
- HMAC 検証 / 署名
- Prometheus 互換メトリクス
- TOML 設定と CLI
- オフライン / 閉域網で運用可能
- SIGTERM / SIGINT での graceful shutdown

## 必要環境

- Gleam 1.18+
- Erlang/OTP 27+
- SQLite (開発時は Nix flake が提供)

Nix を使う場合:

```sh
direnv allow   # または nix develop
gleam test
```

## クイックスタート

秘密情報なしで設定検証だけする場合:

```sh
gleam run -- validate --config examples/minimal.toml
```

HMAC 付きの例は `examples/router.toml` です (`.env.example` を参照)。

```sh
cp examples/minimal.toml router.toml
gleam run -- run --config router.toml
```

別ターミナルからイベントを投入します (`minimal.toml` の source `internal` 宛)。

```sh
curl -i -X POST http://127.0.0.1:8080/events/internal \
  -H 'Content-Type: application/json' \
  -d '{"type":"deploy","repository":{"name":"backend"},"ref":"refs/heads/main"}'
```

永続化完了後に `202 Accepted` が返ります。

## CLI

バイナリ名はプロジェクト名に合わせて `vectum` です (仕様上の仮称 `router` は使いません)。

```sh
vectum run --config router.toml
vectum validate --config router.toml
vectum dead list --config router.toml
vectum dead retry <delivery-id> --config router.toml
vectum dead delete <delivery-id> --config router.toml
```

開発中は `gleam run --` のあとに同じサブコマンドを渡せます。

```sh
gleam run -- validate --config examples/router.toml
```

## 設定

標準ファイル名は `router.toml` です。完全な例は [examples/router.toml](./examples/router.toml) を参照してください。

```toml
[server]
host = "0.0.0.0"
port = 8080

[storage]
path = "./router.db"

[[sources]]
name = "github"
path = "/events/github"
type_from_header = "X-GitHub-Event"

[[destinations]]
name = "audit"
type = "http"
url = "http://127.0.0.1:9090/events"

[[routes]]
name = "github-push"
source = "github"
event = "push"
destinations = ["audit"]

[delivery]
max_attempts = 8
timeout_ms = 10000
initial_backoff_ms = 1000
max_backoff_ms = 60000
jitter = true
```

起動時に設定全体を検証し、不正があればプロセスを終了します。

> Source の `path` キーは現在未使用です。受信 URL は常に `/events/<name>` 固定です(将来のカスタムパス対応に備えた記録用キー)。

> Source の `path` キーは現在未使用です。受信 URL は常に `/events/<name>` 固定です(将来のカスタムパス対応に備えた記録用キー)。

## HTTP API

| Method | Path | 説明 |
| --- | --- | --- |
| `POST` | `/events/:source` | イベント受信。永続化後に `202` |
| `GET` | `/health` | プロセス生存 |
| `GET` | `/ready` | SQLite に到達できること |
| `GET` | `/metrics` | Prometheus テキスト |

受信時の `4xx`:

- `404` Unknown Source
- `400` Invalid JSON / Missing Event Type
- `401` HMAC 検証失敗
- `413` Payload Size Exceeded
- `415` Invalid Content-Type

Destination へは共通 Envelope を POST し、次のヘッダを付与します。

```http
X-Event-Id: <event-id>
Idempotency-Key: <event-id>
Content-Type: application/json
```

配送保証は **at-least-once** です。Consumer は `X-Event-Id` で重複排除できます。

## 開発

```sh
gleam test                 # 全テスト
gleam test -- --target-logs  # (gleeunit)
gleam format --check src test
gleam build
```

コア (Event / Filter / Route / Config / HMAC / Retry / Storage) は HTTP や OTP に依存しない純関数・永続化層としてテストします。Ingress / Dispatcher はスタブ HTTP クライアントで検証します。

## コンテナ

イメージ既定の設定は `examples/docker.toml` で、SQLite は `/data/router.db` に書きます。独自設定を載せる場合も `storage.path` を `/data` 配下にしてください。既定の Destination は動作確認用プレースホルダのため、上書きしない限り配送は失敗します。コンテナを公開する場合は Source への HMAC 設定が必須です。

```sh
docker build -t vectum:0.1.0 .
docker run --rm -p 8080:8080 \
  -v ./data:/data \
  vectum:0.1.0
```

設定を上書きする場合:

```sh
docker run --rm -p 8080:8080 \
  -e VECTUM_CONFIG=/config/router.toml \
  -v ./router.toml:/config/router.toml:ro \
  -v ./data:/data \
  vectum:0.1.0
```

## v0.1 での実装判断

名称、ライブラリ、Worker 粒度などの固定事項は [docs/decisions.md](./docs/decisions.md) にあります。

## ライセンス

Apache-2.0
