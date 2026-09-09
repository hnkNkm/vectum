# セキュリティ

## HMAC

Source 受信と Destination 配送の両方で HMAC-SHA256 を使える。

```text
X-Hub-Signature-256: sha256=<hex>
```

比較は定数時間。設定は `hmac_secret` または `hmac_secret_env`。秘密を TOML に直書きせず環境変数を使うことを推奨する。`hmac_secret_env` が指す変数が無いと `validate` / `run` は失敗する。

| 用途 | 既定ヘッダ |
| --- | --- |
| Source | `X-Hub-Signature-256` |
| Destination | `X-Vectum-Signature` |

`hmac_header` で変更できる。受信時の Metadata からは HMAC ヘッダ、`Authorization`、`Cookie` を除外する。

## TLS

Destination への HTTPS は inets httpc 経由の FFI (`vectum_httpc_ffi`) で送る。
https URL には明示的に `{ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 3}, {customize_hostname_check, [...]}]}` を渡すため、
Destination のサーバ証明書は**システム CA ストアに対して検証され、ホスト名も検証される**。
自己署名や未知の CA の証明書は接続失敗 (ConnectFailed) になり、retry 対象になる。
(OTP 28 の httpc は ssl オプション無しでも検証が既定だが、バージョンに依存しないよう明示している。)

配送 POST は httpc の透過リトライ (`autoretry`) を無効化している。OTP の httpc 既定
(autoretry = infinity) では 503 + `Retry-After` をタイムアウト内に 1 回透過再送し、
vectum のリトライ勘定・backoff から隠れるため。503 はそのまま返り、vectum の backoff に乗る。

Ingress の TLS 終端は reverse proxy に委譲する。プロセス自体は HTTP で待つ。

## Payload 上限

既定は 1 MiB。`Content-Length` が `[server].max_body_bytes` を超えると `413`。
`Transfer-Encoding` に `chunked` を含むリクエストはボディ読み取り前に `413` で拒否する。
mist 6 の `read_body` は `Content-Length` 無しを 0 とみなし chunked を無制限に読むため、
上限チェックの迂回とメモリ枯渇を防ぐ措置。`[server].max_body_bytes` で上限を変更できる。

## 認証モデル

v0.1 の Source 認証は HMAC の有無だけ。`hmac_secret` / `hmac_secret_env` が無ければ検証しない。mTLS、Bearer、IP allowlist は将来候補。
