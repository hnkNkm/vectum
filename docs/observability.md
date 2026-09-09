# 観測

## ログ

構造化 JSON 1 行を標準出力へ出す。

```json
{"level":"info","msg":"event_accepted","event_id":"...","source":"github","event_type":"push"}
```

時刻は `time` キーに RFC 3339 形式で出力する。

主なメッセージ (いずれも `msg` フィールドの値):

- `listening` — HTTP の listen を開始
- `event_accepted` — イベント受理(永続化後)
- `event_rejected` — イベント拒否(受理前)
- `persist_failed` — イベントの永続化失敗
- `delivery_worker_panic` — 配送ワーカーが panic(枠は解放される)
- `delivery_claim_failed` — claim_due の取得失敗
- `delivery_success` — 配送成功
- `delivery_retry` — retry スケジュール
- `delivery_failed` — 配送失敗(リトライ予定)
- `delivery_dead` — dead letter 移行
- `delivery_persist_failed` — 配送結果の永続化失敗
- `delivery_stale` — stale(古い)delivering 行を検知し mark を無視
- `delivery_reaped` — 滞留 delivering を pending に戻した(reaper)
- `reap_failed` — reaper の再開処理が失敗
- `invalid_shutdown_grace` — `VECTUM_SHUTDOWN_GRACE_MS` が不正
- `shutdown_started` — graceful shutdown 開始
- `shutdown_complete` — graceful shutdown 完了

## メトリクス

`GET /metrics` で Prometheus テキスト形式を返す。カウンタはメモリ保持のため、Metrics actor の再起動(Supervisor による自動復旧を含む)で 0 に戻る。永続化は将来検討。

| 名前 | 型 | 説明 |
| --- | --- | --- |
| `events_received_total` | counter | 永続化後に受理した数 |
| `events_rejected_total` | counter | 受理前に拒否した数 |
| `deliveries_total` | counter | 配送試行数 |
| `deliveries_success_total` | counter | 配送成功数 |
| `deliveries_retry_total` | counter | retry した数 |
| `deliveries_dead_total` | counter | dead letter 移行数 |
| `deliveries_reaped_total` | counter | 滞留 delivering の再開数(reaper) |
| `delivery_latency_milliseconds_sum` | counter | 配送レイテンシ合計（ミリ秒） |
| `delivery_latency_milliseconds_count` | counter | レイテンシ件数 |
| `delivery_latency_seconds` | histogram | 配送レイテンシ(秒)。`_bucket{le="…"}`(累積) / `_sum` / `_count`。境界はミリ秒で 5 / 10 / 25 / 50 / 100 / 250 / 500 / 1000 / 2500 / 5000 / 10000 + `+Inf`(#42) |
| `pending_deliveries` | gauge | 未完了 Delivery |

仕様ドラフトの候補名は `delivery_latency_seconds` ヒストグラムと `events_accepted_total` だった。`delivery_latency_seconds` ヒストグラムを実装し(#42)、ミリ秒の sum/count は後方互換のため残している。

p95 は `histogram_quantile` で出せる:

```promql
histogram_quantile(0.95, sum(rate(delivery_latency_seconds_bucket[5m])) by (le))
```

## Health

| パス | 意味 |
| --- | --- |
| `GET /health` | プロセス生存 |
| `GET /ready` | SQLite に到達できる。失敗時は `503` |
