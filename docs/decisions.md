# v0.1 の実装判断

仕様ドラフト §30 の未決事項は次のように固定した。

| 項目 | 決定 |
| --- | --- |
| 正式名称 / CLI | `vectum` |
| Event ID | UUID v7 (`youid`) |
| JSON 内部表現 | `EventValue`（Null / Bool / Int / Float / String / Array / Object） |
| HTTP Server | [mist](https://hex.pm/packages/mist) |
| HTTP Client | inets `httpc` 直接呼び出し(`vectum_httpc_ffi.erl`)。`{autoretry, 0}` / 証明書検証を明示(F1) |
| SQLite | [sqlight](https://hex.pm/packages/sqlight) |
| TOML | [tom](https://hex.pm/packages/tom) |
| HMAC | [gleam_crypto](https://hex.pm/packages/gleam_crypto) SHA-256。Source 既定は GitHub 互換 `sha256=<hex>` |
| Worker | Destination 単位ではなく、共有 worker pool + SQLite からの claim |
| Retention | `[retention]` で 0 より大きい日数を指定した区分だけ自動削除する。dispatcher が 1 時間に最大 1 回、succeeded / dead_letter の Delivery と孤児 Event を 1 トランザクションで削除。手動実行は `vectum prune [--dry-run]`。0 / 未設定は無期限保持(#30) |
| Source 認証 | Source ごとの HMAC(`hmac_secret` / `hmac_secret_env`)と / または Bearer Token(`auth_bearer` / `auth_bearer_env`)。両方設定時は両方の合格が必要(AND、#38) |
| Destination 秘密情報 | HMAC は `hmac_secret` / `hmac_secret_env`、Bearer Token は `auth_bearer` / `auth_bearer_env`(#38) |
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
| 滞留 reaper | delivering を「実効タイムアウトの最大値 ×2(最低 10 秒)」より古ければ滞留と見なし、10 秒間隔でチェックして pending に戻す。二重配送は at-least-once の範囲内 |
| Metadata フィルタ | `metadata.<key>` プレフィックスでヘッダ由来の Metadata を条件にする(プレフィックス無しは Data) |
| 起動時復旧 | プロセス起動時に一度だけ全件復旧する。actor 再起動では復旧せず reaper に委ねる(実行中ワーカーとの即時二重送信を避ける) |
