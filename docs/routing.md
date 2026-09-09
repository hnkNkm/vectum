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

複数フィルタは AND。OR が必要な場合は下記の grouped condition(`[routes.condition]`)を使う。object の dotted path(例: `repository.name`)はサポートする。配列添字は対象外。任意コード実行はしない。

`path` に `metadata.` プレフィックスを付けると、Event Data ではなく **Metadata(HTTP ヘッダ由来)** を条件にできる。

```toml
[[routes.filters]]
path = "metadata.x-github-event"
op = "eq"
value = "push"
```

プレフィックスがない場合は従来どおり Data の dotted path を解釈する。Metadata のキーは大小文字を区別しない(`X-GitHub-Event` と `x-github-event` は同じヘッダにマッチ)。値は文字列として比較する。

## Grouped condition(AND / OR)

`[[routes.filters]]` の代わりに `[routes.condition]` を使うと、AND / OR をネストして任意の組み合わせを表現できる。`filters` と `condition` は排他で、両方書くと設定エラーになる。

ルートは常に group ノードで、`op` に `all`(AND)または `any`(OR)を持つ。`filters` には leaf(下記の従来どおりの filter 形)か group ノードを並べる。

```toml
[[routes]]
name = "critical-or-emergency"
source = "github"
event = "push"
destinations = ["pager"]

[routes.condition]
op = "any"
filters = [
  # (severity == "critical" AND region == "jp")
  { op = "all", filters = [
    { path = "severity", op = "eq", value = "critical" },
    { path = "region", op = "eq", value = "jp" },
  ] },
  # OR source == "emergency"
  { path = "source", op = "eq", value = "emergency" },
]
```

group ノードの `filters` には leaf または group を並べられる。ネストする group は
インライン table(`{ op = "all", filters = [...] }`)で書く。leaf の `op` / `value` は
`[[routes.filters]]` と同じ規則(`exists` / `not_exists` では `value` 省略可、
dotted path / `metadata.` もそのまま使える)。

制約:

- group のネストは root を 1 段として最大 4 段。超えると設定エラー
- group の `filters` を空にすると設定エラー
- group の `op` は `all` / `any` のみ。他は設定エラー
- 評価は設定順(ドキュメント順)で行い、`all` は最初の偽、`any` は最初の真で短絡する

Metadata フィルタを group に混ぜることもできる。

```toml
[routes.condition]
op = "all"
filters = [
  { path = "repository.name", op = "eq", value = "backend" },
  { path = "metadata.x-github-event", op = "eq", value = "push" },
]
```
