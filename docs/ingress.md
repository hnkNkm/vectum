# HTTP Ingress と Source

v0.1 の受信は HTTP のみ。MQTT / NATS / SQS / Kafka / WebSocket は将来 Adapter。

## エンドポイント

```http
POST /events/:source
```

`:source` は設定上の Event Source 名。受理した場合は `202 Accepted`。永続化完了前に 202 を返してはならない。

| 状況 | 応答 |
| --- | --- |
| 未知の Source | `404` |
| Event Type 不明、JSON 不正 | `400` |
| HMAC 検証失敗 | `401` |
| Payload 上限超過 | `413` |
| `Content-Type` が JSON でない | `415` |

永続化失敗時は `500`。マッチする Route がなくても Source と Event Type が取れれば `202` を返し、Delivery 件数は 0 になる。

## Source 設定

```toml
[[sources]]
name = "github"
path = "/events/github"
type_from_header = "X-GitHub-Event"
hmac_secret_env = "GITHUB_WEBHOOK_SECRET"
hmac_header = "X-Hub-Signature-256"
```

| フィールド | 説明 |
| --- | --- |
| `name` | Source 識別子。Ingress の `:source` と一致させる |
| `path` | 既定は `/events/<name>`。実装の照合は URL の Source 名であり、カスタム `path` は未使用 |
| `type_from_header` | HTTP ヘッダから Event Type を取る |
| `type_from_json` | Payload の dotted path から Event Type を取る |
| `type_fixed` | 固定の Event Type |
| `hmac_secret` / `hmac_secret_env` | 設定されていれば受信時に HMAC 検証する |
| `hmac_header` | 既定 `X-Hub-Signature-256` |

Event Type の決定順は header → JSON フィールド → 固定値。いずれも取れない場合は受理しない。

未知 Source は受理しない。未知 Event Type でも、Type 自体が抽出できれば受理する。Route にマッチしなければ Delivery は作らない。
