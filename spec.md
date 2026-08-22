# Gleam Event Router Specification

## 1. Overview

### 1.1 Product Summary

本プロジェクトは、Gleam / BEAM 上で動作する軽量な self-hosted Event Router を提供する。

外部システムからイベントを受信し、共通形式へ正規化したうえで、宣言的なルーティングルールに基づいて複数の宛先へ配送する。

Amazon EventBridge のコア概念に着想を得つつ、クラウド依存を避け、オンプレミス、閉域網、エッジ環境、小〜中規模システムで簡単に運用できることを目的とする。

想定する位置づけは以下の通り。

> A lightweight, self-hosted event router for cloud, on-prem, and edge environments.

本プロジェクトは EventBridge の完全互換実装を目指さない。また、Kafka、RabbitMQ、NATS などの Message Broker や Apache Camel のような大規模 Integration Framework の代替も目的としない。

---

## 2. Goals

### 2.1 Primary Goals

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

### 2.2 Non-Goals

v0.1 では以下を対象外とする。

- Kafka 互換の高スループット Message Broker
- Exactly-once delivery
- 分散クラスタ
- 長期 Event Log
- Consumer Group / Partition / Offset 管理
- Stream Processing
- ETL
- Workflow Engine
- 任意 JavaScript / Lua / WASM の実行
- Web UI
- AWS EventBridge 完全互換
- IAM 相当の大規模権限管理
- Schema Registry
- Event Archive / Replay の高度な管理
- AWS Service Integration の再実装

---

## 3. Target Use Cases

### 3.1 Webhook Aggregation

GitHub、GitLab、Stripe、監視システム、自社サービスなどから Webhook を一箇所で受信し、複数システムへ配送する。

```text
GitHub ───┐
GitLab ───┤
Stripe ───┤
Monitor ──┤
          ▼
     Event Router
      ├──▶ CI
      ├──▶ Internal API
      ├──▶ Audit
      └──▶ Notification
```

各サービスが個別に retry、timeout、fan-out、logging を実装する必要をなくす。

### 3.2 On-Premise System Integration

販売管理、在庫管理、物流、会計、CRM、製造管理など、複数のオンプレミスシステム間の Event Routing に利用する。

```text
Sales System
     │
     │ order.created
     ▼
 Event Router
  ├──▶ Inventory
  ├──▶ Logistics
  └──▶ CRM
```

各システム同士を Point-to-Point で直接接続する構成を避ける。

### 3.3 Factory / Edge Integration

工場、店舗、支店、エッジ拠点などで Event Gateway として利用する。

将来的に MQTT Adapter を追加することで以下の構成を可能にする。

```text
PLC / IoT Gateway
       │
       ▼
   Event Router
    ├──▶ MES
    ├──▶ Historian
    ├──▶ Alert
    └──▶ Cloud API
```

### 3.4 Lightweight Event Bus for Microservices

Kafka 等を導入するほどではない小〜中規模のマイクロサービスで利用する。

```text
Order
Payment
Inventory
   │
   ▼
Event Router
   ├──▶ Notification
   ├──▶ Analytics
   └──▶ Audit
```

Producer は Consumer の存在を認識せず、Event の発行だけを行う。

### 3.5 Monitoring and Alert Routing

Prometheus、Zabbix、Kubernetes、UPS、Network Monitor 等から受信した Event を severity に応じて振り分ける。

```text
Monitoring Systems
       │
       ▼
   Event Router
    ├── critical ─▶ Incident System
    ├── warning  ─▶ Notification
    └── info     ─▶ Log Storage
```

### 3.6 Cloud / On-Premise Bridge

Cloud と On-Premise の境界に配置し、接続先を集約する。

```text
Cloud
  │
  ▼
DMZ Event Router
  ├──▶ ERP
  ├──▶ Factory System
  └──▶ Internal API
```

---

## 4. Design Principles

本プロジェクトは以下の原則を優先する。

### 4.1 Simple

一台の VM、コンテナ、サーバーで簡単に起動できること。

### 4.2 Reliable

受信を受理した Event を可能な限り失わないこと。

### 4.3 Declarative

処理ロジックをコードではなく設定ファイルで記述できること。

### 4.4 Transport Independent

Routing Core は HTTP、MQTT、NATS 等の Transport 実装に依存しないこと。

### 4.5 BEAM Native

OTP Supervisor、Actor / Process、Failure Isolation を積極的に活用すること。

### 4.6 Offline Capable

外部 SaaS、ライセンスサーバー、クラウド API がなくても完全に動作すること。

### 4.7 Minimal Operations

Redis、PostgreSQL、Kafka 等の外部サービスを必須にしないこと。

---

## 5. v0.1 Scope

| Feature | v0.1 |
|---|---|
| HTTP Event Ingress | Required |
| HTTP Destination | Required |
| JSON Event | Required |
| Common Event Envelope | Required |
| Source Identification | Required |
| Event Type Identification | Required |
| Declarative Routing | Required |
| Field Filtering | Required |
| Fan-out | Required |
| Retry | Required |
| Timeout | Required |
| Dead Letter | Required |
| At-least-once Delivery | Required |
| SQLite Persistence | Required |
| HMAC Verification / Signing | Required |
| Metrics | Required |
| TOML Configuration | Required |
| CLI Operations | Required |
| Web UI | Out of Scope |
| MQTT | Future |
| NATS | Future |
| SQS | Future |
| Kafka | Future |
| WebSocket | Future |
| Distributed Cluster | Future |

---

## 6. High-Level Architecture

```text
                ┌──────────────────┐
                │ Transport Adapter│
                │      HTTP        │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │ Event Normalizer │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │   Rule Engine    │
                └────────┬─────────┘
                         ▼
                ┌──────────────────┐
                │    Dispatcher    │
                └────────┬─────────┘
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
           HTTP A      HTTP B      HTTP C
```

将来は以下のように拡張可能な構成とする。

```text
HTTP ──────┐
MQTT ──────┤
NATS ──────┤
SQS ───────┼──▶ Event Core ───▶ HTTP
Kafka ─────┤                  ├▶ MQTT
WebSocket ─┘                  ├▶ NATS
                             └▶ SQS
```

---

## 7. Internal Event Model

### 7.1 Event Envelope

内部 Event は Transport 固有の形式から切り離した共通 Envelope に正規化する。

概念上の Gleam 型は以下とする。

```gleam
pub type Event {
  Event(
    id: String,
    source: String,
    event_type: String,
    timestamp: Timestamp,
    data: EventValue,
    metadata: Dict(String, String),
  )
}
```

### 7.2 Required Fields

- `id`
  - Event Router が生成する一意な Event ID
- `source`
  - Event Source 名
- `event_type`
  - Event Type
- `timestamp`
  - Router が Event を受理した時刻
- `data`
  - Event Payload
- `metadata`
  - Transport Header 等の補助情報

### 7.3 Event ID

Event ID は十分な一意性と時系列性を持つ方式を採用する。

候補:

- UUID v7
- ULID

最終選定は実装時に Gleam / BEAM エコシステムとの相性を確認して決定する。

---

## 8. HTTP Ingress

### 8.1 Endpoint

v0.1 の標準 Event Ingress は HTTP とする。

```http
POST /events/:source
```

例:

```text
POST /events/github
POST /events/stripe
POST /events/monitoring
```

URL の `:source` を Event Source とする。

### 8.2 Event Type Extraction

Event Type は Source ごとに以下から取得可能とする。

- HTTP Header
- JSON Field
- 固定値

例:

```toml
[[sources]]
name = "github"
type_from_header = "X-GitHub-Event"
```

```toml
[[sources]]
name = "internal"
type_from_json = "type"
```

### 8.3 Response

Event と Delivery 情報が永続化された後に HTTP `202 Accepted` を返す。

永続化前に `202` を返してはならない。

### 8.4 Invalid Requests

以下の場合は `4xx` を返す。

- Unknown Source
- Invalid JSON
- Missing Event Type
- Authentication / HMAC Failure
- Payload Size Exceeded
- Invalid Content-Type

---

## 9. Source Configuration

例:

```toml
[[sources]]
name = "github"
path = "/events/github"
type_from_header = "X-GitHub-Event"
```

将来的には Source Type を明示可能にする。

```toml
[[sources]]
name = "factory"
type = "mqtt"
topic = "factory/+/events"
```

ただし MQTT は v0.1 では実装しない。

---

## 10. Routing Rules

### 10.1 Basic Routing

ルールは宣言的に記述する。

```toml
[[routes]]
name = "github-push"
source = "github"
event = "push"
destinations = ["ci", "audit"]
```

### 10.2 Rule Matching

最低限、以下を条件に利用できる。

- Source
- Event Type
- Event Data
- Metadata

### 10.3 Multiple Matches

1つの Event が複数 Rule に一致することを許可する。

一致した全 Rule の Destination に配送する。

同一 Event / Destination の重複生成ポリシーは実装時に明示する。

推奨仕様:

- 同一 Event に対して同一 Destination が複数 Rule から選択された場合、Delivery は1件に deduplicate する。

---

## 11. Filters

### 11.1 Supported Operators

v0.1 では以下を提供する。

- `eq`
- `neq`
- `gt`
- `gte`
- `lt`
- `lte`
- `contains`
- `exists`
- `not_exists`

### 11.2 Example

```toml
[[routes]]
name = "large-payment"
source = "stripe"
event = "payment.succeeded"
destinations = ["fraud-check"]

[[routes.filters]]
path = "amount"
op = "gte"
value = 100000
```

### 11.3 Nested Field Access

`.` 区切りで JSON Object を参照する。

```toml
[[routes.filters]]
path = "repository.name"
op = "eq"
value = "backend"
```

### 11.4 Filter Combination

v0.1 では同一 Rule 内の複数 Filter を AND 条件とする。

OR / nested boolean expression は将来拡張とする。

### 11.5 Arbitrary Code

JavaScript、Lua、Shell 等の任意コード実行はサポートしない。

理由:

- Security
- Sandbox Complexity
- Determinism
- Portability
- Operational Simplicity

内部では設定を型付き Rule AST に変換して評価する。

---

## 12. Destination Model

### 12.1 Destination Abstraction

概念上の型:

```gleam
pub type Destination {
  Http(HttpDestination)
}
```

将来的には以下へ拡張可能とする。

```gleam
pub type Destination {
  Http(HttpDestination)
  Mqtt(MqttDestination)
  Nats(NatsDestination)
  Sqs(SqsDestination)
  Kafka(KafkaDestination)
}
```

### 12.2 HTTP Destination

```toml
[[destinations]]
name = "ci"
type = "http"
url = "https://ci.internal/events"
timeout_ms = 5000
```

### 12.3 HTTP Method

v0.1 は `POST` のみを必須とする。

将来的に Method 設定を許可してもよい。

---

## 13. Delivery Semantics

### 13.1 Guarantee

v0.1 の配送保証は明示的に以下とする。

> At-least-once delivery

Event が Destination に複数回届く可能性がある。

Exactly-once delivery は保証しない。

### 13.2 Idempotency

HTTP Destination へ以下の Header を送信する。

```http
X-Event-Id: <event-id>
```

必要に応じて以下も検討する。

```http
Idempotency-Key: <event-id>
```

Consumer は Event ID を利用して重複排除可能とする。

---

## 14. Retry Policy

### 14.1 Default Configuration

```toml
[delivery]
max_attempts = 8
initial_backoff_ms = 1000
max_backoff_ms = 60000
timeout_ms = 10000
jitter = true
```

### 14.2 Backoff

Exponential Backoff + Jitter を使用する。

概念例:

```text
1s
2s
4s
8s
16s
32s
60s
60s
```

### 14.3 Retry Conditions

推奨デフォルト:

| Result | Action |
|---|---|
| 2xx | Success |
| 3xx | Failure |
| 4xx | Failure |
| 408 | Retry |
| 429 | Retry |
| 5xx | Retry |
| Connection Error | Retry |
| Timeout | Retry |

`Retry-After` Header が存在する場合、将来的に尊重することを検討する。

---

## 15. Dead Letter

最大 Retry 回数を超えた Delivery は削除せず Dead Letter 状態へ移行する。

状態例:

```text
Pending
   ↓
Delivering
   ↓
RetryScheduled
   ↓
...
   ↓
DeadLetter
```

CLI から確認・再配送・削除可能とする。

```bash
router dead list
router dead retry <delivery-id>
router dead delete <delivery-id>
```

---

## 16. Persistence

### 16.1 Default Storage

v0.1 は SQLite を使用する。

外部 Database を必須としない。

例:

```text
router.db
```

### 16.2 Minimal Data Model

最低限以下を保持する。

- Events
- Deliveries

Dead Letter は Delivery の状態として表現してもよい。

### 16.3 Event Record

概念的フィールド:

```text
id
source
event_type
received_at
payload
metadata
```

### 16.4 Delivery Record

概念的フィールド:

```text
id
event_id
destination
status
attempts
next_attempt_at
last_attempt_at
last_error
created_at
updated_at
```

### 16.5 Transaction Boundary

Event 受信時は以下を単一 Transaction とする。

```text
Receive Event
    ↓
Normalize
    ↓
Evaluate Routes
    ↓
SQLite Transaction
 ├── Insert Event
 └── Insert Delivery × N
    ↓
Commit
    ↓
202 Accepted
```

これにより、受理した直後に Router が停止しても Delivery を復元可能とする。

---

## 17. Security

### 17.1 Source Authentication

v0.1 で HMAC Verification をサポートする。

Source ごとに Secret を設定可能とする。

Secret は設定ファイルへの平文直接記述だけでなく、環境変数参照を可能にすることが望ましい。

例:

```toml
[[sources]]
name = "github"
hmac_secret_env = "GITHUB_WEBHOOK_SECRET"
```

### 17.2 Destination Signing

HTTP Destination 向けに HMAC Signature を付与可能とする。

### 17.3 TLS

HTTPS Destination をサポートする。

Server Side TLS Termination を直接 Router が行うか、Reverse Proxy に委譲するかは実装時に決定する。

v0.1 では Reverse Proxy 委譲を許容する。

### 17.4 Payload Limits

過大 Payload による DoS を防ぐため、HTTP Request Body の最大サイズを設定可能とする。

---

## 18. Configuration

### 18.1 Format

TOML を標準設定形式とする。

標準ファイル名:

```text
router.toml
```

### 18.2 Example

```toml
[server]
host = "0.0.0.0"
port = 8080

[storage]
path = "./router.db"

[[sources]]
name = "github"
path = "/events/github"
type_from_header = "X-GitHub-Event"

[[destinations]]
name = "ci"
type = "http"
url = "http://ci.internal/events"

[[destinations]]
name = "audit"
type = "http"
url = "http://audit.internal/events"

[[routes]]
name = "github-push"
source = "github"
event = "push"
destinations = ["ci", "audit"]

[[routes]]
name = "backend-pr"
source = "github"
event = "pull_request"
destinations = ["audit"]

[[routes.filters]]
path = "repository.name"
op = "eq"
value = "backend"

[delivery]
max_attempts = 8
timeout_ms = 10000
initial_backoff_ms = 1000
max_backoff_ms = 60000
jitter = true
```

### 18.3 Configuration Validation

起動時に設定全体を検証し、不正な設定がある場合は起動を失敗させる。

検証対象:

- Duplicate Names
- Unknown Source
- Unknown Destination
- Invalid Filter Operator
- Invalid URL
- Invalid Timeout
- Invalid Retry Configuration
- Invalid Environment Variable Reference
- Unsupported Adapter Type

---

## 19. CLI

標準 CLI 名は仮に `router` とする。

### 19.1 Run

```bash
router run --config router.toml
```

### 19.2 Validate

```bash
router validate --config router.toml
```

### 19.3 Dead Letter

```bash
router dead list
router dead retry <delivery-id>
router dead delete <delivery-id>
```

### 19.4 Status

将来的に以下を検討する。

```bash
router status
router events list
router deliveries list
```

---

## 20. Observability

### 20.1 Logs

構造化ログを出力する。

最低限以下を含める。

- event_id
- delivery_id
- source
- event_type
- destination
- attempt
- result
- latency
- error

### 20.2 Metrics

Prometheus 互換形式での Metrics Export を推奨する。

候補:

```text
events_received_total
events_rejected_total
deliveries_total
deliveries_success_total
deliveries_retry_total
deliveries_dead_total
delivery_latency_seconds
pending_deliveries
```

### 20.3 Health Endpoints

```http
GET /health
GET /ready
```

を提供する。

---

## 21. OTP / Process Architecture

Gleam / OTP を活用し、部分障害を隔離する。

概念構成:

```text
RootSupervisor
│
├── HttpServer
│
├── EventStore
│
├── RouteManager
│
└── DeliverySupervisor
     ├── DeliveryWorker
     ├── DeliveryWorker
     ├── DeliveryWorker
     └── ...
```

または Destination 単位で Worker を管理する構成を検討する。

```text
RootSupervisor
│
├── IngressSupervisor
│    └── HTTP
│
├── RoutingEngine
│
├── Storage
│
└── DestinationSupervisor
     ├── ci
     ├── audit
     └── notification
```

最終的な Process Granularity は性能試験後に決定する。

### 21.1 Failure Isolation

ある Destination への配送 Worker が Crash しても、他 Destination の処理へ影響を与えない構成とする。

### 21.2 Recovery

起動時に SQLite 上の未完了 Delivery を取得し、配送処理を再開する。

---

## 22. Suggested Gleam Modules

例:

```text
src/
├── app.gleam
├── config/
│   ├── config.gleam
│   └── decoder.gleam
├── event/
│   ├── event.gleam
│   └── value.gleam
├── ingress/
│   └── http.gleam
├── routing/
│   ├── route.gleam
│   ├── filter.gleam
│   └── engine.gleam
├── destination/
│   ├── destination.gleam
│   └── http.gleam
├── delivery/
│   ├── delivery.gleam
│   ├── dispatcher.gleam
│   ├── retry.gleam
│   └── worker.gleam
├── storage/
│   ├── storage.gleam
│   └── sqlite.gleam
├── security/
│   └── hmac.gleam
├── metrics/
│   └── metrics.gleam
└── cli/
    └── cli.gleam
```

実装時に過剰な Layering は避ける。

---

## 23. Deployment

### 23.1 Supported Initial Deployment

- Docker / OCI Container
- Linux VM
- On-Premise Server

### 23.2 Minimal Runtime Layout

```text
event-router
router.toml
router.db
```

または Container 環境では:

```text
/config/router.toml
/data/router.db
```

### 23.3 Example Container Usage

```bash
docker run \
  -p 8080:8080 \
  -v ./router.toml:/app/router.toml:ro \
  -v ./data:/data \
  event-router
```

---

## 24. Operational Requirements

### 24.1 No Mandatory External Services

v0.1 は以下を要求しない。

- Redis
- PostgreSQL
- Kafka
- NATS
- Kubernetes
- Cloud Account

### 24.2 Offline Operation

Internet Connection なしで起動、設定、配送、再配送、監視が可能であること。

ただし Destination 自体が Internet 上にある場合、その通信は当然必要となる。

### 24.3 Graceful Shutdown

終了時は新規 Event の受付を停止し、進行中の Storage Transaction を安全に終了する。

可能な範囲で進行中 Delivery の状態を永続化する。

---

## 25. Scalability Boundaries

本ツールは軽量 Event Router であり、巨大 Streaming Platform を目的としない。

v0.1 では Single Node を正式サポート範囲とする。

以下の要件が主になる場合は Kafka 等を推奨する。

- 数百 MB/s 級の Event Stream
- 数億 Event の長期保持
- Partition Ordering
- Consumer Groups
- Offset Management
- Stream Processing
- Distributed Log

---

## 26. Future Roadmap

### v0.1

- HTTP Ingress
- HTTP Destination
- Routing
- Filtering
- Fan-out
- Retry
- Dead Letter
- SQLite
- HMAC
- CLI
- Metrics

### v0.2

候補:

- MQTT Adapter
- NATS Adapter
- Retry-After support
- Better CLI inspection
- Event transformation
- Configuration hot reload

### v0.3

候補:

- SQS Adapter
- Kafka Adapter
- WebSocket / SSE Adapter
- PostgreSQL Optional Backend
- Basic Replay
- HA Design Exploration

---

## 27. Event Transformation

v0.1 では大規模な Transform Engine は実装しない。

ただし将来的には、異なる外部 Event Format を共通 Event Model へ正規化する Adapter Layer を提供する。

```text
System A ─┐
           ├──▶ Normalizer ──▶ Canonical Event
System B ─┘
```

任意スクリプト実行ではなく、宣言的な field mapping を優先する。

例:

```toml
[transform]
event_type_from = "event"
map."orderNo" = "order_id"
```

詳細仕様は v0.2 以降で定義する。

---

## 28. Project Positioning

本プロジェクトの想定ポジション:

```text
             Large / Complex
                   ▲
                   │
             Kafka / Camel
                   │
        ┌──────────┴──────────┐
        │                     │
        │    Event Router     │
        │                     │
        │ routing             │
        │ filtering           │
        │ retry               │
        │ fan-out             │
        │ adapters            │
        │ small persistence   │
        │                     │
        └──────────┬──────────┘
                   │
              Webhook Script
                   │
                   ▼
              Small / Simple
```

主なターゲットユーザーは以下とする。

> 小さな Webhook Server や個別 Integration では管理が辛くなったが、Kafka、Apache Camel、Cloud Event Bus を導入するほどではない利用者。

---

## 29. Product Definition

本プロジェクトを一文で表す。

> A lightweight, reliable, self-hosted event router built with Gleam and BEAM, designed for cloud, on-premise, and edge environments.

日本語:

> Gleam / BEAM で構築された、クラウド・オンプレミス・エッジ環境向けの軽量かつ信頼性の高い self-hosted Event Router。

---

## 30. Open Decisions

実装開始前または初期実装中に以下を決定する。

- プロジェクト正式名称
- CLI Command 名
- UUID v7 / ULID の選択
- JSON Value の内部表現
- HTTP Server Library
- SQLite Library
- TOML Parser
- HMAC 実装
- Delivery Worker の Process Granularity
- Event / Delivery retention policy
- Source authentication model
- Destination secrets management
- Prometheus Metrics の実装方式
- Configuration hot reload の要否
- Event Payload Size のデフォルト上限
- Delivery concurrency のデフォルト値
- 同一 Event / Destination の deduplication 詳細
