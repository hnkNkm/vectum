# HTTP Ingress と Source

v0.1 の受信は HTTP のみ。MQTT / NATS / SQS / Kafka / WebSocket は将来 Adapter。

## エンドポイント

Source は設定の `path` (既定 `POST /events/:source`) で HTTP POST を受ける。

```http
POST /events/:source
```

`:source` は設定上の Event Source 名。Source に `path` を明示すると、そのパス
(例 `POST /hooks/github`) が受信パスになる。照合はパス文字列の完全一致
(大文字小文字区別あり)。受理した場合は `202 Accepted`。永続化完了前に 202 を返してはならない。

| 状況 | 応答 |
| --- | --- |
| 未知の Source / 受信パス | `404` |
| Event Type 不明、JSON 不正 | `400` |
| HMAC 検証失敗 | `401` |
| Payload 上限超過 | `413` |
| `Content-Type` が JSON でない | `415` |

永続化失敗時は `500`。マッチする Route がなくても Source と Event Type が取れれば `202` を返し、Delivery 件数は 0 になる。

## Source 設定

```toml
[[sources]]
name = "github"
path = "/hooks/github"
type_from_header = "X-GitHub-Event"
hmac_secret_env = "GITHUB_WEBHOOK_SECRET"
hmac_header = "X-Hub-Signature-256"
```

| フィールド | 説明 |
| --- | --- |
| `name` | Source 識別子。受信パスの既定値 `/events/<name>` を決める |
| `path` | 受信パス。既定は `/events/<name>`。`/` で始まり `/` 単独でなく、`?` `#` 空白を含まないこと。全 Source 間で重複不可。`/health` `/ready` `/metrics` と衝突不可 |
| `type_from_header` | HTTP ヘッダから Event Type を取る |
| `type_from_json` | Payload の dotted path から Event Type を取る |
| `type_fixed` | 固定の Event Type |
| `hmac_secret` / `hmac_secret_env` | 設定されていれば受信時に HMAC 検証する |
| `hmac_header` | 既定 `X-Hub-Signature-256`。空・空白は設定不可 |

Event Type の決定順は header → JSON フィールド → 固定値。いずれも取れない場合は受理しない。

未知 Source / 受信パスは受理しない。未知 Event Type でも、Type 自体が抽出できれば受理する。Route にマッチしなければ Delivery は作らない。
