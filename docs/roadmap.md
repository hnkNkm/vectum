# ロードマップ

## v0.1（実装済みの範囲）

- HTTP Ingress
- HTTP Destination
- Routing
- Filtering
- Fan-out
- Retry
- Dead Letter
- SQLite
- HMAC
- CLI
- Metrics

充足の細部は [spec-compliance.md](./spec-compliance.md)。

## v0.2 候補

- MQTT Adapter
- NATS Adapter
- Retry-After
- より詳しい CLI 参照
- Event transformation
- Configuration hot reload

## v0.3 候補

- SQS Adapter
- Kafka Adapter
- WebSocket / SSE Adapter
- PostgreSQL Optional Backend
- Basic Replay
- HA Design Exploration

## Event Transformation

v0.1 では大規模な Transform Engine は実装しない。将来は外部 Event Format を共通 Event Model へ正規化する Adapter Layer を置く。任意スクリプトではなく、宣言的な field mapping を優先する。

```toml
[transform]
event_type_from = "event"
map."orderNo" = "order_id"
```

詳細は v0.2 以降で定義する。

## v0.1 対象外

- Web UI
- MQTT / NATS / SQS / Kafka / WebSocket
- クラスタ
- exactly-once
- `status` / `events list` / `deliveries list`
- Retry-After
- ホットリロード
- 自動 retention
