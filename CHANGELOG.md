# Changelog

## Unreleased

- レビューの残り指摘: architecture.md に起動時のみ recover する旨を追記。reaper 閾値の単体テストを追加。一時 DB を `tmp/` に移し、復旧テストは同一 Delivery の再開で検証する
- レビュー指摘対応: Storage actor 再起動時に `recover()` を実行しないように変更。全件復旧はプロセス起動時のみ(`storage.open_and_recover`)。実行中ワーカーとの即時二重配送を防止し、滞留は reaper に一任
- reaper の滞留閾値に Destination 個別タイムアウトを反映(各 Destination の実効タイムアウト最大値 ×2、最低 10 秒)
- シグナルハンドラのインストールを HTTP listen より前に移動し、起動直後の SIGTERM にも対応
- 運用ドキュメントに猶予時間とコンテナ stop timeout の関係、`halt(0)` による終了の範囲を追記
- 滞留 delivering を検出して再開する reaper を dispatcher に追加。10 秒間隔でチェックし、「配送タイムアウト ×2(最低 10 秒)」より古いものを pending に戻す。メトリクス `deliveries_reaped_total` とログ `delivery_reaped` で観測可能
- Storage / Metrics / Dispatcher を OTP Supervisor(one_for_one)配下に置き、クラッシュ時に自動再起動するようにした。参照は registry(persistent_term)経由で共有し、Ingress / Dispatcher は再起動後の actor に自動追従する
- SIGTERM / SIGINT での graceful shutdown を追加。受付 503 化、dispatcher の claim 停止、実行中ワーカーの完了待ち(既定 10 秒、`VECTUM_SHUTDOWN_GRACE_MS` で変更)
- Envelope の JSON キーを仕様どおり `time` に揃えた
- Dispatcher 内部エラーでも `[delivery]` の backoff と `max_attempts` を使う
- `vectum dead retry` で `attempts` を 0 に戻す
- Docker 既定設定の SQLite を `/data/router.db` にした

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
