# 運用

## 必須外部サービスはない

v0.1 は Redis、PostgreSQL、Kafka、NATS、Kubernetes、Cloud Account を要求しない。

## オフライン運用

Internet なしで起動、設定、配送、再配送、監視ができる。Destination が Internet 上にある場合、その通信だけが必要になる。

## デプロイ

単一バイナリ、または Docker。

```bash
docker run --rm -p 8080:8080 \
  -v ./router.toml:/config/router.toml:ro \
  -e VECTUM_CONFIG=/config/router.toml \
  vectum
```

仕様ドラフトの例は `-v ./router.toml:/app/router.toml` だった。イメージは `/config/router.toml` と `VECTUM_CONFIG` を使う。

Ingress の TLS は reverse proxy に委譲する。

## Graceful Shutdown

仕様は「新規受付を止め、進行中の Storage Transaction を安全に終え、可能な範囲で進行中 Delivery を永続化する」としている。v0.1 実装は未対応で、プロセスは起動後スリープし続ける。停止は OS シグナルによる強制終了になる。起動時の `delivering` → `pending` 復旧で未完了配送は再開できる。

## スケール境界

正式サポートは単一ノード。巨大 Streaming Platform は目的にしない。次が主要件なら Kafka 等を推奨する。

- 数百 MB/s 級の Event Stream
- 数億 Event の長期保持
- Partition Ordering
- Consumer Groups
- Offset Management
- Stream Processing
- Distributed Log
