# CLI

コマンド名は `vectum`。仕様ドラフトのプレースホルダは `router` だった。

```bash
vectum run --config router.toml
vectum validate --config router.toml
vectum status --config router.toml
vectum events list --source github --limit 20 --config router.toml
vectum events show <event-id> --config router.toml
vectum deliveries list --status retry_scheduled --config router.toml
vectum deliveries show <delivery-id> --config router.toml
vectum dead list --config router.toml
vectum dead retry <delivery-id> --config router.toml
vectum dead delete <delivery-id> --config router.toml
```

開発中は `gleam run --` のあとに同じサブコマンドを渡せる。

| コマンド | 説明 |
| --- | --- |
| `run` | HTTP Ingress と dispatcher を起動する |
| `validate` | 設定を検証して終了する |
| `status` | storage path・Delivery の status 別件数・未完了合計・最古の pending/retry を表示する(読み取り専用) |
| `events list` | Event を受信の新しい順に一覧する(読み取り専用) |
| `events show` | 指定 Event と、それに紐づく Delivery 一覧を表示する(読み取り専用) |
| `deliveries list` | Delivery を更新の新しい順に一覧する(読み取り専用) |
| `deliveries show` | 指定 Delivery の詳細を表示する(読み取り専用) |
| `dead list` | dead letter を一覧する |
| `dead retry` | 指定 Delivery を `pending` に戻し、`attempts` を 0 にする |
| `dead delete` | 指定 Delivery を削除する |

`--config` を省略すると `VECTUM_CONFIG`、それが無ければ `router.toml`。

## 読み取り専用コマンド (#31)

`status` / `events` / `deliveries` は **状態を変更しない**(SELECT のみ)。
`--config` は `dead` 系と同じく位置を問わず使え、`--flag=value` 形式も受け付ける。

### status

storage path、status 別の Delivery 件数、未完了合計
(`pending` + `delivering` + `retry_scheduled`)、および
`pending` / `retry_scheduled` の中で最も長く滞留している行の時刻と経過秒
(該当行が無ければ最終 2 行は出ない)を表示する。

```text
$ vectum status --config router.toml
storage_path	./router.db
pending	1
delivering	0
retry_scheduled	1
succeeded	120
dead_letter	3
pending_total	2
oldest_open_since_ms	1770000000000
oldest_open_age_s	42
```

時刻は Unix epoch ミリ秒。経過秒はコマンド実行時点からの差分。

### events list

`--source S` / `--type T` で絞り込み、`received_at` の新しい順に表示する。

```text
$ vectum events list --source github --limit 5 --config router.toml
id	source	type	time	payload
evt-9	github	push	2026-01-01T00:00:00.000Z	{"ref":"main"}
evt-8	github	push	2026-01-01T00:00:00.000Z	{"ref":"dev"}
```

`--limit` は既定 50・最大 1000(超過は 1000 に丸める)。0 以下や非整数はエラー。
`time` は Event envelope の時刻、並び順は受信時刻。

### events show

Event 本体のあとに、その Event に紐づく Delivery を更新の新しい順に表示する。

```text
$ vectum events show evt-9 --config router.toml
event:
id	source	type	time	payload
evt-9	github	push	2026-01-01T00:00:00.000Z	{"ref":"main"}

deliveries:
id	event_id	destination	status	attempts	next_attempt_at	last_attempt_at	created_at	updated_at	last_error
d-9a	evt-9	ci	succeeded	1	1770000000000	1770000000000	1770000000000	1770000000000
```

存在しない Event ID はメッセージを出して終了コード 1 で終わる。

### deliveries list

`--status pending|delivering|retry_scheduled|succeeded|dead_letter` と
`--destination D` で絞り込み、`updated_at` の新しい順に表示する。

```text
$ vectum deliveries list --status retry_scheduled --config router.toml
id	event_id	destination	status	attempts	next_attempt_at	last_attempt_at	created_at	updated_at	last_error
d-4	evt-3	audit	retry_scheduled	3	1770000100000	1770000090000	1770000000000	1770000090000	timeout
```

### deliveries show

```text
$ vectum deliveries show d-4 --config router.toml
id	event_id	destination	status	attempts	next_attempt_at	last_attempt_at	created_at	updated_at	last_error
d-4	evt-3	audit	retry_scheduled	3	1770000100000	1770000090000	1770000000000	1770000090000	timeout
```

存在しない Delivery ID はメッセージを出して終了コード 1 で終わる。

### 出力形式

出力はタブ区切り・1 行 1 レコードで、`id`/`event_id`/`destination`/`status`/
`attempts`/`last_error`/時刻列の意味は固定。行は将来の JSON 出力に備えて
コマンドごとに「列定義 + データ行」の構造で組み立てている
(`src/vectum/cli.gleam` の `format_*`)。

`events list` など件数 0 のときは `no events` / `no deliveries` と表示する。

### 使用上の注意

- `--status` / `--destination` / `--source` / `--type` / `--limit` は
  list 系コマンド専用。`show` / `status` / `run` / `dead` に付けるとエラーになる。
- 大量データでも全件読み込まないよう、list 系は必ず `LIMIT` 付きの
  parameterized query で読む。
- 出力の時刻は生の epoch ミリ秒。人間向け整形は将来の表示層の課題。

`dead retry` は `attempts` を 0 に戻す。再配送は `[delivery].max_attempts` 分の backoff を最初からやり直す。

`dead retry` / `dead delete` は該当 ID の `dead_letter` が存在しない場合エラー終了する(非 0 終了コード)。
