# Event Model

Transport 非依存の共通 Event Envelope。HTTP Webhook も MQTT Message も、内部では同じ形に正規化する。

## Envelope

```json
{
  "id": "01JXYZABCDEFGHJKMNPQRSTUVW",
  "source": "github",
  "type": "push",
  "time": "2026-08-23T00:00:00Z",
  "data": {},
  "metadata": {}
}
```

| フィールド | 必須 | 説明 |
| --- | --- | --- |
| `id` | はい | 内部採番。外部の Event ID は使わない |
| `source` | はい | Event Source 名 |
| `type` | はい | Event Type |
| `time` | はい | 受信時刻（UTC）。内部 Record 名は `timestamp` |
| `data` | はい | 正規化後の Payload |
| `metadata` | いいえ | HTTP headers、MQTT topic など |

`id` は UUID v7。仕様は ULID も候補としていたが、v0.1 では UUID v7 に固定した。

## Event Type の決定順

1. Source 設定の `type_from_header`（HTTP Header）
2. Source 設定の `type_from_json`（JSON フィールド）
3. Source 設定の `type_fixed`

いずれも取れない場合は受理しない。

## Event Data と JSON 値

v0.1 の Payload は JSON Object または JSON Array を想定する。内部表現は再帰的な `EventValue`。

- `Null`
- `Bool`
- `Int`
- `Float`
- `String`
- `Array`
- `Object`

フィルタは object の dotted path を辿る。配列要素への添字アクセスは v0.1 対象外。
