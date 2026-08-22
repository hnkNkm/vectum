# CLI

コマンド名は `vectum`。仕様ドラフトのプレースホルダは `router` だった。

```bash
vectum run --config router.toml
vectum validate --config router.toml
vectum dead list --config router.toml
vectum dead retry <delivery-id> --config router.toml
vectum dead delete <delivery-id> --config router.toml
```

開発中は `gleam run --` のあとに同じサブコマンドを渡せる。

| コマンド | 説明 |
| --- | --- |
| `run` | HTTP Ingress と dispatcher を起動する |
| `validate` | 設定を検証して終了する |
| `dead list` | dead letter を一覧する |
| `dead retry` | 指定 Delivery を `pending` に戻す |
| `dead delete` | 指定 Delivery を削除する |

`--config` を省略すると `VECTUM_CONFIG`、それが無ければ `router.toml`。

v0.1 対象外（将来候補）:

- `status`
- `events list`
- `deliveries list`

`dead retry` / `dead delete` は、該当 ID の `dead_letter` が無くても成功終了する。存在確認のエラー化は未実装。
