# vectum ドキュメント

仕様は項目ごとにこのディレクトリで管理します。

## 読む順番

| 文書 | 内容 |
| --- | --- |
| [overview.md](./overview.md) | 製品定義、Goals / Non-Goals、設計原則、位置づけ |
| [use-cases.md](./use-cases.md) | 想定ユースケース |
| [architecture.md](./architecture.md) | 全体構成、OTP、モジュール配置 |
| [event-model.md](./event-model.md) | 共通 Event Envelope と JSON 値 |
| [ingress.md](./ingress.md) | HTTP 受信と Source |
| [routing.md](./routing.md) | ルーティングルールとフィルタ |
| [delivery.md](./delivery.md) | Destination、retry、dead letter |
| [persistence.md](./persistence.md) | SQLite とトランザクション境界 |
| [security.md](./security.md) | HMAC、TLS、Payload 上限 |
| [configuration.md](./configuration.md) | TOML 設定と起動時検証 |
| [cli.md](./cli.md) | CLI |
| [observability.md](./observability.md) | ログ、メトリクス、health |
| [operations.md](./operations.md) | デプロイ、運用、スケール境界 |
| [roadmap.md](./roadmap.md) | 将来拡張 |
| [decisions.md](./decisions.md) | v0.1 で固定した実装判断 |
| [spec-compliance.md](./spec-compliance.md) | 仕様に対する実装の充足状況 |

クイックスタートはリポジトリ直下の [README.md](../README.md) を参照してください。
