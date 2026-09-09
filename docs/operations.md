# 運用

## 必須外部サービスはない

v0.1 は Redis、PostgreSQL、Kafka、NATS、Kubernetes、Cloud Account を要求しない。

## オフライン運用

Internet なしで起動、設定、配送、再配送、監視ができる。Destination が Internet 上にある場合、その通信だけが必要になる。

## デプロイ

単一バイナリ、または Docker。

イメージ既定は `examples/docker.toml` を `/config/router.toml` に焼き込む。`storage.path` は `/data/router.db`、listen は `0.0.0.0:8080`。`/app` は root 所有のため、相対パス `./router.db` だと `vectum` ユーザーで書けない。

> 既定設定の Destination は動作確認用のプレースホルダ(`127.0.0.1`)のため、上書きしない限り配送は失敗し dead-letter になる。コンテナを公開するネットワークに置く場合は、必ず Source に認証(HMAC または Bearer Token)を設定すること。

```bash
docker run --rm -p 8080:8080 \
  -v ./data:/data \
  vectum
```

独自設定を載せる場合は `storage.path` を `/data` 配下にし、データ用ボリュームを同じパスにマウントする。

```bash
docker run --rm -p 8080:8080 \
  -v ./router.toml:/config/router.toml:ro \
  -e VECTUM_CONFIG=/config/router.toml \
  -v ./data:/data \
  vectum
```

Ingress の TLS は reverse proxy に委譲する。

## 状態確認（read-only）

起動中の状態を変えずに SQLite の状態を確認できる CLI が `vectum status` /
`events list|show` / `deliveries list|show`(いずれも読み取り専用、#31)。
HMAC secret は不要で、`[storage] path` さえ読めれば動く。詳細は
[docs/cli.md](./cli.md)。

```bash
# 滞留の有無と status 別件数
vectum status --config router.toml

# 最近受理された Event と、特定 Event の配送状況
vectum events list --limit 10 --config router.toml
vectum events show <event-id> --config router.toml

# retry 中 / dead-letter の Delivery を Destination 指定で確認
vectum deliveries list --status retry_scheduled --config router.toml
vectum deliveries list --status dead_letter --destination audit --config router.toml
vectum deliveries show <delivery-id> --config router.toml
```

サーバー稼働中でも WAL モードのため読み取りは可能。参照コマンドは
SELECT のみで、retry や削除などの操作は `dead retry` / `dead delete` を使う。

## 保持期間と prune (#30)

`[retention]` を設定すると、完了済みデータを保持日数後に自動削除できる
(未設定・0 なら無期限保持)。dispatcher が 1 時間に最大 1 回、
次のルールで削除する。

- `succeeded` の Delivery: `updated_at` が `succeeded_days` より古い行
- `dead_letter` の Delivery: `updated_at` が `dead_letter_days` より古い行
- Event: `received_at` が `events_days` より古く、参照する Delivery が
  残っていない孤児だけ

`pending` / `delivering` / `retry_scheduled` は削除しない。削除は 1
トランザクション(Delivery → 孤児 Event の順)で、失敗時は全体が
ロールバックされる。実行はログ `retention_pruned`、メトリクス
`retention_deleted_deliveries_total` / `retention_deleted_events_total`
で観測できる。

手動実行もできる(HMAC secret 不要。`[storage] path` と `[retention]` だけ読む)。

```bash
# 削除せずに対象件数だけ確認する
vectum prune --dry-run --config router.toml

# 実際に削除する
vectum prune --config router.toml
```

サーバー稼働中でも WAL モードで並行実行できる(busy timeout 内に待機)。

```toml
[retention]
succeeded_days = 7
dead_letter_days = 90
events_days = 30
```

保持期間の意味論は [persistence.md](./persistence.md)、設定の詳細は
[configuration.md](./configuration.md)。

## Graceful Shutdown

SIGTERM / SIGINT を受けると次の順で停止する。

1. 受付停止フラグを立てる。`POST /events` と `GET /ready` は `503` を返し、LB による drain が可能
2. dispatcher は新しい Delivery の claim を止める
3. 実行中の配送ワーカーと in-flight POST 受付の完了を待つ。猶予は既定 10 秒(`VECTUM_SHUTDOWN_GRACE_MS` で変更可)
4. 猶予を過ぎたら強制終了する。未完了 Delivery は次回起動時の復旧で再開される

in-flight の `POST /events` は受付時に数えられ、猶予内なら `call_accept` の commit まで待つ。猶予を過ぎた受付は中断され、書きかけの更新はジャーナルによりロールバックされ、次回起動時の復旧で再開される。

listen socket の明示 close はせず 503 応答で drain し、最後は `halt(0)` で即終了する。mailbox の drain や SQLite 接続の明示 close はしない。

### ヘルスチェックの使い分け

| Endpoint | 意味 | shutdown 中 |
| --- | --- | --- |
| `GET /health` | liveness。プロセスが生きていることだけを見る | `200` のまま |
| `GET /ready` | readiness。受付・DB 応答が可能なこと | `503`(受付停止フラグまたは DB 無応答) |

LB や orchestrator は `/ready` を drain・再起動判定に使い、`/health` の失敗だけを異常終了の合図にする。

### 猶予時間とコンテナの stop timeout

既定の 10 秒は `docker stop` や Kubernetes の一般的な猶予(`terminationGracePeriodSeconds`)と同程度。ワーカー完了を確実に待つには `VECTUM_SHUTDOWN_GRACE_MS` を stop timeout より短く設定するか、逆に stop timeout を延長する。猶予内に終わらない配送は強制切断され、起動時復旧で再配送される(at-least-once のため重複は増える)。

## スケール境界

正式サポートは単一ノード。巨大 Streaming Platform は目的にしない。次が主要件なら Kafka 等を推奨する。

- 数百 MB/s 級の Event Stream
- 数億 Event の長期保持
- Partition Ordering
- Consumer Groups
- Offset Management
- Stream Processing
- Distributed Log
