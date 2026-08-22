# 概要

## 製品定義

> A lightweight, reliable, self-hosted event router built with Gleam and BEAM, designed for cloud, on-premise, and edge environments.

> Gleam / BEAM で構築された、クラウド・オンプレミス・エッジ環境向けの軽量かつ信頼性の高い self-hosted Event Router。

外部システムからイベントを受信し、共通形式へ正規化したうえで、宣言的なルーティングルールに基づいて複数の宛先へ配送する。

Amazon EventBridge のコア概念に着想を得つつ、クラウド依存を避け、オンプレミス、閉域網、エッジ環境、小〜中規模システムで簡単に運用できることを目的とする。

本プロジェクトは EventBridge の完全互換実装を目指さない。Kafka、RabbitMQ、NATS などの Message Broker や Apache Camel のような大規模 Integration Framework の代替でもない。

## Goals

- 軽量な Event Router を self-hosted で提供する
- オンプレミスや閉域網で完全にオフライン運用できる
- 外部データベースを必須としない
- 宣言的な設定のみで Event Routing を構築できる
- Event Source と Destination を疎結合にする
- fan-out、filter、retry、dead-letter を標準機能として提供する
- At-least-once delivery を提供する
- Gleam / BEAM / OTP の Supervisor と軽量 Process を活用する
- Transport に依存しない Core Architecture を構築する
- 単一ノードから簡単に導入できる
- 将来的に MQTT、NATS、SQS、Kafka 等の Adapter を追加可能にする

## Non-Goals (v0.1)

- Kafka 互換の高スループット Message Broker
- Exactly-once delivery
- 分散クラスタ
- 長期 Event Log
- Consumer Group / Partition / Offset 管理
- Stream Processing / ETL / Workflow Engine
- 任意 JavaScript / Lua / WASM の実行
- Web UI
- AWS EventBridge 完全互換
- IAM 相当の大規模権限管理
- Schema Registry
- Event Archive / Replay の高度な管理
- AWS Service Integration の再実装

## 設計原則

| 原則 | 意味 |
| --- | --- |
| Simple | 一台の VM、コンテナ、サーバーで起動できる |
| Reliable | 受理した Event を可能な限り失わない |
| Declarative | 処理ロジックをコードではなく設定で書く |
| Transport Independent | Routing Core は HTTP / MQTT / NATS に依存しない |
| BEAM Native | Supervisor、Process、Failure Isolation を使う |
| Offline Capable | 外部 SaaS やライセンスサーバーなしで動く |
| Minimal Operations | Redis、PostgreSQL、Kafka 等を必須にしない |

## 位置づけ

```text
             Large / Complex
                   ▲
             Kafka / Camel
        ┌──────────┴──────────┐
        │    Event Router     │
        │ routing / filter    │
        │ retry / fan-out     │
        │ adapters / SQLite   │
        └──────────┬──────────┘
              Webhook Script
                   ▼
              Small / Simple
```

対象は「小さな Webhook Server や個別 Integration では管理が辛いが、Kafka や Cloud Event Bus を入れるほどではない」利用者。
