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

ログは常に構造化 JSON を標準出力へ出す。`[log]` セクションは未実装。

## 起動時検証

- Source / Destination / Route 名の重複、Source の受信パス重複・予約パス衝突
- `sources.path` が `/` で始まり `/` 単独でなく、`?` `#` 空白を含まないこと
- Route が未知の Source または Destination を参照していないこと
- 未知のフィルタ演算子がないこと
- Destination URL が http(s) であること
- timeout / retry が正の値であること
- `hmac_secret_env` が指す環境変数が存在する（validate / run 時）
- `hmac_header` が空・空白でないこと（Source / Destination とも）
- Destination `type` が `http` であること

検証に失敗すると起動しない。一方、既知セクション内の未知キーは
`warning:` として stderr へ出力するだけで失敗させない (validate / run の続行)。
