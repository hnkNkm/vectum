# vectum

> A lightweight, reliable, self-hosted event router built with Gleam and BEAM, designed for cloud, on-premise, and edge environments.

Gleam / BEAM で構築された、クラウド・オンプレミス・エッジ環境向けの軽量 self-hosted Event Router です。

外部システムから HTTP でイベントを受信し、共通 Envelope に正規化したうえで、TOML で宣言したルーティングルールに従って複数の HTTP Destination へ配送します。外部データベースは不要で、SQLite のみで At-least-once delivery、retry、dead-letter を提供します。

Amazon EventBridge の完全互換実装ではありません。Kafka / RabbitMQ / Camel の代替でもありません。小さな Webhook 集約やオンプレ連携には過剰だが、大規模バスはまだ早い、という用途向けです。

詳細仕様は [spec.md](./spec.md) を参照してください。

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

```sh
cp examples/router.toml router.toml
gleam run -- run --config router.toml
```

別ターミナルからイベントを投入します。

```sh
curl -i -X POST http://127.0.0.1:8080/events/github \
  -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: push' \
  -d '{"repository":{"name":"backend"},"ref":"refs/heads/main"}'
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

```sh
docker build -t vectum:0.1.0 .
docker run --rm -p 8080:8080 \
  -v ./router.toml:/app/router.toml:ro \
  -v ./data:/data \
  vectum:0.1.0
```

## v0.1 での実装判断

仕様 §30 の未決事項は次のように固定しています。

| 項目 | 決定 |
| --- | --- |
| 正式名称 / CLI | `vectum` |
| Event ID | UUID v7 (`youid`) |
| JSON 内部表現 | `EventValue` (Null / Bool / Int / Float / String / Array / Object) |
| HTTP Server | [mist](https://hex.pm/packages/mist) |
| HTTP Client | [gleam_httpc](https://hex.pm/packages/gleam_httpc) |
| SQLite | [sqlight](https://hex.pm/packages/sqlight) |
| TOML | [tom](https://hex.pm/packages/tom) |
| HMAC | [gleam_crypto](https://hex.pm/packages/gleam_crypto) SHA-256。Source は GitHub 互換 `sha256=<hex>` |
| Worker | Destination 単位ではなく、共有 worker pool + SQLite からの claim |
| Retention | v0.1 では自動削除しない |
| Source 認証 | Source ごとの HMAC。`hmac_secret` または `hmac_secret_env` |
| Destination 秘密情報 | `hmac_secret` / `hmac_secret_env` |
| Metrics | `GET /metrics` の Prometheus テキスト |
| Hot reload | なし (再起動で再読込) |
| Payload 上限 | 既定 1 MiB (`server.max_body_bytes`) |
| 配送並列数 | 既定 8 (`delivery.concurrency`) |
| Dedup | 同一 Event × Destination は Delivery 1 件 |

## ライセンス

Apache-2.0
