# Changelog

## 0.1.0 - 2026-08-23

最初のリリース。Gleam / BEAM 上の self-hosted Event Router として、仕様 v0.1 の必須機能を提供します。

- HTTP Ingress (`POST /events/:source`) と `202 Accepted` (永続化後)
- HTTP Destination (POST) と共通 Event Envelope
- TOML による宣言的ルーティング、フィールドフィルタ、fan-out
- 同一 Event × Destination の Delivery 重複排除
- Exponential backoff + jitter、timeout、dead letter
- SQLite 永続化と起動時の未完了 Delivery 復元
- HMAC-SHA256 検証 / 署名 (環境変数参照可)
- Prometheus 互換 `/metrics`、`/health`、`/ready`
- CLI: `run` / `validate` / `dead list|retry|delete`
