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
