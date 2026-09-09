# 永続化

v0.1 の正本は SQLite。外部 DB は必須にしない。既定パスは `./router.db`。

## 保存対象

- 受信 Event
- Delivery 状態
- Retry 情報
- Dead Letter

## スキーマ

```sql
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  event_type TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  payload TEXT NOT NULL,
  metadata TEXT NOT NULL
);

CREATE TABLE deliveries (
  id TEXT PRIMARY KEY,
  event_id TEXT NOT NULL REFERENCES events(id),
  destination TEXT NOT NULL,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  last_attempt_at INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(event_id, destination)
);
```

`UNIQUE(event_id, destination)` により同一 Event × Destination の重複配送レコードを防ぐ。

## トランザクション

Event 受理と Delivery 作成は同一トランザクション。永続化完了後にのみ `202` を返す。SQLite 接続は Storage actor が直列化する。

SQLite は WAL モードかつ `synchronous = full` で運用する。各コミットはディスクへの fsync 完了後にのみ応答へ進むため、`202` を返した時点で受理は電源断に対しても耐久(コミット後の停電・プロセス死亡でも失われない)。`succeeded` / `retry_scheduled` / `dead_letter` への遷移(配送結果の確定)も同じコミット経路で fsync される。

起動時は `delivering` を `pending` に戻し、クラッシュ直後の未完了配送を再開する。この全件復旧はプロセス起動時に一度だけ行う。actor 再起動時には復旧せず、実行中の滞留は reaper が拾う(即時二重送信を避けるため)。

## 保持期間

terminal 状態の行は `[retention]` 設定に従って自動 / 手動で削除できる(#30)。

- `deliveries.status = 'succeeded'` は `updated_at` が
  `succeeded_days` より古ければ削除
- `deliveries.status = 'dead_letter'` は `updated_at` が
  `dead_letter_days` より古ければ削除
- `events` は `received_at` が `events_days` より古く、参照する
  Delivery が 1 件も残っていない(孤児の)ものだけ削除

`pending` / `delivering` / `retry_scheduled` は削除しない。日数が未設定か
0 の区分は無期限保持(既定、v0.1 の挙動と同じ)。負数は設定エラー。

削除は 1 トランザクションで「Delivery → 孤児になった Event」の順に実行する
(外部キー制約を壊さない)。途中で失敗すると全体がロールバックされる。

自動実行は dispatcher が 1 時間に最大 1 回おこない、ログ `retention_pruned`
とメトリクス `retention_deleted_deliveries_total` /
`retention_deleted_events_total` で観測できる。手動実行は
`vectum prune [--dry-run]`(HMAC secret 不要、`[storage] path` と
`[retention]` だけ読む)。詳細は [cli.md](./cli.md) / [operations.md](./operations.md)。
