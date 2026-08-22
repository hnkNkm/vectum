# アーキテクチャ

## 全体構成

```text
                ┌──────────────────┐
                │ Transport Adapter│
                │      HTTP        │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │ Event Normalizer │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │   Rule Engine    │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │    Dispatcher    │
                └────────┬─────────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
           HTTP A      HTTP B      HTTP C
```

Routing Core は Transport に依存しない。将来は Adapter を増やせる。

```text
HTTP ──────┐
MQTT ──────┤
NATS ──────┤
SQS ───────┼──▶ Event Core ───▶ HTTP
Kafka ─────┤                  ├▶ MQTT
WebSocket ─┘                  ├▶ NATS
                              └▶ SQS
```

v0.1 の Transport は HTTP Ingress と HTTP Destination のみ。

## v0.1 のプロセス構成

仕様は RootSupervisor 配下の粒度を性能試験後に決めてよいとしている。v0.1 実装は `gleam/otp` の static_supervisor で one_for_one 構成とする。

```text
vectum (main)
└── RootSupervisor (one_for_one, permanent)
     ├── Storage actor    … SQLite 接続を直列化。起動時に registry へ再登録
     ├── Metrics actor    … カウンタ。再起動でカウンタはリセット
     └── Dispatcher actor … 定期 tick で due Delivery を claim し worker を spawn
          └── Delivery worker × N
mist HTTP server … Ingress / health / metrics(独立)
```

Storage / Metrics / Dispatcher の参照は registry(persistent_term)経由で共有し、利用側は毎回読み出す。これにより子プロセスが再起動して Subject が変わっても、Ingress / Dispatcher は自動的に新しい参照を使う。

Destination 単位の Supervisor ではなく、共有 worker pool + SQLite claim を採用している。詳細は [decisions.md](./decisions.md)。

ある worker のクラッシュは他 Destination の claim を止めない。Storage / Metrics / Dispatcher が落ちた場合は Supervisor が再起動する(既定の許容は 5 秒あたり 10 回)。超過すると Supervisor 自身が終了するためプロセス全体が停止する(単一ノード前提)。

起動時は `delivering` 状態の Delivery を `pending` に戻し、未完了配送を再開する。

## 実装モジュール

過剰な階層は避け、`src/vectum/` 直下に置く。

| モジュール | 責務 |
| --- | --- |
| `event` / `id` / `clock` | Envelope、UUID v7、時刻 |
| `filter` / `route` | フィルタ AST とルーティング |
| `config` | TOML パースと検証 |
| `hmac` / `retry` | 署名と backoff |
| `storage` | SQLite と Delivery 状態 |
| `accept` | 正規化と受理判定 |
| `delivery` / `dispatcher` | HTTP 配送と claim loop |
| `ingress` | HTTP API |
| `metrics` / `log` | 観測 |
| `registry` / `supervisor` | actor 参照の共有と監視木 |
| `cli` / `app` | CLI と起動 |
