# v0.1 の実装判断

仕様ドラフト §30 の未決事項は次のように固定した。

| 項目 | 決定 |
| --- | --- |
| 正式名称 / CLI | `vectum` |
| Event ID | UUID v7 (`youid`) |
| JSON 内部表現 | `EventValue`（Null / Bool / Int / Float / String / Array / Object） |
| HTTP Server | [mist](https://hex.pm/packages/mist) |
| HTTP Client | [gleam_httpc](https://hex.pm/packages/gleam_httpc) |
| SQLite | [sqlight](https://hex.pm/packages/sqlight) |
| TOML | [tom](https://hex.pm/packages/tom) |
| HMAC | [gleam_crypto](https://hex.pm/packages/gleam_crypto) SHA-256。Source 既定は GitHub 互換 `sha256=<hex>` |
| Worker | Destination 単位ではなく、共有 worker pool + SQLite からの claim |
| Retention | 自動削除しない |
| Source 認証 | Source ごとの HMAC。`hmac_secret` または `hmac_secret_env` |
| Destination 秘密情報 | `hmac_secret` / `hmac_secret_env` |
| Metrics | `GET /metrics` の Prometheus テキスト |
| Hot reload | なし（再起動で再読込） |
| Payload 上限 | 既定 1 MiB（`server.max_body_bytes`） |
| 配送並列数 | 既定 8（`delivery.concurrency`） |
| Dedup | 同一 Event × Destination は Delivery 1 件 |

設定キーはドラフト例に合わせ、`type_from_header` / `type_from_json` / `destinations = [...]` を採用した。

追加の固定事項:

| 項目 | 決定 |
| --- | --- |
| Envelope の時刻キー | 配線 JSON は `time`。Gleam のフィールド名は `timestamp` |
| Dispatcher 内部エラー | Event 取得失敗や未知 Destination も HTTP 接続失敗と同じ retry ポリシー（backoff / `max_attempts` / dead letter） |
| `dead retry` | `attempts` を 0 に戻し、full backoff をやり直す |
| Docker の SQLite | `/data/router.db`。実行ユーザー `vectum` が書ける場所に限定する |
| Graceful shutdown | SIGTERM / SIGINT で受付停止 → 実行中ワーカーの完了待ち(既定 10 秒、`VECTUM_SHUTDOWN_GRACE_MS`)→ 終了。listen socket は close せず 503 応答で drain |
| Supervisor 木 | static_supervisor(one_for_one)配下に Storage / Metrics / Dispatcher を permanent 配置。参照は persistent_term の registry で共有し、再起動後の Subject に自動追従 |
