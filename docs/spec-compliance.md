# 仕様準拠状況（v0.1）

結論: **v0.1 必須機能はほぼ満たしている。** 製品として起動・受理・配送・retry・dead-letter・CLI は動く。一方で Metadata フィルタとカスタム Source path は未達または部分実装。

対象仕様は [docs/](./README.md) 配下の文書です。

## 必須機能

| 機能 | 状態 | 備考 |
| --- | --- | --- |
| HTTP Event Ingress | 満たす | `POST /events/:source`。永続化後に 202 |
| HTTP Destination | 満たす | POST + Envelope |
| JSON Event | 満たす | |
| Common Event Envelope | 満たす | `id` / `source` / `type` / `time` / `data` / `metadata` |
| Source Identification | 満たす | URL の `:source` |
| Event Type Identification | 満たす | header / JSON / 固定値 |
| Declarative Routing | 満たす | TOML `[[routes]]` |
| Field Filtering | 部分 | Data は可。Metadata は不可 |
| Fan-out | 満たす | 複数 Destination + dest 重複排除 |
| Retry | 満たす | exp backoff + equal jitter |
| Timeout | 満たす | Destination または `[delivery].timeout_ms` |
| Dead Letter | 満たす | CLI から list / retry / delete |
| At-least-once Delivery | 満たす | 起動時に `delivering` を復旧 |
| SQLite Persistence | 満たす | 受理と Delivery 作成は同一 txn |
| HMAC Verification / Signing | 満たす | Source / Destination |
| Metrics | 満たす | 名前は実装判断どおり |
| TOML Configuration | 満たす | 起動時検証あり |
| CLI Operations | 満たす | コマンド名は `vectum` |
| Web UI | 対象外 | 未実装で正しい |
| MQTT / NATS / SQS / Kafka / WS | 将来 | 未実装で正しい |
| Distributed Cluster | 将来 | 未実装で正しい |

## 満たしている詳細

- 未知 Source は 404。HMAC 失敗は 401。Payload 超過は 413。非 JSON は 415
- フィルタ演算子 `eq` / `neq` / `gt` / `gte` / `lt` / `lte` / `contains` / `exists` / `not_exists`、dotted path、AND のみ
- 2xx 成功、408 / 429 / 5xx / timeout / 接続失敗は retry、その他 4xx / 3xx は dead letter
- Event 取得失敗や未知 Destination などの内部エラーも同じ backoff / `max_attempts` を適用する
- Destination へ `X-Event-Id` と `Idempotency-Key` を付与
- SIGTERM / SIGINT で受付停止(503)→ 実行中ワーカーの完了待ち → 終了。猶予は `VECTUM_SHUTDOWN_GRACE_MS`(既定 10 秒)
- Storage / Metrics / Dispatcher を static_supervisor(one_for_one, permanent)配下に置き、クラッシュ時に自動再起動する。参照は registry 経由で共有
- 実行中に滞留した delivering を dispatcher の reaper が定期的に検出して pending に戻す(閾値は実効タイムアウト最大値 ×2、最低 10 秒)
- `GET /health`、`GET /ready`、構造化 JSON ログ
- オフライン起動（Destination が Internet 上ならその通信のみ必要）
- HTTPS Destination は httpc TLS。Ingress TLS は reverse proxy 前提

## 未達・部分実装

| 項目 | 仕様 | 実装 |
| --- | --- | --- |
| Metadata フィルタ | Source / Type / Data / **Metadata** を条件にできる | フィルタは `event.data` のみ |
| Source `path` | 設定例にカスタム path | Ingress は `/events/:name` 固定。`path` キーは解析のみで照合には使わない(dead code は削除済み) |
| メトリクス名 | 候補 `events_accepted_total`、`delivery_latency_seconds` ヒストグラム | `events_received_total` とミリ秒の sum/count |
| CLI 名 | プレースホルダ `router` | 製品名 `vectum`（意図した差分） |
| モジュール配置 | 層分けの例 | `src/vectum/*.gleam` に平坦化（仕様も過剰な層は避けるとしている） |
| Docker マウント | 例 `-v ./router.toml:/app/router.toml` | `/config/router.toml` + `VECTUM_CONFIG`。DB は `/data/router.db` |
| `[log]` 設定 | レベル / 形式 | 常に JSON 1 行。設定キーは未読込 |
| RouteManager プロセス | OTP 上の独立 Process | プロセス内の純関数 |

## 正しく対象外にしているもの

Web UI、MQTT / NATS / SQS / Kafka / WebSocket、クラスタ、exactly-once、`status` / `events list` / `deliveries list`、Retry-After、ホットリロード、自動 retention、Transform Engine。

## 次に埋めるなら

1. Metadata をフィルタ対象にする
2. `sources.path` を Ingress 照合に使う、または仕様から外す
3. 存在しない dead-letter ID をエラーにする
4. Metrics actor 再起動時のカウンタ永続化(現状はリセット)
