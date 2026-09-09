# 設定

設定は TOML。起動時に検証し、不正なら起動しない。ホットリロードはしない。変更後はプロセスを再起動する。

## ファイルの探し方

1. `--config <path>`
2. 環境変数 `VECTUM_CONFIG`
3. カレントディレクトリの `router.toml`

## 全体例

秘密を含まない最小例は `examples/minimal.toml`。HMAC 付きの例は `examples/router.toml`。

```toml
[server]
host = "0.0.0.0"
port = 8080
max_body_bytes = 1048576

[storage]
path = "./router.db"

[[sources]]
name = "github"
path = "/events/github"
type_from_header = "X-GitHub-Event"
hmac_secret_env = "GITHUB_WEBHOOK_SECRET"
hmac_header = "X-Hub-Signature-256"

[[destinations]]
name = "ci-webhook"
type = "http"
url = "https://ci.internal/hooks/github"
timeout_ms = 5000

[[routes]]
name = "github-to-ci"
source = "github"
event = "push"
destinations = ["ci-webhook"]

[delivery]
max_attempts = 8
initial_backoff_ms = 1000
max_backoff_ms = 60000
timeout_ms = 10000
jitter = true
concurrency = 8
```

`[[routes]]` のフィルタ条件には、従来の AND 専用 `[[routes.filters]]` のほか、
AND / OR をネストできる `[routes.condition]` を 1 つ書ける。両方は併設できない。

```toml
[[routes]]
name = "critical-or-emergency"
source = "github"
event = "push"
destinations = ["pager"]

[routes.condition]
op = "any"
filters = [
  { op = "all", filters = [
    { path = "severity", op = "eq", value = "critical" },
    { path = "region", op = "eq", value = "jp" },
  ] },
  { path = "source", op = "eq", value = "emergency" },
]
```

group ノードは `op`(`all` / `any`)と `filters`(leaf または group の配列)を持つ。
構文・制約(ネスト最大 4 段、空 group 禁止など)の詳細は [routing.md](./routing.md)。

ログは常に構造化 JSON を標準出力へ出す。`[log]` セクションは未実装。

## 認証（HMAC / Bearer Token）

Source / Destination には認証用の秘密を設定できる。検証規則はすべて同じ:

- `hmac_secret` / `hmac_secret_env` — HMAC 署名鍵（Source は受信検証、Destination は署名付与）
- `auth_bearer` / `auth_bearer_env` — Bearer Token。Source は受信時に `Authorization: Bearer <token>` を検証し、Destination は配送時に同ヘッダを付与する

インライン（`hmac_secret` / `auth_bearer`）と環境変数参照（`*_env`）は**併設できない**。値が空・空白のみの場合も設定エラー。`*_env` が指す環境変数が存在しない場合も起動時エラーになる。どちらも未設定なら検証・付与しない。

HMAC と Bearer は同時に設定できる。Source は両方の検証に合格しないと受理しない（AND）。Destination は両方のヘッダを送る。

```toml
[[sources]]
name = "internal-api"
type_from_json = "type"
auth_bearer_env = "VECTUM_SOURCE_TOKEN"

[[destinations]]
name = "notify-api"
type = "http"
url = "https://example.invalid/events"
auth_bearer_env = "NOTIFY_API_TOKEN"
```

## 起動時検証

- Source / Destination / Route 名の重複、Source の受信パス重複・予約パス衝突
- `sources.path` が `/` で始まり `/` 単独でなく、`?` `#` 空白を含まないこと
- Route が未知の Source または Destination を参照していないこと
- 未知のフィルタ演算子がないこと
- Route が `filters` と `condition` を併設していないこと
- condition の group `op` が `all` / `any` であること、group が空でないこと、
  ネストが 4 段以内であること、leaf の `value` が `exists` / `not_exists`
  以外では必須であること
- Destination URL が http(s) であること
- timeout / retry が正の値であること
- `hmac_secret_env` が指す環境変数が存在する（validate / run 時）
- `hmac_header` が空・空白でないこと（Source / Destination とも）
- `auth_bearer` / `auth_bearer_env` の併設、空・空白のみの値、`auth_bearer_env` が指す環境変数の欠落は設定エラー（`hmac_secret` と同じ規則）
- Destination `type` が `http` であること

検証に失敗すると起動しない。一方、既知セクション内の未知キーは
`warning:` として stderr へ出力するだけで失敗させない (validate / run の続行)。
