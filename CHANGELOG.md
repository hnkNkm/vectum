# Changelog

## Unreleased

- Source / Destination に Bearer Token 認証を追加（`auth_bearer` / `auth_bearer_env`）。Source は受信時に `Authorization: Bearer <token>` を定数時間比較で検証し、欠落・不一致は `401`。Destination は配送時に同ヘッダを付与する。HMAC と併用時は Source が AND（両方合格が必要）、Destination は両ヘッダ送信。token はログ・Metadata・エラーに載せない(#38)
- ルーティングフィルタに OR / grouped condition(`[routes.condition]`)を追加。group ノード(`op` = `all` / `any`)と leaf(従来の filter 形)をネストして `A OR B` や `(A AND B) OR C` を表現できる。`[[routes.filters]]` との併設はエラー、group のネストは最大 4 段、評価は設定順で短絡する(#36)
- CI に build・example 設定の `validate`・E2E smoke(`scripts/e2e_smoke.sh`)ジョブを追加。Ingress の HTTP テストは固定ポートではなく OS 割り当ての一時ポートで実行するようにした
- Read-only 運用 CLI(`status` / `events list|show` / `deliveries list|show`)を追加。SELECT のみで状態を変えず、`--limit` 既定 50・上限 1000。存在しない ID は非 0 終了(#31)
- Source の `path` によるカスタム受信パスを実装。未指定時は従来どおり `/events/<name>`。未知パス・他 Source のパスは 404(#39)
- 空の `hmac_header` を設定検証でエラーにした(F4)
- SQLite を `synchronous = full` で運用し、各コミットを fsync する完全永続化にした(F3)
- httpc の自動リトライを無効化し、`Retry-After` による暗黙リトライを止めた。配送のリトライは vectum の backoff に一元化。Destination への TLS 接続は証明書検証を明示的に有効化(F1)
- retry 対象の応答 (408/429/5xx) で `Retry-After` を尊重するようにした。delta-seconds / HTTP-date に対応し、有効なら backoff・jitter の代わりにサーバ指定時刻 (`now + delay`、jitter なし) へ次回試行を予約する。上限は 24h (`retry_after_max_ms`) で、超過はクランプして last_error に記録。ヘッダなし・不正は従来の exponential backoff へ、過去の HTTP-date は 0ms (即時) として扱う(#37)
- claim 世代トークンによる fencing を導入。`claim_due` は `updated_at` を必ず直前の値より進め(`max(?, updated_at + 1)`)、`mark_success` / `mark_retry` / `mark_dead` は claim 時の token が現在値と一致する行にだけ効く。reaper で奪取された旧ワーカーの遅延完了は 0 件になり、新しい claim の結果を上書きしない(F2)
- 開発者向けガイド AGENTS.md を追加し、現行実装(障害時再起動・recover・reaper 等)に追従させた(#74)
- Dispatcher がワーカーを `spawn_unlinked` で生成し、ワーカー panic 時も concurrency 枠と slot を確実に解放するよう変更。Dispatcher 側のクラッシュでもワーカーを巻き込まない(#43)
- Storage への呼び出しを `try_call` + monitor 化し、actor 側の失敗・クラッシュでも Dispatcher / CLI が panic しないようにした(#44)
- Ingress で chunked `Transfer-Encoding` を `413` で拒否するようにした(#45)
- `claim_due` を単一 `UPDATE … RETURNING` 化し、失敗時は rollback する原子的な claim に変更(#47)
- SQLite に `journal_mode=wal` と `busy_timeout` を設定し、並行書き込みの競合を緩和(#49)
- 破損した event 行は `null` 配送せずエラー扱いにした(#50)
- `mark_success` / `mark_retry` / `mark_dead` に `delivering` ガードと `delivery_stale` 検知を追加し、古いワーカーの遅延完了が新しい claim を上書きしないようにした(#48,#61,#69)
- graceful shutdown 時に受付中の in-flight POST の完了を待つようにした(#55)
- Ingress の Content-Type 照合をメディア型の完全一致にし、空 event-type を拒否するようにした(#66)
- フィルタの Int 精度を扱い、`neq` 演算子と Metadata フィールドをサポート(#65)
- ログの時刻を JSON 準拠の形式で出力するようにした(#64)
- CLI の `--config` / 環境変数解決を堅牢化し、不明なオプションや不正な組み合わせをエラーにした(#67)
- 空の HMAC secret を設定時に拒否するようにした(#46,#63)
- README のクイックスタート手順を実挙動に合わせて修正(#62)
- mist の bind 失敗時はエラーメッセージを出して終了するようにした(#60)
- CLI の dead 操作で storage のみを開くようにし、起動に不要な配送 worker を立てないようにした(#59)
- 空の destinations リストを設定検証でエラーにした(#58)
- `delivery_latency_seconds` ヒストグラムを追加。配送レイテンシを `_bucket{le=…}` / `_sum` / `_count` で公開する(境界 5 ms〜10 s の固定 11 点 + `+Inf`)。`delivery_latency_milliseconds_sum` / `_count` は後方互換のため維持(#42)
- ワーカーが panic しても concurrency 枠を確実に解放するよう変更。枠漏れによる配送停止を防止(#26)
- Metadata フィルタのキー照合を大小文字非依存に変更(`metadata.X-GitHub-Event` と `metadata.x-github-event` が同義)(#27)
- spec-compliance の「次に埋めるなら」を整理し、将来候補は roadmap.md を参照する形にした(#28)
- ドキュメント修正: event-model.md の Event Type 設定キーを実装(`type_from_header` / `type_from_json`)に一致させた。Docker 既定設定の Destination がプレースホルダであること・公開時は HMAC が必須であることを README / operations.md に追記。メトリクスが再起動でリセットされることを observability.md に明記
- フィルタに `metadata.<key>` プレフィックスを追加。HTTP ヘッダ由来の Metadata を条件に振り分けできるようになった(例: `path = "metadata.x-github-event"`)。仕様の Field Filtering を満たす
- `vectum dead retry` / `dead delete` で該当 ID の `dead_letter` が存在しない場合にエラー終了するようにした(以前は無関係でも成功扱い)
- `mark_success` / `mark_retry` / `mark_dead` を `delivering` 状態の行に限定。reaper 後の旧ワーカーの遅延完了が新しい claim の結果を上書きしない
- `delivery.concurrency` を実行中ワーカー数の上限として動作させるようにした(以前は 1 tick あたりの claim 数だった)。遅い Destination でもワーカーが増殖しない
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
