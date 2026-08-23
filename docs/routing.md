# ルーティングとフィルタ

## ルール

```toml
[[routes]]
name = "github-push"
source = "github"
event = "push"
destinations = ["ci", "audit"]
```

複数 Destination への fan-out は `destinations` に列挙するか、複数ルールで書く。

```toml
[[routes]]
name = "order-to-inventory"
source = "sales"
event = "order.created"
destinations = ["inventory"]

[[routes]]
name = "order-to-crm"
source = "sales"
event = "order.created"
destinations = ["crm"]
```

`event = "*"` は当該 Source の全 Event Type にマッチする。

同一 Event が複数ルールにマッチした場合、マッチしたすべての Destination へ配送する。同一 Destination が複数ルールで重複した場合は 1 回だけ配送する。

## フィルタ

```toml
[[routes]]
name = "critical-alerts"
source = "monitor"
event = "alert"
destinations = ["pager"]

[[routes.filters]]
path = "severity"
op = "eq"
value = "critical"
```

| 演算子 | 意味 |
| --- | --- |
| `eq` | 等しい |
| `neq` | 等しくない |
| `gt` / `gte` / `lt` / `lte` | 数値比較 |
| `contains` | 文字列包含、または配列に値が含まれる |
| `exists` | フィールドが存在する |
| `not_exists` | フィールドが存在しない |

複数フィルタは AND。OR と nested condition は v0.1 対象外。object の dotted path（例: `repository.name`）はサポートする。配列添字は対象外。任意コード実行はしない。

`path` に `metadata.` プレフィックスを付けると、Event Data ではなく **Metadata(HTTP ヘッダ由来)** を条件にできる。

```toml
[[routes.filters]]
path = "metadata.x-github-event"
op = "eq"
value = "push"
```

プレフィックスがない場合は従来どおり Data の dotted path を解釈する。Metadata の値は文字列として比較する。
