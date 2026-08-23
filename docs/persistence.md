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

起動時は `delivering` を `pending` に戻し、クラッシュ直後の未完了配送を再開する。この全件復旧はプロセス起動時に一度だけ行う。actor 再起動時には復旧せず、実行中の滞留は reaper が拾う(即時二重送信を避けるため)。

## 保持期間

v0.1 は自動 retention を持たない。運用で SQLite ファイルを管理する。
