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

Destination への HTTPS は gleam_httpc の TLS で送る。Ingress の TLS 終端は reverse proxy に委譲する。プロセス自体は HTTP で待つ。

## Payload 上限

既定は 1 MiB。超過は `413`。`[server].max_body_bytes` で変更できる。

## 認証モデル

v0.1 の Source 認証は HMAC の有無だけ。`hmac_secret` / `hmac_secret_env` が無ければ検証しない。mTLS、Bearer、IP allowlist は将来候補。
