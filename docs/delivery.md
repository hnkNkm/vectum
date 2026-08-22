# Destination と配送

## Destination

```toml
[[destinations]]
name = "ci"
type = "http"
url = "https://ci.internal/events"
timeout_ms = 5000
```

v0.1 の `type` は `http` のみ。配送は `POST`。

付与するヘッダ:

- `Content-Type: application/json`
- `X-Event-Id`
- `Idempotency-Key`（Event ID と同じ値）
- Destination に HMAC がある場合は `hmac_header`（既定 `X-Vectum-Signature`）

`timeout_ms` を省略すると `[delivery].timeout_ms`（既定 10000）を使う。

## Delivery 意味論

- 保証は **at-least-once**。exactly-once は提供しない
- Destination は `X-Event-Id` で冪等に処理することを推奨する
- タイムアウトしたリクエストは成功扱いにしない
- 2xx のみ成功。3xx はリダイレクトせず失敗
- 接続失敗、DNS 失敗、TLS 失敗は retry 対象

## Retry

```toml
[delivery]
max_attempts = 8
initial_backoff_ms = 1000
max_backoff_ms = 60000
timeout_ms = 10000
jitter = true
concurrency = 8
```

| 条件 | 扱い |
| --- | --- |
| HTTP 2xx | success |
| HTTP 408 / 429 / 5xx | retry |
| timeout / connection error | retry |
| その他 4xx / 3xx | fail（dead letter へ） |

Backoff は exponential + equal jitter。上限は `max_backoff_ms`（既定 60s）。`Retry-After` は v0.1 では未対応。

並列数は `concurrency`（既定 8）。Destination 単位の Supervisor ではなく、共有 worker pool が SQLite から due Delivery を claim する。

## Dead Letter

最大 retry 後も成功しない Delivery は `dead_letter` に移す。CLI で一覧、再試行、削除できる。自動再配送はしない。

## 状態

```text
pending → delivering → success
                   ├→ retry_scheduled → pending
                   └→ dead_letter
```

起動時は `delivering` を `pending` に戻す。
